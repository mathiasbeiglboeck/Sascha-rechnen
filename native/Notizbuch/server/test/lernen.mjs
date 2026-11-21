// Test der Lernwörter gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/lernen.mjs
const BASE = process.env.BASE || "http://127.0.0.1:8791";
const KEY = process.env.KEY || "testkey";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
const H = { Authorization: `Bearer ${KEY}` };
let failures = 0, passes = 0;
const ok = (cond, msg, extra) => {
  if (cond) { passes++; console.log("  ok  ", msg); }
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 400) : ""); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const uuid = () => crypto.randomUUID().toUpperCase();
async function api(method, path, { json, body } = {}) {
  const h = { ...H };
  let b = body;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, data: ct.includes("json") ? await r.json() : new Uint8Array(await r.arrayBuffer()) };
}
const PNG = () => { const b = new Uint8Array(200); b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); return b; };
function form(meta) {
  const f = new FormData();
  f.append("meta", JSON.stringify(meta));
  f.append("question", new Blob([PNG()], { type: "image/png" }), "question.png");
  f.append("page", new Blob([PNG()], { type: "image/png" }), "page.png");
  return f;
}
function socket(path) {
  const ws = new WebSocket(BASE.replace(/^http/, "ws") + path, { headers: H });
  const msgs = [];
  ws.onmessage = (e) => msgs.push(String(e.data));
  const opened = new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  return { ws, msgs, opened, json: () => msgs.filter((m) => m.startsWith("{")).map((m) => JSON.parse(m)) };
}
const anchor = { page: 0, x: 0, y: 0, w: 768, h: 200 };

