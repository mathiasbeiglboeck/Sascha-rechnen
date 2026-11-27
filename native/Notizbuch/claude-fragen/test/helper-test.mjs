// Test des Helfers von Anfang bis Ende: lokaler Server (Wegwerf-Schlüssel, nie der echte) + helfer.mjs + fake-claude
// statt Claude Code + fake-osascript statt macOS. Läuft auch unter Linux:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/claude-fragen/test/helper-test.mjs
// Die weiteren Seiten zum Nachlesen brauchen für PDFs poppler (pdfinfo, pdftoppm, pdfimages; macOS: brew install poppler)
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const S = path.dirname(fileURLToPath(import.meta.url));
const BASE = process.env.BASE || "http://127.0.0.1:8791";
const KEY = process.env.KEY || "testkey";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
const H = { Authorization: `Bearer ${KEY}` };
const HELFER = process.env.HELFER || path.join(S, "..", "helfer.mjs");
// realpath: Am Mac ist os.tmpdir() ein Verweis (/var → /private/var), Claude sieht aber den echten Pfad
const TMP = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), "bn-helfer-test-"));
const HOME = path.join(TMP, "home");
const FAKE = path.join(TMP, "fake");
const FAKE_CLAUDE = path.join(S, "fake-claude"), FAKE_OSASCRIPT = path.join(S, "fake-osascript");
let passes = 0, failures = 0;
const ok = (c, m, x) => { if (c) { passes++; console.log("  ok  ", m); } else { failures++; console.log("  FAIL", m, x !== undefined ? JSON.stringify(x).slice(0, 500) : ""); } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const uuid = () => crypto.randomUUID().toUpperCase();
const setMode = (m) => fs.writeFileSync(path.join(FAKE, "mode.json"), JSON.stringify(m));
const calls = () => { try { return fs.readFileSync(path.join(FAKE, "calls.jsonl"), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };

async function api(method, p, { json, body, headers } = {}) {
  const h = { ...H, ...(headers || {}) };
  let b = body;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + p, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, data: ct.includes("json") ? await r.json() : await r.arrayBuffer() };
}
const PNG = () => { const b = new Uint8Array(1000); b.set([0x89, 0x50, 0x4e, 0x47]); return b; };
const JPG = () => { const b = new Uint8Array(3000); b.set([0xff, 0xd8, 0xff, 0xe0]); return b; };
// ctx: die Seiten um die Frage wie von der App ({ span, pages, bytes }: Bereich und beschriebene Seiten ab 0, das PDF),
// dazu wahlweise pv (Seitenstand der Frage) und created (Zeitpunkt des Fragens, Sekunden)
const CTX_PDF = (n) => { const b = new Uint8Array(n); b.set([0x25, 0x50, 0x44, 0x46, 0x2d]); return b; };
async function createAsk(doc, effort = "quick", page = 1, ctx = null) {
  const id = uuid();
  const f = new FormData();
  f.append("meta", JSON.stringify({ anchor: { page, x: 10, y: 20, w: 100, h: 30 }, pv: ctx?.pv || 0, effort, created: ctx?.created || Date.now() / 1000, from: "iPad", ...(ctx?.span ? { span: ctx.span, pages: ctx.pages } : {}), ...(ctx?.mode ? { mode: ctx.mode } : {}) }));
  f.append("question", new Blob([PNG()], { type: "image/png" }), "question.png");
  f.append("page", new Blob([JPG()], { type: "image/jpeg" }), "page.jpg");
  if (ctx?.bytes) f.append("pages", new Blob([CTX_PDF(ctx.bytes)], { type: "application/pdf" }), "pages.pdf");
  const r = await api("PUT", `/api/doc/${doc}/asks/${id}`, { body: f });
  if (r.status !== 200) throw new Error("create " + r.status + JSON.stringify(r.data));
  return { id, t: Date.now() };
}
const askOf = async (doc, id) => (await api("GET", `/api/doc/${doc}/asks`)).data.asks.find((a) => a.id === id);
async function waitFor(fn, ms, step = 100) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const v = await fn(); if (v) return v; await sleep(step); }
  return null;
}

