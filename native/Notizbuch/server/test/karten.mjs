// Test der Vokabelfotos (Lernkarten-App) gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/karten.mjs
import { createHmac } from "node:crypto";
const BASE = process.env.BASE || "http://127.0.0.1:8791";
const KEY = process.env.KEY || "testkey";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
const KKEY = createHmac("sha256", KEY).update("lernkarten-foto").digest("base64url").slice(0, 32);
let failures = 0, passes = 0;
const ok = (cond, msg, extra) => {
  if (cond) { passes++; console.log("  ok  ", msg); }
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 400) : ""); }
};
const uuid = () => crypto.randomUUID().toUpperCase();
async function call(method, path, { key = KKEY, json, body, origin } = {}) {
  const h = { Authorization: `Bearer ${key}` };
  if (origin) h.Origin = origin;
  let b = body;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, headers: r.headers, data: ct.includes("json") ? await r.json() : new Uint8Array(await r.arrayBuffer()) };
}
const JPG = () => { const b = new Uint8Array(300); b.set([0xff, 0xd8, 0xff, 0xe0]); return b; };
const foto = (meta = {}) => { const f = new FormData(); f.append("meta", JSON.stringify(meta)); f.append("foto", new Blob([JPG()], { type: "image/jpeg" }), "foto.jpg"); return f; };

// Lernkarten-Schlüssel darf nur /api/karten
ok((await call("GET", "/api/library")).status === 401, "Lernkarten-Schlüssel: keine Bibliothek");
ok((await call("GET", "/api/asks/open")).status === 401, "Lernkarten-Schlüssel: keine offenen Fragen");
ok((await call("GET", "/api/karten/foto/" + uuid(), { key: "falsch" })).status === 401, "falscher Schlüssel abgewiesen");

// CORS
const pre = await fetch(BASE + "/api/karten/foto/" + uuid(), { method: "OPTIONS", headers: { Origin: "https://mathiasbeiglboeck.github.io", "Access-Control-Request-Method": "POST" } });
ok(pre.status === 204 && pre.headers.get("access-control-allow-origin") === "https://mathiasbeiglboeck.github.io", "CORS-Vorabfrage von GitHub Pages");
const pre2 = await fetch(BASE + "/api/karten/foto/" + uuid(), { method: "OPTIONS", headers: { Origin: "https://boese.example" } });
ok(!pre2.headers.get("access-control-allow-origin"), "fremde Seite bekommt kein CORS");

// Hochladen
const id = uuid();
let r = await call("POST", `/api/karten/foto/${id}`, { body: foto({ from: "Mios iPhone", hinweis: "Unit 3" }), origin: "https://mathiasbeiglboeck.github.io" });
ok(r.status === 200 && r.data.status === "open", "Foto angenommen", r.data);
ok(r.headers.get("access-control-allow-origin") === "https://mathiasbeiglboeck.github.io", "Antwort mit CORS-Kopf");
r = await call("POST", `/api/karten/foto/${id}`, { body: foto() });
ok(r.status === 200 && r.data.status === "open", "doppelt hochgeladen: nichts Neues");
ok((await call("POST", `/api/karten/foto/kaputt`, { body: foto() })).status === 400, "ungültige Kennung");
const nf = new FormData(); nf.append("foto", new Blob([new Uint8Array(50)]), "x.jpg");
ok((await call("POST", `/api/karten/foto/${uuid()}`, { body: nf })).status === 400, "kein Bild abgewiesen");

// Helfer (voller Schlüssel) sieht es
r = await call("GET", "/api/asks/open", { key: KEY });
const open = r.data.asks.find((a) => a.id === id);
ok(open && open.effort === "vokabeln" && open.doc === "vokabelfoto", "Helfer sieht das Foto als Frage", r.data);
r = await call("POST", `/api/asks/${id}/claim`, { key: KEY, json: { lease: 600 } });
ok(r.status === 200 && r.data.karten?.hinweis === "Unit 3" && r.data.images.question?.type === "image/jpeg", "übernommen, mit Hinweis", r.data);
const claim = r.data.claim;
r = await call("GET", `/api/asks/${id}/question`, { key: KEY });
ok(r.status === 200 && r.data[0] === 0xff, "Foto für den Helfer");
r = await call("GET", `/api/karten/foto/${id}`);
ok(r.data.status === "claimed", "App sieht: wird bearbeitet");
const karten = JSON.stringify({ titel: "Unit 3", karten: [{ fremd: "dog", deutsch: "Hund", satz: "The dog barks." }] });
r = await call("PUT", `/api/asks/${id}/answer`, { key: KEY, json: { claim, markdown: karten } });
ok(r.status === 200, "Helfer antwortet");
r = await call("GET", `/api/karten/foto/${id}`);
ok(r.data.status === "answered" && JSON.parse(r.data.answer).karten[0].deutsch === "Hund", "App holt die Karten", r.data);
ok((await call("GET", `/api/asks/${id}/question`, { key: KEY })).status === 404, "Foto nach der Antwort gelöscht");
r = await call("DELETE", `/api/karten/foto/${id}`);
ok(r.status === 200, "App löscht nach dem Übernehmen");
ok((await call("GET", `/api/karten/foto/${id}`)).status === 404, "danach weg");
ok((await call("POST", `/api/karten/foto/${id}`, { body: foto() })).data.status === "gone", "gelöschtes kommt nicht wieder");

// Notizbuch-Weg darf das Pseudo-Dokument nicht verwenden, Lernkarten-Schlüssel nicht fremde Fotos aus Notizbuch-Fragen
const f2 = new FormData(); f2.append("meta", JSON.stringify({ anchor: { page: 0, x: 0, y: 0, w: 1, h: 1 } }));
f2.append("question", new Blob([JPG()]), "q.jpg"); f2.append("page", new Blob([JPG()]), "p.jpg");
ok((await call("PUT", `/api/doc/vokabelfoto/asks/${uuid()}`, { key: KEY, body: f2 })).status === 400, "Notizbuch-Weg ins Pseudo-Dokument abgewiesen");
ok((await call("GET", `/api/karten/foto/${uuid()}`)).status === 404, "unbekanntes Foto: 404");

console.log(`\n${passes} ok, ${failures} fehlgeschlagen`);
process.exit(failures ? 1 : 0);
