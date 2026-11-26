// Test für „Claude schreiben lassen“ (Notizen im Dokument) gegen einen lokalen Server mit Wegwerf-Schlüssel:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/notizen.mjs
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
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 600) : ""); }
};
const uuid = () => crypto.randomUUID().toUpperCase();

async function api(method, path, { json } = {}) {
  const h = { ...H };
  let b;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, data: ct.includes("json") ? await r.json() : await r.text() };
}

const PNG = () => { const b = new Uint8Array(200); b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); return b; };
const JPG = () => { const b = new Uint8Array(300); b.set([0xff, 0xd8, 0xff, 0xe0]); return b; };

function createAsk(doc, id, meta) {
  const f = new FormData();
  f.append("meta", JSON.stringify(meta));
  f.append("question", new Blob([PNG()], { type: "image/png" }), "question.png");
  f.append("page", new Blob([JPG()], { type: "image/jpeg" }), "page.jpg");
  return fetch(`${BASE}/api/doc/${doc}/asks/${id}`, { method: "PUT", headers: H, body: f })
    .then(async (r) => ({ status: r.status, data: await r.json() }));
}

async function newDoc() {
  const id = uuid(), now = Date.now() / 1000;
  await api("PUT", `/api/library/${id}`, { json: { id, title: "Notizen-Test", kind: "notebook", created: now, modified: now, pageCount: 4, pagesVersion: 0 } });
  return id;
}

const anchor = { page: 1, x: 100, y: 200, w: 150, h: 40 };

async function answer(id, body) {
  const c = await api("POST", `/api/asks/${id}/claim`, { json: { lease: 900 } });
  const r = await api("PUT", `/api/asks/${id}/answer`, { json: { claim: c.data.claim, ...body } });
  return { claim: c.data, r };
}

async function main() {
  const doc = await newDoc();
  console.log("== Schreib-Modus");
  const w = uuid(), q = uuid();
  let r = await createAsk(doc, w, { anchor, pv: 0, effort: "thorough", created: 1, from: "iPad", mode: "write" });
  ok(r.status === 200 && r.data.asks.find((a) => a.id === w)?.mode === "write", "mode write kommt an", r.data);
  r = await createAsk(doc, q, { anchor, pv: 0, effort: "quick", created: 2, from: "iPad", mode: "quatsch" });
  ok(r.status === 200 && !("mode" in r.data.asks.find((a) => a.id === q)), "unbekannter mode fällt weg", r.data);

  const notes = [
    { page: 1, x: 0.82, y: 0.3, w: 0.16, text: "Vorzeichen! $-2$", color: "red", size: "small", box: [0.1, 0.28, 0.5, 0.33] },
    { page: 0, x: 0.1, y: 0.5, w: 0.8, text: "**Lösung:** $\\int_0^1 x\\,dx = \\tfrac12$" },
    { page: 2, x: 2, y: 0.5, w: 0.5, text: "außerhalb" },
    { page: 1, x: 0.1, y: 0.1, w: 0.5, text: "x", color: "pink", size: "riesig", extra: 1 },
    { page: -1, x: 0.1, y: 0.1, w: 0.5, text: "Seite -1 gibt es beim Antworten nicht" },
    { page: 1, x: 0.1, y: 0.1, w: 0.5, text: "   " },
  ];
  let a = await answer(w, { markdown: "Zwei Notizen gesetzt.", notes });
  ok(a.claim.mode === "write", "claim nennt mode", a.claim);
  ok(a.r.status === 200, "Antwort mit Notizen 200", a.r);
  r = await api("GET", `/api/doc/${doc}/asks`);
  let got = r.data.asks.find((x) => x.id === w);
  ok(got.status === "answered" && got.answer === "Zwei Notizen gesetzt.", "beantwortet", got);
  ok(Array.isArray(got.notes) && got.notes.length === 3, "ungültige Notizen fallen weg (3 bleiben)", got.notes);
  ok(got.notes[0].color === "red" && got.notes[0].size === "small" && got.notes[0].box.length === 4, "Farbe, Größe, Kasten bleiben", got.notes[0]);
  ok(!("color" in got.notes[2]) && !("size" in got.notes[2]) && !("extra" in got.notes[2]), "unbekannte Farbe/Größe/Felder fallen weg", got.notes[2]);

  a = await answer(q, { markdown: "Normale Antwort", notes });
  r = await api("GET", `/api/doc/${doc}/asks`);
  got = r.data.asks.find((x) => x.id === q);
  ok(got.status === "answered" && !("notes" in got), "Notizen nur bei mode write", got);

  console.log("== Notizen verschieben (Seitenänderung, Löschen einer Notiz)");
  const moved = [{ page: 2, x: 0.82, y: 0.3, w: 0.16, text: "Vorzeichen! $-2$", color: "red" }, { page: -1, x: 0.1, y: 0.5, w: 0.8, text: "weg" }];
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 5, anchors: { [w]: { ...anchor, page: 2 } }, notes: { [w]: moved, [q]: moved } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(r.status === 200 && got.pv === 5 && got.anchor.page === 2 && got.notes.length === 2 && got.notes[1].page === -1, "Notizen ersetzt, Seite −1 erlaubt", got);
  ok(!("notes" in r.data.asks.find((x) => x.id === q)), "Fragen ohne mode write bekommen keine Notizen", r.data);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 3, notes: { [w]: [] } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(got.notes.length === 2, "älterer Seitenstand ändert nichts", got);
  r = await api("PATCH", `/api/doc/${doc}/asks`, { json: { pv: 5, notes: { [w]: [moved[0]] } } });
  got = r.data.asks.find((x) => x.id === w);
  ok(got.notes.length === 1 && got.v > 0, "eine Notiz gelöscht", got);

  for (const x of (await api("GET", `/api/doc/${doc}/asks`)).data.asks) await api("DELETE", `/api/doc/${doc}/asks/${x.id}`);
  console.log(`\n${passes} passed, ${failures} failed`);
  process.exit(failures ? 1 : 0);
}
main().catch((e) => { console.error(e); process.exit(2); });
