// BetterNotes – Helfer für „Claude fragen“ (läuft am Mac im Hintergrund, gestartet von launchd).
//
// Wartet über einen WebSocket am Notizbuch-Server auf neue Fragen aus der App. Für jede Frage:
// übernehmen, Bilder (und das PDF des Dokuments) laden, Claude Code im Chat dieses Dokuments fragen
// (claude -p, je Dokument ein eigener, fortgesetzter Chat), Antwort an den Server schicken.
//
// Der Schlüssel des Servers steht nur in config.json (Rechte 600). Er wird nie ausgegeben, nie geloggt
// und nie an Claude weitergegeben: Claude bekommt nur das Werkzeug Read und den Ordner des Dokuments.
//
// Braucht Node 18 oder neuer; ab Node 22 kommt eine neue Frage sofort an (WebSocket), sonst spätestens
// nach 30 Sekunden.

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const HOME = process.env.BETTERNOTES_HELFER_HOME ||
  path.join(os.homedir(), "Library", "Application Support", "BetterNotes-Helfer");
const CONFIG_FILE = path.join(HOME, "config.json");
const STATE_FILE = path.join(HOME, "state.json");
const LOG_FILE = path.join(HOME, "helfer.log");
const CHATS = path.join(HOME, "chats");

const DEFAULTS = {
  // Aufwand je Menüpunkt: „Claude fragen“ = quick, „Claude gründlich fragen“ = thorough
  quick: { effort: "medium", model: null, minutes: 15 },
  thorough: { effort: "max", model: null, minutes: 45 },
  // Rückfallabfrage, falls eine Meldung über den WebSocket verloren geht (Sekunden)
  pollSeconds: 300,
  // Nach einem Fehler am Mac: neuer Versuch nach so vielen Sekunden; am Nutzungslimit mindestens so lange Pause
  retrySeconds: 60,
  minPauseSeconds: 60,
};

// ---------- Protokoll ----------

function log(...parts) {
  const line = `${new Date().toISOString()} ${parts.join(" ")}\n`;
  try {
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 1_000_000) fs.renameSync(LOG_FILE, LOG_FILE + ".1");
    fs.appendFileSync(LOG_FILE, line);
  } catch {}
  if (process.env.BETTERNOTES_HELFER_ECHO) process.stdout.write(line);
}

// ---------- Konfiguration und Zustand ----------

function loadConfig() {
  const raw = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  if (!raw.url || !raw.key || !raw.claude) throw new Error("config.json braucht url, key und claude");
  return {
    ...DEFAULTS,
    ...raw,
    url: String(raw.url).replace(/\/+$/, ""),
    quick: { ...DEFAULTS.quick, ...(raw.quick || {}) },
    thorough: { ...DEFAULTS.thorough, ...(raw.thorough || {}) },
  };
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  } catch {
    return { docs: {} };
  }
}

function saveState(state) {
  const tmp = STATE_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, STATE_FILE);
}

const config = loadConfig();
const state = loadState();
state.docs = state.docs || {};

// ---------- Server ----------

class HTTPError extends Error {
  constructor(status, body) {
    super(`HTTP ${status}`);
    this.status = status;
    this.body = body;
  }
}

async function api(method, p, { json, timeout = 60000 } = {}) {
  const headers = { Authorization: `Bearer ${config.key}` };
  let body;
  if (json !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(json);
  }
  const res = await fetch(config.url + p, { method, headers, body, signal: AbortSignal.timeout(timeout) });
  const type = res.headers.get("content-type") || "";
  const data = type.includes("json") ? await res.json().catch(() => null) : Buffer.from(await res.arrayBuffer());
  if (!res.ok) throw new HTTPError(res.status, data);
  return { data, type };
}

// ---------- Warten auf Fragen ----------

let socket = null;
let socketAlive = 0; // Zeit des letzten Lebenszeichens (oder des Verbindungsversuchs)
let reconnectDelay = 5;
let pausedUntil = 0; // Nutzungslimit von Claude: bis dahin nichts übernehmen
let oldServer = false;

