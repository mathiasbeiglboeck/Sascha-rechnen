// Test der Strich-Abfrage für den Helfer am Mac (GET /api/doc/<id>/strokes, nur lesen) gegen einen lokalen Server mit
// Wegwerf-Schlüssel, nie gegen den echten:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/strokes.mjs
// Ein einzelner Strich über der Grenze von 1.000.000 Zeichen lässt sich nicht hochladen (höchstens 500.000 je Strich).
// Für den Abschnitt „ein Strich allein über der Grenze“ eine Kopie von src/index.js mit kleinerer Grenze:
//   sed -i.bak 's/const MAX_CHARS = 1000000;/const MAX_CHARS = 1000;/' src/index.js
// und SMALL_CAP=1 (alle anderen Abschnitte rechnen dann mit 1000). Ohne SMALL_CAP wird er übersprungen.
import { createHmac } from "node:crypto";
const BASE = process.env.BASE || "http://127.0.0.1:8791";
const KEY = process.env.KEY || "testkey";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
const SMALL = process.env.SMALL_CAP === "1";
const CAP = SMALL ? 1000 : 1000000;
// Lernkarten-Schlüssel wie in karten.mjs: Er darf nur /api/karten
const KKEY = createHmac("sha256", KEY).update("lernkarten-foto").digest("base64url").slice(0, 32);
let failures = 0, passes = 0;
const ok = (cond, msg, extra) => {
  if (cond) { passes++; console.log("  ok  ", msg); }
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 400) : ""); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const uuid = () => crypto.randomUUID().toUpperCase();

