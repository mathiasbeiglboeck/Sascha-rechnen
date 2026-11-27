// Test für latex.mjs: setzt echte LaTeX-Dokumente (braucht latexmk und pdflatex) gegen einen Server im Speicher.
// node test/latex-test.mjs [texbin]   (texbin: Ordner mit latexmk, Vorgabe /Library/TeX/texbin bzw. /usr/bin)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as L from "../latex.mjs";

let pass = 0, failed = 0;
const ok = (cond, name, extra = "") => {
  if (cond) pass++;
  else { failed++; console.log("FEHLER:", name, extra); }
};

// ---------- reine Teile ----------
{
  const m = L.lineMap("a\nb\nc\nd\ne", "a\nX\nb\nc\nd\ne");
  ok(m[1].line === 1 && !m[1].changed, "Präfix bleibt");
  ok(m[2].line === 3 && !m[2].changed, "eingefügte Zeile schiebt b", JSON.stringify(m[2]));
  ok(m[5].line === 6 && !m[5].changed, "Suffix rückt");
  const r = L.lineMap("a\nb\nc\nd", "a\nB1\nB2\nc\nd");
  ok(r[2].changed && r[2].line === 2, "umgeschriebene Zeile → Anfang der neuen Fassung", JSON.stringify(r[2]));
  ok(r[3].line === 4 && !r[3].changed, "danach unverändert");
  const d = L.lineMap("a\nb\nc", "a\nc");
  ok(d[2].changed && d[2].line === 2, "gelöschte Zeile → Zeile danach", JSON.stringify(d[2]));
  const g = L.groupStrokes([
    { id: 1, box: { x0: 0, y0: 0, x1: 10, y1: 10 } },
    { id: 2, box: { x0: 12, y0: 2, x1: 20, y1: 12 } },
    { id: 3, box: { x0: 200, y0: 300, x1: 210, y1: 310 } },
  ]);
  ok(g.length === 2, "Gruppen", JSON.stringify(g.map((x) => x.map((y) => y.id))));
  const w = { ink: "pen", c: [0, 0, 0, 1], p: [[1, 2, 0, 3, 3, 1, 1, 0, 0]], pk: "x" };
  const s = L.shifted(w, 0, 10.004);
  ok(s.p[0][1] === 12 && s.dy === 10 && L.strokeID(s) !== L.strokeID(w), "verschieben mit dy und neuer ID");
}