function connect() {
  if (typeof WebSocket === "undefined") return; // Node < 22: nur Abfragen (alle 30 s)
  const url = config.url.replace(/^http/, "ws") + "/api/asks/ws";
  let ws;
  try {
    ws = new WebSocket(url, { headers: { Authorization: `Bearer ${config.key}` } });
  } catch (e) {
    log("WebSocket geht nicht:", e.message);
    return;
  }
  socket = ws;
  socketAlive = Date.now();
  ws.addEventListener("open", () => {
    if (socket !== ws) return;
    reconnectDelay = 5;
    socketAlive = Date.now();
    log("verbunden");
    wake("verbunden");
  });
  ws.addEventListener("message", (e) => {
    if (socket !== ws) return;
    socketAlive = Date.now();
    if (typeof e.data !== "string" || e.data === "pong") return;
    let msg;
    try {
      msg = JSON.parse(e.data);
    } catch {
      return;
    }
    if (msg.type === "ask") wake("neue Frage");
    else if (msg.type === "cancel" && typeof msg.id === "string") cancel(msg.id);
  });
  const closed = () => {
    if (socket !== ws) return;
    socket = null;
    setTimeout(connect, reconnectDelay * 1000);
    reconnectDelay = Math.min(reconnectDelay * 2, oldServer ? 600 : 60);
  };
  ws.addEventListener("close", closed);
  ws.addEventListener("error", closed);
}

// Lebenszeichen alle 30 s; kommt 20 s lang keine Antwort (Mac war im Ruhezustand, WLAN gewechselt), neu verbinden
let lastTick = Date.now();
setInterval(() => {
  const now = Date.now();
  const slept = now - lastTick > 60000;
  lastTick = now;
  if (slept) log("aufgewacht");
  // Verbunden: ping; hängt die Verbindung (oder schon der Aufbau), neu verbinden
  if (socket && socket.readyState <= 1) {
    if (slept || now - socketAlive > 50000) {
      log("keine Verbindung mehr, neu verbinden");
      const old = socket;
      socket = null;
      try {
        old.close();
      } catch {}
      connect();
    } else if (socket.readyState === 1) {
      try {
        socket.send("ping");
      } catch {}
    }
  }
  if (slept) wake("aufgewacht");
}, 30000);

// Nächstes Nachsehen: regelmäßig als Rückfall (mit WebSocket selten, ohne alle 30 s), früher, wenn eine
// zurückgestellte Frage fällig wird oder die Pause am Nutzungslimit endet
let pollTimer = null;
let pollAt = Infinity;
function pollBy(at) {
  if (at >= pollAt) return;
  pollAt = at;
  clearTimeout(pollTimer);
  pollTimer = setTimeout(() => {
    pollAt = Infinity;
    wake("Zeit");
  }, Math.max(0, at - Date.now()));
}

// ---------- Abarbeiten ----------

let running = false;
let again = false;
let current = null; // { id, child, cancelled }

function wake(why) {
  if (running) {
    again = true;
    return;
  }
  running = true;
  (async () => {
    do {
      again = false;
      try {
        await work(why);
      } catch (e) {
        log("Fehler:", e.message);
      }
    } while (again);
    running = false;
  })();
}

async function work(why) {
  clearTimeout(pollTimer);
  pollAt = Infinity;
  pollBy(Date.now() + (typeof WebSocket === "undefined" ? 30 : config.pollSeconds) * 1000);
  if (Date.now() < pausedUntil) {
    pollBy(pausedUntil + 500);
    return;
  }
  let open;
  try {
    open = (await api("GET", "/api/asks/open")).data;
    if (oldServer) log("Server kennt die Fragen jetzt");
    oldServer = false;
  } catch (e) {
    if (e.status === 404 && !e.body?.code) {
      if (!oldServer) log("Der Server kennt „Claude fragen“ noch nicht (Server-Update nötig)");
      oldServer = true;
      clearTimeout(pollTimer);
      pollAt = Infinity;
      pollBy(Date.now() + 600000);
      return;
    }
    throw e;
  }
  if (open.next != null) pollBy(Date.now() + (open.next + 1) * 1000);
  for (const ask of open.asks || []) {
    if (Date.now() < pausedUntil) {
      pollBy(pausedUntil + 500);
      return;
    }
    // Danach die Liste neu holen: Inzwischen kamen vielleicht Fragen dazu oder eine wurde zurückgestellt
    if (await answer(ask)) again = true;
  }
}

function cancel(id) {
  if (current && current.id === id) {
    log(id, "Markierung gelöscht, breche ab");
    current.cancelled = true;
    stop(current.child);
  }
}