/// Zwischen Helfer und Server: reicht alles durch (auch den WebSocket) und merkt sich jede Anfrage („GET /api/…“ in
/// seen). intercept(req) kann stattdessen [Status, Inhalt] liefern (Text oder JSON); er lässt sich später austauschen
async function startProxy(intercept = () => null) {
  const p = { seen: [], intercept };
  const server = http.createServer(async (req, res) => {
    p.seen.push(`${req.method} ${req.url}`);
    const own = p.intercept(req);
    if (own) {
      const [status, body] = own;
      res.writeHead(status, { "content-type": typeof body === "string" ? "text/plain" : "application/json" })
        .end(typeof body === "string" ? body : JSON.stringify(body));
      return;
    }
    const chunks = [];
    for await (const x of req) chunks.push(x);
    const skip = new Set(["host", "connection", "content-length", "transfer-encoding"]);
    const up = await fetch(BASE + req.url, { method: req.method, headers: Object.fromEntries(Object.entries(req.headers).filter(([k]) => !skip.has(k))), body: chunks.length ? Buffer.concat(chunks) : undefined });
    res.writeHead(up.status, Object.fromEntries([...up.headers].filter(([k]) => !skip.has(k) && k !== "content-encoding")));
    res.end(Buffer.from(await up.arrayBuffer()));
  });
  server.on("upgrade", (req, socket, head) => {
    const target = new URL(BASE);
    const up = net.connect(Number(target.port), target.hostname, () => {
      up.write(`${req.method} ${req.url} HTTP/1.1\r\n${Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join("\r\n")}\r\n\r\n`);
      if (head.length) up.write(head);
      socket.pipe(up).pipe(socket);
    });
    up.on("error", () => socket.destroy());
    socket.on("error", () => up.destroy());
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  p.url = `http://127.0.0.1:${server.address().port}`;
  p.close = () => {
    server.close();
    server.closeAllConnections?.();
  };
  return p;
}

let helper = null;
const setHelp = (version) => fs.writeFileSync(path.join(FAKE, "help.json"), JSON.stringify({ version }));
const setPages = (cfg) => fs.writeFileSync(path.join(FAKE, "pages.json"), JSON.stringify(cfg));
const writeConfig = (extra = {}) => fs.writeFileSync(path.join(HOME, "config.json"), JSON.stringify({ url: BASE, key: KEY, claude: FAKE_CLAUDE, retrySeconds: 3, minPauseSeconds: 4, readyCheckSeconds: 2, pollSeconds: 300, ...extra }), { mode: 0o600 });
const logText = () => fs.readFileSync(path.join(HOME, "helfer.log"), "utf8");
const promptOf = (c) => c.args[c.args.indexOf("-p") + 1];
const systemOf = (c) => c.args[c.args.indexOf("--append-system-prompt") + 1];
// Wert einer Option, und das Argument danach ist wieder eine Option (eine Liste nimmt nichts Fremdes mit)
const optOf = (c, f) => (c.args.includes(f) && String(c.args[c.args.indexOf(f) + 2]).startsWith("--") ? c.args[c.args.indexOf(f) + 1] : undefined);
// Endet der Test vorzeitig (abgebrochen, Zeitlimit), darf der Helfer nicht weiterlaufen
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => { helper?.kill("SIGTERM"); process.exit(130); });
process.on("exit", () => helper?.kill("SIGTERM"));
// script: ein anderes helfer.mjs (die Kopie ohne weitere-seiten.mjs). KEY dieses Tests bekommt der Helfer nicht mit: Er
// liest den Schlüssel aus config.json, und so fiele er auf, wenn er doch in der Umgebung eines Programms landete
function startHelper(env = {}, script = HELFER) {
  const out = fs.openSync(path.join(TMP, "helfer.out"), "a");
  const { KEY: _key, ...outer } = process.env;
  helper = spawn(process.execPath, [script], {
    env: { ...outer, BETTERNOTES_HELFER_HOME: HOME, BETTERNOTES_HELFER_ECHO: "1", BETTERNOTES_HELFER_OSASCRIPT: FAKE_OSASCRIPT, FAKE_STATE: FAKE, NOTIZBUCH_KEY: "must-not-leak", NOTIZBUCH_URL: "x", ...env },
    stdio: ["ignore", out, out],
  });
}

async function main() {
  fs.rmSync(HOME, { recursive: true, force: true });
  fs.rmSync(path.join(FAKE, "calls.jsonl"), { force: true });
  fs.rmSync(path.join(FAKE, "sessions"), { recursive: true, force: true });
  fs.mkdirSync(FAKE, { recursive: true });
  fs.mkdirSync(HOME, { recursive: true });
  writeConfig();
  setMode({ mode: "ok" });
  setHelp("new");
  setPages({ n: 30 });

  // a PDF document
  const doc = uuid(), now = Date.now() / 1000;
  await api("PUT", `/api/library/${doc}`, { json: { id: doc, title: "Analysis 2 – Blatt 3", kind: "pdf", created: now, modified: now, pageCount: 4, pdfVersion: 7 } });
  const pdf = new TextEncoder().encode("%PDF-1.4\n" + "x".repeat(5000));
  await api("PUT", `/api/pdf/${doc}`, { body: pdf, headers: { "content-type": "application/pdf" } });
  const nb = uuid();
  await api("PUT", `/api/library/${nb}`, { json: { id: nb, title: "Notizen", kind: "notebook", created: now, modified: now, pageCount: 2 } });

  console.log("== helper starts, connects");
  startHelper();
  const connected = await waitFor(() => fs.existsSync(path.join(HOME, "helfer.log")) && fs.readFileSync(path.join(HOME, "helfer.log"), "utf8").includes("verbunden"), 10000);
  ok(connected, "helper connected over WebSocket");
  await sleep(300);

  console.log("== first question (quick): pushed at once, new chat");
  let a = await createAsk(doc, "quick", 2);
  let claimedAt = null;
  const answered = await waitFor(async () => { const x = await askOf(doc, a.id); if (x.status === "claimed" && !claimedAt) claimedAt = Date.now(); return x.status === "answered" ? x : null; }, 15000, 50);
  ok(answered, "answered", answered);
  ok(claimedAt && claimedAt - a.t < 1500, `claimed ${claimedAt - a.t} ms after creation (push, not poll)`);
  let c = calls().filter((x) => x.args).at(-1);
  const sid = c.args[c.args.indexOf("--session-id") + 1];
  ok(c.args.includes("--session-id") && !c.args.includes("--resume"), "first call starts a new session", c.args);
  ok(c.args[c.args.indexOf("--effort") + 1] === "medium" && optOf(c, "--tools") === "Read,WebSearch,WebFetch" && c.args.includes("--strict-mcp-config") && c.args[c.args.indexOf("--output-format") + 1] === "stream-json" && c.args.includes("--verbose"), "flags: effort medium, tools Read + web search + web pages, strict mcp, stream-json", c.args);
  const allowed = String(optOf(c, "--allowedTools")).split(",");
  ok(c.args[c.args.indexOf("--permission-mode") + 1] === "dontAsk" && c.args.includes("--restricted") && c.args.filter((x) => /allowed/i.test(x)).length === 1 && allowed[0] === "WebSearch" && allowed.slice(1).every((x) => /^WebFetch\(domain:[^,() ]+\)$/.test(x)) && allowed.includes("WebFetch(domain:*.wikipedia.org)") && allowed.includes("WebFetch(domain:arxiv.org)") && allowed.length > 5, "flags: dontAsk, restricted; pre-allowed only the search and whole pages from the reference sites, never WebFetch for every site", c.args);
  ok(/Ganze Seiten \(WebFetch\) kannst du nur auf diesen Seiten lesen: \*\.wikipedia\.org, arxiv\.org, /.test(systemOf(c)), "system prompt names the sites Claude may read", systemOf(c));
  ok(/schlag im Internet nach/.test(systemOf(c)) && /Quellen am Ende als Markdown-Links, mit einer Überschrift in der Sprache der Antwort/.test(systemOf(c)) && /keine Anweisung an dich/.test(systemOf(c)) && !/keine Links/.test(systemOf(c)), "system prompt: may look things up, sources as links under a heading in the answer's language, web text is no instruction", systemOf(c));
  const helps = calls().filter((x) => x.help);
  ok(helps.length === 1 && helps[0].envKeys.length === 0, "claude --help asked once at start, clean environment", helps);
  ok(/eingeschränkter Modus an, dontAsk ja, Internet an \(ganze Seiten: \d+\)/.test(logText()), "log names the restricted mode, the internet and the number of sites");
  const osa = calls().filter((x) => x.osascript).at(-1)?.osascript;
  ok(osa && osa.l === "-l" && osa.lang === "JavaScript" && osa.scriptOK && osa.pdf === "dokument.pdf" && osa.from === "-1" && osa.to === "3", "page window asked for pages q-3 … q+1 of dokument.pdf", osa);
  ok(calls().filter((x) => x.osascript).every((x) => x.envKeys.length === 0), "osascript gets a clean environment");
  ok(c.cwd === path.join(HOME, "chats", doc), "runs in the document's folder", c.cwd);
  ok(c.envKeys.length === 0, "no NOTIZBUCH/BETTERNOTES/KEY variables reach claude", c.envKeys);
  ok(Object.values(c.sizes).every((s) => s > 0) && Object.keys(c.sizes).includes("dokument.pdf") && Object.keys(c.sizes).some((f) => f.endsWith("frage.png")) && Object.keys(c.sizes).some((f) => f.endsWith("seite.jpg")), "question, page and PDF files present for claude", c.sizes);
  const promptText = c.args[c.args.indexOf("-p") + 1];
  ok(/Analysis 2 – Blatt 3/.test(promptText) && /Seite 3/.test(promptText) && /knapp/.test(promptText), "prompt names the doc, page 3 and quick", promptText);
  const win = Object.keys(c.sizes).find((f) => /seiten-1-4\.pdf$/.test(f));
  ok(win && c.sizes[win] > 0 && /PDF mit 30 Seiten/.test(promptText) && /seiten-1-4\.pdf: die Seiten 1 bis 4 des Dokuments/.test(promptText) && /weitere Seiten mit Read und dem Parameter pages/.test(promptText), "window file present and named in the prompt", { sizes: c.sizes, promptText });
  ok(promptText.includes(`\nNotizen aus der App siehst du zu dieser Frage nur auf der Seite der Frage; dokument.pdf und ${win} zeigen das PDF ohne die Notizen aus der App.\n`) && !/nachbarseiten/.test(promptText), "old app (no pages around the question): notes only on the question's page, both PDFs without them", promptText);
  ok(logText().includes(`${a.id} Unterlagen: ohne Nachbarseiten (nicht mitgeschickt oder Seiten seither gerückt), PDF-Fenster 1–4 von 30`), "log lists what Claude got", logText().split("\n").filter((l) => l.includes("Unterlagen")));
  ok(/Lies dann die übrigen Dateien, die die Nachricht zur Frage nennt \(die Seiten zum Nachlesen nur nach Bedarf, siehe den nächsten Punkt\), und bei einem PDF, soweit es für die Antwort hilft, weitere Seiten aus dokument\.pdf\. Rate keine Dateinamen/.test(systemOf(c)) && !/mehr vom Dokument/.test(systemOf(c)), "system prompt: read the other files the message names (the pages to look up only as needed), no guessing file names", systemOf(c));
  ok(/Bilder von Seiten zu früheren Fragen zeigen den Stand von damals/.test(systemOf(c)), "system prompt: page images of earlier questions are from back then", systemOf(c));
  ok(answered.answer.startsWith("Antwort (medium)"), "answer text stored", answered.answer);
  ok(!fs.readFileSync(path.join(HOME, "helfer.log"), "utf8").includes(KEY), "key never in the log");

  console.log("== second question (thorough): same chat resumed, PDF not downloaded again");
  const pdfMtime = fs.statSync(path.join(HOME, "chats", doc, "dokument.pdf")).mtimeMs;
  a = await createAsk(doc, "thorough", 0);
  const ans2 = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "answered" ? x : null; }, 15000);
  ok(ans2, "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(c.args[c.args.indexOf("--resume") + 1] === sid && c.args[c.args.indexOf("--effort") + 1] === "max", "resumes the same session with effort max", c.args);
  ok(/Neue Frage zum selben Dokument/.test(c.args[c.args.indexOf("-p") + 1]) && /gründlich/.test(c.args[c.args.indexOf("-p") + 1]), "follow-up prompt, thorough");
  ok(/seiten-1-3\.pdf: die Seiten 1 bis 3/.test(promptOf(c)) && calls().filter((x) => x.osascript).at(-1).osascript.from === "-7", "thorough window: up to 7 pages before, 2 after", promptOf(c));
  ok(fs.statSync(path.join(HOME, "chats", doc, "dokument.pdf")).mtimeMs === pdfMtime, "PDF cached");

  console.log("== Claude schreiben lassen: Auftrag in der Nachricht, Notizen an den Server");
  setMode({ mode: "write" });
  a = await createAsk(doc, "quick", 1, { mode: "write" });
  const wr = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "answered" ? x : null; }, 15000);
  c = calls().filter((x) => x.args).at(-1);
  ok(/Diesmal schreibst du ins Dokument/.test(promptOf(c)) && /```notizen/.test(promptOf(c)) && /das Dokument hat 30 Seiten/.test(promptOf(c)) && /Arbeite zügig/.test(promptOf(c)) && !/Antworte knapp/.test(promptOf(c)), "write: the task, the format, the page count, quick", promptOf(c));
  ok(wr && wr.mode === "write" && wr.answer === "Zwei Fehler am Rand markiert, die Lösung unter den Auftrag geschrieben.\n\n*(Eine Notiz stand auf einer Seite, die es nicht gibt, und fehlt.)*", "write: the speech bubble text without the block, saying that one note is missing", wr);
  ok(wr?.notes?.length === 3 && wr.notes[0].page === 1 && wr.notes[0].x === 0.84 && wr.notes[0].color === "red" && wr.notes[0].size === "small" && wr.notes[0].box[3] === 0.32 && wr.notes[1].page === 0 && wr.notes[1].text.includes("\\int_0^1"), "write: notes in fractions, page from 0, the one outside the document dropped", wr?.notes);
  // Die Seitenzahl gibt beim PDF das PDF (30), nicht der Server (4): Am 26.11. fielen so 13 von 14 Notizen weg
  ok(wr?.notes?.[2]?.page === 11 && wr.notes[2].text === "Index falsch", "write: a note on page 12 of the 30-page PDF stays although the server knows only 4 pages", wr?.notes);
  ok(/schreibt ins Dokument/.test(logText()) && /3 Notizen ins Dokument \(1 außerhalb des Dokuments weggelassen\)/.test(logText()), "write: logged", logText().split("\n").slice(-4));

  console.log("== Claude schreiben lassen im Notizbuch: Seitenzahl aus der Nachricht und eine leere Seite mehr");
  const wnb = uuid();
  await api("PUT", `/api/library/${wnb}`, { json: { id: wnb, title: "Übungen", kind: "notebook", created: now, modified: now, pageCount: 2 } });
  a = await createAsk(wnb, "quick", 0, { mode: "write" });
  const wn = await waitFor(async () => { const x = await askOf(wnb, a.id); return x.status === "answered" ? x : null; }, 15000);
  ok(wn?.notes?.length === 2 && wn.notes[0].page === 1 && wn.notes[1].page === 0, "write, notebook with 2 pages: notes on pages 1 and 2 stay, 12 and 40 go", wn?.notes);
  ok(wn?.answer?.endsWith("*(2 Notizen standen auf Seiten, die es nicht gibt, und fehlen.)*"), "write, notebook: the speech bubble says that two notes are missing", wn?.answer);
  ok(/2 Notizen ins Dokument \(2 außerhalb des Dokuments weggelassen\)/.test(logText()), "write, notebook: logged", logText().split("\n").slice(-4));

  console.log("== Claude schreiben lassen: Seiten ändern sich, während Claude schreibt: noch einmal, in einem neuen Chat");
  {
    const wpc = uuid();
    await api("PUT", `/api/library/${wpc}`, { json: { id: wpc, title: "Seitenwechsel", kind: "notebook", created: now, modified: now, pageCount: 6 } });
    setMode({ mode: "ok" });
    const first = await createAsk(wpc, "quick", 1);
    ok(await waitFor(async () => (await askOf(wpc, first.id)).status === "answered", 15000), "a first question opens the document's chat");
    const before = calls().filter((x) => x.args).length;
    setMode({ mode: "writePage", delayMs: 2500 });
    a = await createAsk(wpc, "quick", 1, { mode: "write" });
    ok(await waitFor(async () => (await askOf(wpc, a.id)).status === "claimed", 15000, 50), "claimed");
    // Eine Seite davor eingefügt: Die App verschiebt die Stelle (Seitenstand 1, Seite 3)
    const moved = await api("PATCH", `/api/doc/${wpc}/asks`, { json: { pv: 1, anchors: { [a.id]: { page: 2, x: 10, y: 20, w: 100, h: 30 } } } });
    ok(moved.status === 200, "page change while Claude writes", moved.status);
    setMode({ mode: "writePage" });
    const done = await waitFor(async () => { const x = await askOf(wpc, a.id); return x.status === "answered" ? x : null; }, 30000);
    const runs = calls().filter((x) => x.args).slice(before);
    ok(runs.length === 2 && runs[0].args.includes("--resume") && runs[1].args.includes("--session-id"), "Claude ran twice: first in the document's chat, then in a new chat", runs.map((r) => r.args.filter((x) => /^--(resume|session-id)$/.test(x))));
    ok(runs[1] && /die ganze Seite 3,/.test(promptOf(runs[1])) && /^Dokument: „Seitenwechsel“/.test(promptOf(runs[1])), "second run: fresh prompt, the question's page in the new numbering", runs[1] && promptOf(runs[1]).slice(0, 400));
    ok(done && done.pv === 1 && done.anchor.page === 2 && done.notes?.map((n) => n.page).join() === "2,3", "notes in the new numbering: under the question (page 3) and on the page after it", done && { pv: done.pv, anchor: done.anchor.page, notes: done.notes?.map((n) => n.page) });
    const lines = logText().split("\n").filter((l) => l.includes(a.id));
    ok(lines.some((l) => /Seiten haben sich geändert, während Claude schrieb: noch einmal, in einem neuen Chat/.test(l)) && lines.filter((l) => /beantwortet nach/.test(l)).length === 1, "logged: the refused run, then one answer", lines);
  }

  console.log("== Claude schreiben lassen: Grenzfälle der Notizen (nur ein Kasten, andere Schreibweisen, Codeblock, Grenzen des Servers)");
  {
    const edge = uuid();
    await api("PUT", `/api/library/${edge}`, { json: { id: edge, title: "Grenzfälle", kind: "notebook", created: now, modified: now, pageCount: 3 } });
    const writeAsk = async (mode) => {
      setMode({ mode });
      const x = await createAsk(edge, "quick", 0, { mode: "write" });
      return { id: x.id, done: await waitFor(async () => { const y = await askOf(edge, x.id); return y.status === "answered" ? y : null; }, 15000) };
    };
    const logOf = (id) => logText().split("\n").filter((l) => l.includes(id) && /beantwortet nach/.test(l)).join("\n");
    let w = await writeAsk("writeEdge");
    const n = w.done?.notes || [];
    ok(n.length === 3 && n[0].page === 0 && n[0].x === 0.1 && n[0].y === 0.2 && Math.abs(n[0].w - 0.2) < 1e-9 && n[0].text === "" && n[0].box?.join() === "0.1,0.2,0.3,0.25", "a note with only a box: kept, x and y from the box's corner", n[0]);
    ok(n[1]?.page === 1 && n[1].text === "Groß geschrieben" && n[1].color === "red" && n[1].x === 0.1 && n[1].w === 0.4, "keys in other spellings („Seite“, „Text“, „Farbe“) count", n[1]);
    ok(n[2]?.text === "Code:\n```python\nprint(1)\n```", "a note with a code block arrives whole (the block does not end at its ```)", n[2]);
    const bubble = w.done?.answer || "";
    ok(bubble.startsWith("Drei Notizen gesetzt.\n") && bubble.includes("Zum Format etwa:\n```json\n{\"seite\": 1, \"x\": 10}\n```") && bubble.endsWith("\n\n*(Eine Notiz war unvollständig und fehlt.)*") && !/```notizen|print\(1\)|Groß geschrieben|kasten/.test(bubble), "speech bubble: nothing of the notes leaks into it, a later ```json example does not replace them, the incomplete note is named", bubble);
    ok(/3 Notizen ins Dokument \(1 unvollständig weggelassen\)/.test(logOf(w.id)), "logged: one incomplete note left out", logOf(w.id));
    w = await writeAsk("writeMany");
    ok(w.done?.notes?.length === 100 && w.done.notes.at(-1).text === "Fehler 99" && w.done.answer.endsWith("*(50 Notizen passten nicht mehr ins Dokument und fehlen.)*"), "150 notes: the first 100 stored, the speech bubble says 50 are missing", w.done && { n: w.done.notes?.length, answer: w.done.answer });
    ok(/100 Notizen ins Dokument \(50 über der Grenze des Servers weggelassen\)/.test(logOf(w.id)), "logged: 50 over the server's limit", logOf(w.id));
    w = await writeAsk("writeLong");
    ok(w.done?.notes?.length === 1 && w.done.notes[0].text.length === 7999 && /^a+$/.test(w.done.notes[0].text), "a note cut at 8000 UTF-16 units without half a surrogate pair: 7999 kept", w.done?.notes?.[0]?.text?.length);
    ok(w.done?.answer?.endsWith("\n\n*(Eine Notiz war zu lang und ist gekürzt.)*"), "speech bubble: says the note was cut", w.done?.answer);
    ok(/1 Notizen ins Dokument \(1 gekürzt\)/.test(logOf(w.id)), "logged: one note cut", logOf(w.id));
    for (const x of (await api("GET", `/api/doc/${edge}/asks`)).data.asks) await api("DELETE", `/api/doc/${edge}/asks/${x.id}`);
  }
  setMode({ mode: "ok" });

  console.log("== other document: its own chat; notebook without PDF");
  a = await createAsk(nb, "quick", 0);
  const ans3 = await waitFor(async () => { const x = await askOf(nb, a.id); return x.status === "answered" ? x : null; }, 15000);
  ok(ans3, "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(c.args.includes("--session-id") && c.args[c.args.indexOf("--session-id") + 1] !== sid && c.cwd.endsWith(nb), "new session in its own folder", c);
  ok(!Object.keys(c.sizes).includes("dokument.pdf") && /Notizbuch/.test(c.args[c.args.indexOf("-p") + 1]), "no PDF for a notebook", c.sizes);
  ok(/\nZu dieser Frage hast du vom Notizbuch nur diese eine Seite\. Such nicht nach anderen Dateien, und braucht die Frage eine Seite, die du nicht siehst, sag das kurz\.\n/.test(promptOf(c)), "old app, notebook: says this one page is all there is for this question and not to search", promptOf(c));

  console.log("== notebook with the pages around the question (new app)");
  a = await createAsk(nb, "thorough", 3, { span: [0, 5], pages: [0, 1, 4], bytes: 4321 });
  ok(await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  let ctxFile = Object.keys(c.sizes).find((f) => f.endsWith(`${a.id}/nachbarseiten.pdf`));
  ok(ctxFile && c.sizes[ctxFile] === 4321, "pages PDF downloaded next to the question", c.sizes);
  ok(promptOf(c).includes(`- ${ctxFile}: die Seiten 1, 2 und 5, wie sie in der App aussehen, jede oben mit ihrer Nummer beschriftet\nVon Seite 1 bis 6 ist außer der Seite der Frage nur auf den Seiten 1, 2 und 5 etwas geschrieben, die übrigen sind leer. Weitere Seiten hast du zu dieser Frage nicht: Such nicht nach anderen Dateien`), "prompt names the pages (from 1) and says the others in the range are empty", promptOf(c));
  ok(/die ganze Seite 4, die Frage darauf/.test(promptOf(c)) && c.args.includes("--resume"), "question on page 4, same chat as before", promptOf(c));
  ok(logText().includes(`${a.id} Unterlagen: Nachbarseiten 1, 2, 5 (Bereich 1–6)`), "log lists the pages", logText().split("\n").filter((l) => l.includes("Unterlagen")).slice(-1));

  console.log("== notebook: nothing else written nearby; a one-page notebook; pages out of range");
  a = await createAsk(nb, "quick", 2, { span: [0, 3], pages: [] });
  ok(await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(/\nVon Seite 1 bis 4 ist außer der Seite der Frage nichts geschrieben\. Weitere Seiten hast du zu dieser Frage nicht/.test(promptOf(c)) && !/nachbarseiten/.test(promptOf(c)) && !fs.existsSync(path.join(HOME, "chats", nb, "fragen", a.id, "nachbarseiten.pdf")), "empty neighbours: said so, no file", promptOf(c));
  ok(logText().includes(`${a.id} Unterlagen: Nachbarseiten keine beschrieben (Bereich 1–4)`), "log: none written");
  a = await createAsk(nb, "quick", 0, { span: [0, 0], pages: [] });
  ok(await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(/\nDas Notizbuch hat nur diese eine Seite\. Such nicht nach anderen Dateien\.\n/.test(promptOf(c)), "one-page notebook: said so", promptOf(c));
  // Frage nicht im Bereich (dürfte nie vorkommen): lieber nichts über die anderen Seiten sagen
  a = await createAsk(nb, "quick", 9, { span: [0, 5], pages: [1], bytes: 500 });
  ok(await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(/Zu dieser Frage hast du vom Notizbuch nur diese eine Seite/.test(promptOf(c)) && !/nachbarseiten/.test(promptOf(c)), "question outside the range: pages ignored", promptOf(c));
  // Eine Seite beschrieben: Einzahl
  a = await createAsk(nb, "quick", 2, { span: [0, 3], pages: [1], bytes: 800 });
  ok(await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  ctxFile = Object.keys(c.sizes).find((f) => f.endsWith(`${a.id}/nachbarseiten.pdf`));
  ok(ctxFile && promptOf(c).includes(`- ${ctxFile}: Seite 2, wie sie in der App aussieht, oben mit ihrer Nummer beschriftet\nVon Seite 1 bis 4 ist außer der Seite der Frage nur auf Seite 2 etwas geschrieben, die übrigen sind leer.`), "one written page: singular", promptOf(c));

  console.log("== page count in the first line: the server's may lag behind the app, the pages around the question do not");
  {
    // Auf die letzte Seite geschrieben und gleich gefragt: Die App hat eine leere Seite angehängt, der Server weiß es noch nicht
    const nowP = Date.now() / 1000, grown = uuid(), single = uuid(), older = uuid(), long = uuid();
    await api("PUT", `/api/library/${grown}`, { json: { id: grown, title: "Gerade angehängt", kind: "notebook", created: nowP, modified: nowP, pageCount: 1 } });
    await api("PUT", `/api/library/${single}`, { json: { id: single, title: "Eine Seite", kind: "notebook", created: nowP, modified: nowP, pageCount: 2 } });
    await api("PUT", `/api/library/${older}`, { json: { id: older, title: "Ältere App", kind: "notebook", created: nowP, modified: nowP, pageCount: 1 } });
    await api("PUT", `/api/library/${long}`, { json: { id: long, title: "Lang", kind: "notebook", created: nowP, modified: nowP, pageCount: 20 } });
    a = await createAsk(grown, "thorough", 0, { span: [0, 1], pages: [] });
    ok(await waitFor(async () => (await askOf(grown, a.id)).status === "answered", 15000), "answered");
    c = calls().filter((x) => x.args).at(-1);
    ok(promptOf(c).startsWith("Dokument: „Gerade angehängt“ (Notizbuch mit 2 Seiten).\n") && /\nVon Seite 1 bis 2 ist außer der Seite der Frage nichts geschrieben\./.test(promptOf(c)), "server says 1 page, the app's range has 2: the first line says 2", promptOf(c));
    // Nur die Seite der Frage im Bereich: Die App hatte nur sie, auch wenn der Server noch von einer zweiten weiß
    a = await createAsk(single, "quick", 0, { span: [0, 0], pages: [] });
    ok(await waitFor(async () => (await askOf(single, a.id)).status === "answered", 15000), "answered");
    c = calls().filter((x) => x.args).at(-1);
    ok(promptOf(c).startsWith("Dokument: „Eine Seite“ (Notizbuch mit 1 Seite).\n") && /\nDas Notizbuch hat nur diese eine Seite\./.test(promptOf(c)), "range of one page, server says 2: the first line says 1, like the note", promptOf(c));
    // Ältere App ohne die Seiten um die Frage: wenigstens bis zur Seite der Frage
    a = await createAsk(older, "quick", 2);
    ok(await waitFor(async () => (await askOf(older, a.id)).status === "answered", 15000), "answered");
    c = calls().filter((x) => x.args).at(-1);
    ok(promptOf(c).startsWith("Dokument: „Ältere App“ (Notizbuch mit 3 Seiten).\n") && /die ganze Seite 3, die Frage darauf/.test(promptOf(c)), "no range, server says 1 page, question on page 3: at least 3", promptOf(c));
    // Der Bereich endet vor dem Ende des Dokuments: Dann gilt die Zahl vom Server
    a = await createAsk(long, "quick", 2, { span: [0, 3], pages: [] });
    ok(await waitFor(async () => (await askOf(long, a.id)).status === "answered", 15000), "answered");
    c = calls().filter((x) => x.args).at(-1);
    ok(promptOf(c).startsWith("Dokument: „Lang“ (Notizbuch mit 20 Seiten).\n") && /\nVon Seite 1 bis 4 ist außer der Seite der Frage nichts geschrieben\./.test(promptOf(c)), "range ends before the server's last page: the server's 20", promptOf(c));
  }

  console.log("== PDF changed in the app, the question arrives first: the helper waits for the new PDF");
  {
    const sk = uuid(), nowS = Date.now() / 1000;
    await api("PUT", `/api/library/${sk}`, { json: { id: sk, title: "Skript", kind: "pdf", created: nowS, modified: nowS, pageCount: 3, pdfVersion: 1, pagesVersion: 100 } });
    await api("PUT", `/api/pdf/${sk}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "a".repeat(3000)), headers: { "content-type": "application/pdf" } });
    const runs = calls().filter((x) => x.args).length;
    // Die Uhr des iPads geht eine Stunde nach: Es zählt, seit wann die Frage am Server ist
    a = await createAsk(sk, "quick", 3, { span: [0, 3], pages: [], pv: 200, created: Date.now() / 1000 - 3600 });
    const held = await waitFor(async () => { const x = await askOf(sk, a.id); return x.status === "open" && x.note ? x : null; }, 10000, 50);
    ok(held && held.note === "Das geänderte PDF ist noch nicht oben" && calls().filter((x) => x.args).length === runs && !fs.existsSync(path.join(HOME, "chats", sk, "dokument.pdf")), "released with a note, Claude not asked, old PDF not fetched", held);
    ok(await waitFor(() => logText().includes(`${a.id} PDF am Server noch vor der letzten Seitenänderung, neuer Versuch in 5 s`), 3000, 20), "log: tries again in 5 s", logText().split("\n").slice(-3));
    // Jetzt kommen das neue PDF und danach der Seitenstand, wie die App sie hinauflädt
    const newer = new TextEncoder().encode("%PDF-1.4\n" + "b".repeat(4000));
    await api("PUT", `/api/pdf/${sk}`, { body: newer, headers: { "content-type": "application/pdf" } });
    const metaAt = Date.now();
    await api("PUT", `/api/library/${sk}`, { json: { id: sk, title: "Skript", kind: "pdf", created: nowS, modified: nowS + 1, pageCount: 4, pdfVersion: 2, pagesVersion: 200 } });
    const done = await waitFor(async () => { const x = await askOf(sk, a.id); return x.status === "answered" ? x : null; }, 20000, 50);
    // Ohne Wecken käme der Helfer erst nach seinen 5 s (und 1 s für die Abfrage) wieder
    ok(done && done.note === null && Date.now() - metaAt < 4000, `answered ${Date.now() - metaAt} ms after the page state arrived (the server wakes the helper), note gone`, done);
    c = calls().filter((x) => x.args).at(-1);
    ok(fs.statSync(path.join(HOME, "chats", sk, "dokument.pdf")).size === newer.length && /seiten-\d+-\d+\.pdf/.test(promptOf(c)) && !/vor der letzten Seitenänderung/.test(promptOf(c)), "Claude got the new PDF and its window, no warning", promptOf(c));
    // Die Seite der Frage ist gelöscht (sie rückte auf -1): Dann wartet der Helfer nicht, Claude erfährt nur, dass das PDF älter ist
    const cuts = calls().filter((x) => x.osascript).length;
    a = await createAsk(sk, "quick", 1, { pv: 300 });
    ok(await waitFor(async () => { const x = await askOf(sk, a.id); return x.status === "open" && x.note; }, 10000, 50), "held: page state 300 not at the server yet");
    await api("PATCH", `/api/doc/${sk}/asks`, { json: { pv: 300, anchors: { [a.id]: { page: -1, x: 10, y: 20, w: 100, h: 30 } } } });
    ok(await waitFor(async () => (await askOf(sk, a.id)).status === "answered", 15000), "page deleted meanwhile: answered at the next try, no more waiting");
    c = calls().filter((x) => x.args).at(-1);
    ok(promptOf(c).includes("\ndokument.pdf ist noch der Stand vor der letzten Seitenänderung in der App (das neue PDF ist noch nicht angekommen).\n") && !/Seitennummern/.test(promptOf(c)) && /seite\.jpg: die ganze Seite, die Frage/.test(promptOf(c)) && calls().filter((x) => x.osascript).length === cuts, "told the PDF is older, nothing about page numbers (there are none), no window", promptOf(c));
  }

  console.log("== ∞ (question as JPEG: the printed question over the spot)");
  {
    const id = uuid();
    const f = new FormData();
    f.append("meta", JSON.stringify({ anchor: { page: 1, x: 10, y: 20, w: 100, h: 30 }, pv: 0, effort: "quick", created: Date.now() / 1000, from: "iPad", span: [0, 2], pages: [] }));
    f.append("question", new Blob([JPG()], { type: "image/jpeg" }), "question.jpg");
    f.append("page", new Blob([JPG()], { type: "image/jpeg" }), "page.jpg");
    const r = await api("PUT", `/api/doc/${nb}/asks/${id}`, { body: f });
    ok(r.status === 200 && await waitFor(async () => (await askOf(nb, id)).status === "answered", 15000), "answered", r.status);
    c = calls().filter((x) => x.args).at(-1);
    ok(/frage\.jpg: die Frage \(oben gedruckt\) und die Stelle, um die es geht, pink umrandet\n- \S+seite\.jpg: die ganze Seite 2, die Stelle darauf farbig umrandet\n/.test(promptOf(c)), "∞: printed question and the spot", promptOf(c));
    ok(/zieht mit dem Lasso ein ∞ über eine Stelle/.test(systemOf(c)), "system prompt knows the ∞", systemOf(c));
  }

  console.log("== retry without the pages (moved meanwhile): no stale pages PDF from the first try");
  setMode({ mode: "error" });
  a = await createAsk(nb, "quick", 2, { span: [0, 3], pages: [0], bytes: 900 });
  const firstTry = await waitFor(async () => { const x = await askOf(nb, a.id); return x.status === "open" && /Fehler am Mac/.test(x.note || "") ? x : null; }, 10000, 100);
  c = calls().filter((x) => x.args).at(-1);
  ok(firstTry && Object.keys(c.sizes).some((f) => f.endsWith(`${a.id}/nachbarseiten.pdf`)), "first try had the pages PDF", { firstTry, sizes: c.sizes });
  setMode({ mode: "ok" });
  const moved = await api("PATCH", `/api/doc/${nb}/asks`, { json: { pv: 1, anchors: { [a.id]: { page: 3, x: 10, y: 20, w: 100, h: 30 } } } });
  ok(moved.status === 200 && await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 20000, 200), "answered on the retry", moved.status);
  c = calls().filter((x) => x.args).at(-1);
  ok(!/nachbarseiten/.test(promptOf(c)) && !fs.existsSync(path.join(HOME, "chats", nb, "fragen", a.id, "nachbarseiten.pdf")) && /Zu dieser Frage hast du vom Notizbuch nur diese eine Seite/.test(promptOf(c)) && /die ganze Seite 4/.test(promptOf(c)), "retry: no pages, old file gone, only this page", promptOf(c));
  ok(logText().includes(`${a.id} Unterlagen: ohne Nachbarseiten (nicht mitgeschickt oder Seiten seither gerückt)`), "log: pages moved", logText().split("\n").filter((l) => l.includes("Unterlagen")).slice(-1));

  console.log("== new PDF version: downloaded again and mentioned");
  await api("PUT", `/api/library/${doc}`, { json: { id: doc, title: "Analysis 2 – Blatt 3", kind: "pdf", created: now, modified: now + 5, pageCount: 4, pdfVersion: 9 } });
  await api("PUT", `/api/pdf/${doc}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "y".repeat(9000)) });
  setPages({ n: 6 });
  a = await createAsk(doc, "quick", 0);
  await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000);
  c = calls().filter((x) => x.args).at(-1);
  ok(c.sizes["dokument.pdf"] === 9009 && /PDF wurde seit der letzten Frage geändert/.test(c.args[c.args.indexOf("-p") + 1]), "new PDF fetched and mentioned", c.sizes);
  ok(!/seiten-/.test(promptOf(c)) && !fs.readdirSync(path.join(HOME, "chats", doc, "fragen", a.id)).some((f) => f.startsWith("seiten")), "small PDF (6 pages): no window, no leftover file", promptOf(c));
  ok(!/\n- dokument\.pdf/.test(promptOf(c)) && c.args.includes("--resume") && /\nNotizen aus der App siehst du zu dieser Frage nur auf der Seite der Frage; dokument\.pdf zeigt das PDF ohne die Notizen aus der App\.\n/.test(promptOf(c)), "follow-up without a window: dokument.pdf not listed again (Claude has it), only the note", promptOf(c));

  console.log("== PDF with handwriting on the pages around the question (new app)");
  a = await createAsk(doc, "thorough", 1, { span: [0, 3], pages: [0, 3], bytes: 2500 });
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  ctxFile = Object.keys(c.sizes).find((f) => f.endsWith(`${a.id}/nachbarseiten.pdf`));
  ok(ctxFile && c.sizes[ctxFile] === 2500 && promptOf(c).includes(`- ${ctxFile}: die Seiten 1 und 4, wie sie in der App aussehen, jede oben mit ihrer Nummer beschriftet`), "pages PDF downloaded and named", { sizes: c.sizes, p: promptOf(c) });
  ok(promptOf(c).includes("\nVon Seite 1 bis 4 gibt es Notizen aus der App nur auf der Seite der Frage und auf den Seiten 1 und 4; dokument.pdf zeigt das PDF ohne die Notizen aus der App. Notizen auf weiter entfernten Seiten siehst du zu dieser Frage nicht.\n"), "PDF: where the notes are, the PDF has none", promptOf(c));
  ok(logText().includes(`${a.id} Unterlagen: Nachbarseiten 1, 4 (Bereich 1–4), ganzes PDF (6 Seiten)`), "log: pages and whole PDF", logText().split("\n").filter((l) => l.includes("Unterlagen")).slice(-1));
  a = await createAsk(doc, "quick", 1, { span: [0, 2], pages: [] });
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(promptOf(c).includes("\nVon Seite 1 bis 3 gibt es Notizen aus der App nur auf der Seite der Frage; dokument.pdf zeigt das PDF ohne die Notizen aus der App."), "PDF, no notes nearby: said so", promptOf(c));
  setPages({ n: 30 });

  console.log("== usage limit: released with note, helper pauses, then answers");
  setMode({ mode: "limit" });
  a = await createAsk(doc, "quick", 1);
  const rel = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "open" && x.note ? x : null; }, 15000);
  ok(rel && /Claude-Limit erreicht, neuer Versuch um \d\d:\d\d/.test(rel.note), "app sees open with limit note", rel);
  const nCalls = calls().filter((x) => x.args).length;
  setMode({ mode: "ok" });
  const b = await createAsk(doc, "quick", 1); // arrives during the pause: not claimed yet
  await sleep(1500);
  ok((await askOf(doc, b.id)).status === "open", "no claims during the pause");
  const after = await waitFor(async () => (await askOf(doc, a.id)).status === "answered" && (await askOf(doc, b.id)).status === "answered", 20000, 300);
  ok(after, "both answered after the pause");
  ok(calls().filter((x) => x.args).length === nCalls + 2, "exactly two more runs");

  console.log("== error: retried once, then failed");
  setMode({ mode: "error" });
  a = await createAsk(doc, "quick", 1);
  const firstRelease = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "open" && /Fehler am Mac/.test(x.note || "") ? x : null; }, 10000, 100);
  ok(firstRelease, "first error → released with note", firstRelease);
  const failed = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "failed" ? x : null; }, 20000, 300);
  ok(failed && /Something broke/.test(failed.note), "second error → failed with message", failed);
  setMode({ mode: "ok" });

  console.log("== too many turns: failed at once, no second run");
  setMode({ mode: "maxturns" });
  let runs0 = calls().filter((x) => x.args).length;
  a = await createAsk(doc, "quick", 1);
  const mt = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "failed" ? x : null; }, 15000, 200);
  ok(mt && /zu viele Schritte/.test(mt.note), "failed with a readable note", mt);
  await sleep(1500);
  ok(calls().filter((x) => x.args).length === runs0 + 1, "exactly one run");
  setMode({ mode: "ok" });

  console.log("== delete while Claude works: run killed, nothing posted");
  setMode({ mode: "ok", delayMs: 20000 });
  a = await createAsk(doc, "thorough", 1);
  await waitFor(async () => (await askOf(doc, a.id)).status === "claimed", 5000, 50);
  await sleep(500);
  await api("DELETE", `/api/doc/${doc}/asks/${a.id}`);
  const killed = await waitFor(() => calls().some((x) => x.killed), 8000, 100);
  ok(killed, "claude run killed after delete");
  setMode({ mode: "ok" });
  ok(/Markierung gelöscht, breche ab/.test(logText()), "helper logged the cancel");
  // and continues working
  a = await createAsk(doc, "quick", 1);
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "next question answered after a cancel");

  console.log("== chat gone (e.g. cleaned up): new chat");
  fs.rmSync(path.join(FAKE, "sessions", sid));
  a = await createAsk(doc, "quick", 1);
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "answered");
  const last2 = calls().filter((x) => x.args).slice(-2);
  ok(last2[0].args.includes("--resume") && last2[1].args.includes("--session-id") && /Dokument: „Analysis/.test(last2[1].args[last2[1].args.indexOf("-p") + 1]), "resume failed → fresh session with full intro", last2.map((x) => x.args.slice(0, 2)));

  console.log("== chat too big for Claude (images and pages of many questions): new chat, no pause");
  for (const message of ["Prompt is too long", "Context limit reached · /compact or /clear to continue", "API Error: 400 A maximum of 100 PDF pages may be provided.", "PDF too large (max 100 pages, 20MB). Try reading the file a different way (e.g., extract text with pdftotext).", "Request too large for the API's 32MB request limit"]) {
    setMode({ mode: "toobig", message });
    const runs = calls().filter((x) => x.args).length;
    a = await createAsk(doc, "quick", 1);
    const big = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "answered" ? x : null; }, 15000, 100);
    const tb = calls().filter((x) => x.args).slice(runs);
    ok(big && tb.length === 2 && tb[0].args.includes("--resume") && tb[1].args.includes("--session-id") && /Dokument: „Analysis/.test(promptOf(tb[1])), `„${message.slice(0, 30)}…“: fresh chat answers at once`, tb.map((x) => x.args.slice(0, 2)));
    ok(logText().includes(`${a.id} Chat zu groß, neuer Chat`) && !logText().split("\n").some((l) => l.includes(a.id) && /Nutzungslimit/.test(l)), "logged, not taken for a usage limit");
  }
  // Der neue Chat geht weiter
  setMode({ mode: "ok" });
  a = await createAsk(doc, "quick", 1);
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "answered");
  c = calls().filter((x) => x.args).at(-1);
  const prev = calls().filter((x) => x.args).at(-2);
  ok(c.args.includes("--resume") && c.args[c.args.indexOf("--resume") + 1] === prev.args[prev.args.indexOf("--session-id") + 1], "next question resumes the new chat", c.args.slice(0, 4));

  console.log("== helper down: question waits; on start it is picked up");
  helper.kill("SIGTERM");
  await sleep(500);
  a = await createAsk(doc, "quick", 1);
  await sleep(1000);
  ok((await askOf(doc, a.id)).status === "open", "open while the helper is down");
  // its page is deleted meanwhile (undo still possible): page -1
  const pm = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 0, anchors: { [a.id]: { page: -1, x: 10, y: 20, w: 100, h: 30 } } } });
  ok(pm.data.asks.find((x) => x.id === a.id).anchor.page === -1, "moved to page -1");
  const osaBefore = calls().filter((x) => x.osascript).length;
  startHelper();
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "answered after restart");
  c = calls().filter((x) => x.args).at(-1);
  ok(/frage\.png: die handgeschriebene Frage\n- \S+seite\.jpg: die ganze Seite, die Frage/.test(promptOf(c)) && calls().filter((x) => x.osascript).length === osaBefore && !/vor der letzten Seitenänderung/.test(promptOf(c)), "deleted page: whole page without number, no window", promptOf(c));
  ok(/Seite gelöscht/.test(logText()), "log says the page was deleted");
  ok(logText().includes(`${a.id} Unterlagen: ohne Nachbarseiten (Seite gelöscht), ganzes PDF, weitere Seiten aus: Seite der Frage gelöscht`), "deleted page: no further pages to read", logText().split("\n").filter((l) => l.includes(a.id)));

  async function restartWith(fn, env, script) {
    helper.kill("SIGTERM");
    await sleep(500);
    fn();
    const before = logText().split("\n").length;
    startHelper(env, script);
    await waitFor(() => logText().split("\n").slice(before - 1).some((l) => l.includes("verbunden")), 10000);
  }
  async function askOnce(effort = "quick") {
    const x = await createAsk(doc, effort, 5);
    const done = await waitFor(async () => (await askOf(doc, x.id)).status === "answered", 15000);
    return { done, c: calls().filter((y) => y.args).at(-1) };
  }

  console.log("== old claude version: no --restricted, no dontAsk");
  await restartWith(() => setHelp("old"));
  let r = await askOnce();
  ok(r.done && !r.c.args.includes("--restricted") && !r.c.args.includes("--permission-mode") && optOf(r.c, "--tools") === "Read" && !r.c.args.some((x) => /allowed/i.test(x)), "answered with tools Read only: no internet without the restricted mode", r.c.args);
  ok(/keine Links/.test(systemOf(r.c)) && !/Internet/.test(systemOf(r.c)), "system prompt without the internet", systemOf(r.c));
  ok(/eingeschränkter Modus nicht verfügbar, dontAsk nein, Internet aus \(nur im eingeschränkten Modus\)/.test(logText()), "log says restricted mode unavailable, so no internet");

  console.log("== config restricted: false");
  await restartWith(() => { setHelp("new"); writeConfig({ restricted: false }); });
  r = await askOnce();
  ok(r.done && !r.c.args.includes("--restricted") && r.c.args[r.c.args.indexOf("--permission-mode") + 1] === "dontAsk" && optOf(r.c, "--tools") === "Read" && !r.c.args.some((x) => /allowed/i.test(x)), "dontAsk without --restricted, and then no internet", r.c.args);
  ok(/eingeschränkter Modus aus \(config\), dontAsk ja, Internet aus \(nur im eingeschränkten Modus\)/.test(logText()), "log says restricted off by config, so no internet");

  console.log("== config web: false: only the document");
  await restartWith(() => { setHelp("new"); writeConfig({ web: false }); });
  r = await askOnce();
  ok(r.done && optOf(r.c, "--tools") === "Read" && !r.c.args.some((x) => /allowed/i.test(x)) && r.c.args.includes("--restricted") && r.c.args[r.c.args.indexOf("--permission-mode") + 1] === "dontAsk", "tools Read only, nothing pre-allowed", r.c.args);
  ok(/keine Links/.test(systemOf(r.c)) && !/Internet/.test(systemOf(r.c)), "system prompt without the internet", systemOf(r.c));
  ok(/Internet aus \(config\)/.test(logText()), "log says internet off by config");

  console.log("== config pdfWaitSeconds: 0: a question to a changed PDF goes on at once, with the PDF there is");
  await restartWith(() => { setHelp("new"); writeConfig({ pdfWaitSeconds: 0 }); });
  {
    const sk2 = uuid(), nowW = Date.now() / 1000;
    await api("PUT", `/api/library/${sk2}`, { json: { id: sk2, title: "Skript 2", kind: "pdf", created: nowW, modified: nowW, pageCount: 20, pdfVersion: 1, pagesVersion: 100 } });
    await api("PUT", `/api/pdf/${sk2}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "c".repeat(3000)), headers: { "content-type": "application/pdf" } });
    const cuts = calls().filter((x) => x.osascript).length;
    const w = await createAsk(sk2, "quick", 9, { span: [6, 10], pages: [], pv: 300 });
    ok(await waitFor(async () => (await askOf(sk2, w.id)).status === "answered", 15000), "answered at once");
    const cw = calls().filter((x) => x.args).at(-1);
    ok(promptOf(cw).startsWith("Dokument: „Skript 2“ (PDF).\nDas Dokument liegt in dokument.pdf.\n") && promptOf(cw).includes("\nVon Seite 7 bis 11 gibt es Notizen aus der App nur auf der Seite der Frage; dokument.pdf zeigt das PDF ohne die Notizen aus der App. Notizen auf weiter entfernten Seiten siehst du zu dieser Frage nicht.\ndokument.pdf ist noch der Stand vor der letzten Seitenänderung in der App (das neue PDF ist noch nicht angekommen): Seine Seitennummern können von denen hier abweichen. Es gelten die Seitennummern in dieser Nachricht.\n") && !/seiten-\d+-\d+\.pdf/.test(promptOf(cw)) && calls().filter((x) => x.osascript).length === cuts, "old PDF: no page count, not „das ganze“, no window cut from it, Claude is told", promptOf(cw));
    ok(logText().includes(`${w.id} Unterlagen: Nachbarseiten keine beschrieben (Bereich 7–11), ganzes PDF, noch vom Stand vor der letzten Seitenänderung`), "log says so", logText().split("\n").filter((l) => l.includes("Unterlagen")).slice(-1));
    ok(logText().includes(`${w.id} Unterlagen: Nachbarseiten keine beschrieben (Bereich 7–11), ganzes PDF, noch vom Stand vor der letzten Seitenänderung, weitere Seiten aus: PDF zu alt`), "old PDF: no further pages to read (their numbers would not match)", logText().split("\n").filter((l) => l.includes("Unterlagen")).slice(-1));
    // Claude schreiben lassen mit dem alten PDF: Zeigt der Bereich nur die Seite der Frage, bleibt diese Zahl im Auftrag
    setMode({ mode: "write" });
    const w1 = await createAsk(sk2, "quick", 0, { span: [0, 0], pages: [], pv: 300, mode: "write" });
    ok(await waitFor(async () => (await askOf(sk2, w1.id)).status === "answered", 15000), "answered at once");
    const cw1 = calls().filter((x) => x.args).at(-1);
    ok(promptOf(cw1).includes("(eine leere Seite danach ist recht; das Dokument hat 1 Seite, darüber hinaus gibt es keine).") && /ist noch der Stand vor der letzten Seitenänderung/.test(promptOf(cw1)), "write, old PDF, a range of one page: the task still says the document has 1 page", promptOf(cw1).match(/eine leere Seite[^\n]*/)?.[0]);
    setMode({ mode: "ok" });
  }

  console.log("== denied tools are logged with the answer");
  setMode({ mode: "denied" });
  r = await askOnce();
  ok(r.done && /beantwortet nach \d+ s \(\d+ Zeichen\), abgelehnt: Read, WebFetch/.test(logText()), "answer logged with the denied tools", logText().split("\n").filter((l) => l.includes("beantwortet")).slice(-1));
  setMode({ mode: "ok" });

  console.log("== web sites from config.json: all, none, only valid ones");
  await restartWith(() => writeConfig({ webSites: ["*"] }));
  r = await askOnce();
  ok(r.done && optOf(r.c, "--tools") === "Read,WebSearch,WebFetch" && optOf(r.c, "--allowedTools") === "WebSearch,WebFetch" && /Ganze Seiten liest du mit WebFetch/.test(systemOf(r.c)) && /ganze Seiten: alle/.test(logText()), "[\"*\"]: every site", r.c.args);
  await restartWith(() => writeConfig({ webSites: [] }));
  r = await askOnce();
  ok(r.done && optOf(r.c, "--tools") === "Read,WebSearch" && optOf(r.c, "--allowedTools") === "WebSearch" && /nur suchen/.test(systemOf(r.c)) && /ganze Seiten: keine/.test(logText()), "[]: search only, no WebFetch at all", r.c.args);
  await restartWith(() => writeConfig({ webSites: ["arxiv.org", "x.org/evil", "bad site", "a,b.org", "c(d).org", "*.wikipedia.org"] }));
  r = await askOnce();
  ok(r.done && optOf(r.c, "--allowedTools") === "WebSearch,WebFetch(domain:arxiv.org),WebFetch(domain:*.wikipedia.org)", "invalid site patterns are dropped", r.c.args);

  console.log("== page window fails: whole PDF only, logged once");
  await restartWith(() => { writeConfig(); setPages({ n: 30, fail: true }); });
  r = await askOnce();
  const r2 = await askOnce("thorough");
  ok(r.done && r2.done && !/seiten-/.test(promptOf(r.c)) && !/seiten-/.test(promptOf(r2.c)), "answered without a window", [promptOf(r.c), promptOf(r2.c)]);
  ok(logText().split("\n").filter((l) => l.includes("nicht ausgeschnitten") && l.includes("PDFKit kaputt")).length === 1, "failure logged once with the reason");
  setMode({ mode: "write" });
  a = await createAsk(doc, "quick", 2, { mode: "write" });
  const wf = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "answered" ? x : null; }, 15000);
  c = calls().filter((x) => x.args).at(-1);
  ok(wf && /Diesmal schreibst du ins Dokument/.test(promptOf(c)) && promptOf(c).includes("(eine leere Seite danach ist recht).") && !/darüber hinaus gibt es keine/.test(promptOf(c)), "write, PDF without PDFKit: no page count in the task (it would be a guess)", promptOf(c).match(/eine leere Seite[^\n]*/)?.[0]);
  setMode({ mode: "ok" });
  ok(r.c.args.includes("--restricted"), "restricted again with the default config");
  setPages({ n: 30 });

  console.log("== pages PDF cannot be downloaded: tried twice, then answered without the pages");
  {
    // Zwischen Helfer und Server: reicht alles durch (auch den WebSocket), nur das PDF der Seiten scheitert
    let failed = 0;
    const proxy = await startProxy((req) => (/^\/api\/asks\/[^/]+\/pages$/.test(req.url) ? (failed++, [500, "kaputt"]) : null));
    await restartWith(() => writeConfig({ url: proxy.url }));
    a = await createAsk(nb, "quick", 2, { span: [0, 3], pages: [1], bytes: 600 });
    ok(await waitFor(async () => (await askOf(nb, a.id)).status === "answered", 15000), "answered without the pages");
    c = calls().filter((x) => x.args).at(-1);
    ok(failed === 2 && !/nachbarseiten/.test(promptOf(c)) && /Zu dieser Frage hast du vom Notizbuch nur diese eine Seite/.test(promptOf(c)) && !fs.existsSync(path.join(HOME, "chats", nb, "fragen", a.id, "nachbarseiten.pdf")), `tried twice (${failed}), prompt says only this page`, promptOf(c));
    ok(logText().includes(`${a.id} Nachbarseiten nicht geladen: HTTP 500`) && logText().includes(`${a.id} Unterlagen: Nachbarseiten nicht geladen`), "logged", logText().split("\n").filter((l) => l.includes(a.id)));
    await restartWith(() => writeConfig());
    proxy.close();
  }

  console.log("== Claude schreiben lassen im PDF: Seiten ändern sich, während Claude schreibt: der neue Lauf wartet aufs geänderte PDF");
  {
    // Maßstab: pdfWaitSeconds 2 steht für 180, ein erster Lauf von 3,5 s für einen von mehr als drei Minuten
    await restartWith(() => { setHelp("new"); writeConfig({ pdfWaitSeconds: 2 }); });
    setPages({ n: 30 });
    const sk3 = uuid(), nowR = Date.now() / 1000;
    await api("PUT", `/api/library/${sk3}`, { json: { id: sk3, title: "Skript 3", kind: "pdf", created: nowR, modified: nowR, pageCount: 4, pdfVersion: 7 } });
    await api("PUT", `/api/pdf/${sk3}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "x".repeat(5000)), headers: { "content-type": "application/pdf" } });
    const before = calls().filter((x) => x.args).length;
    setMode({ mode: "writePage", delayMs: 3500 });
    const w = await createAsk(sk3, "quick", 1, { mode: "write" });
    ok(await waitFor(async () => (await askOf(sk3, w.id)).status === "claimed", 15000, 50), "claimed");
    // Eine Seite davor eingefügt: Die App verschiebt die Stelle (Seitenstand 1, Seite 3); ihr neues PDF und der
    // Seitenstand kommen erst danach
    const moved = await api("PATCH", `/api/doc/${sk3}/asks`, { json: { pv: 1, anchors: { [w.id]: { page: 2, x: 10, y: 20, w: 100, h: 30 } } } });
    ok(moved.status === 200, "page change while Claude writes", moved.status);
    const lines = () => logText().split("\n").filter((l) => l.includes(w.id));
    ok(await waitFor(() => lines().some((l) => /Seiten haben sich geändert, während Claude schrieb/.test(l)), 15000, 20), "the answer is refused: pages changed while Claude wrote", lines());
    setMode({ mode: "writePage" });
    // Der neue Lauf zählt ab dem Neustellen: Er wartet wie eine neue Frage aufs geänderte PDF, statt das alte zu nehmen
    ok(await waitFor(() => lines().some((l) => /PDF am Server noch vor der letzten Seitenänderung, neuer Versuch in \d+ s/.test(l)), 5000, 20), "the new run waits for the changed PDF", lines());
    // Jetzt kommen das neue PDF und danach der Seitenstand, wie die App sie hinauflädt
    await api("PUT", `/api/pdf/${sk3}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "n".repeat(5200)), headers: { "content-type": "application/pdf" } });
    await api("PUT", `/api/library/${sk3}`, { json: { id: sk3, title: "Skript 3", kind: "pdf", created: nowR, modified: nowR + 1, pageCount: 5, pdfVersion: 8, pagesVersion: 1 } });
    const done = await waitFor(async () => { const x = await askOf(sk3, w.id); return x.status === "answered" ? x : null; }, 20000);
    const runs = calls().filter((x) => x.args).slice(before);
    const second = runs[1];
    ok(runs.length === 2 && second.args.includes("--session-id") && Object.keys(second.sizes).some((k) => /seiten-\d+-\d+\.pdf$/.test(k)) && !/ist noch der Stand vor der letzten Seitenänderung/.test(promptOf(second)), "second run: in a new chat, with the page window from the new PDF, not told the PDF is older", runs.map((r) => ({ args: r.args.filter((x) => /^--(resume|session-id)$/.test(x)), files: Object.keys(r.sizes) })));
    ok(done && done.pv === 1 && done.anchor.page === 2 && done.notes?.map((n) => n.page).join() === "2,3", "answered in the new numbering: under the question (page 3) and on the page after it", done && { pv: done.pv, anchor: done.anchor.page, notes: done.notes?.map((n) => n.page) });
    await restartWith(() => writeConfig());
    setMode({ mode: "ok" });
  }

  console.log("== Claude schreiben lassen: Antwort verfällt (gelöscht: der Chat bleibt; neu vergeben: neuer Chat)");
  {
    // Zwischen Helfer und Server: reicht alles durch, nur die nächste Antwort des Helfers bekommt `refuse`
    let refuse = null;
    const proxy = await startProxy((req) => {
      if (!refuse || req.method !== "PUT" || !/^\/api\/asks\/[^/]+\/answer$/.test(req.url)) return null;
      const r = refuse;
      refuse = null;
      return r;
    });
    await restartWith(() => writeConfig({ url: proxy.url }));
    setMode({ mode: "ok" });
    const vf = uuid();
    await api("PUT", `/api/library/${vf}`, { json: { id: vf, title: "Verfällt", kind: "notebook", created: now, modified: now, pageCount: 3 } });
    const answeredIn = async (x) => waitFor(async () => (await askOf(vf, x.id)).status === "answered", 15000);
    const first = await createAsk(vf, "quick", 0);
    ok(await answeredIn(first), "a first question opens the document's chat");
    const sid1 = calls().filter((x) => x.args).at(-1).args.find((x, i, all) => all[i - 1] === "--session-id");
    // Die Markierung wurde gelöscht, während Claude schrieb: Die Antwort verfällt, der Chat bleibt
    refuse = [404, { error: "Diese Frage gibt es nicht (mehr)", code: "gone" }];
    const g = await createAsk(vf, "quick", 1, { mode: "write" });
    ok(await waitFor(() => logText().includes(`${g.id} inzwischen gelöscht`), 15000, 50), "write answer refused (deleted meanwhile): logged", logText().split("\n").filter((l) => l.includes(g.id)));
    const q2 = await createAsk(vf, "quick", 1);
    ok(await answeredIn(q2), "answered");
    c = calls().filter((x) => x.args).at(-1);
    ok(sid1 && c.args[c.args.indexOf("--resume") + 1] === sid1 && !logText().split("\n").some((l) => l.includes(g.id) && /beantwortet nach/.test(l)), "deleted: the next question goes on in the document's chat, nothing logged as answered", c.args.filter((x) => /^--(resume|session-id)$/.test(x)));
    // Inzwischen neu vergeben: Die Antwort verfällt, steht aber im Chat; der nächste Lauf beginnt einen neuen
    refuse = [409, { error: "Nicht dein Auftrag", code: "not-yours" }];
    const t = await createAsk(vf, "quick", 1, { mode: "write" });
    ok(await waitFor(() => logText().includes(`${t.id} inzwischen neu vergeben`), 15000, 50), "write answer refused (taken meanwhile): logged", logText().split("\n").filter((l) => l.includes(t.id)));
    const q3 = await createAsk(vf, "quick", 1);
    ok(await answeredIn(q3), "answered");
    c = calls().filter((x) => x.args).at(-1);
    ok(c.args.includes("--session-id") && !c.args.includes("--resume") && c.args[c.args.indexOf("--session-id") + 1] !== sid1, "taken: the next question starts a new chat", c.args.filter((x) => /^--(resume|session-id)$/.test(x)));
    for (const x of [g, t]) await api("DELETE", `/api/doc/${vf}/asks/${x.id}`);
    await restartWith(() => writeConfig());
    proxy.close();
  }

  // Der Helfer sucht auch in /opt/homebrew/bin und /usr/local/bin: Liegt dort ein echtes claude, fiele der Test darauf
  // herein (und würde es aufrufen). Dann diese beiden Abschnitte auslassen
  const realClaude = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"].filter((f) => fs.existsSync(f));
  if (realClaude.length) {
    console.log("== skipped: finding Claude Code (a real claude lies in " + realClaude.join(", ") + ")");
  } else {
    console.log("== no claude in config.json: the newest copy in the Claude app is found");
    // wie am Mac ohne claude im Terminal: ~/Library/Application Support/Claude/claude-code/<Version>/<Kennung>/claude.app/…
    const userHome = path.join(TMP, "userhome");
    const appCopy = (version, build) => {
      const d = path.join(userHome, "Library", "Application Support", "Claude", "claude-code", version, build, "claude.app", "Contents", "MacOS");
      fs.mkdirSync(d, { recursive: true });
      fs.symlinkSync(FAKE_CLAUDE, path.join(d, "claude"));
      return path.join(d, "claude");
    };
    appCopy("2.1.99", "a1");
    const newest = appCopy("2.1.325", "b2");
    fs.writeFileSync(path.join(userHome, "Library", "Application Support", "Claude", "claude-code", ".DS_Store"), "");
    // PATH nur mit node (fake-claude braucht ihn), nie mit einem echten claude daneben
    const nodeOnly = path.join(TMP, "nodebin");
    fs.mkdirSync(nodeOnly, { recursive: true });
    fs.symlinkSync(process.execPath, path.join(nodeOnly, "node"));
    const onlyNode = { HOME: userHome, PATH: [nodeOnly, "/usr/bin", "/bin"].join(path.delimiter) };
    await restartWith(() => writeConfig({ claude: undefined }), onlyNode);
    r = await askOnce();
    ok(r.done, "answered without claude in config.json");
    ok(logText().includes(`Claude Code: da (${newest})`), "the newest app copy is used", logText().split("\n").filter((l) => l.includes("Claude Code")).slice(-2));

    console.log("== no claude anywhere: released with a note, pause");
    fs.rmSync(path.join(userHome, "Library"), { recursive: true, force: true });
    await restartWith(() => {}, onlyNode);
    a = await createAsk(doc, "quick", 1);
    const nf = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "open" && x.note ? x : null; }, 15000, 200);
    ok(nf && /nicht zu finden/.test(nf.note), "app sees the not-found note", nf);
    ok(/Claude Code nicht gefunden/.test(logText()) && /Claude Code fehlt, Pause bis es da ist/.test(logText()), "helper logs it and pauses");
    await sleep(500);
    ok(calls().filter((x) => x.notify && /fehlt/.test(x.notify)).length === 1, "one notification on the Mac");
    await api("DELETE", `/api/doc/${doc}/asks/${a.id}`);
    await restartWith(() => writeConfig());

  }

  console.log("== login being refreshed elsewhere: no pause, just tried again");
  setMode({ mode: "refreshlock" });
  a = await createAsk(doc, "quick", 1);
  const rl = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "open" && x.note ? x : null; }, 15000, 200);
  ok(rl && /neuer Versuch/.test(rl.note) && !/abgemeldet/.test(logText()), "released for a retry, not logged out", rl);
  setMode({ mode: "ok" });
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000, 200), "answered on the retry");

  console.log("== logged out: released with a note, pause until logged in again, one notification");
  // Langer Abstand für neue Versuche: Die Frage darf trotzdem nicht am Server warten, wenn die Anmeldung wieder da ist
  await restartWith(() => writeConfig({ retrySeconds: 60 }));
  const notesBefore = calls().filter((x) => x.notify).length;
  fs.writeFileSync(path.join(FAKE, "auth.json"), JSON.stringify({ loggedIn: false }));
  setMode({ mode: "authexpired" });
  a = await createAsk(doc, "quick", 1);
  const au = await waitFor(async () => { const x = await askOf(doc, a.id); return x.status === "open" && x.note ? x : null; }, 15000, 200);
  ok(au && /abgemeldet/.test(au.note), "app sees the logged-out note", au);
  ok(/abgemeldet, Pause bis zur Anmeldung \(Failed to authenticate: OAuth session expired/.test(logText()), "helper pauses and logs Claude's message");
  await sleep(500);
  const notes = calls().filter((x) => x.notify).slice(notesBefore);
  ok(notes.length === 1 && /abgemeldet/.test(notes[0].notify), "one notification on the Mac", notes);
  const b2 = await createAsk(doc, "quick", 1);
  await sleep(4500);
  ok((await askOf(doc, b2.id)).status === "open", "nothing claimed while logged out");
  ok(calls().some((x) => x.authStatus === false), "login state checked meanwhile (claude auth status)");
  setMode({ mode: "ok" });
  fs.writeFileSync(path.join(FAKE, "auth.json"), JSON.stringify({ loggedIn: true }));
  const tLogin = Date.now();
  const back = await waitFor(async () => (await askOf(doc, a.id)).status === "answered" && (await askOf(doc, b2.id)).status === "answered", 20000, 300);
  ok(back && /wieder angemeldet/.test(logText()) && Date.now() - tLogin < 8000, `after logging in both are answered within seconds (${((Date.now() - tLogin) / 1000).toFixed(1)} s, retrySeconds 60)`);

  console.log("== error on the Mac itself (folder not writable): pause, no cycling through the questions");
  await restartWith(() => writeConfig());
  setMode({ mode: "ok" });
  const broken = uuid(), nowB = Date.now() / 1000;
  await api("PUT", `/api/library/${broken}`, { json: { id: broken, title: "Kaputt", kind: "notebook", created: nowB, modified: nowB, pageCount: 1 } });
  fs.mkdirSync(path.join(HOME, "chats"), { recursive: true });
  fs.writeFileSync(path.join(HOME, "chats", broken), "kein Ordner");
  const notifyBefore = calls().filter((x) => x.notify).length;
  const lf = await createAsk(broken, "quick", 0);
  const lfOpen = await waitFor(async () => { const x = await askOf(broken, lf.id); return x.status === "open" && x.note ? x : null; }, 15000, 200);
  ok(lfOpen && /später/.test(lfOpen.note), "question handed back with a note", lfOpen);
  ok(/Pause 10 Minuten wegen eines Fehlers am Mac \(ENOTDIR\)/.test(logText()), "helper pauses and logs why");
  await sleep(300);
  ok(calls().filter((x) => x.notify).length === notifyBefore + 1, "one notification on the Mac");
  const waiting = await createAsk(doc, "quick", 1);
  await sleep(4000);
  ok((await askOf(doc, waiting.id)).status === "open" && (await askOf(broken, lf.id)).status === "open", "during the pause nothing else is taken, and the question is not given up");
  fs.rmSync(path.join(HOME, "chats", broken));
  await restartWith(() => writeConfig());
  ok(await waitFor(async () => (await askOf(doc, waiting.id)).status === "answered", 15000, 200), "after a restart the waiting question is answered");
  await api("DELETE", `/api/doc/${broken}/asks/${lf.id}`);

  console.log("== other errors (answer too long for the server): two more tries with growing gaps, then failed");
  setMode({ mode: "huge" });
  const hg = await createAsk(doc, "quick", 1);
  const hgDone = await waitFor(async () => { const x = await askOf(doc, hg.id); return x.status === "failed" ? x : null; }, 40000, 300);
  ok(hgDone && /^Gescheitert: /.test(hgDone.note), "failed after the third try, with the reason", hgDone);
  const hgRuns = calls().filter((x) => x.args && x.mode === "huge").length;
  ok(hgRuns === 3, `Claude ran 3 times for it, not endlessly (${hgRuns})`);

  console.log("== chat budget (chatMB): a question that would bring the chat over it starts a new one");
  await restartWith(() => writeConfig({ chatMB: 1 }));
  setMode({ mode: "ok" });
  const nowD = Date.now() / 1000;
  const sidOf = (x) => x.args[x.args.indexOf(x.args.includes("--resume") ? "--resume" : "--session-id") + 1];
  const stateOf = (id) => JSON.parse(fs.readFileSync(path.join(HOME, "state.json"), "utf8")).docs[id];
  // je Frage 4000 Bytes (Bild der Frage 1000, Seite 3000), mit Seiten um die Frage dazu deren PDF
  async function budgetAsk(d, ctxBytes) {
    const x = await createAsk(d, "quick", 1, ctxBytes ? { span: [0, 2], pages: [0], bytes: ctxBytes } : null);
    const done = await waitFor(async () => (await askOf(d, x.id)).status === "answered", 15000, 100);
    return { id: x.id, done, c: calls().filter((y) => y.args).at(-1) };
  }
  const bd = uuid();
  await api("PUT", `/api/library/${bd}`, { json: { id: bd, title: "Budget", kind: "notebook", created: nowD, modified: nowD, pageCount: 3 } });
  const bu1 = await budgetAsk(bd, 400000), bu2 = await budgetAsk(bd, 400000), bu3 = await budgetAsk(bd, 400000);
  ok(bu1.done && bu2.done && bu3.done, "budget: three questions answered");
  ok(bu1.c.args.includes("--session-id") && bu2.c.args.includes("--resume") && sidOf(bu2.c) === sidOf(bu1.c), "second question (0.8 MB in all) continues the chat", [bu1, bu2].map((b) => b.c.args.slice(0, 2)));
  ok(bu3.c.args.includes("--session-id") && sidOf(bu3.c) !== sidOf(bu1.c) && /Dokument: „Budget“/.test(promptOf(bu3.c)), "the third would make 1.2 MB: new chat with the full intro", bu3.c.args.slice(0, 2));
  ok(logText().includes(`${bu3.id} Chat 0,8 MB + diese Frage 0,4 MB, mehr als 1,0 MB: neuer Chat`) && !logText().split("\n").some((l) => l.includes(bu2.id) && l.includes("neuer Chat")), "logged with both sizes and the budget, only for the third", logText().split("\n").filter((l) => l.includes("neuer Chat")).slice(-2));
  ok(stateOf(bd)?.chatBytes === 404000 && stateOf(bd).session === sidOf(bu3.c), "counting starts again with the new chat", stateOf(bd));

  console.log("== chat budget: a chat from the older helper (not counted) is estimated from the files of its questions");
  const lg = uuid();
  await api("PUT", `/api/library/${lg}`, { json: { id: lg, title: "Alt", kind: "notebook", created: nowD, modified: nowD, pageCount: 3 } });
  const lg1 = await budgetAsk(lg, 400000);
  await restartWith(() => {
    const st = JSON.parse(fs.readFileSync(path.join(HOME, "state.json"), "utf8"));
    delete st.docs[lg].chatBytes;
    fs.writeFileSync(path.join(HOME, "state.json"), JSON.stringify(st));
  });
  const lg2 = await budgetAsk(lg, 400000), lg3 = await budgetAsk(lg, 400000);
  ok(lg1.done && lg2.done && lg3.done, "three questions answered");
  ok(logText().includes(`${lg2.id} Chat ohne Zählung (frühere Fassung), geschätzt 0,4 MB`) && lg2.c.args.includes("--resume") && sidOf(lg2.c) === sidOf(lg1.c), "estimated from the first question's files (0.4 MB), the chat continues", lg2.c.args.slice(0, 2));
  ok(lg3.c.args.includes("--session-id") && logText().includes(`${lg3.id} Chat 0,8 MB + diese Frage 0,4 MB`), "the estimate counts: the third starts a new chat (it would not, if an old chat counted as empty)", lg3.c.args.slice(0, 2));

  console.log("== chat budget: a small PDF read whole does not count, only a changed one in a running chat");
  setPages({ n: 6 });
  const kd = uuid();
  await api("PUT", `/api/library/${kd}`, { json: { id: kd, title: "Klein", kind: "pdf", created: nowD, modified: nowD, pageCount: 6, pdfVersion: 1 } });
  await api("PUT", `/api/pdf/${kd}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "k".repeat(600000)), headers: { "content-type": "application/pdf" } });
  const kl1 = await budgetAsk(kd);
  ok(kl1.done && kl1.c.sizes["dokument.pdf"] === 600009 && !/seiten-/.test(promptOf(kl1.c)) && stateOf(kd)?.chatBytes === 4000, "first question: the whole small PDF is not counted (4000 bytes)", { st: stateOf(kd), sizes: kl1.c.sizes });
  await api("PUT", `/api/library/${kd}`, { json: { id: kd, title: "Klein", kind: "pdf", created: nowD, modified: nowD + 5, pageCount: 6, pdfVersion: 2 } });
  await api("PUT", `/api/pdf/${kd}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "n".repeat(600000)), headers: { "content-type": "application/pdf" } });
  const kl2 = await budgetAsk(kd), kl3 = await budgetAsk(kd);
  ok(kl2.done && kl2.c.args.includes("--resume") && /PDF wurde seit der letzten Frage geändert/.test(promptOf(kl2.c)) && kl3.done && kl3.c.args.includes("--resume") && stateOf(kd).chatBytes === 4000 + 604009 + 4000, "changed PDF in the running chat counts once (0.6 MB), the chat goes on", stateOf(kd));
  setPages({ n: 30 });
  await restartWith(() => writeConfig());

  console.log("== restart while Claude works: the question is handed back at once");
  setMode({ mode: "ok", delayMs: 8000 });
  const rs = await createAsk(doc, "quick", 1);
  ok(await waitFor(async () => (await askOf(doc, rs.id)).status === "claimed", 10000, 100), "claimed");
  helper.kill("SIGTERM");
  const rsBack = await waitFor(async () => { const x = await askOf(doc, rs.id); return x.status === "open" ? x : null; }, 5000, 100);
  ok(rsBack && /neu gestartet/.test(rsBack.note || ""), "handed back right away with a note", rsBack);
  setMode({ mode: "ok" });
  await sleep(500);
  const tRestart = Date.now();
  startHelper();
  ok(await waitFor(async () => (await askOf(doc, rs.id)).status === "answered", 15000, 200), `answered right after the restart (${((Date.now() - tRestart) / 1000).toFixed(1)} s), not after its 20-minute lease`);

  await weitereTests(restartWith);
  await vokabelTests();
  await lernTests();
  helper.kill("SIGTERM");
  const logPath = path.join(HOME, "helfer.log");
  if (!failures && !process.env.KEEP) fs.rmSync(TMP, { recursive: true, force: true });
  console.log(`\n${passes} passed, ${failures} failed${failures || process.env.KEEP ? ` (Protokoll: ${logPath})` : ""}`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); helper?.kill(); process.exit(2); });

async function createLern(wort, versuch = 1, gelesen = undefined) {
  const id = uuid();
  const f = new FormData();
  f.append("meta", JSON.stringify({ anchor: { page: 0, x: 0, y: 0, w: 768, h: 200 }, pv: 0, created: Date.now() / 1000, from: "iPad", wort, satz: `Ein Satz mit ${wort}.`, versuch, ...(gelesen !== undefined ? { gelesen } : {}) }));
  f.append("question", new Blob([PNG()], { type: "image/png" }), "question.png");
  f.append("page", new Blob([PNG()], { type: "image/png" }), "page.png");
  const r = await api("PUT", `/api/doc/lernwoerter/asks/${id}`, { body: f });
  if (r.status !== 200) throw new Error("lern " + r.status + JSON.stringify(r.data));
  return id;
}
const lernAnswer = async (id) => {
  const x = await waitFor(async () => { const a = await askOf("lernwoerter", id); return a?.status === "answered" || a?.status === "failed" ? a : null; }, 15000, 50);
  return x;
};
const promptAny = (c) => c.streamPrompt || promptOf(c);

async function lernTests() {
  console.log("== Lernwörter");
  setMode({ mode: "ok", gelesen: "Farad" });
  let n = calls().filter((x) => x.args).length;
  let id = await createLern("Fahrrad");
  let x = await lernAnswer(id);
  let ans = x && JSON.parse(x.answer);
  ok(ans?.gelesen === "Farad" && ans.richtig === false && ans.hinweis === null, "lesen: gelesen, falsch, ohne Hinweis", x);
  let lc = calls().filter((c) => c.args).slice(n);
  ok(lc.length === 1 && lc[0].stream && lc[0].imageBytes === 1000, "ein Aufruf, Bild in der Nachricht (stream-json)", lc.map((c) => [c.stream, c.imageBytes]));
  ok(!promptAny(lc[0]).includes("Fahrrad") && !systemOf(lc[0]).includes("Fahrrad") && promptAny(lc[0]).includes("Auf dem Bild steht"), "Lesen kennt das Wort nicht", promptAny(lc[0]));
  ok(fs.existsSync(path.join(lc[0].cwd, "wort.png")), "Bild auch im Ordner");
  ok(optOf(lc[0], "--tools") === "Read" && lc[0].args[lc[0].args.indexOf("--effort") + 1] === "low" && lc[0].args.includes("--restricted") && !lc[0].args.includes("--allowedTools") && lc[0].args.includes("--verbose"), "nur Read, effort low, eingeschränkt, kein Internet", lc[0].args);
  ok(lc[0].envKeys.length === 0, "kein Schlüssel in der Umgebung");
  await api("DELETE", `/api/doc/lernwoerter/asks/${id}`);

  // Tipp als eigene Frage (mit dem Gelesenen)
  n = calls().filter((c) => c.args).length;
  id = await createLern("Fahrrad", 1, "Farad");
  x = await lernAnswer(id);
  ans = x && JSON.parse(x.answer);
  ok(/doppelter Mitlaut/.test(ans?.hinweis || "") && ans.gelesen === undefined, "Tipp-Frage: nur der Hinweis", x);
  lc = calls().filter((c) => c.args).slice(n);
  ok(lc.length === 1 && !lc[0].stream && promptOf(lc[0]).includes("„Fahrrad“") && promptOf(lc[0]).includes("„Farad“") && promptOf(lc[0]).includes("Verrate das richtige Wort nicht"), "Tipp: Wort, Gelesenes, nicht verraten, ohne Bild", lc.map(promptAny));
  ok(fs.readFileSync(path.join(HOME, "helfer.log"), "utf8").includes("Lernwort, Hinweis"), "Protokoll: Hinweis");

  n = calls().filter((c) => c.args).length;
  id = await createLern("Fahrrad", 2, "Farad");
  x = await lernAnswer(id);
  lc = calls().filter((c) => c.args).slice(n);
  ok(x && promptOf(lc[0]).includes("das Wort darfst du nennen"), "2. Versuch: Wort nennen erlaubt", lc.map(promptAny));

  // Richtig; Großschreibung zählt
  setMode({ mode: "ok", gelesen: "Fahrrad" });
  id = await createLern("Fahrrad");
  x = await lernAnswer(id);
  ok(x && JSON.parse(x.answer).richtig === true, "richtig erkannt", x?.answer);
  setMode({ mode: "ok", gelesen: "fahrrad" });
  id = await createLern("Fahrrad");
  x = await lernAnswer(id);
  ok(x && JSON.parse(x.answer).richtig === false, "klein geschrieben ist nicht richtig");

  // Unleserlich
  setMode({ mode: "ok", unleserlich: true });
  id = await createLern("Meer");
  x = await lernAnswer(id);
  ok(x && JSON.parse(x.answer).unleserlich === true, "unleserlich gemeldet", x?.answer);

  // stream-json geht nicht: einmal Read, danach bleibt es bei Read
  setMode({ mode: "ok", gelesen: "Meer", noStream: true });
  n = calls().filter((c) => c.args).length;
  id = await createLern("Meer");
  x = await lernAnswer(id);
  lc = calls().filter((c) => c.args).slice(n);
  ok(x && JSON.parse(x.answer).richtig === true && lc.length === 2 && lc[0].stream && !lc[1].stream && promptOf(lc[1]).includes("In wort.png steht"), "ohne stream-json: zurück zu Read", lc.map((c) => c.stream));
  n = calls().filter((c) => c.args).length;
  id = await createLern("Meer");
  x = await lernAnswer(id);
  lc = calls().filter((c) => c.args).slice(n);
  ok(x && lc.length === 1 && !lc[0].stream, "danach gleich Read", lc.map((c) => c.stream));
  // Antwort nimmt der Helfer, sobald sie da ist, nicht erst nach der Zusammenfassung (hier 4 s)
  setMode({ mode: "ok", gelesen: "Meer", summaryMs: 4000 });
  let t0 = Date.now();
  id = await createLern("Meer");
  x = await lernAnswer(id);
  ok(x && Date.now() - t0 < 3000 && JSON.parse(x.answer).richtig === true, `Lesen ohne auf die Zusammenfassung zu warten (${Date.now() - t0} ms)`);
  t0 = Date.now();
  id = await createLern("Fahrrad", 1, "Farad");
  x = await lernAnswer(id);
  ok(x && Date.now() - t0 < 3000 && /Mitlaut/.test(JSON.parse(x.answer).hinweis), `Tipp ebenso (${Date.now() - t0} ms)`);
  await sleep(500);
  setMode({ mode: "ok" });
}

async function createFoto(hinweis) {
  const id = uuid();
  const f = new FormData();
  f.append("meta", JSON.stringify({ from: "Mios iPhone", ...(hinweis ? { hinweis } : {}) }));
  const jpg = new Uint8Array(1500); jpg.set([0xff, 0xd8, 0xff, 0xe0]);
  f.append("foto", new Blob([jpg], { type: "image/jpeg" }), "foto.jpg");
  const r = await api("POST", `/api/karten/foto/${id}`, { body: f });
  if (r.status !== 200) throw new Error("foto " + r.status + JSON.stringify(r.data));
  return id;
}
const fotoDone = (id) => waitFor(async () => { const r = await api("GET", `/api/karten/foto/${id}`); return r.data?.status === "answered" || r.data?.status === "failed" ? r.data : null; }, 15000, 50);

async function vokabelTests() {
  console.log("== Vokabelfotos");
  setMode({ mode: "ok" });
  let n = calls().filter((c) => c.args).length;
  let id = await createFoto("Unit 3, Seite 42");
  let x = await fotoDone(id);
  let ans = x && x.answer && JSON.parse(x.answer);
  ok(ans?.titel === "Unit 3" && ans.karten.length === 2 && ans.karten[0].deutsch === "Hund" && ans.karten[1].satzSelbst === false, "Karten aus dem Foto", x);
  ok(ans && ans.geheim === undefined && ans.karten[0].extra === undefined, "nur bekannte Felder", ans);
  let lc = calls().filter((c) => c.args).slice(n);
  ok(lc.length === 1 && lc[0].stream && lc[0].imageBytes === 1500, "ein Aufruf, Foto in der Nachricht", lc.map((c) => [c.stream, c.imageBytes]));
  ok(promptAny(lc[0]).includes("„Unit 3, Seite 42“"), "Mios Hinweis im Auftrag", promptAny(lc[0]));
  ok(optOf(lc[0], "--tools") === "Read" && lc[0].args[lc[0].args.indexOf("--effort") + 1] === "medium" && lc[0].args.includes("--restricted") && !lc[0].args.includes("--allowedTools"), "nur Read, effort medium, eingeschränkt, kein Internet", lc[0].args);
  ok(lc[0].envKeys.length === 0 && fs.existsSync(path.join(lc[0].cwd, "foto.jpg")) && lc[0].cwd.includes("vokabelfotos"), "eigener Ordner, Foto darin, kein Schlüssel");
  ok(fs.readFileSync(path.join(HOME, "helfer.log"), "utf8").includes("Vokabelfoto"), "Protokoll: Vokabelfoto");
  await api("DELETE", `/api/karten/foto/${id}`);

  setMode({ mode: "ok", vokabelnLeer: true });
  id = await createFoto();
  x = await fotoDone(id);
  ans = x && x.answer && JSON.parse(x.answer);
  ok(ans && ans.karten.length === 0 && /keine Vokabeln/.test(ans.problem), "keine Liste: Hinweis für Mio", x);

  setMode({ mode: "error" });
  id = await createFoto();
  x = await waitFor(async () => { const r = await api("GET", `/api/karten/foto/${id}`); return r.data?.status === "open" && r.data.note ? r.data : null; }, 15000, 100);
  ok(x && /Fehler am Mac/.test(x.note), "Fehler: zurück in die Warteschlange mit Hinweis", x);
  await api("DELETE", `/api/karten/foto/${id}`);
  setMode({ mode: "ok" });
  await sleep(300);
}

// ---------- Weitere Seiten zum Nachlesen ----------

// Notizbuchseite i (ab 0) liegt bei y = 6 + i · (A4H + 6), 768 breit (PageLayout); ein PDF stapelt seine Seiten ebenso
const A4H = 768 * 297 / 210, GAP = 6;
const pageTop = (i) => GAP + i * (A4H + GAP);
const round2 = (v) => Math.round(v * 100) / 100;
/// Ein Strich wie aus der App (StrokeCodec: Schlüssel sortiert, zehn Werte je Punkt: x, y, Zeit, Breite, Höhe, Deckkraft,
/// Druck, Azimut, Neigung, Zweitskala; pk, „/“ als „\/“) oder wie aus dem Browser (neun Werte, ohne pk). top: Oberkante
/// der Seite, x und y darin
function inkStroke({ top, x = 120, y = 150, n = 14, browser = false, c = [0, 0, 0, 1], ink = "com.apple.ink.pen" }) {
  const p = Array.from({ length: n }, (_, k) => {
    const q = [round2(x + k * 9), round2(top + y + Math.sin(k / 2) * 8), round2(k * 0.012), 2.4];
    return browser ? [...q, 2.4, 1, 1, 0, 1.571] : [...q, 2.4, 1, 0.42, 0.8, 1.1, 1];
  });
  return browser ? JSON.stringify({ c, ink, p })
    : JSON.stringify({ c, ink, p, pk: Buffer.from(`PKDrawing ${x}/${y}?>`).toString("base64") }).replace(/\//g, "\\/");
}
/// Striche hinauf wie die App (POST /api/doc/<id>/sync); list: [[id, data], …]
const syncAdd = async (doc, list) => {
  const r = await api("POST", `/api/doc/${doc}/sync`, { json: { since: 0, add: list.map(([id, data]) => ({ id, data })), remove: [] } });
  if (r.status !== 200) throw new Error("sync " + r.status);
};
const syncRemove = (doc, ids) => api("POST", `/api/doc/${doc}/sync`, { json: { since: 0, add: [], remove: ids } });
/// Ein kleines echtes PDF mit diesen Seitengrößen (pt; [842, 595] ist Querformat), jede Seite mit Rahmen und Balken
function makePDF(sizes, mark = 0) {
  const objs = [null, "<< /Type /Catalog /Pages 2 0 R >>",
    `<< /Type /Pages /Kids [${sizes.map((_, i) => `${3 + 2 * i} 0 R`).join(" ")}] /Count ${sizes.length} >>`];
  sizes.forEach(([w, h], i) => {
    const content = `0.2 0.3 ${0.5 + mark / 10} rg 40 40 ${w - 80} ${30 + 10 * i} re f 0 0 0 RG 4 w 20 20 ${w - 40} ${h - 40} re S`;
    objs.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Contents ${4 + 2 * i} 0 R >>`);
    objs.push(`<< /Length ${content.length} >>\nstream\n${content}\nendstream`);
  });
  let out = "%PDF-1.4\n";
  const at = [];
  for (let k = 1; k < objs.length; k++) {
    at[k] = out.length;
    out += `${k} 0 obj\n${objs[k]}\nendobj\n`;
  }
  const xref = out.length;
  out += `xref\n0 ${objs.length}\n0000000000 65535 f \n${at.slice(1).map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("")}`;
  return Buffer.from(`${out}trailer\n<< /Size ${objs.length} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`, "latin1");
}
/// Breite und Höhe eines JPEG (aus der SOF-Marke)
function jpegSize(buf) {
  for (let i = 2; i + 9 < buf.length;) {
    if (buf[i] !== 0xff) return null;
    const m = buf[i + 1];
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5) };
    i += 2 + buf.readUInt16BE(i + 2);
  }
  return null;
}
/// Alle Dateien unter dir (ohne Verweisen zu folgen), mit lstat
function walk(dir) {
  const out = [];
  const go = (d) => {
    let list = [];
    try {
      list = fs.readdirSync(d, { withFileTypes: true });
    } catch {}
    for (const e of list) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) go(p);
      else out.push({ file: p, st: fs.lstatSync(p) });
    }
  };
  go(dir);
  return out;
}
const pdfinfo = (file) => execFileSync("pdfinfo", [file], { encoding: "utf8" });
const hasPoppler = (() => {
  try {
    execFileSync("pdfinfo", ["-v"], { stdio: "ignore" });
    execFileSync("pdftoppm", ["-v"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
})();

async function weitereTests(restartWith) {
  console.log("== weitere Seiten zum Nachlesen: setup (proxy counts the server calls, osascript logged in full)");
  const proxy = await startProxy();
  // osascript über eine Hülle, die jeden Aufruf ganz festhält (argv; welche Umgebungswerte den Schlüssel enthalten)
  const OSA_LOG = path.join(FAKE, "osascript-argv.jsonl");
  const osaWrapper = path.join(TMP, "osascript-protokoll");
  fs.writeFileSync(osaWrapper, `#!/usr/bin/env node
const fs = require("fs"), { spawnSync } = require("child_process");
const secret = (v) => [${JSON.stringify(KEY)}, "must-not-leak"].some((s) => String(v).includes(s));
const leak = Object.keys(process.env).filter((k) => secret(process.env[k]));
fs.appendFileSync(${JSON.stringify(OSA_LOG)}, JSON.stringify({ argv: process.argv.slice(2), leak }) + "\\n");
const r = spawnSync(${JSON.stringify(FAKE_OSASCRIPT)}, process.argv.slice(2), { stdio: "inherit" });
process.exit(r.status ?? 1);
`, { mode: 0o755 });
  const env = { BETTERNOTES_HELFER_OSASCRIPT: osaWrapper };
  const cfg = (extra = {}) => writeConfig({ url: proxy.url, ...extra });
  await restartWith(() => cfg(), env);
  const stateDoc = (id) => JSON.parse(fs.readFileSync(path.join(HOME, "state.json"), "utf8")).docs[id];
  const unterlagen = (id) => (logText().split("\n").find((l) => l.includes(`${id} Unterlagen: `)) || "").split(`${id} Unterlagen: `)[1];
  const logOf = (id) => logText().split("\n").filter((l) => l.includes(id));
  const getsOf = (doc) => proxy.seen.filter((u) => u.startsWith(`GET /api/doc/${doc}/strokes?`));
  const cacheOf = (doc) => fs.readdirSync(path.join(HOME, "seitenbilder", doc)).filter((f) => f.endsWith(".pdf"));
  const bgCalls = () => calls().filter((x) => x.bg && x.bg.pdf === "dokument.pdf");
  /// Eine Frage stellen und auf die Antwort warten; c: der Aufruf von Claude dazu
  async function ask(doc, effort, page, ctx, mode) {
    if (mode) setMode(mode);
    const x = await createAsk(doc, effort, page, ctx);
    const done = await waitFor(async () => (await askOf(doc, x.id))?.status === "answered", 20000, 100);
    const c = calls().filter((y) => y.args && promptOf(y)?.includes(`fragen/${x.id}/`)).at(-1) || null;
    return { id: x.id, done: Boolean(done), c, p: c ? promptOf(c) : "" };
  }
  const now = Date.now() / 1000;

  console.log("== weitere Seiten: notebook, the other written pages are offered as files");
  // Geschrieben auf den Seiten 1, 2, 4, 7 (die Frage), 9 und 12; die App zeigt 4 bis 9 (darin 4 und 9 beschrieben)
  const nb = uuid();
  await api("PUT", `/api/library/${nb}`, { json: { id: nb, title: "Weitere", kind: "notebook", created: now, modified: now, pageCount: 12 } });
  await syncAdd(nb, [
    [uuid(), inkStroke({ top: pageTop(0) })],
    [uuid(), inkStroke({ top: pageTop(1), browser: true, c: [0.2, 0.4, 1, 1] })],
    [uuid(), inkStroke({ top: pageTop(3), x: 200 })],
    [uuid(), inkStroke({ top: pageTop(6), x: 300 })],
    [uuid(), inkStroke({ top: pageTop(8), x: 250, browser: true })],
    [uuid(), inkStroke({ top: pageTop(11), x: 180 })],
    [uuid(), inkStroke({ top: pageTop(11), x: 100, y: 300, ink: "com.apple.ink.marker", c: [1, 0.85, 0, 0.5] })],
  ]);
  const ctx = { span: [3, 8], pages: [3, 8], bytes: 2000 };
  const MORE_NB = "weitere beschriebene Seiten zum Nachlesen, je Seite eine Datei, oben mit ihrer Nummer beschriftet, für";
  const DRAWN_NB = "Der Mac zeichnet sie aus den Strichen am Server nach: Ganz frisch Geschriebenes kann fehlen, und die Striche sehen etwas anders aus als in der App.";
  const moreNB = (id, pages, extra = "") => `- fragen/${id}/weitere/seite-<Nummer>.pdf: ${MORE_NB} ${pages}. ${DRAWN_NB}${extra}`;
  const NEAR = "Von Seite 4 bis 9 ist außer der Seite der Frage nur auf den Seiten 4 und 9 etwas geschrieben, die übrigen sind leer.";
  const NOTE_TODAY = `${NEAR} Weitere Seiten hast du zu dieser Frage nicht: Such nicht nach anderen Dateien, und braucht die Frage eine Seite, die du nicht siehst, sag das kurz.`;
  const noteMore = (on, x = "") => `${NEAR} Sonst ist im Notizbuch nur ${on} etwas geschrieben; alle anderen Seiten sind leer.${x} Such nicht nach anderen Dateien.`;
  const nbPrompt = (id, { fresh = false, more = null, note }) => [
    ...(fresh ? ["Dokument: „Weitere“ (Notizbuch mit 12 Seiten).", "", "Frage:"] : ["Neue Frage zum selben Dokument („Weitere“):"]),
    `- fragen/${id}/frage.png: die handgeschriebene Frage`,
    `- fragen/${id}/seite.jpg: die ganze Seite 7, die Frage darauf farbig umrandet`,
    `- fragen/${id}/nachbarseiten.pdf: die Seiten 4 und 9, wie sie in der App aussehen, jede oben mit ihrer Nummer beschriftet`,
    ...(more ? [more] : []), note, "", "Antworte knapp: das Wesentliche in wenigen Sätzen.",
  ].join("\n");
  // Claude liest die Seiten 1 und 12 (und versucht dokument.pdf, das es im Notizbuch nicht gibt)
  let q = await ask(nb, "quick", 6, ctx, { mode: "ok", readWeitere: [1, 12], readDokument: "4-6" });
  ok(q.done && q.p === nbPrompt(q.id, { fresh: true, more: moreNB(q.id, "die Seiten 1, 2 und 12"), note: noteMore("auf den Seiten 1, 2 und 12") }), "message: the file line for pages 1, 2 and 12 after the app's pages, then where else something is written", q.p);
  ok(q.c.args[q.c.args.indexOf("--output-format") + 1] === "stream-json" && q.c.args.includes("--verbose") && optOf(q.c, "--max-turns") === "40", "stream-json (the helper sees what Claude reads), 40 turns", q.c.args);
  ok(unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten 1, 2, 12 (3 neu gezeichnet)", "log: which pages, three drawn", unterlagen(q.id));
  const listing = q.c.weitere || [];
  ok(listing.map((f) => f.name).join(",") === "seite-1.pdf,seite-12.pdf,seite-2.pdf" && listing.every((f) => f.file && !f.symlink && f.nlink === 1 && f.size > 1000), "while Claude runs: one file per page, copies (nlink 1, no links)", listing);
  const qdir = path.join(HOME, "chats", nb, "fragen", q.id);
  ok(fs.readdirSync(path.join(qdir, "weitere")).sort().join(",") === "seite-1.pdf,seite-12.pdf", "afterwards only what Claude read is left (seite-2.pdf deleted)", fs.readdirSync(path.join(qdir, "weitere")));
  ok(logOf(q.id).some((l) => l.endsWith(`${q.id} weitere Seiten gelesen: 1, 12 (0,0 MB)`)), "log: pages read", logOf(q.id));
  let st = stateDoc(nb);
  const sizeOf = (list, n) => list.find((f) => f.name === `seite-${n}.pdf`)?.size;
  ok(st.chatBytes === 1000 + 3000 + 2000 + sizeOf(listing, 1) + sizeOf(listing, 12) && st.chatPages === 2, "chat counts the question's files and the two pages read (dokument.pdf does not exist here: nothing)", { st, listing });
  const cached = (key) => path.join(HOME, "seitenbilder", nb, `${key}.pdf`);
  ok(Object.keys(st.gelesen || {}).join(",") === "1,12" && fs.existsSync(cached(st.gelesen[1])) && fs.readFileSync(cached(st.gelesen[1])).equals(fs.readFileSync(path.join(qdir, "weitere", "seite-1.pdf"))) && fs.statSync(cached(st.gelesen[1])).nlink === 1, "state: pages read with their drawn version; the copy equals the drawn page, no hard link", st.gelesen);
  ok(fs.existsSync(path.join(HOME, "spiegel", nb, "striche.ndjson")) && fs.existsSync(path.join(HOME, "spiegel", nb, "stand.json")) && !walk(path.join(HOME, "chats")).some((f) => /spiegel|seitenbilder|striche\.ndjson|hintergrund\.js/.test(f.file)), "copy of the strokes and drawn pages outside chats/", walk(path.join(HOME, "spiegel")).map((f) => f.file));
  if (hasPoppler) {
    const info = pdfinfo(path.join(qdir, "weitere", "seite-12.pdf"));
    ok(/^Pages:\s+1$/m.test(info) && /^Page size:\s+1200 x 1741 pts/m.test(info), "seite-12.pdf: one page, 1200 × 1741 (page and band, like the app's pages)", info);
  }
  ok(systemOf(q.c).includes("Rate keine Dateinamen: Es gibt nur die Dateien, die die Nachricht zur Frage nennt.\n- Nennt die Nachricht weitere Seiten zum Nachlesen (seite-<Nummer>.pdf), entscheidest du selbst, ob du welche brauchst: Baut die Frage auf etwas auf, das woanders im Dokument steht (eine Definition, eine Bezeichnung, eine frühere Rechnung oder Skizze, „siehe oben“), lies gezielt die Seiten, auf denen es stehen dürfte, mehrere auf einmal; weißt du nicht, wo, beginne mit den Seiten vor der Frage. Geht es ohne, lies keine, und nie mehr, als die Nachricht erlaubt.\n- Antworte") && systemOf(q.c).includes("Bilder von Seiten zu früheren Fragen zeigen den Stand von damals, ebenso Seiten, die du früher nachgelesen hast; seither können Seiten dazugekommen, weggefallen oder verschoben sein."), "system prompt: Claude decides itself, reads on purpose, never more than allowed", systemOf(q.c));

  console.log("== weitere Seiten: the next question fetches only what changed and draws only the changed page");
  const gets0 = getsOf(nb).length, cache0 = cacheOf(nb).length, seen0 = st.gelesen;
  await syncAdd(nb, [[uuid(), inkStroke({ top: pageTop(11), x: 400, y: 600 })]]);
  q = await ask(nb, "quick", 6, ctx, { mode: "ok", readWeitere: [1, 12] });
  const gets = getsOf(nb).slice(gets0);
  ok(q.done && gets.length === 1 && /since=[1-9]\d*&/.test(gets[0]), "one call to the server, from where the copy stood", gets);
  ok(unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten 1, 2, 12 (1 neu gezeichnet)" && cacheOf(nb).length === cache0 + 1, "only page 12 drawn again", [unterlagen(q.id), cacheOf(nb).length]);
  ok(q.p === nbPrompt(q.id, { more: moreNB(q.id, "die Seiten 1, 2 und 12", " Seit du sie in diesem Chat nachgelesen hast, unverändert: Seite 1; geändert: Seite 12."), note: noteMore("auf den Seiten 1, 2 und 12") }), "same chat: which pages read before are unchanged, which changed", q.p);
  st = stateDoc(nb);
  ok(st.gelesen[1] === seen0[1] && st.gelesen[12] !== seen0[12] && st.chatPages === 4, "state: page 1 the same, page 12 the new version, 4 pages in the chat", st);

  console.log("== weitere Seiten: nothing else written: the message exactly as without them");
  const solo = uuid();
  await api("PUT", `/api/library/${solo}`, { json: { id: solo, title: "Nur hier", kind: "notebook", created: now, modified: now, pageCount: 5 } });
  await syncAdd(solo, [[uuid(), inkStroke({ top: pageTop(0) })], [uuid(), inkStroke({ top: pageTop(2), browser: true })]]);
  const soloCtx = { span: [0, 4], pages: [0], bytes: 900 };
  const soloPrompt = (id) => [
    "Dokument: „Nur hier“ (Notizbuch mit 5 Seiten).", "", "Frage:",
    `- fragen/${id}/frage.png: die handgeschriebene Frage`,
    `- fragen/${id}/seite.jpg: die ganze Seite 3, die Frage darauf farbig umrandet`,
    `- fragen/${id}/nachbarseiten.pdf: Seite 1, wie sie in der App aussieht, oben mit ihrer Nummer beschriftet`,
    "Von Seite 1 bis 5 ist außer der Seite der Frage nur auf Seite 1 etwas geschrieben, die übrigen sind leer. Weitere Seiten hast du zu dieser Frage nicht: Such nicht nach anderen Dateien, und braucht die Frage eine Seite, die du nicht siehst, sag das kurz.",
    "", "Antworte knapp: das Wesentliche in wenigen Sätzen.",
  ].join("\n");
  q = await ask(solo, "quick", 2, soloCtx, { mode: "ok" });
  ok(q.done && q.p === soloPrompt(q.id) && optOf(q.c, "--max-turns") === "30" && q.c.weitere === null, "message as today, 30 turns, no folder", q.p);
  ok(unterlagen(q.id) === "Nachbarseiten 1 (Bereich 1–5)", "log as today", unterlagen(q.id));
  const soloWith = { p: q.p.replaceAll(q.id, "<id>"), system: systemOf(q.c) };

  console.log("== weitere Seiten: the app's pages did not come (older app, download failed): the helper offers them too");
  q = await ask(nb, "quick", 6, null, { mode: "ok" });
  const ALL = "die Seiten 1, 2, 4, 9 und 12";
  const oldApp = (id, extra) => ["Neue Frage zum selben Dokument („Weitere“):", `- fragen/${id}/frage.png: die handgeschriebene Frage`,
    `- fragen/${id}/seite.jpg: die ganze Seite 7, die Frage darauf farbig umrandet`, moreNB(id, ALL, extra),
    "Außer der Seite der Frage ist im Notizbuch nur auf den Seiten 1, 2, 4, 9 und 12 etwas geschrieben; alle anderen Seiten sind leer. Such nicht nach anderen Dateien.",
    "", "Antworte knapp: das Wesentliche in wenigen Sätzen."].join("\n");
  const SAME = " Seit du sie in diesem Chat nachgelesen hast, unverändert: die Seiten 1 und 12.";
  ok(q.done && q.p === oldApp(q.id, SAME), "older app: all written pages but the question's, said without a range", q.p);
  ok(unterlagen(q.id) === "ohne Nachbarseiten (nicht mitgeschickt oder Seiten seither gerückt), weitere Seiten 1, 2, 4, 9, 12 (2 neu gezeichnet)", "log: 4 and 9 drawn now", unterlagen(q.id));
  proxy.intercept = (req) => (/^\/api\/asks\/[^/]+\/pages$/.test(req.url) ? [500, "kaputt"] : null);
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  proxy.intercept = () => null;
  ok(q.done && q.p === oldApp(q.id, SAME) && unterlagen(q.id) === "Nachbarseiten nicht geladen, weitere Seiten 1, 2, 4, 9, 12", "download of the app's pages failed: the same", [q.p, unterlagen(q.id)]);

  console.log("== weitere Seiten: the question's page state differs from the server's: none, texts as today");
  let g = getsOf(nb).length;
  q = await ask(nb, "quick", 6, { ...ctx, pv: 777 }, { mode: "ok" });
  ok(q.done && q.p === nbPrompt(q.id, { note: NOTE_TODAY }) && optOf(q.c, "--max-turns") === "30" && q.c.weitere === null && unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten aus: Seitenstand anders", "page numbers would not match: none", [q.p, unterlagen(q.id)]);

  console.log("== weitere Seiten: server without the strokes route: none, logged once, asked again after 10 minutes or a restart");
  proxy.intercept = (req) => (req.method === "GET" && /^\/api\/doc\/[^/]+\/strokes\?/.test(req.url) ? [404, { error: "Unbekannte Adresse" }] : null);
  g = getsOf(nb).length;
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  const q404 = await ask(nb, "quick", 6, ctx);
  proxy.intercept = () => null;
  ok(q.done && q404.done && [q, q404].every((x) => x.p === nbPrompt(x.id, { note: NOTE_TODAY }) && unterlagen(x.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten aus: Server ohne Route"), "texts as today", [unterlagen(q.id), unterlagen(q404.id)]);
  ok(getsOf(nb).length === g + 1 && logText().split("\n").filter((l) => l.includes("Weitere Seiten: Der Server kennt die Striche-Abfrage noch nicht (Server-Update nötig), neuer Versuch alle 10 Minuten")).length === 1, "one call (404), then none; logged once", getsOf(nb).slice(g));
  // Server-Update da, der Helfer neu gestartet (Einrichten): Die Pause steht nicht im Zustand, er fragt gleich wieder
  await restartWith(() => {
    cfg({ morePages: { quick: 2 }, morePagesSeconds: { quick: 0 } });
    const s = JSON.parse(fs.readFileSync(path.join(HOME, "state.json"), "utf8"));
    ok(!JSON.stringify(s.weitere || {}).includes("offUntil"), "the pause is not kept in the state (a restart asks again at once)", s.weitere);
  }, env);

  console.log("== weitere Seiten: at most morePages; a page not drawn in time is not offered, then drawn when idle");
  await syncAdd(nb, [[uuid(), inkStroke({ top: pageTop(9), x: 333 })]]);
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  const AT_MOST_2 = " Lies davon höchstens 2; findest du darin nicht, was die Frage braucht, sag das kurz.";
  ok(q.done && q.p === nbPrompt(q.id, { more: moreNB(q.id, "die Seiten 1, 2 und 12", `${AT_MOST_2}${SAME}`), note: noteMore("auf den Seiten 1, 2, 10 und 12", " Seite 10 gibt es zu dieser Frage nicht zum Nachlesen; braucht die Frage diese Seite, sag das kurz.") }), "page 10 not ready by the deadline: said so; at most 2 to read, and to say so if they lack what the question needs", q.p);
  ok(unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten 1, 2, 12, nicht bereit 10", "log: not ready", unterlagen(q.id));
  ok(await waitFor(() => logText().includes(`Weitere Seiten: 1 Seite von ${nb.slice(0, 8)} vorgezeichnet`), 15000, 100), "drawn afterwards while nothing is open");
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  ok(q.done && q.p === nbPrompt(q.id, { more: moreNB(q.id, "die Seiten 1, 2, 10 und 12", `${AT_MOST_2}${SAME}`), note: noteMore("auf den Seiten 1, 2, 10 und 12") }) && unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten 1, 2, 10, 12", "next question: page 10 there (still no time to draw)", [q.p, unterlagen(q.id)]);
  {
    // Zwei Seiten nicht rechtzeitig gezeichnet: der Satz dazu in der Mehrzahl
    const mz = uuid();
    await api("PUT", `/api/library/${mz}`, { json: { id: mz, title: "Mehrzahl", kind: "notebook", created: now, modified: now, pageCount: 6 } });
    await syncAdd(mz, [0, 2, 4].map((i) => [uuid(), inkStroke({ top: pageTop(i), x: 100 + 30 * i })]));
    const m1 = await ask(mz, "quick", 0, null, { mode: "ok" });
    ok(m1.done && m1.c.weitere === null && await waitFor(() => logText().includes(`Weitere Seiten: 2 Seiten von ${mz.slice(0, 8)} vorgezeichnet`), 15000, 100), "nothing drawn in time: nothing offered, both pages drawn when idle", logOf(m1.id));
    await syncAdd(mz, [3, 5].map((i) => [uuid(), inkStroke({ top: pageTop(i), x: 100 + 30 * i })]));
    const m2 = await ask(mz, "quick", 0, null, { mode: "ok" });
    ok(m2.done && m2.p === ["Neue Frage zum selben Dokument („Mehrzahl“):", `- fragen/${m2.id}/frage.png: die handgeschriebene Frage`,
      `- fragen/${m2.id}/seite.jpg: die ganze Seite 1, die Frage darauf farbig umrandet`, moreNB(m2.id, "die Seiten 3 und 5"),
      "Außer der Seite der Frage ist im Notizbuch nur auf den Seiten 3 bis 6 etwas geschrieben; alle anderen Seiten sind leer. Die Seiten 4 und 6 gibt es zu dieser Frage nicht zum Nachlesen; braucht die Frage eine davon, sag das kurz. Such nicht nach anderen Dateien.",
      "", "Antworte knapp: das Wesentliche in wenigen Sätzen."].join("\n") && unterlagen(m2.id) === "ohne Nachbarseiten (nicht mitgeschickt oder Seiten seither gerückt), weitere Seiten 3, 5, nicht bereit 4, 6", "pages 4 and 6 not ready: said in the plural", [m2.p, unterlagen(m2.id)]);
  }

  console.log("== weitere Seiten: off in config.json: texts as today, no call to the server");
  await restartWith(() => cfg({ morePages: { quick: 0, thorough: 0 } }), env);
  g = getsOf(nb).length;
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  ok(q.done && q.p === nbPrompt(q.id, { note: NOTE_TODAY }) && optOf(q.c, "--max-turns") === "30" && q.c.weitere === null && getsOf(nb).length === g, "message as today, nothing fetched", q.p);
  ok(unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten aus (config)", "log: off", unterlagen(q.id));

  console.log("== weitere Seiten: daily limit of rows read at the server reached: none");
  await restartWith(() => cfg({ mirrorRowsPerDay: 1 }), env);
  g = getsOf(nb).length;
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  ok(q.done && q.p === nbPrompt(q.id, { note: NOTE_TODAY }) && unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten aus: Tageslimit erreicht" && getsOf(nb).length === g, "texts as today, no call", [unterlagen(q.id), getsOf(nb).slice(g)]);
  await restartWith(() => cfg(), env);

  console.log("== weitere Seiten: a page inserted in the app, its strokes being moved: pages from there withheld");
  {
    // Die App lädt nach dem Einfügen jeden Strich darunter eine Seite tiefer mit neuer ID hinauf und löscht die alten
    // erst mit dem letzten Stück: eine Weile beide („Zwillinge“)
    const tw = uuid(), pv = Date.now();
    await api("PUT", `/api/library/${tw}`, { json: { id: tw, title: "Zwillinge", kind: "notebook", created: now, modified: now, pageCount: 7, pagesVersion: pv } });
    const old = [[uuid(), 3, 150], [uuid(), 3, 420], [uuid(), 4, 200], [uuid(), 4, 520]];
    await syncAdd(tw, [[uuid(), inkStroke({ top: pageTop(0), x: 90 })], [uuid(), inkStroke({ top: pageTop(1), x: 260, browser: true })],
      ...old.map(([id, i, x]) => [id, inkStroke({ top: pageTop(i), x })])]);
    await syncAdd(tw, old.map(([, i, x]) => [uuid(), inkStroke({ top: pageTop(i + 1), x })]));
    const twPrompt = (id, fresh, more, note) => [
      ...(fresh ? ["Dokument: „Zwillinge“ (Notizbuch mit 7 Seiten).", "", "Frage:"] : ["Neue Frage zum selben Dokument („Zwillinge“):"]),
      `- fragen/${id}/frage.png: die handgeschriebene Frage`, `- fragen/${id}/seite.jpg: die ganze Seite 1, die Frage darauf farbig umrandet`,
      more, note, "", "Antworte knapp: das Wesentliche in wenigen Sätzen."].join("\n");
    q = await ask(tw, "quick", 0, { pv }, { mode: "ok" });
    ok(q.done && q.p === twPrompt(q.id, true, moreNB(q.id, "Seite 2"), "Bis Seite 3 ist außer der Seite der Frage nur auf Seite 2 etwas geschrieben; ab Seite 4 werden die Seiten nach einer Seitenänderung gerade neu abgeglichen, von dort gibt es diesmal nichts zum Nachlesen. Such nicht nach anderen Dateien."), "only page 2, and from page 4 on nothing this time", q.p);
    ok(unterlagen(q.id) === "ohne Nachbarseiten (nicht mitgeschickt oder Seiten seither gerückt), weitere Seiten 2 (1 neu gezeichnet), im Abgleich ab 4", "log: being matched from page 4", unterlagen(q.id));
    await syncRemove(tw, old.map(([id]) => id));
    q = await ask(tw, "quick", 0, { pv }, { mode: "ok" });
    ok(q.done && q.p === twPrompt(q.id, false, moreNB(q.id, "die Seiten 2, 5 und 6"), "Außer der Seite der Frage ist im Notizbuch nur auf den Seiten 2, 5 und 6 etwas geschrieben; alle anderen Seiten sind leer. Such nicht nach anderen Dateien.") && unterlagen(q.id) === "ohne Nachbarseiten (nicht mitgeschickt oder Seiten seither gerückt), weitere Seiten 2, 5, 6 (2 neu gezeichnet)", "old copies removed: pages 2, 5 and 6 at their new place", [q.p, unterlagen(q.id)]);
  }

  if (!hasPoppler) {
    console.log("== skipped: weitere Seiten of a PDF (pdfinfo/pdftoppm missing)");
  } else {
    console.log("== weitere Seiten: PDF with a landscape page: the PDF page under the notes, cached per PDF version");
    setPages({ n: 4 });
    const pd = uuid();
    const sizes = [[595, 842], [595, 842], [842, 595], [595, 842]];
    const meta = { id: pd, title: "Skript quer", kind: "pdf", created: now, modified: now, pageCount: 4, pdfVersion: 1 };
    await api("PUT", `/api/library/${pd}`, { json: meta });
    await api("PUT", `/api/pdf/${pd}`, { body: makePDF(sizes, 0), headers: { "content-type": "application/pdf" } });
    const hs = sizes.map(([w, h]) => 768 * h / w);
    const ptop = (i) => GAP + hs.slice(0, i).reduce((s, h) => s + h + GAP, 0);
    await syncAdd(pd, [[uuid(), inkStroke({ top: ptop(0) })], [uuid(), inkStroke({ top: ptop(2), x: 300, y: 100 })],
      [uuid(), inkStroke({ top: ptop(2), x: 60, y: 220, ink: "com.apple.ink.marker", c: [1, 0.9, 0, 0.5] })], [uuid(), inkStroke({ top: ptop(3), browser: true })]]);
    const MORE_PDF = "weitere Seiten mit Notizen aus der App zum Nachlesen, je Seite eine Datei mit der PDF-Seite und den Notizen darauf, oben mit ihrer Nummer beschriftet, für die Seiten 3 und 4. Der Mac zeichnet die Notizen aus den Strichen am Server nach: Ganz frisch Geschriebenes kann fehlen, und die Striche sehen etwas anders aus als in der App.";
    const pdCtx = { span: [0, 1], pages: [] };
    const pdNote = "Von Seite 1 bis 2 gibt es Notizen aus der App nur auf der Seite der Frage; dokument.pdf zeigt das PDF ohne die Notizen aus der App.";
    const bg0 = bgCalls().length;
    // Claude liest Seite 3, Seite 4 scheitert (zählt nicht), und Seiten 1 bis 3 aus dokument.pdf
    q = await ask(pd, "quick", 0, pdCtx, { mode: "ok", readWeitere: [3, 4], readFail: [4], readDokument: "1-3" });
    ok(q.done && q.p === ["Dokument: „Skript quer“ (PDF mit 4 Seiten).", "Das ganze Dokument liegt in dokument.pdf.", "", "Frage:",
      `- fragen/${q.id}/frage.png: die handgeschriebene Frage`, `- fragen/${q.id}/seite.jpg: die ganze Seite 1, die Frage darauf farbig umrandet`,
      `- fragen/${q.id}/weitere/seite-<Nummer>.pdf: ${MORE_PDF}`, `${pdNote} Weiter weg gibt es Notizen aus der App nur auf den Seiten 3 und 4.`,
      "", "Antworte knapp: das Wesentliche in wenigen Sätzen."].join("\n"), "message: PDF pages with the notes, where else there are notes", q.p);
    ok(unterlagen(q.id) === "Nachbarseiten keine beschrieben (Bereich 1–2), ganzes PDF (4 Seiten), weitere Seiten 3, 4 (2 neu gezeichnet)", "log", unterlagen(q.id));
    const vdir = (v) => path.join(HOME, "seitenbilder", pd, `v${v}`);
    const hoehen = JSON.parse(fs.readFileSync(path.join(vdir(1), "hoehen.json"), "utf8"));
    ok(hoehen.heights.length === 4 && hoehen.heights.every((h, i) => Math.abs(h - hs[i]) < 0.5) && hoehen.pages[2].w === 842 && hoehen.pages[2].h === 595, "page heights from the PDF (landscape page 3: 768 · 595/842)", hoehen);
    const bg2 = fs.readFileSync(path.join(vdir(1), "bg-2.jpg")), bg3 = fs.readFileSync(path.join(vdir(1), "bg-3.jpg"));
    // 595 × 842 pt ist bei 768 Breite 1086,8 hoch, bei 1200 Pixeln Breite 1698
    ok(JSON.stringify(jpegSize(bg2)) === JSON.stringify({ w: 1600, h: 1131 }) && JSON.stringify(jpegSize(bg3)) === JSON.stringify({ w: 1200, h: 1698 }), "backgrounds exactly as big as the page area (landscape 1600 × 1131, portrait 1200 × 1698)", [jpegSize(bg2), jpegSize(bg3)]);
    const page3 = path.join(HOME, "chats", pd, "fragen", q.id, "weitere", "seite-3.pdf");
    const images = execFileSync("pdfimages", ["-list", page3], { encoding: "utf8" });
    ok(/^Page size:\s+1600 x 1175 pts/m.test(pdfinfo(page3)) && fs.readFileSync(page3).includes(bg2) && /\s1600\s+1131\s+\S+\s+\d+\s+\d+\s+jpeg\s/.test(images), "seite-3.pdf: landscape page with band, the background JPEG embedded unchanged", [pdfinfo(page3), images]);
    ok(!fs.existsSync(path.join(HOME, "chats", pd, "fragen", q.id, "weitere", "seite-4.pdf")), "seite-4.pdf (its read failed) deleted");
    const bgs = bgCalls().slice(bg0);
    ok(bgs.length === 2 && bgs[0].bg.mode === "hoehen" && bgs[1].bg.mode === "bilder" && bgs[1].bg.specs.join(" ") === "2:1600:1131 3:1200:1698" && bgs.every((x) => x.envKeys.length === 0), "osascript: heights once, both backgrounds in one call, clean environment", bgs);
    st = stateDoc(pd);
    ok(st.chatBytes === 4000 + 450000 + fs.statSync(page3).size && st.chatPages === 4 && Object.keys(st.gelesen).join(",") === "3", "chat: 3 pages from dokument.pdf (150 KB each) and seite-3.pdf counted, the failed read of seite-4.pdf not", st);
    ok(logOf(q.id).some((l) => /weitere Seiten gelesen: 3 \(\d+,\d MB\)$/.test(l)), "log: page 3 read", logOf(q.id));
    q = await ask(pd, "quick", 0, pdCtx, { mode: "ok" });
    ok(q.done && unterlagen(q.id) === "Nachbarseiten keine beschrieben (Bereich 1–2), ganzes PDF (4 Seiten), weitere Seiten 3, 4" && bgCalls().length === bg0 + 2 && q.p.includes(`${MORE_PDF} Seit du sie in diesem Chat nachgelesen hast, unverändert: Seite 3.\n`), "next question: nothing drawn, osascript not asked", [unterlagen(q.id), q.p]);
    // Neue PDF-Fassung: neue Höhen und Hintergründe, die alten weg
    await api("PUT", `/api/pdf/${pd}`, { body: makePDF(sizes, 3), headers: { "content-type": "application/pdf" } });
    await api("PUT", `/api/library/${pd}`, { json: { ...meta, modified: now + 5, pdfVersion: 2 } });
    q = await ask(pd, "quick", 0, pdCtx, { mode: "ok" });
    ok(q.done && unterlagen(q.id) === "Nachbarseiten keine beschrieben (Bereich 1–2), ganzes PDF (4 Seiten), weitere Seiten 3, 4 (2 neu gezeichnet)" && !fs.existsSync(vdir(1)) && fs.existsSync(path.join(vdir(2), "hoehen.json")) && fs.existsSync(path.join(vdir(2), "bg-2.jpg")) && bgCalls().length === bg0 + 4, "new PDF version: drawn again from new backgrounds, the old ones gone", [unterlagen(q.id), fs.readdirSync(path.join(HOME, "seitenbilder", pd))]);
    ok(q.p.startsWith("Das PDF wurde seit der letzten Frage geändert; dokument.pdf ist neu.\n") && q.p.includes(`${MORE_PDF} Seit du sie in diesem Chat nachgelesen hast, geändert: Seite 3.\n`), "Claude is told page 3 changed since it read it", q.p);

    // Notizen auf Seite 4 nicht bereit (hier scheitert ihr Hintergrund): Es fehlen nur die Notizen, nicht die PDF-Seite
    fs.writeFileSync(path.join(FAKE, "bg.json"), JSON.stringify({ failPages: [3] }));
    fs.rmSync(path.join(vdir(2), "bg-3.jpg"));
    await syncAdd(pd, [[uuid(), inkStroke({ top: ptop(3), x: 400, y: 300 })]]);
    q = await ask(pd, "quick", 0, pdCtx, { mode: "ok" });
    fs.rmSync(path.join(FAKE, "bg.json"));
    ok(q.done && q.p.includes(`\n${pdNote} Weiter weg gibt es Notizen aus der App nur auf den Seiten 3 und 4. Die Notizen auf Seite 4 gibt es zu dieser Frage nicht zum Nachlesen (die PDF-Seite selbst steht in dokument.pdf); braucht die Frage diese Notizen, sag das kurz.\n`) && unterlagen(q.id) === "Nachbarseiten keine beschrieben (Bereich 1–2), ganzes PDF (4 Seiten), weitere Seiten 3, nicht bereit 4", "PDF: notes on page 4 not ready: only the notes are missing, the PDF page is in dokument.pdf", [q.p, unterlagen(q.id)]);

    console.log("== weitere Seiten: the PDF background does not work on this Mac: none for PDFs, notebooks still");
    fs.writeFileSync(path.join(FAKE, "bg.json"), JSON.stringify({ fail: true }));
    await restartWith(() => cfg(), env);
    q = await ask(pd, "quick", 0, pdCtx, { mode: "ok" });
    ok(q.done && unterlagen(q.id) === "Nachbarseiten keine beschrieben (Bereich 1–2), ganzes PDF (4 Seiten), weitere Seiten aus: PDF-Hintergrund geht nicht" && q.p.includes(`\n${pdNote} Notizen auf weiter entfernten Seiten siehst du zu dieser Frage nicht.\n`) && q.c.weitere === null, "PDF: texts as today", [unterlagen(q.id), q.p]);
    ok(logText().includes("Weitere Seiten: PDF-Hintergrund geht nicht (execution error: PDFKit kaputt (-2700)), bei PDFs ohne weitere Seiten"), "log says why", logText().split("\n").filter((l) => l.includes("PDF-Hintergrund")).slice(-1));
    q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
    ok(q.done && unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten 1, 2, 10, 12", "notebook in the same run: pages offered", unterlagen(q.id));
    fs.rmSync(path.join(FAKE, "bg.json"));
    setPages({ n: 30 });
  }

  console.log("== weitere Seiten: room in the chat (chatMB): too little for two pages → new chat; not even for one → none");
  {
    const pl = uuid();
    await api("PUT", `/api/library/${pl}`, { json: { id: pl, title: "Platz", kind: "notebook", created: now, modified: now, pageCount: 4 } });
    await syncAdd(pl, [0, 1, 2, 3].map((i) => [uuid(), inkStroke({ top: pageTop(i), x: 100 + 40 * i, browser: i === 2 })]));
    const a1 = await ask(pl, "quick", 3, null, { mode: "ok", readWeitere: [1, 3] });
    const sizes = (a1.c?.weitere || []).map((f) => f.size).sort((x, y) => x - y);
    const s1 = stateDoc(pl);
    ok(a1.done && sizes.length === 3 && s1.chatBytes === 4000 + sizeOf(a1.c.weitere, 1) + sizeOf(a1.c.weitere, 3) && s1.chatPages === 2, "first question: the two pages read counted", { s1, w: a1.c?.weitere });
    const median = sizes[1];
    await restartWith(() => cfg({ chatMB: (s1.chatBytes + 4000 + 1.5 * median) / 1e6 }), env);
    const b1 = await ask(pl, "quick", 3, null, { mode: "ok" });
    ok(b1.done && b1.c.args.includes("--session-id") && b1.p.startsWith("Dokument: „Platz“ (Notizbuch mit 4 Seiten).\n") && b1.p.includes(moreNB(b1.id, "die Seiten 1 bis 3")) && !b1.p.includes("Lies davon") && logOf(b1.id).some((l) => l.includes("zu wenig Platz für weitere Seiten, neuer Chat")), "room for one page in the running chat: new chat, all three offered", [b1.p, logOf(b1.id)]);
    await restartWith(() => cfg({ chatMB: (4000 + 0.5 * median) / 1e6 }), env);
    const c1 = await ask(pl, "quick", 3, null, { mode: "ok" });
    ok(c1.done && c1.p === ["Dokument: „Platz“ (Notizbuch mit 4 Seiten).", "", "Frage:", `- fragen/${c1.id}/frage.png: die handgeschriebene Frage`,
      `- fragen/${c1.id}/seite.jpg: die ganze Seite 4, die Frage darauf farbig umrandet`,
      "Zu dieser Frage hast du vom Notizbuch nur diese eine Seite. Such nicht nach anderen Dateien, und braucht die Frage eine Seite, die du nicht siehst, sag das kurz.",
      "", "Antworte knapp: das Wesentliche in wenigen Sätzen."].join("\n") && optOf(c1.c, "--max-turns") === "30" && c1.c.weitere === null, "not even room for one in a new chat: none, texts as today", c1.p);
    ok(logOf(c1.id).some((l) => l.endsWith(`${c1.id} weitere Seiten aus: kein Platz im Chat`)) && !fs.existsSync(path.join(HOME, "chats", pl, "fragen", c1.id, "weitere")), "logged, folder removed", logOf(c1.id));
    // chatMB 0 heißt jede Frage ein neuer Chat, nicht keine weiteren Seiten: Nachgelesen wird wie mit 8 MB
    await restartWith(() => cfg({ chatMB: 0 }), env);
    const d1 = await ask(pl, "quick", 3, null, { mode: "ok", readWeitere: [1] });
    const d2 = await ask(pl, "quick", 3, null, { mode: "ok" });
    ok([d1, d2].every((x) => x.done && x.c.args.includes("--session-id") && x.p.includes(moreNB(x.id, "die Seiten 1 bis 3")) && !x.p.includes("Lies davon")), "chatMB 0: each question in a new chat, the pages offered as usual", [d1.p, d2.p]);
    // morePages 1: Ein neuer Chat brächte nicht mehr; im laufenden ist Platz für die eine erlaubte Seite
    await restartWith(() => cfg({ morePages: { quick: 1 } }), env);
    const e1 = await ask(pl, "quick", 3, null, { mode: "ok" });
    const e2 = await ask(pl, "quick", 3, null, { mode: "ok" });
    ok(e1.done && e2.done && e2.c.args.includes("--resume") && e2.p.includes(moreNB(e2.id, "die Seiten 1 bis 3", " Lies davon höchstens eine; findest du darin nicht, was die Frage braucht, sag das kurz.")) && !logOf(e2.id).some((l) => l.includes("zu wenig Platz")), "morePages 1: the next question continues the chat, at most one page", [e2.c.args, e2.p, logOf(e2.id)]);
    // Nur eine Seite angeboten, und sie passt noch in den laufenden Chat (zwei passten nicht): kein neuer Chat
    const one = uuid();
    await api("PUT", `/api/library/${one}`, { json: { id: one, title: "Eine", kind: "notebook", created: now, modified: now, pageCount: 2 } });
    await syncAdd(one, [0, 1].map((i) => [uuid(), inkStroke({ top: pageTop(i), x: 120 + 40 * i })]));
    await restartWith(() => cfg(), env);
    const f1 = await ask(one, "quick", 0, null, { mode: "ok" });
    const size1 = sizeOf(f1.c?.weitere || [], 2);
    await restartWith(() => cfg({ chatMB: (stateDoc(one).chatBytes + 4000 + 1.5 * size1) / 1e6 }), env);
    const f2 = await ask(one, "quick", 0, null, { mode: "ok" });
    ok(f1.done && f2.done && size1 > 0 && f2.c.args.includes("--resume") && f2.p.includes(moreNB(f2.id, "Seite 2")) && !f2.p.includes("Lies davon") && !logOf(f2.id).some((l) => l.includes("zu wenig Platz")), "one page offered, room for it in the running chat: the chat continues", [size1, f2.c?.args, f2.p, logOf(f2.id)]);
    await restartWith(() => cfg(), env);
  }

  console.log("== weitere Seiten: stream-json lines of many MB (the content of files read): little memory, answered");
  {
    setMode({ mode: "ok" });
    await ask(nb, "quick", 6, ctx);
    const hwm = () => {
      try {
        return Number(/VmHWM:\s+(\d+) kB/.exec(fs.readFileSync(`/proc/${helper.pid}/status`, "utf8"))[1]) * 1024;
      } catch {
        return null;
      }
    };
    const h1 = hwm();
    q = await ask(nb, "quick", 6, ctx, { mode: "ok", bigLines: 3, bigLineMB: 100 });
    const h2 = hwm();
    ok(q.done && (await askOf(nb, q.id)).answer.startsWith("Antwort (medium)"), "answered after three lines of 100 MB");
    if (h1 && h2) ok(h2 - h1 < 100e6, `the helper's memory peak grew by ${((h2 - h1) / 1e6).toFixed(1)} MB (less than one line)`, { h1, h2 });
    else console.log("  (memory not measured: no /proc)");
    setMode({ mode: "ok" });
  }

  console.log("== weitere Seiten: Claude stops without a result line (crash): the error shows nothing of the stream");
  {
    // Davor liest Claude eine weitere Seite und schreibt Text daraus: Davon darf nichts in die App oder ins Protokoll
    setMode({ mode: "noresult", readWeitere: [1] });
    const x = await createAsk(nb, "quick", 6, ctx);
    const failed = await waitFor(async () => { const a = await askOf(nb, x.id); return a?.status === "failed" ? a : null; }, 20000, 200);
    setMode({ mode: "ok" });
    ok(failed && failed.note === "Claude am Mac: Exit 1", "retried once, then failed with „Claude am Mac: Exit 1“", failed);
    ok(logOf(x.id).filter((l) => l.endsWith("Claude am Mac: Exit 1")).length === 2 && !logOf(x.id).some((l) => /Geheimnis|"type"|tool_/.test(l)), "log: the same, no line of the stream", logOf(x.id));
  }

  console.log("== weitere Seiten: Claude Code without stream-json: none, json as before");
  fs.writeFileSync(path.join(FAKE, "help.json"), JSON.stringify({ version: "new", stream: false }));
  await restartWith(() => cfg(), env);
  q = await ask(nb, "quick", 6, ctx, { mode: "ok" });
  ok(q.done && q.p === nbPrompt(q.id, { note: NOTE_TODAY }) && q.c.args[q.c.args.indexOf("--output-format") + 1] === "json" && !q.c.args.includes("--verbose") && optOf(q.c, "--max-turns") === "30" && q.c.weitere === null && unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9), weitere Seiten aus: Claude Code zu alt", "texts as today, json", [unterlagen(q.id), q.c.args]);
  setHelp("new");

  console.log("== weitere Seiten: helfer.mjs without weitere-seiten.mjs next to it: everything as before");
  {
    const ohne = path.join(TMP, "ohne");
    fs.mkdirSync(ohne, { recursive: true });
    fs.copyFileSync(HELFER, path.join(ohne, "helfer.mjs"));
    const lines0 = logText().split("\n").length;
    await restartWith(() => cfg(), env, path.join(ohne, "helfer.mjs"));
    const since = logText().split("\n").slice(lines0 - 1);
    ok(since.filter((l) => /Weitere Seiten aus: .*weitere-seiten\.mjs/.test(l)).length === 1, "logged once at the start", since.filter((l) => l.includes("Weitere Seiten")));
    const solo2 = uuid();
    await api("PUT", `/api/library/${solo2}`, { json: { id: solo2, title: "Nur hier", kind: "notebook", created: now, modified: now, pageCount: 5 } });
    q = await ask(solo2, "quick", 2, soloCtx, { mode: "ok" });
    ok(q.done && q.p.replaceAll(q.id, "<id>") === soloWith.p && systemOf(q.c) === soloWith.system, "same message and system prompt as with the module when nothing else is written", q.p);
    ok(q.c.args[q.c.args.indexOf("--output-format") + 1] === "json" && !q.c.args.includes("--verbose") && optOf(q.c, "--max-turns") === "30", "json output as before", q.c.args);
    q = await ask(nb, "quick", 6, ctx, { mode: "ok", readWeitere: [1] });
    ok(q.done && q.p === nbPrompt(q.id, { note: NOTE_TODAY }) && q.c.weitere === null && unterlagen(q.id) === "Nachbarseiten 4, 9 (Bereich 4–9)", "written pages elsewhere: nothing offered, texts and log as before", [q.p, unterlagen(q.id)]);
  }

  console.log("== weitere Seiten: right after a restart (setup) the helper fetches a missing copy of the last documents' strokes");
  {
    await restartWith(() => cfg(), env); // wieder der Helfer mit weitere-seiten.mjs daneben
    const fresh = uuid();
    await api("PUT", `/api/library/${fresh}`, { json: { id: fresh, title: "Neu da", kind: "notebook", created: now, modified: now, pageCount: 4 } });
    await syncAdd(fresh, [[uuid(), inkStroke({ top: pageTop(0) })], [uuid(), inkStroke({ top: pageTop(3), x: 220 })]]);
    q = await ask(fresh, "quick", 1, null, { mode: "ok" });
    const mirrorDir = path.join(HOME, "spiegel", fresh), claudeRuns = calls().filter((x) => x.args).length;
    ok(q.done && fs.existsSync(path.join(mirrorDir, "stand.json")), "asked once: its copy exists", q.done);
    // Wie gleich nach dem Einrichten mit dem neuen Helfer: Die Kopie fehlt noch. Dazu zwei ältere Dokumente ohne Kopie,
    // deren letzte Frage beim Start gerade älter als 60 Tage ist: Das Aufräumen beim Start löscht sie (und ändert damit fragen/
    // dieser Dokumente), zu den Dokumenten mit den letzten Fragen macht sie das nicht
    const older = [uuid(), uuid()];
    await restartWith(() => {
      cfg();
      fs.rmSync(mirrorDir, { recursive: true, force: true });
      const st = JSON.parse(fs.readFileSync(path.join(HOME, "state.json"), "utf8"));
      const t = new Date(Date.now() - 61 * 86400000);
      for (const id of older) {
        st.docs[id] = {};
        const f = path.join(HOME, "chats", id, "fragen", uuid());
        fs.mkdirSync(f, { recursive: true });
        fs.utimesSync(f, t, t);
        fs.utimesSync(path.dirname(f), t, t);
      }
      fs.writeFileSync(path.join(HOME, "state.json"), JSON.stringify(st, null, 2));
    }, env);
    const back = await waitFor(() => { try { return JSON.parse(fs.readFileSync(path.join(mirrorDir, "stand.json"), "utf8")).complete === true; } catch { return false; } }, 10000);
    ok(back && getsOf(fresh).some((u) => /since=0&/.test(u)) && calls().filter((x) => x.args).length === claudeRuns, "fetched in idle time without a question, Claude not asked", getsOf(fresh));
    ok(older.every((id) => !getsOf(id).length && !fs.readdirSync(path.join(HOME, "chats", id, "fragen")).length), "not the older documents whose old questions the start just removed", older.map(getsOf));
    const g0 = getsOf(fresh).length;
    await restartWith(() => cfg(), env);
    await sleep(1500);
    ok(getsOf(fresh).length === g0, "a complete copy is not fetched again at the next start (the next question does that)", getsOf(fresh).slice(g0));
  }

  console.log("== weitere Seiten: the key never leaves the helper");
  {
    const secrets = [KEY, "must-not-leak"].map((s) => Buffer.from(s));
    const files = [...walk(path.join(HOME, "chats")), ...walk(path.join(HOME, "spiegel")), ...walk(path.join(HOME, "seitenbilder"))];
    const leaks = [...files.map((f) => f.file), path.join(HOME, "helfer.log"), path.join(FAKE, "calls.jsonl"), ...(fs.existsSync(OSA_LOG) ? [OSA_LOG] : [])]
      .filter((f) => { const b = fs.readFileSync(f); return secrets.some((s) => b.includes(s)); });
    ok(files.length > 20 && !leaks.length, `not in chats/, spiegel/, seitenbilder/, the log or the arguments of claude (${files.length} files)`, leaks);
    ok(!files.some((f) => f.st.isSymbolicLink()) && files.filter((f) => f.file.includes(`${path.sep}weitere${path.sep}`)).every((f) => f.st.nlink === 1), "no links in chats/, every page file a copy of its own");
    // Ohne poppler gab es keine Fragen zu PDFs, also kein osascript
    if (!hasPoppler) console.log("  skip  osascript: arguments and environment (pdfinfo/pdftoppm missing)");
    else {
      const osa = fs.readFileSync(OSA_LOG, "utf8").trim().split("\n").map((l) => JSON.parse(l));
      const bgArgs = osa.filter((o) => o.argv[2]?.endsWith("hintergrund.js"));
      ok(bgArgs.length >= 3 && osa.every((o) => !o.leak.length) && bgArgs.every((o) => ["hoehen", "bilder", "farben"].includes(o.argv[3]) && o.argv.slice(4).every((x) => x.startsWith(HOME) || /^\d+:\d+:\d+$/.test(x))), "osascript: only paths in the helper's folder and numbers, no key in its environment", bgArgs.slice(0, 3));
    }
  }

  await restartWith(() => writeConfig(), {}, HELFER);
  proxy.close();
}