async function main() {
  const app = socket("/api/doc/lernwoerter/ws");
  const helper = socket("/api/asks/ws");
  await Promise.all([app.opened, helper.opened]);

  console.log("== Wortliste");
  let r = await api("GET", "/api/lernen");
  ok(r.status === 200 && Array.isArray(r.data.words) && r.data.words.length === 0, "leer am Anfang", r.data);
  r = await api("POST", "/api/lernen/woerter", { json: { add: [{ wort: " Fahrrad ", satz: "Ich fahre mit dem Fahrrad." }, "Meer", "Mädchen", "", { wort: "x".repeat(61) }] } });
  ok(r.status === 200 && r.data.added.length === 3, "drei gültige Wörter angelegt", r.data);
  await sleep(200);
  ok(app.json().some((m) => m.type === "lernen"), "App bekommt {type: lernen}", app.msgs);
  r = await api("GET", "/api/lernen");
  ok(r.data.words.map((w) => w.wort).join(",") === "Fahrrad,Meer,Mädchen", "Reihenfolge, getrimmt, NFC", r.data.words);
  ok(r.data.words[0].satz === "Ich fahre mit dem Fahrrad." && r.data.words[1].satz === null, "Sätze", r.data.words);
  r = await api("POST", "/api/lernen/woerter", { json: { add: [{ wort: "Meer", satz: "Im Meer schwimmen Fische." }], remove: ["Fahrrad", "Gibtsnicht"] } });
  ok(r.data.removed.join() === "Fahrrad" && r.data.added.join() === "Meer", "entfernen und Satz ersetzen", r.data);
  r = await api("GET", "/api/lernen");
  ok(r.data.words.find((w) => w.wort === "Fahrrad").removed > 0, "entfernt bleibt als Grabstein", r.data.words);
  ok(r.data.words.find((w) => w.wort === "Meer").satz === "Im Meer schwimmen Fische.", "Satz ersetzt");
  r = await api("POST", "/api/lernen/woerter", { json: { add: ["Fahrrad"] } });
  r = await api("GET", "/api/lernen");
  const fr = r.data.words.find((w) => w.wort === "Fahrrad");
  ok(!fr.removed && fr.satz === "Ich fahre mit dem Fahrrad.", "wieder hinzugefügt: Satz bleibt", fr);

  console.log("== Protokoll");
  const e1 = { id: uuid(), wort: "Meer", t: 1000, ergebnis: "richtig", gelesen: ["Meer"], from: "iPad" };
  const e2 = { id: uuid(), wort: "Fahrrad", t: 1001, ergebnis: "zweiter", gelesen: ["Farad", "Fahrrad"], wdh: true };
  r = await api("POST", "/api/lernen/log", { json: { events: [e1, e2, { id: "kaputt", wort: "x", t: 1, ergebnis: "richtig" }, { id: uuid(), wort: "Meer", t: 1, ergebnis: "super" }] } });
  ok(r.data.added === 2, "zwei gültige Versuche", r.data);
  r = await api("POST", "/api/lernen/log", { json: { events: [e1] } });
  ok(r.data.added === 0, "doppelt hochgeladen: nichts Neues", r.data);
  r = await api("GET", "/api/lernen");
  ok(r.data.log.length === 2 && r.data.log[1].gelesen[0] === "Farad" && r.data.log[1].wdh === true, "Protokoll gelesen", r.data.log);
  const seq = r.data.log[0].seq;
  r = await api("GET", `/api/lernen?since=${seq}`);
  ok(r.data.log.length === 1 && r.data.log[0].wort === "Fahrrad", "since", r.data.log);

  console.log("== Lernwort als Frage");
  const id = uuid();
  r = await api("PUT", `/api/doc/lernwoerter/asks/${id}`, { body: form({ anchor, pv: 0, effort: "quick", created: Date.now() / 1000, from: "iPad" }) });
  ok(r.status === 400, "ohne Wort abgelehnt", r);
  helper.msgs.length = 0;
  r = await api("PUT", `/api/doc/lernwoerter/asks/${id}`, { body: form({ anchor, pv: 0, created: Date.now() / 1000, from: "iPad", wort: "Fahrrad", satz: "Ich fahre mit dem Fahrrad.", versuch: 2 }) });
  ok(r.status === 200 && r.data.asks.length === 1 && r.data.asks[0].effort === "lernwort", "angelegt, Art lernwort", r.data);
  await sleep(200);
  ok(helper.json().some((m) => m.type === "ask"), "Helfer geweckt", helper.msgs);
  // Eine normale Frage in einem echten Dokument, älter: Das Lernwort kommt trotzdem zuerst
  const doc = uuid(), now = Date.now() / 1000;
  await api("PUT", `/api/library/${doc}`, { json: { id: doc, title: "T", kind: "notebook", created: now, modified: now, pageCount: 1 } });
  const normal = uuid();
  r = await api("PUT", `/api/doc/${doc}/asks/${normal}`, { body: form({ anchor, pv: 0, effort: "lernwort", created: 1, from: "iPad" }) });
  ok(r.status === 200 && r.data.asks[0].effort === "quick", "echtes Dokument: Art lernwort nicht möglich", r.data);
  r = await api("GET", "/api/asks/open");
  ok(r.data.asks[0].id === id, "Lernwort zuerst", r.data);
  r = await api("POST", `/api/asks/${id}/claim`, { json: { lease: 300 } });
  ok(r.status === 200 && r.data.lern?.wort === "Fahrrad" && r.data.lern.versuch === 2 && r.data.lern.satz, "claim mit Wort", r.data);
  const claim = r.data.claim;
  r = await api("PUT", `/api/asks/${id}/answer`, { json: { claim, markdown: JSON.stringify({ gelesen: "Farad" }) } });
  ok(r.status === 200, "beantwortet");
  r = await api("GET", "/api/doc/lernwoerter/asks");
  ok(r.data.asks[0].status === "answered" && JSON.parse(r.data.asks[0].answer).gelesen === "Farad", "App liest Antwort", r.data);
  r = await api("DELETE", `/api/doc/lernwoerter/asks/${id}`);
  ok(r.status === 200 && r.data.asks.length === 0, "aufgeräumt", r.data);

  await api("DELETE", `/api/doc/${doc}/asks/${normal}`);
  app.ws.close(); helper.ws.close();
  console.log(`\n${passes} ok, ${failures} FAIL`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(1); });