function stop(child) {
  if (!child || child.exitCode !== null) return;
  child.kill("SIGTERM");
  setTimeout(() => {
    if (child.exitCode === null) child.kill("SIGKILL");
  }, 5000);
}

async function answer(ask) {
  const level = ask.effort === "thorough" ? config.thorough : config.quick;
  const lease = Math.max(900, level.minutes * 60 + 300);
  let job;
  try {
    job = (await api("POST", `/api/asks/${ask.id}/claim`, { json: { lease } })).data;
  } catch (e) {
    if (e.status === 404 || e.status === 409) return false; // gelöscht, schon vergeben oder aufgegeben
    throw e;
  }
  const title = job.doc.title || "Dokument";
  log(ask.id, `übernommen: „${title}“, Seite ${job.anchor.page + 1}, ${ask.effort === "thorough" ? "gründlich" : "schnell"}`);
  const t0 = Date.now();
  // Frist verlängern, solange Claude arbeitet
  const renew = setInterval(() => {
    api("POST", `/api/asks/${ask.id}/claim`, { json: { lease, claim: job.claim } }).catch(() => {});
  }, 300000);
  current = { id: ask.id, child: null, cancelled: false };
  try {
    const dir = path.join(CHATS, job.doc.id);
    const files = await fetchFiles(job, dir);
    if (current.cancelled) return;
    const result = await askClaude(job, dir, files, level);
    if (current.cancelled) return;
    if (result.ok) {
      await reply(ask.id, { claim: job.claim, markdown: result.text });
      log(ask.id, `beantwortet nach ${Math.round((Date.now() - t0) / 1000)} s (${result.text.length} Zeichen)`);
    } else if (result.limit) {
      pausedUntil = result.retryAt;
      const at = new Date(result.retryAt).toLocaleTimeString("de-AT", { hour: "2-digit", minute: "2-digit" });
      await reply(ask.id, {
        claim: job.claim, release: true, retryAfter: Math.ceil((result.retryAt - Date.now()) / 1000),
        note: `Claude-Limit erreicht, neuer Versuch um ${at}`,
      });
      log(ask.id, `Nutzungslimit, zurückgestellt bis ${at}`);
    } else {
      const tries = (state.failures?.[ask.id] || 0) + 1;
      state.failures = { ...(state.failures || {}), [ask.id]: tries };
      saveState(state);
      if (tries < 2 && !result.timeout) {
        await reply(ask.id, {
          claim: job.claim, release: true, retryAfter: config.retrySeconds, note: "Fehler am Mac, neuer Versuch",
        });
        log(ask.id, `Fehler, neuer Versuch in ${config.retrySeconds} s:`, result.error);
      } else {
        await reply(ask.id, { claim: job.claim, error: result.error });
        log(ask.id, "gescheitert:", result.error);
      }
    }
  } catch (e) {
    if (current.cancelled) return;
    log(ask.id, "Fehler:", e.message);
    // Zurück in die Warteschlange; die Frist des Servers fängt den Rest ab
    await reply(ask.id, { claim: job.claim, release: true, retryAfter: 120, note: "Fehler am Mac, neuer Versuch" })
      .catch(() => {});
  } finally {
    clearInterval(renew);
    current = null;
  }
  return true;
}

async function reply(id, body) {
  for (let attempt = 0; ; attempt++) {
    try {
      await api("PUT", `/api/asks/${id}/answer`, { json: body });
      return;
    } catch (e) {
      // gelöscht (404) oder inzwischen neu vergeben (409): Diese Antwort verfällt
      if (e.status === 404 || e.status === 409) {
        log(id, e.status === 404 ? "inzwischen gelöscht" : "inzwischen neu vergeben");
        return;
      }
      // Netz weg: noch zweimal versuchen, damit die Antwort nicht verloren geht
      if (attempt >= 2 || (e.status && e.status < 500)) throw e;
      await new Promise((r) => setTimeout(r, attempt ? 30000 : 5000));
    }
  }
}

// ---------- Dateien für Claude ----------