// ---------- mit LaTeX ----------
const texbin = process.argv[2] || (fs.existsSync("/Library/TeX/texbin/latexmk") ? "/Library/TeX/texbin" : "/usr/bin");
if (!fs.existsSync(path.join(texbin, "latexmk"))) {
  console.log(`latexmk fehlt in ${texbin}: nur die reinen Teile getestet`);
} else {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "nb-latex-"));
  const proj = path.join(root, "Exciting Games");
  fs.mkdirSync(proj);
  fs.writeFileSync(path.join(proj, "notizbuch.json"), JSON.stringify({ ordner: "Exciting Games" }));
  const words = "Spiel Strategie Gleichgewicht Wahrscheinlichkeit Markov Kette optimal Transport Martingal Wert".split(" ");
  const par = (k, n = 50) => Array.from({ length: n }, (_, i) => words[(i * 7 + k) % words.length]).join(" ") + ".";
  const doc = (extra) => [
    "\\documentclass[11pt]{article}", "\\usepackage[a4paper,margin=2cm]{geometry}", "\\begin{document}",
    "\\section{Einleitung}", par(1), "", ...extra, par(2), "\\newpage", "\\section{Ziel}", "ZIELZEILE " + par(3), "",
    par(4), "", "UMSCHREIBEN " + par(5), "", par(6), "\\end{document}", ""].join("\n");
  fs.writeFileSync(path.join(proj, "antrag.tex"), doc([]));
  fs.writeFileSync(path.join(proj, "notizen.txt"), "keine .tex");

  // Server im Speicher
  const lib = new Map(), pdfs = new Map(), strokes = new Map();
  let seq = 0;
  const api = async (method, p, { json } = {}) => {
    let m;
    if (method === "GET" && p === "/api/library") return { data: { docs: [...lib.values()] } };
    if (method === "PUT" && (m = /^\/api\/library\/(.+)$/.exec(p))) { lib.set(m[1], json); return { data: json }; }
    if (method === "GET" && (m = /^\/api\/doc\/([^/]+)\/strokes/.exec(p))) {
      const changes = [...strokes.entries()].filter(([, v]) => v.doc === m[1]).map(([id, v]) => ({ id, seq: v.seq, data: v.data }));
      return { data: { top: seq, last: seq, more: false, changes } };
    }
    if (method === "POST" && (m = /^\/api\/doc\/([^/]+)\/sync$/.exec(p))) {
      for (const a of json.add) strokes.set(a.id, { doc: m[1], data: a.data, seq: ++seq });
      for (const id of json.remove) strokes.delete(id);
      return { data: {} };
    }
    throw new Error("unbekannt " + method + " " + p);
  };
  const upload = async (p, bytes) => { pdfs.set(p, bytes); };
  const logs = [];
  const H = L.create({ api, upload, log: (...a) => logs.push(a.join(" ")), getConfig: () => ({ latex: { wurzeln: [root], texbin } }) });

  ok(L.findProjects([root]).length === 1, "Projekt gefunden");
  ok(JSON.stringify(L.mainFiles(L.findProjects([root])[0])) === '["antrag.tex"]', "Hauptdatei");

  const project = L.findProjects([root])[0];
  let r = await H.build(project, "antrag.tex", "Test");
  ok(r.ok && r.doc, "erstes Setzen", JSON.stringify(r) + logs.join("\n"));
  const meta = lib.get(r.doc);
  ok(meta && meta.folder === "Exciting Games" && meta.kind === "pdf" && meta.pageCount === 1, "Dokument im Ordner, eine Seite", JSON.stringify(meta));
  const zustand = JSON.parse(fs.readFileSync(path.join(proj, ".notizbuch", "antrag", "zustand.json"), "utf8"));
  ok(zustand.pages[0].height > 400 && zustand.pages[0].height < 2000 && zustand.pages.length === 1, "lange Seite", JSON.stringify(zustand.pages));

  // Lage der Zielzeile (alt) aus SyncTeX
  const rowY = (side, needle) => {
    const sync = L.readSynctex(path.join(proj, ".notizbuch", "antrag", "stand", "synctex.gz"));
    const src = fs.readFileSync(path.join(proj, "antrag.tex"), "utf8").split("\n");
    const line = src.findIndex((l) => l.startsWith(needle)) + 1;
    const row = sync.rows.find((x) => x.line === line);
    const f = L.pageFrames(side)[0];
    return f.top + row.v * f.scale;
  };
  const yZiel = rowY(zustand.pages, "ZIELZEILE");
  const yUm = rowY(zustand.pages, "UMSCHREIBEN");
  // Ein Wort aus zwei Strichen neben die Zielzeile, eins neben die umzuschreibende
  const wire = (x, y) => ({ ink: "pen", c: [0, 0, 0, 1], p: [[x, y, 0, 2, 2, 1, 1, 0, 0], [x + 20, y + 3, 0.1, 2, 2, 1, 1, 0, 0]], pk: "QQ==" });
  const put = (w) => { const id = L.strokeID(w); strokes.set(id, { doc: r.doc, data: JSON.stringify(w), seq: ++seq }); return id; };
  put(wire(700, yZiel - 3)); put(wire(715, yZiel - 1));
  put(wire(700, yUm - 3));

  // Unverändert: nichts passiert
  let r2 = await H.build(project, "antrag.tex", "Test");
  ok(r2.unchanged, "ohne Änderung nichts neu", JSON.stringify(r2));

  // Oben zwei Absätze einfügen, die umzuschreibende Zeile ändern
  fs.writeFileSync(path.join(proj, "antrag.tex"),
    doc(["NEU " + par(7, 80), "", "NEU2 " + par(8, 80), ""]).replace("UMSCHREIBEN " + par(5), "Ganz anders formuliert. " + par(9, 30)));
  r2 = await H.build(project, "antrag.tex", "Test");
  ok(r2.ok && r2.moved === 3 && r2.changed === 1, "drei Striche verschoben, einer an umgeschriebener Stelle", JSON.stringify(r2) + logs.join("\n"));
  const z2 = JSON.parse(fs.readFileSync(path.join(proj, ".notizbuch", "antrag", "zustand.json"), "utf8"));
  const yZiel2 = rowY(z2.pages, "ZIELZEILE");
  const ys = [...strokes.values()].map((v) => JSON.parse(v.data)).map((w) => w.p[0][1]).sort((a, b) => a - b);
  ok(ys.some((y) => Math.abs(y - (yZiel2 - 3)) < 0.6) && ys.some((y) => Math.abs(y - (yZiel2 - 1)) < 0.6),
    "Wort sitzt wieder neben der Zielzeile", `${yZiel} → ${yZiel2}: ${ys.join(", ")}`);
  ok(lib.get(r.doc).pdfVersion > meta.pdfVersion && lib.get(r.doc).pagesVersion === lib.get(r.doc).pdfVersion, "neue PDF-Version");
  ok([...strokes.values()].every((v) => { const w = JSON.parse(v.data); return w.dy !== undefined; }), "dx/dy gesetzt");

  // Fehler im Dokument: nichts ausgetauscht, fehler.txt da
  const before = lib.get(r.doc).pdfVersion;
  fs.writeFileSync(path.join(proj, "antrag.tex"), doc(["\\undefinedmacro"]));
  const r3 = await H.build(project, "antrag.tex", "Test");
  ok(!r3.ok && fs.existsSync(path.join(proj, ".notizbuch", "antrag", "fehler.txt")) && lib.get(r.doc).pdfVersion === before,
    "Fehler: altes PDF bleibt", JSON.stringify(r3));
  ok(/undefinedmacro|Undefined control sequence/.test(r3.error || ""), "Fehlertext", r3.error);

  // Zuordnung Dokument → Projekt und Stelle → Quellzeilen
  fs.writeFileSync(path.join(proj, "antrag.tex"), doc([]));
  const r4 = await H.build(project, "antrag.tex", "Test");
  ok(r4.ok, "wieder setzbar", JSON.stringify(r4));
  const found = H.findDoc(r.doc.toLowerCase());
  ok(found && found.file === "antrag.tex" && found.project.dir === proj, "Dokument gehört zum Projekt");
  const z4 = JSON.parse(fs.readFileSync(path.join(proj, ".notizbuch", "antrag", "zustand.json"), "utf8"));
  const yZ = rowY(z4.pages, "ZIELZEILE");
  const spot = H.sourceSpot(project, "antrag.tex", { page: 0, x: 700, y: yZ - L.PAGE_GAP - 5, w: 40, h: 10 });
  const zline = fs.readFileSync(path.join(proj, "antrag.tex"), "utf8").split("\n").findIndex((l) => l.startsWith("ZIELZEILE")) + 1;
  ok(spot && spot.file === "antrag.tex" && spot.from <= zline && spot.to >= zline, "Stelle → Quellzeile", JSON.stringify(spot) + " " + zline);
  ok(fs.existsSync(path.join(proj, "antrag.pdf")), "A4-PDF neben der .tex");
  // git
  const s1 = H.projectStamp(project);
  const c1 = await H.commit(project, "erster Stand");
  ok(c1 && fs.existsSync(path.join(proj, ".gitignore")), "git angelegt", String(c1));
  ok(await H.commit(project, "nichts") === null, "nichts zu sichern");
  fs.appendFileSync(path.join(proj, "antrag.tex"), "% Kommentar\n");
  ok(H.projectStamp(project) !== s1, "Änderung erkannt");
  ok(typeof (await H.commit(project, "Auftrag")) === "string", "Auftrag gesichert");

  // tick: erkennt die Änderung erst nach der Ruhezeit
  fs.writeFileSync(path.join(proj, "antrag.tex"), doc([]));
  await H.tick();
  fs.rmSync(root, { recursive: true, force: true });
}

console.log(`${pass} bestanden, ${failed} fehlgeschlagen`);
process.exit(failed ? 1 : 0);
