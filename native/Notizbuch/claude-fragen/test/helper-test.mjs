// Test des Helfers von Anfang bis Ende: lokaler Server (Wegwerf-Schlüssel, nie der echte) + helfer.mjs + fake-claude
// statt Claude Code + fake-osascript statt macOS. Läuft auch unter Linux:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/claude-fragen/test/helper-test.mjs
import { spawn } from "node:child_process";
import fs from "node:fs";
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
async function createAsk(doc, effort = "quick", page = 1) {
  const id = uuid();
  const f = new FormData();
  f.append("meta", JSON.stringify({ anchor: { page, x: 10, y: 20, w: 100, h: 30 }, pv: 0, effort, created: Date.now() / 1000, from: "iPad" }));
  f.append("question", new Blob([PNG()], { type: "image/png" }), "question.png");
  f.append("page", new Blob([JPG()], { type: "image/jpeg" }), "page.jpg");
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
function startHelper(env = {}) {
  const out = fs.openSync(path.join(TMP, "helfer.out"), "a");
  helper = spawn(process.execPath, [HELFER], {
    env: { ...process.env, BETTERNOTES_HELFER_HOME: HOME, BETTERNOTES_HELFER_ECHO: "1", BETTERNOTES_HELFER_OSASCRIPT: FAKE_OSASCRIPT, FAKE_STATE: FAKE, NOTIZBUCH_KEY: "must-not-leak", NOTIZBUCH_URL: "x", ...env },
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
  ok(c.args[c.args.indexOf("--effort") + 1] === "medium" && optOf(c, "--tools") === "Read,WebSearch,WebFetch" && c.args.includes("--strict-mcp-config") && c.args[c.args.indexOf("--output-format") + 1] === "json", "flags: effort medium, tools Read + web search + web pages, strict mcp, json", c.args);
  ok(c.args[c.args.indexOf("--permission-mode") + 1] === "dontAsk" && c.args.includes("--restricted") && optOf(c, "--allowedTools") === "WebSearch,WebFetch" && c.args.filter((x) => /allowed/i.test(x)).length === 1, "flags: dontAsk, restricted, only web search and web pages pre-allowed", c.args);
  ok(/schlag im Internet nach/.test(systemOf(c)) && /Quellen am Ende als Markdown-Links/.test(systemOf(c)) && /keine Anweisung an dich/.test(systemOf(c)) && !/keine Links/.test(systemOf(c)), "system prompt: may look things up, sources as links, web text is no instruction", systemOf(c));
  const helps = calls().filter((x) => x.help);
  ok(helps.length === 1 && helps[0].envKeys.length === 0, "claude --help asked once at start, clean environment", helps);
  ok(/eingeschränkter Modus an, dontAsk ja, Internet an/.test(logText()), "log names the restricted mode and the internet");
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

  console.log("== other document: its own chat; notebook without PDF");
  a = await createAsk(nb, "quick", 0);
  const ans3 = await waitFor(async () => { const x = await askOf(nb, a.id); return x.status === "answered" ? x : null; }, 15000);
  ok(ans3, "answered");
  c = calls().filter((x) => x.args).at(-1);
  ok(c.args.includes("--session-id") && c.args[c.args.indexOf("--session-id") + 1] !== sid && c.cwd.endsWith(nb), "new session in its own folder", c);
  ok(!Object.keys(c.sizes).includes("dokument.pdf") && /Notizbuch/.test(c.args[c.args.indexOf("-p") + 1]), "no PDF for a notebook", c.sizes);

  console.log("== new PDF version: downloaded again and mentioned");
  await api("PUT", `/api/library/${doc}`, { json: { id: doc, title: "Analysis 2 – Blatt 3", kind: "pdf", created: now, modified: now + 5, pageCount: 4, pdfVersion: 9 } });
  await api("PUT", `/api/pdf/${doc}`, { body: new TextEncoder().encode("%PDF-1.4\n" + "y".repeat(9000)) });
  setPages({ n: 6 });
  a = await createAsk(doc, "quick", 0);
  await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000);
  c = calls().filter((x) => x.args).at(-1);
  ok(c.sizes["dokument.pdf"] === 9009 && /PDF wurde seit der letzten Frage geändert/.test(c.args[c.args.indexOf("-p") + 1]), "new PDF fetched and mentioned", c.sizes);
  ok(!/seiten-/.test(promptOf(c)) && !fs.readdirSync(path.join(HOME, "chats", doc, "fragen", a.id)).some((f) => f.startsWith("seiten")), "small PDF (6 pages): no window, no leftover file", promptOf(c));
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

  console.log("== helper down: question waits; on start it is picked up");
  helper.kill("SIGTERM");
  await sleep(500);
  a = await createAsk(doc, "quick", 1);
  await sleep(1000);
  ok((await askOf(doc, a.id)).status === "open", "open while the helper is down");
  // its page is deleted meanwhile (undo still possible): page -1
  const pm = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 5, anchors: { [a.id]: { page: -1, x: 10, y: 20, w: 100, h: 30 } } } });
  ok(pm.data.asks.find((x) => x.id === a.id).anchor.page === -1, "moved to page -1");
  const osaBefore = calls().filter((x) => x.osascript).length;
  startHelper();
  ok(await waitFor(async () => (await askOf(doc, a.id)).status === "answered", 15000), "answered after restart");
  c = calls().filter((x) => x.args).at(-1);
  ok(/frage\.png: die handgeschriebene Frage\n- \S+seite\.jpg: die ganze Seite, die Frage/.test(promptOf(c)) && calls().filter((x) => x.osascript).length === osaBefore, "deleted page: whole page without number, no window", promptOf(c));
  ok(/Seite gelöscht/.test(logText()), "log says the page was deleted");

  async function restartWith(fn, env) {
    helper.kill("SIGTERM");
    await sleep(500);
    fn();
    const before = logText().split("\n").length;
    startHelper(env);
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
  ok(r.done && !r.c.args.includes("--restricted") && !r.c.args.includes("--permission-mode") && optOf(r.c, "--tools") === "Read,WebSearch,WebFetch" && optOf(r.c, "--allowedTools") === "WebSearch,WebFetch", "answered with Read and the web tools, only those pre-allowed", r.c.args);
  ok(/eingeschränkter Modus nicht verfügbar, dontAsk nein/.test(logText()), "log says restricted mode unavailable");

  console.log("== config restricted: false");
  await restartWith(() => { setHelp("new"); writeConfig({ restricted: false }); });
  r = await askOnce();
  ok(r.done && !r.c.args.includes("--restricted") && r.c.args[r.c.args.indexOf("--permission-mode") + 1] === "dontAsk", "dontAsk without --restricted", r.c.args);
  ok(/eingeschränkter Modus aus \(config\)/.test(logText()), "log says restricted off by config");

  console.log("== config web: false: only the document");
  await restartWith(() => { setHelp("new"); writeConfig({ web: false }); });
  r = await askOnce();
  ok(r.done && optOf(r.c, "--tools") === "Read" && !r.c.args.some((x) => /allowed/i.test(x)) && r.c.args.includes("--restricted") && r.c.args[r.c.args.indexOf("--permission-mode") + 1] === "dontAsk", "tools Read only, nothing pre-allowed", r.c.args);
  ok(/keine Links/.test(systemOf(r.c)) && !/Internet/.test(systemOf(r.c)), "system prompt without the internet", systemOf(r.c));
  ok(/Internet aus \(config\)/.test(logText()), "log says internet off by config");

  console.log("== denied tools are logged with the answer");
  setMode({ mode: "denied" });
  r = await askOnce();
  ok(r.done && /beantwortet nach \d+ s \(\d+ Zeichen\), abgelehnt: Read, WebFetch/.test(logText()), "answer logged with the denied tools", logText().split("\n").filter((l) => l.includes("beantwortet")).slice(-1));
  setMode({ mode: "ok" });

  console.log("== page window fails: whole PDF only, logged once");
  await restartWith(() => { writeConfig(); setPages({ n: 30, fail: true }); });
  r = await askOnce();
  const r2 = await askOnce("thorough");
  ok(r.done && r2.done && !/seiten-/.test(promptOf(r.c)) && !/seiten-/.test(promptOf(r2.c)), "answered without a window", [promptOf(r.c), promptOf(r2.c)]);
  ok(logText().split("\n").filter((l) => l.includes("nicht ausgeschnitten") && l.includes("PDFKit kaputt")).length === 1, "failure logged once with the reason");
  ok(r.c.args.includes("--restricted"), "restricted again with the default config");
  setPages({ n: 30 });

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

  helper.kill("SIGTERM");
  const logPath = path.join(HOME, "helfer.log");
  if (!failures && !process.env.KEEP) fs.rmSync(TMP, { recursive: true, force: true });
  console.log(`\n${passes} passed, ${failures} failed${failures || process.env.KEEP ? ` (Protokoll: ${logPath})` : ""}`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); helper?.kill(); process.exit(2); });