async function fetchFiles(job, dir) {
  const qdir = path.join(dir, "fragen", job.id);
  fs.mkdirSync(qdir, { recursive: true });
  const files = {};
  for (const name of ["question", "page"]) {
    const { data, type } = await api("GET", `/api/asks/${job.id}/${name}`, { timeout: 120000 });
    const file = path.join(qdir, (name === "question" ? "frage" : "seite") + (type.includes("png") ? ".png" : ".jpg"));
    fs.writeFileSync(file, data);
    files[name] = path.relative(dir, file);
  }
  const doc = (state.docs[job.doc.id] = state.docs[job.doc.id] || {});
  const pdf = path.join(dir, "dokument.pdf");
  if (job.doc.hasPDF && (doc.pdfVersion !== job.doc.pdfVersion || !fs.existsSync(pdf))) {
    const { data } = await api("GET", `/api/pdf/${job.doc.id}`, { timeout: 300000 });
    fs.writeFileSync(pdf, data);
    doc.pdfChanged = doc.pdfVersion !== undefined;
    doc.pdfVersion = job.doc.pdfVersion;
    saveState(state);
  }
  files.pdf = job.doc.hasPDF && fs.existsSync(pdf) ? "dokument.pdf" : null;
  return files;
}

// ---------- Claude ----------

const SYSTEM = `Du beantwortest Fragen, die Mathias in seiner Notizbuch-App (BetterNotes) auf dem iPad oder iPhone \
handschriftlich zu einem Dokument stellt. Er markiert die Frage mit dem Lasso und wählt „Claude fragen“. Deine Antwort \
erscheint in der App als Markierung neben der Frage; tippt er sie an, liest er sie dort.

So gehst du vor:
- Sieh dir zuerst mit dem Werkzeug Read das Bild der Frage an, dann die ganze Seite, auf der sie steht (die Frage ist \
dort farbig umrandet). Lies das Dokument (dokument.pdf, falls vorhanden), soweit es für die Antwort hilft.
- Antworte in der Sprache der Frage, direkt und ohne Einleitung. Stell keine Rückfragen: Ist etwas unklar oder \
unleserlich, sag kurz, wie du es gelesen hast, und antworte darauf.
- Format: Markdown. Formeln in LaTeX, $…$ im Text und $$…$$ abgesetzt. Kein HTML, keine Bilder, keine Links und \
keine Dateinamen oder Pfade.
- Beziehe dich auf das Dokument (Seite, Satz, Gleichung), wo es hilft.
- Spätere Fragen in diesem Chat gehören zum selben Dokument; frühere Fragen und Antworten kannst du voraussetzen.`;

function prompt(job, files, fresh) {
  const kind = job.doc.kind === "pdf" ? "PDF" : "Notizbuch";
  const pages = job.doc.pageCount ? ` mit ${job.doc.pageCount} Seiten` : "";
  const doc = state.docs[job.doc.id] || {};
  const lines = [];
  if (fresh) {
    lines.push(`Dokument: „${job.doc.title || "ohne Titel"}“ (${kind}${pages}).`);
    if (files.pdf) lines.push(`Das ganze Dokument liegt in ${files.pdf}.`);
    lines.push("");
    lines.push("Frage:");
  } else {
    if (doc.pdfChanged && files.pdf) lines.push(`Das PDF wurde seit der letzten Frage geändert; ${files.pdf} ist neu.`);
    lines.push(`Neue Frage zum selben Dokument${job.doc.title ? ` („${job.doc.title}“)` : ""}:`);
  }
  lines.push(`- ${files.question}: die handgeschriebene Frage`);
  lines.push(`- ${files.page}: die ganze Seite ${job.anchor.page + 1}, die Frage darauf farbig umrandet`);
  lines.push("");
  lines.push(
    job.effort === "thorough"
      ? "Antworte gründlich: mit Begründung oder Beweisskizze und, wo es hilft, einem Beispiel."
      : "Antworte knapp: das Wesentliche in wenigen Sätzen.",
  );
  return lines.join("\n");
}

