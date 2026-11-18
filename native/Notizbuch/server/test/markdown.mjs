// Test des Eingangs für Markdown gegen einen lokalen Server mit Wegwerf-Schlüssel, nie gegen den echten:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/markdown.mjs
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
const uuid = () => crypto.randomUUID().toUpperCase();
const utf8 = (s) => new TextEncoder().encode(s);
const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

async function api(method, path, { json, body, headers } = {}) {
  const h = { ...H, ...(headers || {}) };
  let b = body;
  if (json !== undefined) { b = JSON.stringify(json); h["content-type"] = "application/json"; }
  const r = await fetch(BASE + path, { method, headers: h, body: b });
  const ct = r.headers.get("content-type") || "";
  const data = ct.includes("json") ? await r.json() : new Uint8Array(await r.arrayBuffer());
  return { status: r.status, data, ct };
}
const inbox = (body, query = "?type=md", headers = { "content-type": "application/x-www-form-urlencoded" }) =>
  api("POST", "/api/inbox" + query, { body, headers });
const library = async () => (await api("GET", "/api/library")).data.docs;
const entry = async (id) => (await library()).find((d) => d.id === id);
const PDF = (tag) => utf8(`%PDF-1.4\n% ${tag}\n` + "x".repeat(300) + "\n%%EOF\n");

