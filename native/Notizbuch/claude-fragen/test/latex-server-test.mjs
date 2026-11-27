// LaTeX-Modus gegen einen lokalen Server (wie helper-test.mjs nur mit Wegwerf-Schlüssel):
// BASE=http://127.0.0.1:8791 KEY=testkey node native/Notizbuch/claude-fragen/test/latex-server-test.mjs [texbin]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as L from "../latex.mjs";

const BASE = process.env.BASE, KEY = process.env.KEY;
if (!BASE || !/^http:\/\/(127\.0\.0\.1|localhost):/.test(BASE) || !KEY) {
  console.log("Nur gegen einen lokalen Server: BASE=http://127.0.0.1:… KEY=…");
  process.exit(2);
}
const texbin = process.argv[2] || (fs.existsSync("/Library/TeX/texbin/latexmk") ? "/Library/TeX/texbin" : "/usr/bin");
let pass = 0, failed = 0;
const ok = (c, name, extra = "") => { if (c) pass++; else { failed++; console.log("FEHLER:", name, extra); } };

async function api(method, p, { json } = {}) {
  const res = await fetch(BASE + p, { method, headers: { Authorization: `Bearer ${KEY}`,
    ...(json !== undefined ? { "content-type": "application/json" } : {}) }, body: json !== undefined ? JSON.stringify(json) : undefined });
  const type = res.headers.get("content-type") || "";
  const data = type.includes("json") ? await res.json() : Buffer.from(await res.arrayBuffer());
  if (!res.ok) throw new Error(`${method} ${p}: ${res.status} ${JSON.stringify(data)}`);
  return { data, type };
}
const upload = async (p, bytes) => {
  const res = await fetch(BASE + p, { method: "PUT", headers: { Authorization: `Bearer ${KEY}` }, body: bytes });
  if (!res.ok) throw new Error(`PUT ${p}: ${res.status}`);
};

const root = fs.mkdtempSync(path.join(os.tmpdir(), "nb-latex-srv-"));
const proj = path.join(root, "Exciting Games");
fs.mkdirSync(proj);
fs.writeFileSync(path.join(proj, "notizbuch.json"), "{}");
const par = (k, n = 60) => Array.from({ length: n }, (_, i) => ["Spiel", "Wert", "Markov", "optimal", "Kette"][(i + k) % 5]).join(" ") + ".";
const src = (extra) => ["\\documentclass{article}", "\\begin{document}", par(1), "", ...extra, "ANKER " + par(2), "", par(3),
  "\\end{document}", ""].join("\n");
fs.writeFileSync(path.join(proj, "ideen.tex"), src([]));
const logs = [];
const H = L.create({ api, upload, log: (...a) => logs.push(a.join(" ")), getConfig: () => ({ latex: { wurzeln: [root], texbin } }) });
const project = L.findProjects([root])[0];

const r1 = await H.build(project, "ideen.tex", "Test");
ok(r1.ok, "angelegt", JSON.stringify(r1) + logs.join("\n"));
const lib1 = (await api("GET", "/api/library")).data.docs.find((d) => d.id === r1.doc);
ok(lib1 && lib1.folder === "Exciting Games" && lib1.hasPDF && lib1.kind === "pdf", "im Ordner, mit PDF", JSON.stringify(lib1));

// Ein Strich der App (mit pk) neben die Ankerzeile
const z = JSON.parse(fs.readFileSync(path.join(proj, ".notizbuch", "ideen", "zustand.json"), "utf8"));
const sync = L.readSynctex(path.join(proj, ".notizbuch", "ideen", "stand", "synctex.gz"));
const line = src([]).split("\n").findIndex((l) => l.startsWith("ANKER")) + 1;
const f = L.pageFrames(z.pages)[0];
const y = f.top + sync.rows.find((r) => r.line === line).v * f.scale;
const wire = { ink: "com.apple.ink.pen", c: [0, 0, 1, 1], p: [[720, y, 0, 2, 2, 1, 1, 0, 0, 1], [740, y + 2, 0.1, 2, 2, 1, 1, 0, 0, 1]], pk: "AAAA" };
const id = L.strokeID(wire);
await api("POST", `/api/doc/${r1.doc}/sync`, { json: { since: 0, add: [{ id, data: JSON.stringify(wire) }], remove: [] } });

fs.writeFileSync(path.join(proj, "ideen.tex"), src(["NEU " + par(4, 120), ""]));
const r2 = await H.build(project, "ideen.tex", "Test");
ok(r2.ok && r2.moved === 1, "verschoben", JSON.stringify(r2) + logs.join("\n"));
const lib2 = (await api("GET", "/api/library")).data.docs.find((d) => d.id === r1.doc);
ok(lib2.pdfVersion > lib1.pdfVersion && lib2.pagesVersion === lib2.pdfVersion, "neue PDF-Version am Server", JSON.stringify(lib2));
const all = (await api("GET", `/api/doc/${r1.doc}/strokes?since=0&limit=1000`)).data.changes;
const alive = all.filter((c) => c.data);
ok(alive.length === 1 && alive[0].id !== id && all.some((c) => c.id === id && !c.data), "alter Strich weg, neuer da", JSON.stringify(all.map((c) => [c.id, !!c.data])));
const moved = JSON.parse(alive[0].data);
const z2 = JSON.parse(fs.readFileSync(path.join(proj, ".notizbuch", "ideen", "zustand.json"), "utf8"));
const sync2 = L.readSynctex(path.join(proj, ".notizbuch", "ideen", "stand", "synctex.gz"));
const line2 = src(["NEU " + par(4, 120), ""]).split("\n").findIndex((l) => l.startsWith("ANKER")) + 1;
const f2 = L.pageFrames(z2.pages)[0];
const y2 = f2.top + sync2.rows.find((r) => r.line === line2).v * f2.scale;
ok(Math.abs(moved.p[0][1] - y2) < 0.6 && Math.abs(moved.dy - (y2 - y)) < 0.6 && moved.pk === "AAAA", "an der neuen Stelle, mit dy",
  `${y} → ${y2}, ${moved.p[0][1]} dy ${moved.dy}`);
const pdf = (await api("GET", `/api/pdf/${r1.doc}`)).data;
ok(pdf.subarray(0, 5).toString() === "%PDF-" && pdf.length === fs.statSync(path.join(proj, ".notizbuch", "ideen", "bau", "ideen.pdf")).size,
  "neues PDF am Server");

fs.rmSync(root, { recursive: true, force: true });
console.log(`${pass} bestanden, ${failed} fehlgeschlagen`);
process.exit(failed ? 1 : 0);