async function askClaude(job, dir, files, level) {
  const doc = (state.docs[job.doc.id] = state.docs[job.doc.id] || {});
  for (let attempt = 0; attempt < 2; attempt++) {
    const fresh = !doc.session;
    const session = doc.session || randomUUID();
    const args = [
      "-p", prompt(job, files, fresh),
      "--output-format", "json",
      "--tools", "Read",
      "--allowedTools", "Read",
      "--strict-mcp-config",
      "--append-system-prompt", SYSTEM,
      "--max-turns", "30",
      ...(fresh ? ["--session-id", session] : ["--resume", session]),
      ...(level.effort ? ["--effort", level.effort] : []),
      ...(level.model ? ["--model", level.model] : []),
    ];
    const run = await runClaude(args, dir, level.minutes);
    if (current?.cancelled) return { ok: false, error: "abgebrochen" };
    const parsed = parseResult(run);
    // Chat gibt es nicht mehr (etwa nach 30 Tagen von Claude Code aufgeräumt): neuen anfangen
    if (!fresh && !parsed.ok && /no conversation found|session.*not found/i.test(parsed.error || "")) {
      log(job.id, "alter Chat nicht mehr da, neuer Chat");
      delete doc.session;
      continue;
    }
    if (parsed.ok || parsed.sessionUsed) {
      doc.session = session;
      doc.title = job.doc.title;
      doc.pdfChanged = false;
      saveState(state);
    }
    return parsed;
  }
  return { ok: false, error: "Chat konnte nicht fortgesetzt werden" };
}

function runClaude(args, cwd, minutes) {
  return new Promise((resolve) => {
    // Keine Werte des Helfers an Claude weitergeben
    const env = { ...process.env };
    for (const k of Object.keys(env)) if (/^(NOTIZBUCH|BETTERNOTES)_/i.test(k)) delete env[k];
    fs.mkdirSync(cwd, { recursive: true });
    const child = spawn(config.claude, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    if (current) current.child = child;
    let out = "", err = "", timedOut = false;
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    const timer = setTimeout(() => {
      timedOut = true;
      stop(child);
    }, minutes * 60000);
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ code: -1, out, err: err + e.message, timedOut });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, out, err, timedOut });
    });
  });
}

function parseResult({ code, out, err, timedOut }) {
  if (timedOut) return { ok: false, timeout: true, error: "Claude hat zu lange gebraucht." };
  let r = null;
  try {
    r = JSON.parse(out.trim().split("\n").pop());
  } catch {}
  const text = typeof r?.result === "string" ? r.result.trim() : "";
  if (r && !r.is_error && r.subtype === "success" && text) return { ok: true, text, sessionUsed: true };
  const message = (text || err || out || `Exit ${code}`).trim().slice(-500);
  if (/usage limit|limit reached|hit your limit|rate.?limit|out of (extra )?usage/i.test(message)) {
    // „…|1763305200“ (Ende des Limits als Unix-Zeit) oder „resets 5pm“: im Zweifel in 30 Minuten
    const ts = message.match(/\|(\d{10})\b/);
    const retryAt = ts ? Number(ts[1]) * 1000 + 60000 : Date.now() + 1800000;
    return { ok: false, limit: true, retryAt: Math.max(retryAt, Date.now() + config.minPauseSeconds * 1000), error: message };
  }
  return { ok: false, error: `Claude am Mac: ${message}`, sessionUsed: !!r?.session_id };
}

// ---------- Aufräumen ----------

// Bilder von Fragen, die älter als 60 Tage sind (die Chats behalten sie ohnehin)
function prune() {
  const limit = Date.now() - 60 * 86400000;
  try {
    for (const doc of fs.readdirSync(CHATS)) {
      const q = path.join(CHATS, doc, "fragen");
      if (!fs.existsSync(q)) continue;
      for (const id of fs.readdirSync(q)) {
        const p = path.join(q, id);
        if (fs.statSync(p).mtimeMs < limit) fs.rmSync(p, { recursive: true, force: true });
      }
    }
  } catch {}
  if (state.failures && Object.keys(state.failures).length > 200) {
    state.failures = {};
    saveState(state);
  }
}

// ---------- Start ----------

process.on("uncaughtException", (e) => {
  log("Absturz:", e.message);
  process.exit(1); // launchd startet neu
});
process.on("unhandledRejection", (e) => {
  log("Absturz:", e?.message || String(e));
  process.exit(1);
});
process.on("SIGTERM", () => {
  if (current?.child) stop(current.child);
  log("beendet");
  process.exit(0);
});

fs.mkdirSync(CHATS, { recursive: true });
log(`gestartet (Node ${process.versions.node}${typeof WebSocket === "undefined" ? ", ohne WebSocket: Abfrage alle 30 s" : ""})`);
prune();
connect();
wake("Start");