async function main() {
  console.log("== Markdown in den Eingang");
  const text = "# Analysis *Blatt* 3\n\nText mit $x^2$ und Umlauten äöü ß.\n\n## Aufgabe 1\n";
  let r = await inbox(utf8(text));
  ok(r.status === 200 && r.data.title === "Analysis Blatt 3" && r.data.source === "md" && /^[0-9A-F-]{36}$/.test(r.data.id),
    "?type=md: Name aus der ersten Überschrift, source md", r);
  const md = r.data.id;
  let e = await entry(md);
  ok(e && e.kind === "pdf" && e.source === "md" && e.hasPDF === false && e.folder === "temp" && e.pageCount === 0
    && e.layoutVersion === 2 && !e.deleted, "Bibliothek: PDF-Dokument ohne PDF, aus Markdown, in temp", e);
  r = await api("GET", `/api/md/${md}`);
  ok(r.status === 200 && /^text\/markdown/.test(r.ct) && /charset=utf-8/.test(r.ct) && same(r.data, utf8(text)),
    "GET /api/md: genau der Text, als UTF-8", { status: r.status, ct: r.ct });
  r = await api("GET", `/api/pdf/${md}`);
  ok(r.status === 404, "noch kein PDF", r.status);

  console.log("== Erkennen und Name");
  r = await inbox(utf8("Kein Titel hier\n\nnur Text\n"), "?title=Mein%20Titel", { "content-type": "text/markdown; charset=utf-8" });
  ok(r.status === 200 && r.data.title === "Mein Titel" && r.data.source === "md", "Content-Type text/markdown, ?title gewinnt", r);
  r = await inbox(utf8("Nur Text ohne Überschrift\n"), "", { "content-type": "text/plain" });
  ok(r.status === 200 && r.data.title === "Aus dem Eingang" && r.data.source === "md", "text/plain ohne Überschrift", r);
  r = await inbox(utf8("Text\n"), "?type=markdown");
  ok(r.status === 200 && r.data.source === "md", "?type=markdown", r);
  r = await inbox(utf8('---\nauthor: x\ntitle: "Vorspann-Titel"\n---\n# Andere\n'));
  ok(r.status === 200 && r.data.title === "Vorspann-Titel", "title aus dem Vorspann", r);
  r = await inbox(utf8("---\nauthor: x\n---\n\n### Dritte Ebene ###\n"));
  ok(r.status === 200 && r.data.title === "Dritte Ebene", "Vorspann ohne title: erste Überschrift danach", r);
  r = await inbox(utf8("---\n# Nach Trennlinie\n---\nText\n"));
  ok(r.status === 200 && r.data.title === "Nach Trennlinie", "Trennlinie am Anfang ist kein Vorspann", r);
  r = await inbox(utf8("```md\n# nicht im Code\n```\n~~~\n# auch nicht\n~~~\n#### zu tief\n## Echte `Überschrift` **fett** $a+b$ [Link](https://x.de)\n"));
  ok(r.status === 200 && r.data.title === "Echte Überschrift fett a+b Link", "Überschrift außerhalb von Codeblöcken, ohne Markdown-Zeichen", r);
  r = await inbox(utf8("#Kein Leerzeichen\n#\n# \\(x\\) und C#\n"));
  ok(r.status === 200 && r.data.title === "x und C#", "nur echte Überschriften", r);
  r = await inbox(new Uint8Array([0xef, 0xbb, 0xbf, ...utf8("# BOM-Titel\r\nText\r\n")]));
  const bom = r.data.id;
  ok(r.status === 200 && r.data.title === "BOM-Titel", "BOM und CRLF", r);
  r = await api("GET", `/api/md/${bom}`);
  ok(same(r.data, utf8("# BOM-Titel\r\nText\r\n")), "BOM fällt weg", Array.from(r.data.slice(0, 4)));
  r = await inbox(utf8("# " + "Lang ".repeat(100)));
  ok(r.status === 200 && r.data.title.length === 200, "Name höchstens 200 Zeichen", r.data.title?.length);
  // Ein Emoji genau an der Grenze: kein halbes Zeichenpaar im Namen (das JSON wäre für die Apps unlesbar)
  r = await inbox(utf8("# " + "a".repeat(199) + "😀 Rest\n"));
  const emoji = r.data.id;
  ok(r.status === 200 && r.data.title === "a".repeat(199), "Emoji an der Grenze fällt ganz weg", r.data.title?.length);
  r = await api("GET", "/api/library");
  const rawLib = await (await fetch(BASE + "/api/library", { headers: H })).text();
  ok(!/\\ud83d"/i.test(rawLib) && (await entry(emoji)).title === "a".repeat(199), "Bibliothek ohne halbes Zeichenpaar");
  r = await inbox(PDF("emoji"), "?title=" + encodeURIComponent("b".repeat(199) + "😀"));
  ok(r.status === 200 && r.data.title === "b".repeat(199), "auch beim PDF-Namen", r.data.title?.length);

  console.log("== Abgelehnt");
  const count0 = (await library()).length;
  r = await inbox(new Uint8Array([0x23, 0x20, 0xc3, 0x28, 0x0a]));
  ok(r.status === 400 && /UTF-8/.test(r.data.error), "kein UTF-8", r);
  r = await inbox(new Uint8Array([0x23, 0x20, 0x41, 0x00, 0x42]));
  ok(r.status === 400 && /keine Textdatei/.test(r.data.error), "Binärdatei (NUL)", r);
  r = await inbox(new Uint8Array(0));
  ok(r.status === 400, "leer", r);
  r = await inbox(utf8(" \n\t\n"));
  ok(r.status === 400 && /Leer/.test(r.data.error), "nur Leerzeichen", r);
  r = await inbox(utf8("a".repeat(512 * 1024 + 1)));
  ok(r.status === 400 && /zu groß/.test(r.data.error), "zu groß", r);
  r = await inbox(utf8("# Titel\n"), "");
  ok(r.status === 400 && /kein PDF/.test(r.data.error) && /type=md/.test(r.data.error), "ohne type=md kein Markdown, Hinweis darauf", r);
  r = await inbox(utf8("# Titel\n"), "?type=pdf", { "content-type": "application/json" });
  ok(r.status === 400, "JSON ist kein Markdown", r);
  ok((await library()).length === count0, "Abgelehntes legt nichts an");
  r = await inbox(utf8("a".repeat(512 * 1024)));
  ok(r.status === 200, "genau 512 KB geht", r.status);
  const before = (await library()).length;

  console.log("== PDF in den Eingang wie bisher");
  r = await inbox(PDF("eingang"), "?title=Blatt");
  ok(r.status === 200 && r.data.title === "Blatt" && r.data.source === undefined, "PDF wie bisher", r);
  e = await entry(r.data.id);
  ok(e && e.hasPDF === true && e.source === undefined && e.folder === "temp", "PDF-Eintrag ohne source", e);
  r = await inbox(PDF("mit-type"), "?type=md");
  ok(r.status === 200 && r.data.source === undefined, "PDF mit ?type=md bleibt PDF", r);
  ok((await library()).length === before + 2, "nur die zwei PDFs dazu");

  console.log("== Das erste gesetzte PDF gilt");
  const postedAt = (await entry(md)).modified;
  await new Promise((done) => setTimeout(done, 1100));
  r = await api("PUT", `/api/pdf/${md}?ifMissing=1`, { body: PDF("A"), headers: { "content-type": "application/pdf" } });
  ok(r.status === 200 && r.data.ok === true, "erstes Gerät legt sein PDF ab", r);
  const typesetAt = (await entry(md)).modified;
  ok(typesetAt >= postedAt + 1, "gilt ab dem Setzen als geändert (temp, Reihenfolge)", { postedAt, typesetAt });
  r = await api("PUT", `/api/pdf/${md}?ifMissing=1`, { body: PDF("B"), headers: { "content-type": "application/pdf" } });
  ok(r.status === 200 && r.data.ok === false && r.data.exists === true, "zweites bekommt exists", r);
  r = await api("GET", `/api/pdf/${md}`);
  ok(same(r.data, PDF("A")), "am Server liegt das erste");
  e = await entry(md);
  ok(e.hasPDF === true && e.source === "md" && e.modified === typesetAt, "Bibliothek: jetzt mit PDF", e);
  r = await api("PUT", `/api/pdf/${uuid()}?ifMissing=1`, { body: PDF("C") });
  ok(r.status === 200 && r.data.gone === true, "unbekanntes Dokument: gone", r);
  r = await api("PUT", `/api/pdf/${bom}?ifMissing=1`, { body: utf8("<html>kein pdf</html>") });
  ok(r.status === 400 && /kein PDF/.test(r.data.error), "kein PDF: abgelehnt", r);
  ok((await entry(bom)).hasPDF === false, "…und nichts abgelegt");

  // Zwei Geräte gleichzeitig: genau eines gewinnt, und sein PDF liegt am Server
  const race = (await inbox(utf8("# Rennen\n"))).data.id;
  const tries = ["X1", "X2", "X3", "X4"].map((t) =>
    api("PUT", `/api/pdf/${race}?ifMissing=1`, { body: PDF(t) }).then((x) => ({ t, ...x.data })));
  const results = await Promise.all(tries);
  const winners = results.filter((x) => x.ok === true);
  ok(winners.length === 1 && results.filter((x) => x.exists === true).length === 3, "gleichzeitig: genau eins gewinnt", results);
  r = await api("GET", `/api/pdf/${race}`);
  ok(winners.length === 1 && same(r.data, PDF(winners[0].t)), "…und sein PDF liegt am Server");
  r = await api("PUT", `/api/pdf/${race}?ifMissing=1`, { body: PDF("spät") });
  ok(r.data.exists === true, "später noch einmal: exists, nichts geändert", r.data);

  // Ein normales Hochladen (etwa nach dem Löschen von Seiten) ersetzt es wie bisher
  r = await api("PUT", `/api/pdf/${md}`, { body: PDF("neu"), headers: { "content-type": "application/pdf" } });
  ok(r.status === 200 && r.data.ok === true, "normales PUT wie bisher");
  ok(same((await api("GET", `/api/pdf/${md}`)).data, PDF("neu")), "…ersetzt das PDF");

  console.log("== Löschen");
  const now = Date.now() / 1000 + 5;
  r = await api("PUT", `/api/library/${md}`, { json: { id: md, title: "", kind: "notebook", deleted: true, created: now, modified: now, pageCount: 0 } });
  ok(r.status === 200 && r.data.deleted === true, "Grabstein", r.data);
  ok((await api("GET", `/api/md/${md}`)).status === 404, "Markdown weg");
  ok((await api("GET", `/api/pdf/${md}`)).status === 404, "PDF weg");
  r = await api("PUT", `/api/pdf/${md}?ifMissing=1`, { body: PDF("spät") });
  ok(r.data.gone === true, "spätes Setzen nach dem Löschen: gone", r);
  ok((await api("GET", `/api/pdf/${md}`)).status === 404, "…und nichts abgelegt");
  r = await api("PUT", `/api/library/${bom}`, { json: { id: bom, title: "", kind: "notebook", deleted: true, created: now, modified: now, pageCount: 0 } });
  ok((await api("GET", `/api/md/${bom}`)).status === 404, "Markdown ohne PDF: mit gelöscht");

  console.log("== Eintrag einer App ersetzt den des Eingangs");
  const later = Date.now() / 1000 + 10;
  r = await api("PUT", `/api/library/${race}`, { json: { id: race, title: "Rennen", kind: "pdf", created: later - 20, modified: later, pageCount: 3, layoutVersion: 2, folder: "temp" } });
  e = await entry(race);
  ok(e.pageCount === 3 && e.source === undefined && e.hasPDF === true, "App-Eintrag ohne source (das PDF ist da)", e);
  ok((await api("GET", `/api/md/${race}`)).status === 200, "Markdown bleibt bis zum Löschen");

  console.log(`\n${passes} ok, ${failures} fehlgeschlagen`);
  process.exit(failures ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