async function api(method, path, { json, key = KEY } = {}) {
  const headers = key === null ? {} : { Authorization: `Bearer ${key}` };
  let body;
  if (json !== undefined) { body = JSON.stringify(json); headers["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers, body });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, data: ct.includes("json") ? await r.json() : await r.text() };
}
const strokes = async (doc, query = "") => (await api("GET", `/api/doc/${doc}/strokes${query}`)).data;
const sync = async (doc, body) => (await api("POST", `/api/doc/${doc}/sync`, { json: body })).data;
const library = async () => (await api("GET", "/api/library")).data.docs;
async function newDoc(meta) {
  const id = uuid(), now = Date.now() / 1000;
  const r = await api("PUT", `/api/library/${id}`, { json: { id, title: "Test", kind: "notebook", created: now, modified: now, pageCount: 1, ...meta } });
  if (r.status !== 200) throw new Error("newDoc " + r.status);
  return id;
}
function socket(path, key = KEY) {
  const ws = new WebSocket(BASE.replace(/^http/, "ws") + path, key ? { headers: { Authorization: `Bearer ${key}` } } : undefined);
  const msgs = [];
  ws.onmessage = (e) => msgs.push(String(e.data));
  const opened = new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  return { ws, msgs, opened };
}

/// Holt alle Striche ab since in Stücken, wie der Helfer; prüft dabei jedes Stück (Grenzen, more, last, Reihenfolge)
async function pull(doc, { lite = true, limit = null, since = 0, name }) {
  const pages = [];
  let cursor = since;
  for (let i = 0; i < 5000; i++) {
    const q = `?since=${cursor}${limit ? `&limit=${limit}` : ""}${lite ? "&lite=1" : ""}`;
    const page = await strokes(doc, q);
    pages.push(page);
    // Ohne Fortschritt (last nicht weiter als since) liefe der Helfer endlos: hier abbrechen, unten fällt es auf
    if (!page.more || !(page.last > cursor)) break;
    cursor = page.last;
  }
  const all = pages.flatMap((p) => p.changes);
  const max = limit || 500;
  const chars = (p) => p.changes.reduce((n, c) => n + (c.data ? c.data.length : 0), 0);
  const bad = [];
  pages.forEach((p, i) => {
    const next = pages[i + 1];
    if (p.more !== (i < pages.length - 1)) bad.push([i, "more"]);
    if (p.changes.length > max || (p.more && !p.changes.length)) bad.push([i, "Anzahl", p.changes.length]);
    if (p.changes.length && p.last !== p.changes.at(-1).seq) bad.push([i, "last"]);
    if (!p.changes.length && p.last !== (i ? pages[i - 1].last : since)) bad.push([i, "last ohne Zeilen"]);
    if (chars(p) > CAP && p.changes.length !== 1) bad.push([i, "Grenze überschritten", chars(p)]);
    // Weniger als limit, aber more: Dann hätte die nächste Zeile die Grenze überschritten
    if (p.more && next && p.changes.length < max && chars(p) + (next.changes[0]?.data?.length || 0) <= CAP) bad.push([i, "zu früh aufgehört"]);
    if (p.top !== pages[0].top) bad.push([i, "top"]);
    if (p.low !== pages[0].low) bad.push([i, "low"]);
  });
  if (all.some((c, i) => i && c.seq <= all[i - 1].seq)) bad.push(["Reihenfolge"]);
  ok(!bad.length, `${name}: ${pages.length} Stücke, jedes in Ordnung (more, last, höchstens ${max} Zeilen, Grenze ${CAP} Zeichen)`, bad.slice(0, 5));
  return { pages, all, capped: pages.filter((p) => p.more && p.changes.length < max).length };
}

// ---------- Striche wie im Betrieb ----------
let seed = 20261123;
const rnd = () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const round = (x, f) => Math.round(x * f) / f;
// PencilKit-Original als Base64 (enthält „/“ und „+“)
const pkOf = (bytes) => Buffer.from(Array.from({ length: bytes }, () => (rnd() * 256) | 0)).toString("base64");
// Wie StrokeCodec.values: x, y, Zeit, Breite, Höhe, Deckkraft, Druck, Azimut, Neigung, Zweitskala
const appPoints = (n, x0, y0) => Array.from({ length: n }, (_, k) => [
  round(x0 + k * 1.7, 100), round(y0 + Math.sin(k / 3) * 4, 100), round(k * 0.008, 1000), round(2 + rnd(), 100),
  round(2 + rnd(), 100), 1, round(rnd(), 1000), round(rnd() * 6.28, 1000), round(0.6 + rnd(), 1000), 1]);
// Wie viewer.html beim Zeichnen: neun Werte, kein pk
const browserPoints = (n, x0, y0) => appPoints(n, x0, y0).map((q) => [q[0], q[1], q[2], q[3], q[3], 1, 1, 0, 1.571]);
// Wie StrokeCodec.data: Schlüssel sortiert (alias, c, ink, p, pk), JSONEncoder schreibt „/“ als „\/“
const appStroke = ({ alias = false, ink = "com.apple.ink.pen", c = [0, 0, 0, 1], p, pk }) =>
  JSON.stringify({ ...(alias ? { alias: true } : {}), c, ink, p, pk }).replace(/\//g, "\\/");
// Wie shifted() in viewer.html: Ein Strich aus der App bekommt dx/dy hinter pk angehängt (und „/“ ohne „\“)
const shifted = (data, dx, dy) => {
  const w = JSON.parse(data);
  return JSON.stringify({ ...w, ...(w.pk ? { dx: round((w.dx || 0) + dx, 100), dy: round((w.dy || 0) + dy, 100) } : {}),
    p: w.p.map((q) => [round(q[0] + dx, 100), round(q[1] + dy, 100), ...q.slice(2)]) });
};
function realStroke(i) {
  const n = 5 + Math.floor(rnd() * 36), x = 40 + rnd() * 600, y = 30 + i * 9;
  const pk = pkOf(150 + Math.floor(rnd() * 2000));
  switch (i % 10) {
    case 5: return appStroke({ ink: "com.apple.ink.marker", c: [1, 0.8, 0, 0.5], p: appPoints(n, x, y), pk });
    case 6: case 7: return JSON.stringify({ c: [0.2, 0.4, 1, 1], ink: "com.apple.ink.pen", p: browserPoints(n, x, y) });
    case 8: return shifted(appStroke({ p: appPoints(n, x, y), pk }), 24, -12.5);
    // pk als erster Schlüssel (so schreibt es keine heutige App, der Server muss es trotzdem verkraften)
    case 9: return JSON.stringify({ pk, c: [0, 0, 0, 1], ink: "com.apple.ink.pencil", p: appPoints(n, x, y) }).replace(/\//g, "\\/");
    default: return appStroke({ alias: i % 20 === 3, p: appPoints(n, x, y), pk });
  }
}
// Erwartet ohne pk, unabhängig vom Server ausgerechnet: pk samt Komma davor, oder danach, wenn es vorne steht
const minusPK = (s) => s.replace(/,"pk":"[^"]*"|"pk":"[^"]*",/, "");
const withoutKey = (o, k) => { const c = { ...o }; delete c[k]; return c; };

async function main() {
  console.log(`== Schlüssel${SMALL ? " (SMALL_CAP: Grenze 1000 Zeichen)" : ""}`);
  const doc = await newDoc({ title: "Analysis Mitschrift", pageCount: 40, layoutVersion: 2, pagesVersion: 1763900000123 });
  await sync(doc, { since: 0, add: [{ id: "erst", data: appStroke({ p: appPoints(3, 10, 10), pk: pkOf(40) }) }], remove: [] });
  let r = await api("GET", `/api/doc/${doc}/strokes`, { key: null });
  ok(r.status === 401 && !("changes" in r.data), "ohne Schlüssel: 401", r);
  r = await api("GET", `/api/doc/${doc}/strokes`, { key: KKEY });
  ok(r.status === 401 && !("changes" in r.data), "mit dem Lernkarten-Schlüssel: 401", r);
  r = await api("GET", `/api/doc/${doc}/strokes`, { key: "falsch" });
  ok(r.status === 401, "falscher Schlüssel: 401", r.status);
  r = await api("GET", `/api/doc/${doc}/strokes`);
  ok(r.status === 200 && r.data.changes?.length === 1 && r.data.changes[0].id === "erst", "voller Schlüssel: 200", r);
  r = await api("POST", `/api/doc/${doc}/strokes`);
  ok(r.status === 404, "nur GET", r.status);

  console.log("== unbekanntes Dokument: kein 404 (das hieße für den Helfer: Server ohne diese Adresse)");
  r = await api("GET", `/api/doc/${uuid()}/strokes?since=42&lite=1`);
  ok(r.status === 200 && JSON.stringify(r.data) === JSON.stringify({ top: 0, low: 0, last: 42, more: false, meta: null, changes: [] }),
    "200 mit top 0, low 0, last = since, meta null, keine Striche", r.data);

  console.log("== 1.234 Striche wie aus App und Browser, dazu gelöschte und geänderte");
  const other = await newDoc({ title: "Nachbar" });
  const N = 1234;
  const ids = Array.from({ length: N }, (_, i) => `S${String(i).padStart(4, "0")}-${uuid()}`);
  for (let i = 0; i < N; i += 300) {
    await sync(doc, { since: 0, add: ids.slice(i, i + 300).map((id, k) => ({ id, data: realStroke(i + k) })), remove: [] });
    // Ein anderes Dokument dazwischen: Die Nummern des Dokuments haben Lücken
    if (i === 600) await sync(other, { since: 0, add: [1, 2, 3, 4, 5].map((k) => ({ id: `n${k}`, data: realStroke(k) })), remove: [] });
  }
  const removed = ids.filter((_, i) => i % 31 === 7);
  const changed = ids.filter((_, i) => i % 61 === 11 && i % 31 !== 7);
  const back = removed.slice(0, 2);
  await sync(doc, { since: 0, add: [], remove: removed });
  await sync(doc, { since: 0, add: changed.map((id, k) => ({ id, data: shifted(realStroke(k * 10), 48, 48) })), remove: [] });
  await sync(doc, { since: 0, add: back.map((id) => ({ id, data: realStroke(3) })), remove: [] });
  const ref = await sync(doc, { since: 0 });
  const refById = new Map(ref.changes.map((c) => [c.id, c.data]));
  ok(ref.changes.length === N + 1 && ref.changes.filter((c) => c.data === null).length === removed.length - back.length,
    `/sync since=0 als Vergleich: ${ref.changes.length} Striche, ${removed.length - back.length} Grabsteine`, ref.changes.length);
  ok(ref.changes.some((c) => c.data?.includes('"pk":"') && c.data.includes("\\/")) && ref.changes.some((c) => c.data?.includes(',"dx":')) &&
    ref.changes.some((c) => c.data?.startsWith('{"pk":')) && ref.changes.some((c) => c.data && !c.data.includes('"pk"')),
    "alle Formen dabei: pk am Ende (mit \\/), vor dx/dy, vorne, ohne pk");

  const lite = await pull(doc, { lite: true, limit: 100, name: "lite=1, limit=100" });
  ok(JSON.stringify(lite.all.map((c) => c.id)) === JSON.stringify(ref.changes.map((c) => c.id)),
    "gleiche Striche in gleicher Reihenfolge wie /sync since=0", { got: lite.all.length, want: ref.changes.length });
  const diff = lite.all.filter((c) => c.data !== (refById.get(c.id) === null ? null : minusPK(refById.get(c.id))));
  ok(!diff.length, "jeder Strich wie bei /sync, nur ohne pk (Zeichen für Zeichen)", diff.slice(0, 2));
  const unparsable = lite.all.filter((c) => {
    if (c.data === null) return false;
    try { return JSON.stringify(JSON.parse(c.data)) !== JSON.stringify(withoutKey(JSON.parse(refById.get(c.id)), "pk")); } catch { return true; }
  });
  ok(!unparsable.length, "gültiges JSON, gleich dem Strich ohne pk", unparsable.slice(0, 2));
  ok(!lite.all.some((c) => c.data?.includes('"pk"')), "kein pk mehr in lite");
  const last = lite.pages.at(-1);
  ok(last.last === ref.seq && last.top === ref.seq && lite.pages[0].top === ref.seq, "last am Ende = top = höchste Nummer von /sync", { last: last.last, top: last.top, seq: ref.seq });
  ok(lite.pages[0].low === lite.all[0].seq && lite.all[0].seq < ref.seq, "low = niedrigste Nummer des Dokuments", { low: lite.pages[0].low, first: lite.all[0].seq });
  if (!SMALL) ok(lite.pages.length === Math.ceil(ref.changes.length / 100) && lite.pages.slice(0, -1).every((p) => p.changes.length === 100),
    "volle Stücke zu 100", lite.pages.map((p) => p.changes.length));
  const m0 = lite.pages[0].meta;
  ok(JSON.stringify(m0) === JSON.stringify({ kind: "notebook", pageCount: 40, pagesVersion: 1763900000123, pdfVersion: 0, layoutVersion: 2, deleted: false }),
    "meta: nur kind, pageCount, pagesVersion, pdfVersion, layoutVersion, deleted", m0);

  const full = await pull(doc, { lite: false, limit: 1000, name: "ohne lite, limit=1000" });
  ok(full.all.length === ref.changes.length && full.all.every((c, i) => c.id === ref.changes[i].id && c.data === ref.changes[i].data),
    "ohne lite: genau die Daten von /sync (mit pk, \\/ unverändert)");
  ok(full.capped > 0, `die Grenze von ${CAP} Zeichen beendet Stücke vor limit (${full.capped}×), mit mindestens einer Zeile`, full.pages.map((p) => p.changes.length));
  const dflt = await pull(doc, { lite: true, name: "lite=1 ohne limit (Vorgabe 500)" });
  ok(dflt.all.length === ref.changes.length && (SMALL || dflt.pages[0].changes.length === 500), "Vorgabe: 500 je Stück", dflt.pages.map((p) => p.changes.length));

  console.log("== Grabsteine, geänderte Striche");
  const tomb = lite.all.filter((c) => c.data === null);
  ok(tomb.length === removed.length - back.length && tomb.every((c) => removed.includes(c.id) && !back.includes(c.id)), "gelöschte Striche als data null", tomb.length);
  const firstTomb = lite.all.findIndex((c) => c.data === null);
  ok(lite.all.slice(firstTomb, firstTomb + tomb.length).every((c) => c.data === null), "mit der Nummer ihres Löschens (nach allen Hinzufügungen)");
  ok(new Set(lite.all.map((c) => c.id)).size === lite.all.length, "jeder Strich nur einmal, auch die geänderten");
  ok(changed.every((id) => lite.all.find((c) => c.id === id)?.data === minusPK(refById.get(id)) && refById.get(id).includes(',"dx":')),
    `geänderte Striche (${changed.length}) mit ihren neuen Daten`);
  ok(back.every((id) => typeof lite.all.find((c) => c.id === id)?.data === "string"), "gelöscht und wieder da: lebt");
  r = await strokes(doc, `?since=${ref.seq - 1}&lite=1`);
  ok(r.changes.length === 1 && r.changes[0].id === back[1] && !r.more && r.last === ref.seq, "nur der letzte nach since = top − 1", r);

  console.log("== more und last an den Rändern (an 1.100 Grabsteinen, für die die Zeichengrenze keine Rolle spielt)");
  const tdoc = await newDoc({ title: "Grabsteine" });
  await sync(tdoc, { since: 0, add: [], remove: Array.from({ length: 1100 }, (_, i) => `t${i}`) });
  const t0 = await strokes(tdoc, "?limit=1000");
  const tseq = t0.changes.map((c) => c.seq);
  ok(t0.changes.length === 1000 && t0.more && t0.last === tseq.at(-1) && t0.changes.every((c) => c.data === null), "1000 Grabsteine in einem Stück, more", t0.changes.length);
  const tall = await pull(tdoc, { limit: 1000, name: "alle Grabsteine" });
  const ttop = tall.pages.at(-1).last;
  ok(tall.all.length === 1100 && JSON.stringify(tall.pages.map((p) => p.changes.length)) === "[1000,100]" && ttop === tall.pages[0].top,
    "1000 und 100, last am Ende = top", tall.pages.map((p) => p.changes.length));
  r = await strokes(tdoc, `?since=${tall.all.at(-4)?.seq}&limit=3`);
  ok(r.changes.length === 3 && r.more === false && r.last === ttop, "genau limit übrig: alle, more false", r);
  r = await strokes(tdoc, `?since=${tall.all.at(-4)?.seq}&limit=2`);
  ok(r.changes.length === 2 && r.more === true && r.last === tall.all.at(-2)?.seq, "einer mehr als limit: more true, last = Nummer des letzten", r);
  r = await strokes(doc, `?since=${ref.seq}&lite=1`);
  ok(r.changes.length === 0 && !r.more && r.last === ref.seq && r.top === ref.seq, "since = top: nichts, last = since", r);
  r = await strokes(doc, `?since=${ref.seq + 5}&lite=1`);
  ok(r.changes.length === 0 && !r.more && r.last === ref.seq + 5 && r.top === ref.seq, "since über top: nichts, last = since", r);
  const o = await pull(other, { name: "das andere Dokument" });
  ok(o.all.length === 5 && o.all.every((c) => /^n\d$/.test(c.id)), "das andere Dokument: nur seine Striche", o.all.map((c) => c.id));

  console.log("== since und limit, die keine passenden Zahlen sind (wie bei den anderen Adressen: Vorgabe bzw. erlaubter Bereich)");
  const count = async (q) => (await strokes(tdoc, q)).changes?.length;
  ok(await count("") === 500, "ohne limit: 500");
  ok(await count("?limit=0") === 500, "limit=0: Vorgabe 500");
  ok(await count("?limit=abc") === 500, "limit keine Zahl: Vorgabe 500");
  ok(await count("?limit=5000") === 1000, "limit über 1000: 1000");
  ok(await count("?limit=-3") === 1, "negatives limit: 1");
  ok(await count("?limit=2.9") === 2, "limit=2.9: 2");
  r = await strokes(tdoc, "?since=-5&limit=1");
  ok(r.changes[0]?.id === "t0" && r.last === tseq[0], "negatives since: wie 0", r);
  r = await strokes(tdoc, "?since=abc&limit=1");
  ok(r.changes[0]?.id === "t0", "since keine Zahl: wie 0", r);
  r = await strokes(tdoc, `?since=${tseq[9]}.7&limit=1`);
  ok(r.changes[0]?.id === "t10", "since mit Nachkommastellen: abgeschnitten", r);
  for (const big of ["1e30", "Infinity"]) {
    r = await strokes(tdoc, `?since=${big}`);
    ok(r.changes.length === 0 && !r.more && Number.isSafeInteger(r.last) && r.last > tseq.at(-1), `since=${big}: nichts, last eine endliche Zahl`, r);
  }

  console.log("== pk entfernen: hinter, vor dx/dy, vorne; sonst unverändert");
  const pdoc = await newDoc({ title: "pk" });
  const pts = appPoints(2, 100, 200), pk = "QUJD\\/REVGR0g+SUpL=";
  const cases = [
    ["am Ende (App)", `{"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)},"pk":"${pk}"}`, `{"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)}}`],
    ["mit alias", `{"alias":true,"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)},"pk":"${pk}"}`, `{"alias":true,"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)}}`],
    ["vor dx/dy (im Browser verschoben)", `{"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)},"pk":"QUJD/REVG","dx":24,"dy":-12.5}`, `{"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)},"dx":24,"dy":-12.5}`],
    ["vorne", `{"pk":"${pk}","c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)}}`, `{"c":[0,0,0,1],"ink":"com.apple.ink.pen","p":${JSON.stringify(pts)}}`],
    ["leer", `{"c":[1,0,0,1],"pk":""}`, `{"c":[1,0,0,1]}`],
    ["aus dem Browser (9 Werte, ohne pk)", JSON.stringify({ c: [0.2, 0.4, 1, 1], ink: "com.apple.ink.pen", p: browserPoints(3, 5, 5) }), null],
    ["nicht abgeschlossen", `{"c":[0,0,0,1],"pk":"QUJD`, null],
    ["nur pk", `{"pk":"QUJD"}`, null],
    ["Anführungszeichen im Wert", `{"c":[0,0,0,1],"pk":"QU\\"JD","ink":"x"}`, null],
    ["mit Leerzeichen", `{"c":[0,0,0,1], "pk": "QUJD"}`, null],
    ["pk keine Zeichenkette", `{"c":[0,0,0,1],"pk":null}`, null],
    ["kein JSON", "abc", null],
  ];
  await sync(pdoc, { since: 0, add: cases.map(([, data], i) => ({ id: `p${i}`, data })), remove: [] });
  const pl = (await pull(pdoc, { name: "mit lite" })).all, pf = (await pull(pdoc, { lite: false, name: "ohne lite" })).all;
  cases.forEach(([name, data, want], i) => {
    const got = pl.find((c) => c.id === `p${i}`)?.data;
    ok(got === (want ?? data) && pf.find((c) => c.id === `p${i}`)?.data === data, `${name}: ${want ? "ohne pk" : "unverändert"}`, { got, want: want ?? data });
    if (want) {
      let same = false;
      try { same = JSON.stringify(JSON.parse(got)) === JSON.stringify(withoutKey(JSON.parse(data), "pk")); } catch {}
      ok(same, `${name}: gültiges JSON ohne pk`, got);
    }
  });

  console.log("== Grenze von 1.000.000 Zeichen mit großen Strichen (je knapp 500.000, mehr nimmt /sync nicht an)");
  const bdoc = await newDoc({ title: "groß" });
  const bigs = [0, 1, 2, 3, 4].map((i) => appStroke({ p: appPoints(5, 10, i * 20), pk: pkOf(357000 + i * 1000) }));
  ok(bigs.every((d) => d.length > 476000 && d.length <= 500000), "Striche zwischen 476.000 und 500.000 Zeichen", bigs.map((d) => d.length));
  await sync(bdoc, { since: 0, add: bigs.map((data, i) => ({ id: `b${i}`, data })), remove: [] });
  const bf = await pull(bdoc, { lite: false, limit: 1000, name: "große Striche ohne lite" });
  ok(bf.all.length === 5 && bf.all.every((c, i) => c.data === bigs[i]) && bf.pages.every((p) => p.changes.length >= 1), "alle fünf, jedes Stück mit mindestens einer Zeile", bf.pages.map((p) => p.changes.length));
  if (!SMALL) ok(JSON.stringify(bf.pages.map((p) => p.changes.length)) === "[2,2,1]", "je zwei (zusammen unter 1.000.000), der dritte käme darüber", bf.pages.map((p) => p.changes.length));
  const bl = await pull(bdoc, { lite: true, limit: 1000, name: "große Striche mit lite" });
  ok(bl.all.length === 5 && bl.all.every((c, i) => c.data === minusPK(bigs[i])), "lite: alle fünf ohne pk");
  if (!SMALL) ok(bl.pages.length === 1, "lite: die Grenze zählt die zurückgegebenen Daten (ohne pk), alle fünf in einem Stück", bl.pages.length);

  console.log("== ein Strich allein über der Grenze (braucht die kleine Grenze, SMALL_CAP=1)");
  if (SMALL) {
    const sdoc = await newDoc({ title: "Grenze" });
    const sizes = [1500, 300, 300, 2500, 999, 1];
    await sync(sdoc, { since: 0, add: sizes.map((n, i) => ({ id: `g${i}`, data: "x".repeat(n) })), remove: [] });
    const s = await pull(sdoc, { lite: false, name: "kleine Grenze" });
    ok(JSON.stringify(s.pages.map((p) => p.changes.map((c) => c.data.length))) === "[[1500],[300,300],[2500],[999,1]]",
      "über der Grenze: allein in seinem Stück, nie ein leeres Stück", s.pages.map((p) => p.changes.map((c) => c.data.length)));
  } else console.log("  (übersprungen)");

  console.log("== Metadaten: PDF, ältere Einträge ohne Versionen");
  const pdfDoc = await newDoc({ title: "Skriptum", kind: "pdf", pageCount: 12, pdfVersion: 1763900000456, pagesVersion: 1763900000456, layoutVersion: 2 });
  r = await strokes(pdfDoc);
  ok(JSON.stringify(r.meta) === JSON.stringify({ kind: "pdf", pageCount: 12, pagesVersion: 1763900000456, pdfVersion: 1763900000456, layoutVersion: 2, deleted: false }), "PDF: Versionen wie gespeichert", r.meta);
  const oldDoc = await newDoc({ title: "alt", pageCount: 3 });
  r = await strokes(oldDoc);
  ok(JSON.stringify(r.meta) === JSON.stringify({ kind: "notebook", pageCount: 3, pagesVersion: 0, pdfVersion: 0, layoutVersion: null, deleted: false }),
    "ohne Versionen: 0, ohne layoutVersion: null", r.meta);

  console.log("== Dokument gelöscht und zurückgeholt: meta.deleted, top < since, dann low > since");
  const wdoc = await newDoc({ title: "Weg", pageCount: 7, layoutVersion: 2, pagesVersion: 1763900000789 });
  const wdata = Array.from({ length: 30 }, (_, i) => realStroke(i));
  await sync(wdoc, { since: 0, add: wdata.map((data, i) => ({ id: `w${i}`, data })), remove: [] });
  const w = await pull(wdoc, { name: "vor dem Löschen" });
  const cursor = w.pages.at(-1).last;
  ok(w.all.length === 30 && cursor > 0 && w.pages[0].meta?.deleted === false, "30 Striche, Stand gemerkt", { n: w.all.length, cursor });
  r = await strokes(wdoc, `?since=${cursor}&lite=1`);
  ok(r.low === w.all[0].seq && r.low <= cursor && r.top === cursor && !r.changes.length, "nichts gelöscht: low ≤ since ≤ top", r);
  const t = Date.now() / 1000 + 10;
  r = await api("PUT", `/api/library/${wdoc}`, { json: { id: wdoc, title: "", kind: "notebook", deleted: true, created: t, modified: t, pageCount: 0 } });
  ok(r.status === 200 && r.data.deleted === true, "in der Bibliothek gelöscht", r.data);
  r = await strokes(wdoc, `?since=${cursor}&lite=1`);
  ok(r.meta?.deleted === true && r.top === 0 && r.top < cursor && r.changes.length === 0 && !r.more && r.last === cursor,
    "danach: meta.deleted, top 0 < since, keine Striche", r);
  r = await strokes(wdoc, "?since=0&lite=1");
  ok(r.changes.length === 0 && r.meta?.deleted === true, "auch ab 0 keine Striche mehr", r);
  // Wie die App ein anderswo gelöschtes, hier danach geändertes Dokument zurückholt (SyncEngine: PUT mit neuerem
  // modified, dann alle Striche unter ihren IDs neu hoch). Der hier gelöschte Strich w7 kommt nicht mehr, auch kein
  // Grabstein: Seine Zeile ging mit dem Löschen weg
  r = await api("PUT", `/api/library/${wdoc}`, { json: { id: wdoc, title: "Weg", kind: "notebook", created: t, modified: t + 10, pageCount: 2, layoutVersion: 2 } });
  r = await strokes(wdoc, `?since=${cursor}&lite=1`);
  ok(r.meta?.deleted === false && r.meta.pageCount === 2 && r.top === 0 && r.low === 0 && r.top < cursor, "zurückgeholt: nicht gelöscht, top 0 < since", r);
  const again = await sync(wdoc, { since: 0, add: wdata.map((data, i) => ({ id: `w${i}`, data })).filter((c) => c.id !== "w7"), remove: [] });
  r = await strokes(wdoc, `?since=${cursor}&lite=1`);
  const from0 = await strokes(wdoc, "?since=0&lite=1");
  ok(r.meta?.deleted === false && r.top === again.seq && r.top > cursor && r.low > cursor && r.changes.length === 29,
    "alle Striche neu hochgeladen: top > since verrät nichts mehr, low > since schon (die Nummern zählen über alle Dokumente)", r);
  ok(JSON.stringify(r) === JSON.stringify(from0) && !from0.changes.some((c) => c.id === "w7"),
    "ab since genau dasselbe wie ab 0, ohne den gelöschten Strich (alles neu holen genügt)", { since: r.changes.length, from0: from0.changes.length });

  console.log("== nur lesen: kein WebSocket hört etwas, strokeSeq und Zähler bleiben");
  const app = socket(`/api/doc/${doc}/ws`);
  const token = (await api("POST", `/api/share/${doc}`)).data.token;
  const guest = socket(`/s/${token}/ws`, null);
  const helper = socket("/api/asks/ws");
  await Promise.all([app.opened, guest.opened, helper.opened]);
  const probe1 = await sync(doc, { since: 0, add: [{ id: "probe1", data: realStroke(7) }], remove: [] });
  await sleep(400);
  const before = { app: app.msgs.length, guest: guest.msgs.length, helper: helper.msgs.length };
  const entry = async () => JSON.stringify((await library()).find((d) => d.id === doc));
  const libBefore = await entry();
  ok(before.app > 0 && before.guest > 0 && JSON.parse(libBefore).strokeSeq === probe1.seq, "Sockets verbunden, strokeSeq = höchste Nummer", { before, lib: libBefore.slice(0, 200) });
  const queries = ["", "?lite=1", "?since=0&limit=1000", "?since=0&limit=1&lite=1", `?since=${probe1.seq}`, `?since=${probe1.seq + 99}&lite=1`, "?limit=abc&since=xyz"];
  for (const q of queries) await strokes(doc, q);
  for (const q of ["?lite=1", "?since=3"]) { await strokes(other, q); await strokes(uuid(), q); await strokes(wdoc, q); }
  r = await strokes(doc, `?since=${probe1.seq - 1}`);
  ok(r.top === probe1.seq && r.changes.length === 1 && r.changes[0].id === "probe1", "top = strokeSeq der Bibliothek", r);
  await sleep(500);
  ok(app.msgs.length === before.app, "App-Socket des Dokuments: nichts", app.msgs.slice(before.app));
  ok(guest.msgs.length === before.guest, "Gast im Browser: nichts", guest.msgs.slice(before.guest));
  ok(helper.msgs.length === before.helper, "Helfer-Socket: nichts", helper.msgs.slice(before.helper));
  ok(await entry() === libBefore, "Eintrag in /api/library unverändert (strokeSeq, Metadaten)");
  const probe2 = await sync(doc, { since: 0, add: [{ id: "probe2", data: realStroke(8) }], remove: [] });
  ok(probe2.seq === probe1.seq + 1, "keine Nummer verbraucht: der nächste Strich bekommt die nächste Nummer", { probe1: probe1.seq, probe2: probe2.seq });
  await sleep(300);
  ok(app.msgs.length > before.app, "zum Vergleich: ein echter Strich erreicht die App sehr wohl", app.msgs.length);
  app.ws.close(); guest.ws.close(); helper.ws.close();

  console.log(`\n${passes} ok, ${failures} fehlgeschlagen`);
  process.exit(failures ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
