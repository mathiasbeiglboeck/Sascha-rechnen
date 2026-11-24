// Test von „Als PDF sichern“ in der Web-Ansicht (viewer.html) gegen einen lokalen Server mit Wegwerf-Schlüssel, nie
// gegen den echten. Braucht poppler (pdfinfo, pdftoppm, pdfimages, pdftotext), python3 mit pypdf (Seitengrößen,
// Anmerkungen, verschlüsseltes PDF) und Playwright mit Chromium, einmal im Ordner server eingerichtet mit
//   npm i --no-save playwright && npx playwright install chromium
// (oder NODE_PATH auf ein Playwright, das schon anderswo liegt). Dauert etwa eine Minute:
//   cd native/Notizbuch/server && npx wrangler dev --ip 127.0.0.1 --port 8791 --var SECRET:testkey --persist-to <leerer Ordner>
//   BASE=http://127.0.0.1:8791 KEY=testkey node test/export.mjs
// Ohne Internet: LIBS=<Ordner mit pdf.min.js und pdf.worker.min.js (pdf.js 3.11.174) und pdf-lib.min.js (pdf-lib
// 1.17.1, wie im npm-Paket)>; die Adressen der CDNs beantwortet der Test dann aus diesem Ordner.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

const BASE = process.env.BASE || "http://127.0.0.1:8791";
const KEY = process.env.KEY || "testkey";
const LIBS = process.env.LIBS || "";
if (!/^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(BASE)) {
  console.error("Nur gegen einen lokalen Server (BASE=http://127.0.0.1:…), nie gegen den echten");
  process.exit(2);
}
const require = createRequire(import.meta.url);
const { chromium, devices } = require("playwright");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "export-test-"));

let failures = 0, passes = 0;
const ok = (cond, msg, extra) => {
  if (cond) { passes++; console.log("  ok  ", msg); }
  else { failures++; console.log("  FAIL", msg, extra !== undefined ? JSON.stringify(extra).slice(0, 600) : ""); }
};
const uuid = () => crypto.randomUUID().toUpperCase();
const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: opts.binary ? undefined : "utf8", maxBuffer: 1 << 28, ...opts });

async function api(method, p, { json, body, type } = {}) {
  const headers = { Authorization: `Bearer ${KEY}` };
  if (json !== undefined) { body = JSON.stringify(json); headers["content-type"] = "application/json"; }
  else if (type) headers["content-type"] = type;
  const r = await fetch(BASE + p, { method, headers, body });
  const ct = r.headers.get("content-type") || "";
  return { status: r.status, data: ct.includes("json") ? await r.json() : await r.text() };
}
async function newDoc(meta) {
  const id = uuid(), now = Date.now() / 1000;
  const r = await api("PUT", `/api/library/${id}`, { json: { id, title: "Test", kind: "notebook", created: now, modified: now, pageCount: 1, ...meta } });
  if (r.status !== 200) throw new Error("newDoc " + r.status);
  return id;
}
const share = async (doc) => (await api("POST", `/api/share/${doc}`)).data.token;
const add = (doc, list) => api("POST", `/api/doc/${doc}/sync`, { json: { since: 0, add: list.map(([id, w]) => ({ id, data: JSON.stringify(w) })), remove: [] } });

// Seitengeometrie wie in viewer.html
const W = 768, GAP = 6, A4H = W * 297 / 210;
const pageTop = (i) => GAP + i * (A4H + GAP);
// Striche: zehn Werte wie aus der App (Breite 3, Zweitskala 0,5: gezeichnet 3), neun wie aus dem Browser
const appLine = (x0, y0, x1, y1, c, n = 30, ink = "com.apple.ink.pen", w = 3) => ({ ink, c,
  p: Array.from({ length: n + 1 }, (_, i) => [x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n, i * 0.01, w, w, 1, 0.5, 0.3, 1.2, 0.5]) });
const browserLine = (x0, y0, x1, y1, c, w = 4) => ({ ink: "com.apple.ink.pen", c,
  p: Array.from({ length: 21 }, (_, i) => [x0 + (x1 - x0) * i / 20, y0 + (y1 - y0) * i / 20, i * 0.02, w, w, 1, 1, 0, 1.571]) });
// Zehn Werte mit anderer Zweitskala (gezeichnet q3 · q9 · 2), wie die App Browser-Striche weitergibt
const scaledLine = (x0, y0, x1, y1, q3, q9) => ({ ink: "com.apple.ink.pen", c: [0, 0, 0, 1],
  p: Array.from({ length: 31 }, (_, i) => [x0 + (x1 - x0) * i / 30, y0 + (y1 - y0) * i / 30, i * 0.01, q3, q3, 1, 0.5, 0.3, 1.2, q9]) });

/// Test-PDF: je Seite MediaBox, CropBox, Rotate und der Text „Seite N“ (Helvetica) in der linken oberen Ecke der
/// MediaBox. Dazu je Seite wahlweise: prefix (Inhalt davor, etwa ein „cm“ ohne q/Q), split (Inhalt in zwei Teilen),
/// inherit (Schrift nur am Seitenbaum, nicht an der Seite), link (Link-Anmerkung). Liefert die Bytes
function testPDF(pages) {
  const objs = [];
  const addObj = (s) => { objs.push(s); return objs.length; };
  const font = addObj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
  const stream = (s) => addObj(`<< /Length ${s.length} >>\nstream\n${s}\nendstream`);
  const kidsAt = [];
  pages.forEach((pg, i) => {
    const [x0, , , y1] = pg.media;
    const s = `${pg.prefix || ""} BT /F1 28 Tf ${x0 + 30} ${y1 - 60} Td (Seite ${i + 1}) Tj ET BT /F1 12 Tf ${x0 + 30} ${y1 - 85} Td (Gedruckter Text ${i + 1}) Tj ET`;
    const contents = pg.split ? `[${stream(s.slice(0, s.indexOf("BT /F1 12")))} 0 R ${stream(s.slice(s.indexOf("BT /F1 12")))} 0 R]` : `${stream(s)} 0 R`;
    const annots = pg.link ? ` /Annots [<< /Type /Annot /Subtype /Link /Rect [${x0 + 30} ${y1 - 70} ${x0 + 200} ${y1 - 30}] /Border [0 0 0] /A << /S /URI /URI (https://example.org/) >> >>]` : "";
    kidsAt.push({ pg, contents, annots });
  });
  const parent = objs.length + pages.length + 1;
  const kids = kidsAt.map(({ pg, contents, annots }) => addObj(`<< /Type /Page /Parent ${parent} 0 R /MediaBox [${pg.media.join(" ")}]` +
    (pg.crop ? ` /CropBox [${pg.crop.join(" ")}]` : "") + (pg.rotate ? ` /Rotate ${pg.rotate}` : "") +
    (pg.inherit ? "" : ` /Resources << /Font << /F1 ${font} 0 R >> >>`) + ` /Contents ${contents}${annots} >>`));
  if (addObj(`<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} /Resources << /Font << /F1 ${font} 0 R >> >> >>`) !== parent) throw new Error("parent");
  const root = addObj(`<< /Type /Catalog /Pages ${parent} 0 R >>`);
  let out = "%PDF-1.4\n";
  const offsets = [];
  objs.forEach((o, i) => { offsets.push(out.length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` + offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("");
  out += `trailer\n<< /Size ${objs.length + 1} /Root ${root} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, "latin1");
}
/// So erscheint eine Seite (wie pdf.js): sichtbare Box und Drehung → Breite und Höhe
function shown(pg) {
  const m = pg.media, c = pg.crop || m;
  const b = [Math.max(m[0], c[0]), Math.max(m[1], c[1]), Math.min(m[2], c[2]), Math.min(m[3], c[3])];
  const w = b[2] - b[0], h = b[3] - b[1], rot = ((((pg.rotate || 0) % 360) + 360) % 360);
  return rot % 180 ? [h, w] : [w, h];
}

// Eine Seite als Bild, so wie sie gezeigt wird (sichtbare Box, gedreht) und 768 Pixel breit, mal scale (shownWidth:
// gezeigte Breite in Punkten; pdftoppm zeigt sonst die ganze MediaBox und misst die Breite ungedreht). at(x, y): Farbe
// eines Pixels, find(Farbe): wie viele Pixel diese Farbe haben und wo (kleinstes Rechteck um sie), count(Farbe,
// [x0, y0, x1, y1]): wie viele in diesem Rechteck (Pixel, Ränder eingeschlossen)
function shot(pdfFile, pageNo, shownWidth = 595.28, scale = 1) {
  const out = path.join(TMP, `p-${path.basename(pdfFile)}-${pageNo}`);
  run("pdftoppm", ["-f", String(pageNo), "-l", String(pageNo), "-cropbox", "-r", String(72 * 768 * scale / shownWidth), "-singlefile", pdfFile, out]);
  const buf = fs.readFileSync(out + ".ppm");
  fs.rmSync(out + ".ppm");
  // PPM P6: Kopf „P6\n<w> <h>\n255\n“
  const m = /^P6\s+(\d+)\s+(\d+)\s+255\s/.exec(buf.subarray(0, 50).toString("latin1"));
  const w = Number(m[1]), h = Number(m[2]), off = m[0].length;
  const at = (x, y) => { const i = off + 3 * (Math.round(y) * w + Math.round(x)); return [buf[i], buf[i + 1], buf[i + 2]]; };
  const find = (color) => {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, n = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const i = off + 3 * (y * w + x);
      if (color(buf[i], buf[i + 1], buf[i + 2])) { n++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    }
    return { w, h, n, box: n ? [x0, y0, x1, y1] : null };
  };
  const count = (color, [x0, y0, x1, y1]) => {
    let n = 0;
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
      const i = off + 3 * (y * w + x);
      if (color(buf[i], buf[i + 1], buf[i + 2])) n++;
    }
    return n;
  };
  return { w, h, at, find, count };
}
// Farbe ungefähr [r, g, b] (je ± tol)
const about = (want, tol) => (r, g, b) => Math.abs(r - want[0]) <= tol && Math.abs(g - want[1]) <= tol && Math.abs(b - want[2]) <= tol;
const isBlue = (r, g, b) => b > 150 && r < 110 && g < 110;
const isRed = (r, g, b) => r > 150 && g < 110 && b < 110;
const isGreen = (r, g, b) => g > 150 && r < 110 && b < 110;
const isBlack = (r, g, b) => r < 90 && g < 90 && b < 90;
// Die blauen Striche einer Seite
const blueBox = (pdfFile, pageNo, shownWidth) => shot(pdfFile, pageNo, shownWidth).find(isBlue);
const near = (a, b, tol) => a && b && a.every((v, i) => Math.abs(v - b[i]) <= tol);
/// Je Seite MediaBox, CropBox, /Rotate (geerbt wie gelesen) und Zahl der Anmerkungen, mit pypdf
function geometry(pdfFile) {
  return JSON.parse(run("python3", ["-I", "-c", [
    "import sys, json", "from pypdf import PdfReader", "out = []",
    "for p in PdfReader(sys.argv[1]).pages:",
    "    out.append({'media': [float(v) for v in p.mediabox], 'crop': [float(v) for v in p.cropbox],",
    "                'rot': int(p.get('/Rotate', 0)), 'annots': len(p.get('/Annots') or [])})",
    "print(json.dumps(out))"].join("\n"), pdfFile]));
}

/// PDF aus einzelnen Objekten (der Text zwischen „n 0 obj“ und „endobj“; Objekt 1 ist der Katalog). tail: Text nach dem
/// Ende, den keine Querverweistabelle kennt (wie Reste eines abgebrochenen Anhängens)
function rawPDF(objs, tail = "") {
  let out = "%PDF-1.4\n";
  const offsets = [];
  objs.forEach((o, i) => { offsets.push(out.length); out += `${i + 1} 0 obj\n${o}\nendobj\n`; });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n` + offsets.map((o) => `${String(o).padStart(10, "0")} 00000 n \n`).join("");
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n${tail}`;
  return Buffer.from(out, "latin1");
}
const streamOf = (s, dict = "") => `<< /Length ${Buffer.byteLength(s, "latin1")}${dict} >>\nstream\n${s}\nendstream`;
const textOp = (t, x = 60, y = 790, size = 24, font = "/F1") => `BT ${font} ${size} Tf ${x} ${y} Td (${t}) Tj ET`;
/// A4-Seiten (595 × 842) zum Zusammenstellen: Objekt 1 Katalog, 2 Seitenbaum, 3 Helvetica. page(Inhalt, Zusatz, Ressourcen)
/// legt eine Seite an, finish(Katalog-Zusatz, kids) setzt Katalog und Seitenbaum
function a4Builder() {
  const objs = ["", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"];
  const add = (o) => { objs.push(o); return objs.length; };
  const fonts = "/Font << /F1 3 0 R >>";
  const content = (s) => `${add(streamOf(s))} 0 R`;
  const page = (contents, extra = "", resources = fonts) =>
    add(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << ${resources} >> /Contents ${contents}${extra} >>`);
  const form = (s, bbox, res = "") => add(streamOf(s, ` /Type /XObject /Subtype /Form /BBox [${bbox.join(" ")}]${res}`));
  const finish = (catalog, kids, tail = "") => {
    objs[0] = `<< /Type /Catalog /Pages 2 0 R${catalog} >>`;
    objs[1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] /Count ${kids.length} >>`;
    return rawPDF(objs, tail);
  };
  return { add, fonts, content, page, form, finish };
}
// Höhe einer A4-Seite in der Ansicht und Seitenanfänge
const H4 = W * 842 / 595;
const top4 = (i) => GAP + i * (H4 + GAP);
/// Annotation-Flags (/F) je Seite, mit pypdf
function annotFlags(pdfFile) {
  return JSON.parse(run("python3", ["-I", "-c", [
    "import sys, json", "from pypdf import PdfReader",
    "print(json.dumps([[int(a.get_object().get('/F', 0)) for a in (p.get('/Annots') or [])] for p in PdfReader(sys.argv[1]).pages]))"].join("\n"), pdfFile]));
}
/// Der Inhalt einer Seite als Text (entpackt), mit pypdf
const pageContent = (pdfFile, pageNo) => run("python3", ["-I", "-c", [
  "import sys", "from pypdf import PdfReader",
  "sys.stdout.write(PdfReader(sys.argv[1]).pages[int(sys.argv[2]) - 1].get_contents().get_data().decode('latin1'))"].join("\n"), pdfFile, String(pageNo)]);
/// Seiten, deren Inhalt (entpackt, mit pypdf) kaputte Zahlen hat: Infinity, NaN oder undefined
const brokenPages = (pdfFile) => JSON.parse(run("python3", ["-I", "-c", [
  "import sys, json, re", "from pypdf import PdfReader", "out = []",
  "for i, p in enumerate(PdfReader(sys.argv[1]).pages):",
  "    c = p.get_contents()",
  "    if c is not None and re.search(rb'Infinity|NaN|undefined', c.get_data()): out.append(i + 1)",
  "print(json.dumps(out))"].join("\n"), pdfFile]));
/// Angaben, die pdf-lib von sich aus ins PDF schriebe (das Original hat keine)
const addedInfo = (pdfFile) => run("pdfinfo", [pdfFile]).split("\n").filter((l) => /^(Creator|Producer|CreationDate|ModDate):/.test(l));
const jpegs = (file) => run("pdfimages", ["-list", file]).trim().split("\n").slice(2).filter((l) => /\bjpeg\b/.test(l)).length;
const imageLines = (file) => run("pdfimages", ["-list", file]).trim().split("\n").slice(2);
const imagePixels = (file) => imageLines(file).map((l) => { const c = l.trim().split(/\s+/); return Number(c[3]) * Number(c[4]); });
/// Verschlüsselt ein PDF (nur mit Besitzer-Passwort, wie viele Skripte aus dem Netz)
const encrypt = (from, to) => run("python3", ["-I", "-c", "import sys\nfrom pypdf import PdfReader, PdfWriter\nw = PdfWriter(clone_from=PdfReader(sys.argv[1]))\nw.encrypt(user_password='', owner_password='geheim', algorithm='RC4-128')\nw.write(sys.argv[2])", from, to]);

// ---------- Browser ----------
const browser = await chromium.launch();
// cdn: "jsdelivr" (normal), "unpkg" (jsdelivr fällt aus, die zweite Adresse hilft) oder "none" (kein Internet).
// delay: pdf-lib kommt erst nach so vielen Millisekunden (Zeit, um während des Sicherns etwas zu ändern)
async function browserContext({ phone = false, cdn = "jsdelivr", delay = 0 } = {}) {
  const context = await browser.newContext(phone ? { ...devices["iPhone 13"] } : { viewport: { width: 1280, height: 900 } });
  // Laufende Zeitgeber (setInterval) zählen: Das Sichern darf keinen zurücklassen, der beim Ansehen weiterläuft
  await context.addInitScript(() => {
    const live = new Set(), set = window.setInterval, clear = window.clearInterval;
    window.setInterval = function (...args) { const id = set.apply(this, args); live.add(id); return id; };
    window.clearInterval = function (id) { live.delete(id); return clear.call(this, id); };
    window.liveIntervals = () => live.size;
  });
  const lib = (file, wait = 0) => async (route) => {
    if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
    return route.fulfill({ path: path.join(LIBS, file),
      headers: { "access-control-allow-origin": "*", "content-type": "application/javascript; charset=utf-8" } });
  };
  if (LIBS) {
    await context.route("https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js", lib("pdf.min.js"));
    await context.route("https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js", lib("pdf.worker.min.js"));
  }
  for (const [host, url] of [["jsdelivr", "https://cdn.jsdelivr.net/npm/pdf-lib@1.17.1/dist/pdf-lib.min.js"],
    ["unpkg", "https://unpkg.com/pdf-lib@1.17.1/dist/pdf-lib.min.js"]]) {
    if (cdn === host && LIBS) await context.route(url, lib("pdf-lib.min.js", delay));
    else if (cdn === host && delay) await context.route(url, async (route) => { await new Promise((resolve) => setTimeout(resolve, delay)); return route.continue(); });
    else if (cdn !== host && (cdn !== "jsdelivr" || host !== "unpkg")) await context.route(url, (route) => route.abort());
  }
  return context;
}
async function open(token, options = {}) {
  const context = await browserContext(options);
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  // Anfragen an den Server (zum Prüfen, dass das Sichern keine macht) und nach pdf-lib (erst beim Sichern)
  page.serverHits = [];
  page.libHits = [];
  page.on("request", (r) => {
    if (r.url().startsWith(BASE)) page.serverHits.push(r.url());
    if (/pdf-lib/.test(r.url())) page.libHits.push(r.url());
  });
  await page.goto(`${BASE}/s/${token}`);
  // Geladen und verbunden (erst dann gibt es den Knopf)
  await page.waitForFunction(() => document.querySelectorAll(".page").length > 0 && document.getElementById("status").classList.contains("live"), null, { timeout: 30000 });
  return { context, page, errors };
}
/// Wartet, bis fn im Browser stimmt. Nach ms false statt eines Abbruchs: Was nicht kommt, zählt als Fehler der Prüfung
const until = (page, fn, arg = null, ms = 30000) => page.waitForFunction(fn, arg, { timeout: ms }).then(() => true, () => false);
const toastText = (page) => page.evaluate(() => document.getElementById("toast").textContent);
const busy = (page) => page.getAttribute("#export", "aria-disabled");
async function exportNow(page, name) {
  await page.waitForTimeout(300);
  page.serverHits.length = 0;
  const [download] = await Promise.all([page.waitForEvent("download", { timeout: 60000 }), page.click("#export")]);
  const file = path.join(TMP, name);
  await download.saveAs(file);
  return { file, suggested: download.suggestedFilename(), hits: [...page.serverHits] };
}

try {
  // ---------- Notizbuch ----------
  console.log("== Notizbuch: drei Seiten (die dritte nur wegen Tinte), Striche aller Arten");
  const nb = await newDoc({ title: "Export Notizbuch: Test/1", kind: "notebook", pageCount: 2 });
  const blue = [0, 0, 1, 1];
  await add(nb, [
    ["l1", appLine(100, pageTop(0) + 100, 300, pageTop(0) + 100, blue)],          // blaues L auf Seite 1
    ["l2", appLine(100, pageTop(0) + 100, 100, pageTop(0) + 250, blue)],
    ["mk", appLine(80, pageTop(0) + 400, 500, pageTop(0) + 400, [1, 0.85, 0, 0.5], 30, "com.apple.ink.marker", 10)],
    ["dot", { ink: "com.apple.ink.pen", c: [0.8, 0, 0, 1], p: [[600, pageTop(0) + 600, 0, 4, 4, 1, 1, 0, 1.571]] }],
    ["cross", appLine(700, pageTop(1) - 40, 700, pageTop(1) + 40, [0, 0.6, 0, 1])],  // über die Seitengrenze
    ["br", browserLine(200, pageTop(1) + 300, 500, pageTop(1) + 330, [0.8, 0, 0, 1])],
    ["old", { ink: "com.apple.ink.pen", c: [0, 0, 0, 1], p: [[100, pageTop(1) + 500, 0, 5, 5, 1, 0.4, 0.2, 1.1], [400, pageTop(1) + 500, 0.5, 5, 5, 1, 0.4, 0.2, 1.1]] }],
    ["p3", browserLine(100, pageTop(2) + 100, 100, pageTop(2) + 250, blue, 3)],    // Seite 3: nur ein blauer Strich
    ["bad", { ink: "com.apple.ink.pen", c: [0, 0, 0, 1], p: [[100, pageTop(0) + 700, 0, 3, 3, 1, 1, 0, 1.571], [200, null, 0, 3, 3, 1, 1, 0, 1.571]] }],
  ]);
  const nbToken = await share(nb);
  {
    const { context, page, errors } = await open(nbToken);
    ok(await page.isVisible("#export") && (await page.getAttribute("#export", "aria-label")) === "Als PDF sichern", "button „Als PDF sichern“ in der Leiste");
    ok(page.serverHits.some((u) => u.includes("/data")), "Zählen der Anfragen an den Server geht (Laden gesehen)", page.serverHits);
    // Beim bloßen Ansehen kostet das Sichern nichts: pdf-lib lädt erst beim ersten Klick
    await page.waitForTimeout(1000);
    const idle = { libHits: page.libHits.length, lib: await page.evaluate(() => typeof PDFLib), intervals: await page.evaluate(() => liveIntervals()) };
    ok(idle.libHits === 0 && idle.lib === "undefined", "vor dem ersten Klick: pdf-lib nicht geladen", idle);
    const t0 = Date.now();
    const { file, suggested, hits } = await exportNow(page, "notizbuch.pdf");
    ok(suggested === "Export Notizbuch. Test-1.pdf", "Dateiname wie in der App (: wird ., / wird -)", suggested);
    ok(hits.length === 0, "Sichern fragt den Server nichts", hits);
    ok(await page.evaluate(() => document.querySelectorAll(".page").length) === 4, "Ansicht zeigt vier Seiten (die letzte leer)");
    const info = run("pdfinfo", ["-f", "1", "-l", "9", file]);
    ok(/Pages:\s+3\n/.test(info), "drei Seiten: die leere am Ende fehlt", info);
    ok((info.match(/Page\s+\d+ size:\s+595\.28 x 841\.89\d* pts/g) || []).length === 3, "jede Seite A4 (595,28 × 841,9)", info);
    ok(/Title:\s+Export Notizbuch: Test\/1/.test(info), "Titel im PDF", info);
    ok(!/image/i.test(run("pdfimages", ["-list", file]).split("\n").slice(2).join("")), "nur Vektoren, keine Bilder");
    const b1 = blueBox(file, 1);
    // Blaues L: x 100…300, y 100…250 (Seitenpunkte = Pixel bei 768 Breite), Breite 3 → ±1,5 und runde Enden
    ok(near(b1.box, [98, 98, 302, 252], 2.5), "Seite 1: blaues L an seiner Stelle", b1);
    const b3 = blueBox(file, 3);
    ok(near(b3.box, [98, 98, 102, 252], 2.5), "Seite 3: der Strich von Seite 3", b3);
    const b2 = blueBox(file, 2);
    ok(b2.n === 0, "Seite 2: kein blauer Strich", b2);
    // Grüner Strich über der Grenze: unten auf Seite 1 und oben auf Seite 2 je ein Stück
    const green = (n) => {
      const out = path.join(TMP, `g-${n}`);
      run("pdftoppm", ["-f", String(n), "-l", String(n), "-scale-to-x", "768", "-scale-to-y", "-1", "-singlefile", file, out]);
      const buf = fs.readFileSync(out + ".ppm"), m = /^P6\s+(\d+)\s+(\d+)\s+255\s/.exec(buf.subarray(0, 50).toString("latin1"));
      fs.rmSync(out + ".ppm");
      const w = Number(m[1]), h = Number(m[2]), off = m[0].length;
      let y0 = Infinity, y1 = -Infinity;
      for (let y = 0; y < h; y++) for (let x = 690; x < 710; x++) {
        const i = off + 3 * (y * w + x);
        if (buf[i + 1] > 120 && buf[i] < 90 && buf[i + 2] < 90) { y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
      }
      return [y0, y1, h];
    };
    const g1 = green(1), g2 = green(2);
    ok(g1[1] >= g1[2] - 2 && g1[0] > g1[2] - 50, "Strich über der Grenze: Ende von Seite 1", g1);
    // 40 Punkte über die Grenze, dazu das runde Ende (Breite 3)
    ok(g2[0] <= 1 && g2[1] >= 39 && g2[1] <= 43, "Strich über der Grenze: Anfang von Seite 2", g2);
    const txt = run("pdftotext", [file, "-"]);
    ok(!/Infinity|NaN|undefined/.test(fs.readFileSync(file, "latin1")), "keine kaputten Zahlen im PDF (Angaben)");
    ok(brokenPages(file).length === 0, "keine kaputten Zahlen in den Zeichnungen (entpackt)", brokenPages(file));
    ok(txt.trim() === "", "Notizbuch: kein Text im PDF (nur Striche)", txt.slice(0, 100));
    // Textmarker durchscheinend und multipliziert: gelb auf Weiß, darunter die Karos (statt deckend oder gar nicht)
    const p1 = shot(file, 1), band = [150, 397, 450, 403];
    const marker = { onWhite: p1.count(about([255, 236, 127], 10), band), onGrid: p1.count(about([209, 192, 104], 12), band) };
    ok(marker.onWhite > 1500 && marker.onGrid > 40, "Textmarker wie in der Ansicht: durchscheinend, die Karos darunter zu sehen", marker);
    const gridGrey = about([209, 209, 209], 8);
    const grid = { p2: shot(file, 2).count(gridGrey, [0, 600, 767, 700]) };
    ok(grid.p2 > 1500, "Karos wie in der App (grau 0,82)", grid);
    ok(await page.evaluate(() => document.getElementById("toast").textContent) === "PDF gesichert", "Hinweis „PDF gesichert“");
    ok(await busy(page) === null, "Knopf danach wieder frei");
    await page.waitForTimeout(1000);
    const left = await page.evaluate(() => liveIntervals());
    ok(left === idle.intervals, "danach läuft nichts weiter (keine Zeitgeber übrig)", { left, before: idle.intervals });
    // Ohne Verbindung (die Ansicht könnte veraltet sein) kein Knopf, die Leiste wie bisher
    const shownIn = await page.evaluate(() => {
      const shown = () => getComputedStyle(document.getElementById("export")).display !== "none";
      const live = shown();
      status("Verbindung unterbrochen …");
      const off = shown();
      status("live", true);
      return { live, off, back: shown() };
    });
    ok(shownIn.live && !shownIn.off && shownIn.back, "ohne Verbindung kein Sichern-Knopf, verbunden wieder da", shownIn);
    // Breites Fenster (710) mit „Einfügen“: Der Name gibt nur Platz her, solange der Knopf da ist
    await page.setViewportSize({ width: 710, height: 900 });
    const caps = await page.evaluate(() => {
      const paste = document.getElementById("paste"), cap = () => getComputedStyle(document.getElementById("title")).maxWidth;
      paste.hidden = false;
      const live = cap();
      status("Verbindung unterbrochen …");
      const off = cap();
      status("live", true);
      paste.hidden = true;
      return { live, off };
    });
    await page.setViewportSize({ width: 1280, height: 900 });
    ok(caps.live === "64px" && caps.off === "83px", "breites Fenster mit „Einfügen“: ohne Verbindung (kein Knopf) der Name so breit wie bisher", caps);
    ok(!errors.length, "keine Fehler im Browser", errors);
    console.log(`  (Export in ${Date.now() - t0} ms)`);
    await context.close();
  }

  // ---------- PDF ----------
  console.log("== PDF: Original bleibt (Text, Größen, Drehung), Notizen darüber an der gezeigten Stelle");
  const pdfPages = [
    { media: [0, 0, 595, 842], link: true },
    { media: [0, 0, 842, 595] },
    { media: [0, 0, 595, 842], rotate: 90 },
    { media: [0, 0, 600, 800], crop: [50, 100, 550, 700] },
    { media: [0, 0, 595, 842], crop: [20, 30, 520, 830], rotate: 270 },
    { media: [0, 0, 595, 842], rotate: 180 },
    { media: [-100, -200, 495, 642] },
    { media: [0, 0, 595, 842], rotate: -90 },
    { media: [0, 0, 595, 842], prefix: "0.5 0 0 0.5 0 0 cm 0.9 g" },   // verstellt die Abbildung, ohne q/Q
    { media: [0, 0, 595, 842], inherit: true, split: true },
    { media: [0, 0, 595, 842], crop: [-50, 100, 400, 900] },             // CropBox ragt über die MediaBox
    { media: [0, 0, 595, 842], rotate: 450 },
  ];
  const bytes = testPDF(pdfPages);
  const plain = path.join(TMP, "plain.pdf"), locked = path.join(TMP, "locked.pdf");
  fs.writeFileSync(plain, bytes);
  const heights = pdfPages.map((pg) => { const [w, h] = shown(pg); return W * h / w; });
  const tops = []; { let y = GAP; for (const h of heights) { tops.push(y); y += h + GAP; } }
  const lStrokes = (prefix) => tops.flatMap((t, i) => [
    [`${prefix}h${i}`, appLine(100, t + 100, 300, t + 100, blue)],
    [`${prefix}v${i}`, appLine(100, t + 100, 100, t + 250, blue)],
  ]);
  async function pdfDoc(title, data) {
    const v = 1763900000000 + Math.floor(Math.random() * 1000);
    const id = await newDoc({ title, kind: "pdf", pageCount: pdfPages.length, pdfVersion: v, pagesVersion: v, layoutVersion: 2 });
    const r = await api("PUT", `/api/pdf/${id}`, { body: data, type: "application/pdf" });
    if (r.status !== 200) throw new Error("pdf upload " + r.status);
    await add(id, lStrokes("l"));
    return id;
  }
  const pd = await pdfDoc("Skript", bytes);
  let refL = 0; // so viele blaue Pixel hat ein ganzes L (Seite 1 des Skripts)
  {
    const { context, page, errors } = await open(await share(pd));
    await page.waitForFunction((n) => document.querySelectorAll(".page").length === n, pdfPages.length);
    await page.waitForTimeout(700);
    const idle = { libHits: page.libHits.length, lib: await page.evaluate(() => typeof PDFLib), intervals: await page.evaluate(() => liveIntervals()) };
    ok(idle.libHits === 0 && idle.lib === "undefined", "PDF ansehen: pdf-lib nicht geladen", idle);
    const { file, suggested, hits } = await exportNow(page, "skript.pdf");
    ok(suggested === "Skript.pdf", "Dateiname", suggested);
    ok(hits.length === 0, "Sichern lädt das PDF nicht noch einmal vom Server", hits);
    await page.waitForTimeout(1000);
    const left = await page.evaluate(() => liveIntervals());
    ok(left === idle.intervals, "danach läuft nichts weiter (keine Zeitgeber übrig)", { left, before: idle.intervals });
    ok(addedInfo(file).length === 0, "keine Angaben von pdf-lib (Programm, Datum) dazu", addedInfo(file));
    ok(brokenPages(file).length === 0, "keine kaputten Zahlen in den Zeichnungen (entpackt)", brokenPages(file));
    const before = geometry(path.join(TMP, "plain.pdf")), after = geometry(file);
    ok(after.length === pdfPages.length, "gleich viele Seiten", after.length);
    pdfPages.forEach((pg, i) => {
      const [w, h] = shown(pg);
      ok(JSON.stringify(after[i]) === JSON.stringify(before[i]), `Seite ${i + 1}: MediaBox, CropBox, Drehung und Links wie im Original (${w} × ${h} gezeigt)`, { before: before[i], after: after[i] });
    });
    ok(after[0].annots === 1, "Link auf Seite 1 bleibt", after[0]);
    ok(!/Title:/.test(run("pdfinfo", [file])), "kein Titel dazu: Die Angaben des Originals bleiben, wie sie sind");
    const text = run("pdftotext", [file, "-"]);
    ok(pdfPages.every((_, i) => text.includes(`Seite ${i + 1}`)), "gedruckter Text bleibt Text (auch mit geerbter Schrift)", text.slice(0, 200));
    ok(run("pdfimages", ["-list", file]).trim().split("\n").length <= 2, "keine Bilder (Original + Vektoren)");
    pdfPages.forEach((pg, i) => {
      const [w, h] = shown(pg), b = blueBox(file, i + 1, w), k = 768 / w;
      // Blaues L in Seitenpunkten: 100…300 × 100…250 bei 768 Breite; Breite 3 → ±1,5, dazu Rundung
      ok(Math.abs(b.w - 768) <= 1 && Math.abs(b.h - h * k) <= 1.5 && near(b.box, [98, 98, 302, 252], 2.5), `Seite ${i + 1}: blaues L oben links wie in der Ansicht`, b);
      if (i === 0) refL = b.n;
    });
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }

  console.log("== Verschlüsseltes PDF: Seiten als Bild, Notizen trotzdem als Vektoren an der Stelle");
  encrypt(plain, locked);
  const pe = await pdfDoc("Gesperrt", fs.readFileSync(locked));
  {
    const { context, page, errors } = await open(await share(pe));
    await page.waitForFunction((n) => document.querySelectorAll(".page").length === n, pdfPages.length);
    const before = await page.evaluate(() => liveIntervals());
    const { file, hits } = await exportNow(page, "gesperrt.pdf");
    ok(hits.length === 0, "Sichern fragt den Server nichts", hits);
    await page.waitForTimeout(1000);
    ok(await page.evaluate(() => liveIntervals()) === before, "danach läuft nichts weiter (keine Zeitgeber übrig)");
    ok(brokenPages(file).length === 0, "keine kaputten Zahlen in den Zeichnungen (entpackt)", brokenPages(file));
    // Was die Bilder zeigen: das Gedruckte an derselben Stelle wie im Original (gedreht, beschnitten). Seiten ohne
    // dunkle Schrift (abgeschnitten, hellgrau) bleiben auch im Bild ohne
    pdfPages.forEach((pg, i) => {
      const [w] = shown(pg), want = shot(plain, i + 1, w).find(isBlack), got = shot(file, i + 1, w).find(isBlack);
      if (!want.n) ok(got.n < 20, `Seite ${i + 1}: Bild ohne dunkle Schrift wie das Original`, got);
      else ok(near(got.box, want.box, 3) && Math.abs(got.n / want.n - 1) < 0.25, `Seite ${i + 1}: Bild zeigt das Gedruckte wie das Original`, { want, got });
    });
    const info = run("pdfinfo", ["-f", "1", "-l", "20", file]);
    ok(new RegExp(`Pages:\\s+${pdfPages.length}\\n`).test(info) && !/Encrypted:\s+yes/.test(info), "alle Seiten, unverschlüsselt", info);
    const images = run("pdfimages", ["-list", file]).trim().split("\n").slice(2);
    ok(images.length === pdfPages.length && images.every((l) => /\bjpeg\b/.test(l)), "je Seite ein JPEG", images);
    // Kurzes Dokument: jede Seite doppelt so scharf wie gezeigt (A4: 2 Mio. Pixel), aber höchstens 2,4 Mio. Pixel
    const pixels = images.map((l) => { const c = l.trim().split(/\s+/); return Number(c[3]) * Number(c[4]); });
    ok(pixels.every((n, i) => { const [w, h] = shown(pdfPages[i]); return n <= 2.4e6 && Math.abs(n / (4 * w * h) - 1) < 0.02; }),
      "Bilder doppelt scharf, aber nicht riesig", pixels);
    pdfPages.forEach((pg, i) => {
      const [w, h] = shown(pg), b = blueBox(file, i + 1, w);
      const m = new RegExp(`Page\\s+${i + 1} size:\\s+([\\d.]+) x ([\\d.]+) pts`).exec(info);
      ok(m && Math.abs(Number(m[1]) - w) < 0.01 && Math.abs(Number(m[2]) - h) < 0.01, `Seite ${i + 1}: so groß wie gezeigt (${w} × ${h})`, m?.[0]);
      ok(near(b.box, [98, 98, 302, 252], 3), `Seite ${i + 1}: blaues L oben links`, b);
    });
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }

  console.log("== Telefon und ohne Baustein");
  {
    const { context, page, errors } = await open(nbToken, { phone: true });
    const box = await page.locator("#export").boundingBox(), title = await page.locator("#title").boundingBox();
    ok(box && title && Math.abs(box.y - title.y) < 12, "Telefon, Nur sehen: Knopf oben bei Name und Status", { box, title });
    ok(await page.isHidden("#colors"), "Telefon, Nur sehen: Farben ausgeblendet (wie bisher)");
    const { suggested } = await exportNow(page, "telefon.pdf");
    ok(suggested.endsWith(".pdf"), "Telefon: Export geht auch im Nur-Sehen-Modus", suggested);
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }
  {
    const { context, page, errors } = await open(nbToken, { cdn: "unpkg" });
    const { suggested } = await exportNow(page, "unpkg.pdf");
    ok(suggested.endsWith(".pdf"), "jsdelivr fällt aus: pdf-lib kommt von unpkg", suggested);
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }
  {
    const { context, page } = await open(nbToken, { cdn: "none" });
    await page.click("#export");
    ok(await until(page, () => /geht gerade nicht/.test(document.getElementById("toast").textContent), null, 50000), "Baustein lädt nicht: Hinweis statt Absturz", await toastText(page));
    ok(await busy(page) === null, "Knopf danach wieder frei");
    await context.close();
  }
  console.log("== Leeres Notizbuch ohne Namen");
  {
    const empty = await newDoc({ title: "", kind: "notebook", pageCount: 3 });
    const { context, page, errors } = await open(await share(empty));
    const { file, suggested } = await exportNow(page, "leer.pdf");
    ok(suggested === "Notizen.pdf", "ohne Namen: Notizen.pdf wie in der App", suggested);
    const info = run("pdfinfo", [file]);
    const grid = shot(file, 1).count(about([209, 209, 209], 8), [0, 500, 767, 560]);
    ok(/Pages:\s+1\n/.test(info) && grid > 2000, "eine leere Seite mit Karos", { info, grid });
    ok(!/Title:/.test(info), "kein Titel im PDF", info);
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }

  // ---------- Was eine unabhängige Prüfung gefunden hat ----------
  async function uploadPDF(title, data, pageCount, strokes) {
    const v = 1763900000000 + Math.floor(Math.random() * 1000);
    const id = await newDoc({ title, kind: "pdf", pageCount, pdfVersion: v, pagesVersion: v, layoutVersion: 2 });
    const r = await api("PUT", `/api/pdf/${id}`, { body: data, type: "application/pdf" });
    if (r.status !== 200) throw new Error("pdf upload " + r.status);
    if (strokes.length) await add(id, strokes);
    return id;
  }
  // Blaues L oben links auf A4-Seite i, rote Linie auf Seite i
  const lOn = (prefix, i) => [[`${prefix}h${i}`, appLine(100, top4(i) + 100, 300, top4(i) + 100, blue)],
    [`${prefix}v${i}`, appLine(100, top4(i) + 100, 100, top4(i) + 250, blue)]];
  const redOn = (prefix, i) => [[`${prefix}r${i}`, appLine(100, top4(i) + 400, 500, top4(i) + 400, [1, 0, 0, 1])]];
  async function exportDoc(id, name, pages) {
    const { context, page, errors } = await open(await share(id));
    await page.waitForFunction((n) => document.querySelectorAll(".page").length === n, pages, { timeout: 30000 });
    const result = await exportNow(page, name);
    await context.close();
    return { ...result, errors };
  }

  console.log("== PDF mit Eigenheiten: Zustand offen gelassen, Anmerkungen, kleine #xx-Namen, gemeinsamer Inhalt");
  {
    const b = a4Builder(), kids = [];
    kids.push(b.page(b.content(`2 0 0 2 0 0 cm q ${textOp("Seite 1", 30, 395, 12)}`)));
    kids.push(b.page(b.content("q 0.5 0 0 0.5 0 0 cm BT /F1 48 Tf 120 1580 Td (Text ohne ET) Tj")));
    kids.push(b.page(b.content(`${textOp("Seite 3")} [6 6] 0 d 0 0 100 100 re W n /GSa gs q`), "",
      `${b.fonts} /ExtGState << /GSa << /CA 0.15 /ca 0.15 >> >>`));
    const grey = b.form("0.85 g 0 0 200 170 re f", [0, 0, 200, 170]);
    const marker = b.form("/GSm gs 1 1 0 rg 0 0 170 15 re f", [0, 0, 170, 15], " /Resources << /ExtGState << /GSm << /BM /Multiply >> >> >>");
    const red = b.form("1 0 0 rg 0 0 100 100 re f", [0, 0, 100, 100]);
    kids.push(b.page(b.content(textOp("Seite 4")), " /Annots [" +
      `<< /Type /Annot /Subtype /Square /Rect [60 620 260 790] /F 4 /AP << /N ${grey} 0 R >> >> ` +
      `<< /Type /Annot /Subtype /Highlight /Rect [70 755 240 770] /QuadPoints [70 770 240 770 70 755 240 755] /C [1 1 0] /F 4 /AP << /N ${marker} 0 R >> >> ` +
      `<< /Type /Annot /Subtype /Square /Rect [400 50 500 150] /F 4 /AP << /N ${red} 0 R >> >>]`));
    const off = b.form("0.8 1 0.8 rg 0 0 200 170 re f", [0, 0, 200, 170]), on = b.form("0 g 0 0 200 170 re f", [0, 0, 200, 170]);
    const box = b.add(`<< /Type /Annot /Subtype /Widget /FT /Btn /T (Feld) /V /Off /AS /Off /Rect [60 620 260 790] /F 4 /AP << /N << /On ${on} 0 R /Off ${off} 0 R >> >> >>`);
    kids.push(b.page(b.content(textOp("Seite 5")), ` /Annots [${box} 0 R]`));
    const img = b.add(streamOf("\x00\xc8\x00".repeat(4), " /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8"));
    kids.push(b.page(b.content("BT /F#c3#a4 24 Tf 300 400 Td (Umlaut-Schrift) Tj ET q 100 0 0 100 300 200 cm /Im#e4 Do Q"), "",
      `/Font << /F#c3#a4 3 0 R >> /XObject << /Im#e4 ${img} 0 R >>`));
    const shared = b.add(`[${b.content(textOp("Geteilt"))}]`);
    kids.push(b.page(`${shared} 0 R`), b.page(`${shared} 0 R`));
    const bytes = b.finish(` /ViewerPreferences [ ] /AcroForm << /Fields [${box} 0 R] >>`, kids);
    const id = await uploadPDF("Eigenheiten", bytes, kids.length, [...[0, 1, 2, 3, 4, 5, 6].flatMap((i) => lOn("e", i)), ...redOn("e", 7)]);
    const { file, errors, hits } = await exportDoc(id, "eigenheiten.pdf", kids.length);
    const images = imageLines(file);
    ok(images.length === 1 && !/jpeg/.test(images[0]), "Original bleibt (keine Seite als Bild, nur sein eigenes Bild)", images);
    ok(!/Title:/.test(run("pdfinfo", [file])) && addedInfo(file).length === 0, "kaputte ViewerPreferences stören nicht, kein Titel und keine Angaben dazu", addedInfo(file));
    ok(hits.length === 0 && brokenPages(file).length === 0, "Server nicht gefragt, keine kaputten Zahlen", { hits, broken: brokenPages(file) });
    ["q offen nach cm", "Text ohne ET", "Strichelung, Beschneidung und Deckkraft offen", "über Rechteck und Markierung",
      "über Ankreuzfeld", "kleine #xx-Namen", "gemeinsame Inhaltsliste"].forEach((what, i) => {
      const b1 = blueBox(file, i + 1);
      ok(near(b1.box, [98, 98, 302, 252], 2.5) && b1.n >= refL * 0.9, `Seite ${i + 1} (${what}): blaues L ganz und an der Stelle`, { ...b1, refL });
    });
    const text = run("pdftotext", [file, "-"]);
    ok(["Seite 1", "Text ohne ET", "Umlaut-Schrift", "Geteilt"].every((t) => text.includes(t)), "Text bleibt Text (auch die Schrift mit kleinem #xx)", text.slice(0, 300));
    const p4 = shot(file, 4), p5 = shot(file, 5);
    const grey4 = p4.at(310, 274);
    ok(grey4.every((v) => v >= 200 && v <= 230) && Math.max(...grey4) - Math.min(...grey4) < 8, "Seite 4: graues Rechteck jetzt unter den Notizen", grey4);
    ok(p4.find(isRed).n > 10000, "Seite 4: rotes Rechteck daneben bleibt", p4.find(isRed).n);
    const flags = annotFlags(file);
    ok(JSON.stringify(flags[3]) === "[6,6,4]" && JSON.stringify(flags[4]) === "[6]", "Anmerkungen unter den Notizen ausgeblendet, die daneben nicht", flags);
    const green5 = p5.at(310, 274);
    ok(green5[1] > 240 && green5[0] > 190 && green5[0] < 215 && green5[2] > 190 && green5[2] < 215, "Seite 5: Ankreuzfeld so, wie es gerade steht (aus: hellgrün)", green5);
    ok(shot(file, 6).find(isGreen).n > 10000, "Seite 6: Bild mit kleinem #xx-Namen bleibt", shot(file, 6).find(isGreen).n);
    const p7red = shot(file, 7).find(isRed).n, p8 = shot(file, 8);
    ok(p7red === 0 && p8.find(isBlue).n === 0 && p8.find(isRed).n > 500, "Seiten 7 und 8 (gemeinsamer Inhalt): jede nur mit ihren eigenen Notizen", { p7red, p8blue: p8.find(isBlue).n, p8red: p8.find(isRed).n });
    ok(!errors.length, "keine Fehler im Browser", errors);
  }

  console.log("== PDFs, die nur als Bild sicher gehen: die Notizen trotzdem ganz und an der Stelle");
  const rasterCases = [
    ["zu viele Q", 1, () => { const b = a4Builder(); return b.finish("", [b.page(b.content("q Q Q 0.5 0 0 0.5 0 0 cm BT /F1 48 Tf 120 1580 Td (Zu viele Q) Tj ET"))]); }],
    ["Seite doppelt im Seitenbaum", 2, () => { const b = a4Builder(), p = b.page(b.content(textOp("Doppelt"))); return b.finish("", [p, p]); }],
    ["alter Rest einer Seite (gedreht) hinter dem Ende", 1, () => {
      const b = a4Builder(), c = b.content(textOp("Seite 1")), p = b.page(c);
      return b.finish("", [p], `${p} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Rotate 180 /Resources << ${b.fonts} >> /Contents ${c} >>\nendobj\n`);
    }],
    ["Anmerkung ohne gespeichertes Aussehen", 1, () => {
      const b = a4Builder();
      return b.finish("", [b.page(b.content(textOp("Seite 1")), " /Annots [<< /Type /Annot /Subtype /Square /Rect [60 620 260 790] /F 4 /IC [1 1 0] /C [0 0 0] >>]")]);
    }],
    ["Formularfeld, das sein Aussehen neu erstellen soll", 1, () => {
      const b = a4Builder(), look = b.form("0.8 0.9 1 rg 0 0 200 170 re f", [0, 0, 200, 170]);
      const field = b.add(`<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (Hallo) /DA (/F1 12 Tf 0 g) /Rect [60 620 260 790] /F 4 /AP << /N ${look} 0 R >> >>`);
      return b.finish(` /AcroForm << /Fields [${field} 0 R] /NeedAppearances true /DR << ${b.fonts} >> /DA (/F1 0 Tf 0 g) >>`,
        [b.page(b.content(textOp("Seite 1")), ` /Annots [${field} 0 R]`)]);
    }],
  ];
  for (const [name, n, make] of rasterCases) {
    // Bei der doppelten Seite nur auf der ersten Notizen: Die zweite (dasselbe Objekt im PDF) darf sie nicht bekommen
    const id = await uploadPDF(name, make(), n, lOn("r", 0));
    const { file, errors, hits } = await exportDoc(id, `raster-${rasterCases.findIndex((c) => c[0] === name)}.pdf`, n);
    const b1 = blueBox(file, 1);
    ok(jpegs(file) === n && near(b1.box, [98, 98, 302, 252], 3) && b1.n >= refL * 0.9, `${name}: Seiten als Bild, Notizen ganz und an der Stelle`, { jpegs: jpegs(file), ...b1, refL });
    // Im Bild das Gedruckte oben links, wo es die Ansicht zeigt (nicht leer, nicht gedreht)
    const printed = shot(file, 1).count(isBlack, [60, 30, 330, 80]);
    ok(printed > 150, `${name}: das Gedruckte im Bild oben links wie in der Ansicht`, printed);
    if (n === 2) ok(blueBox(file, 2).n === 0, `${name}: die zweite Seite ohne die Notizen der ersten`, blueBox(file, 2));
    if (/gedreht/.test(name)) ok(geometry(file)[0].rot === 0, `${name}: Seite wie in der Ansicht (nicht gedreht)`, geometry(file));
    ok(hits.length === 0, `${name}: Server nicht gefragt`, hits);
    ok(!errors.length, "keine Fehler im Browser", errors);
  }
  {
    // Große Seite (A3): höchstens 2,4 Mio. Bildpunkte (doppelt scharf wären es 4 Mio.)
    const a3 = path.join(TMP, "a3.pdf"), a3locked = path.join(TMP, "a3-gesperrt.pdf");
    fs.writeFileSync(a3, testPDF([{ media: [0, 0, 842, 1191] }]));
    encrypt(a3, a3locked);
    const id = await uploadPDF("A3", fs.readFileSync(a3locked), 1, []);
    const { file, errors } = await exportDoc(id, "a3-export.pdf", 1);
    const px = imagePixels(file);
    ok(px.length === 1 && Math.abs(px[0] / 2.4e6 - 1) < 0.005, "verschlüsseltes A3: Bild mit 2,4 Mio. Bildpunkten, nicht größer", px);
    ok(!errors.length, "keine Fehler im Browser", errors);
  }

  console.log("== Aus der zweiten Prüfung: Anmerkungen fern der Striche, eigenwillige Aussehen und Inhalte");
  {
    const b = a4Builder(), kids = [];
    // 1: Notiz ohne Aussehen und Formularfeld (soll sein Aussehen neu erstellen) zwischen zwei Strichen, die beide nicht berühren
    const look = b.form("0.8 0.9 1 rg 0 0 200 30 re f", [0, 0, 200, 30]);
    const field = b.add(`<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /V (Hallo) /DA (/F1 12 Tf 0 g) /Rect [200 500 400 530] /F 4 /AP << /N ${look} 0 R >> >>`);
    kids.push(b.page(b.content(textOp("Seite 1")), ` /Annots [<< /Type /Annot /Subtype /Text /Rect [280 400 300 420] /Contents (Notiz) >> ${field} 0 R]`));
    // 2: Aussehen ohne /Subtype /Form (pdf.js zeigt es trotzdem)
    const noSub = b.add(streamOf("0.5 g 0 0 200 170 re f", " /BBox [0 0 200 170]"));
    kids.push(b.page(b.content(textOp("Seite 2")), ` /Annots [<< /Type /Annot /Subtype /Square /Rect [60 620 260 790] /F 4 /AP << /N ${noSub} 0 R >> >>]`));
    // 3: /CA 0,3 bei gespeichertem Aussehen (pdf.js zeigt es deckend)
    const red = b.form("1 0 0 rg 0 0 200 170 re f", [0, 0, 200, 170]);
    kids.push(b.page(b.content(textOp("Seite 3")), ` /Annots [<< /Type /Annot /Subtype /Square /Rect [60 620 260 790] /F 4 /CA 0.3 /AP << /N ${red} 0 R >> >>]`));
    // 4: leere Seite, ihr Inhalt ein leerer gepackter Datenstrom
    kids.push(b.page(`${b.add(streamOf("", " /Filter /FlateDecode"))} 0 R`));
    // 5: „>“ und „%“ in einer Eigenschaft, danach ein offenes q, alles in einer Zeile
    kids.push(b.page(b.content("/Span <</ActualText (5>3%)>> BDC BT /F1 24 Tf 60 790 Td (Seite 5) Tj ET EMC 2 0 0 2 0 0 cm q BT /F1 12 Tf 30 300 Td (klein) Tj ET")));
    // 6: Anmerkung auf einer ausgeschalteten Ebene (pdf.js zeigt sie nicht)
    const ocg = b.add("<< /Type /OCG /Name (Aus) >>"), grey = b.form("0.5 g 0 0 200 170 re f", [0, 0, 200, 170]);
    kids.push(b.page(b.content(textOp("Seite 6")), ` /Annots [<< /Type /Annot /Subtype /Square /Rect [60 620 260 790] /F 4 /OC ${ocg} 0 R /AP << /N ${grey} 0 R >> >>]`));
    const bytes = b.finish(` /AcroForm << /Fields [${field} 0 R] /NeedAppearances true /DR << ${b.fonts} >> /DA (/F1 0 Tf 0 g) >>` +
      ` /OCProperties << /OCGs [${ocg} 0 R] /D << /OFF [${ocg} 0 R] >> >>`, kids);
    const far = [["f1", appLine(300, top4(0) + 86, 460, top4(0) + 86, blue)], ["f2", appLine(300, top4(0) + 1006, 460, top4(0) + 1006, blue)]];
    const id = await uploadPDF("Zweite Prüfung", bytes, kids.length, [...far, ...[1, 2, 3, 4, 5].flatMap((i) => lOn("z", i))]);
    const { file, errors, hits } = await exportDoc(id, "zweite.pdf", kids.length);
    ok(jpegs(file) === 0, "keine Seite als Bild: Anmerkungen fern der Striche und der leere Inhalt stören nicht", imageLines(file));
    const text = run("pdftotext", [file, "-"]);
    // Auf Seite 5 liest pdftotext statt „Seite 5“ den Ersatztext der Eigenschaft (ActualText)
    ok(["Seite 1", "Seite 2", "Seite 3", "5>3%", "klein", "Seite 6"].every((t) => text.includes(t)), "Text bleibt Text", text.slice(0, 200));
    const flags = annotFlags(file);
    ok(JSON.stringify(flags[0]) === "[0,4]", "Seite 1: Notiz und Formularfeld zwischen den Strichen bleiben, wie sie sind (noch ausfüllbar)", flags);
    ok(JSON.stringify(flags.slice(1)) === "[[6],[6],[],[],[6]]", "Anmerkungen unter den Notizen: Teil der Seite", flags);
    const p2 = shot(file, 2).at(250, 200), p3 = shot(file, 3).at(250, 200), p6 = shot(file, 6).at(250, 200);
    ok(p2.every((v) => v >= 116 && v <= 140), "Seite 2: Aussehen ohne /Subtype bleibt zu sehen (grau)", p2);
    ok(p3[0] > 240 && p3[1] < 20 && p3[2] < 20, "Seite 3: deckend rot wie in der Ansicht (/CA gilt nicht)", p3);
    ok(p6.every((v) => v >= 250), "Seite 6: Anmerkung auf ausgeschalteter Ebene bleibt unsichtbar", p6);
    [2, 3, 4, 5, 6].forEach((n) => {
      const bl = blueBox(file, n);
      ok(near(bl.box, [98, 98, 302, 252], 2.5) && bl.n >= refL * 0.9, `Seite ${n}: blaues L ganz und an der Stelle`, { ...bl, refL });
    });
    ok(hits.length === 0 && brokenPages(file).length === 0, "Server nicht gefragt, keine kaputten Zahlen", { hits, broken: brokenPages(file) });
    ok(!errors.length, "keine Fehler im Browser", errors);
  }

  console.log("== Notizbuch: Breiten wie in der Ansicht, Punkte, nur Seiten mit sichtbarer Tinte, Dateinamen");
  {
    const t0 = pageTop(0), t1 = pageTop(1), t2 = pageTop(2);
    const nb2 = await newDoc({ title: "Breiten", kind: "notebook", pageCount: 3 });
    await add(nb2, [
      // Alte Striche aus der App (neun Werte, 4. bis 10.11.): so breit wie in der Ansicht (q[3])
      ["old9", { ink: "com.apple.ink.pen", c: [0, 0, 0, 1], p: [[100, t0 + 300, 0, 5, 5, 1, 0.4, 0.2, 1.1], [400, t0 + 300, 0.5, 5, 5, 1, 0.4, 0.2, 1.1]] }],
      ["app10", appLine(100, t0 + 400, 400, t0 + 400, [0, 0, 0, 1])],
      // Zehn Werte mit anderer Zweitskala: 4 · 1 · 2 = 8 breit, und wie ein weitergegebener Browser-Strich 2,9 · 0,31 · 2 = 1,8
      ["w8", scaledLine(100, t0 + 500, 400, t0 + 500, 4, 1)],
      ["w18", scaledLine(100, t0 + 550, 400, t0 + 550, 2.9, 0.31)],
      // Tippen: zwei Punkte fast an derselben Stelle werden ein Punkt, so breit wie der Stift
      ["tap", { ink: "com.apple.ink.pen", c: [0.8, 0, 0, 1], p: [[600, t0 + 600, 0, 8, 8, 1, 1, 0, 1.571], [600.02, t0 + 600.03, 0.01, 8, 8, 1, 1, 0, 1.571]] }],
      // Dick, 3 Punkte über dem Seitenende: reicht mit seiner halben Breite nicht auf Seite 2
      ["thick", browserLine(100, t0 + A4H - 3, 300, t0 + A4H - 3, blue, 9.43)],
      // In der Lücke zwischen zwei Seiten: auf keiner zu sehen
      ["gap", appLine(400, t1 - 3, 600, t1 - 3, blue)],
      // Kaputt (ein Wert fehlt) auf Seite 3: wird nicht gezeichnet
      ["bad3", { ink: "com.apple.ink.pen", c: [0, 0, 0, 1], p: [[100, t2 + 100, 0, 3, 3, 1, 1, 0, 1.571], [200, t2 + 100, 0.1, 3, null, 1, 1, 0, 1.571]] }],
    ]);
    const { context, page, errors } = await open(await share(nb2));
    const { file } = await exportNow(page, "breiten.pdf");
    const info = run("pdfinfo", [file]);
    ok(/Pages:\s+1\n/.test(info), "nur Seite 1: Auf den anderen ist keine Tinte zu sehen", info);
    const s1 = shot(file, 1);
    const across = (x, y0, y1) => { let n = 0; for (let y = y0; y <= y1; y++) if (isBlack(...s1.at(x, y))) n++; return n; };
    const w9 = across(250, 285, 315), w10 = across(250, 385, 415);
    ok(w9 >= 4 && w9 <= 6, "alter Strich (neun Werte): 5 breit wie in der Ansicht", w9);
    ok(w10 >= 2 && w10 <= 4, "Strich aus der App: 3 breit", w10);
    // Viermal so fein gemessen (1 Seitenpunkt = 4 Pixel)
    const s4 = shot(file, 1, 595.28, 4);
    const across4 = (x, y0, y1) => { let n = 0; for (let y = y0; y <= y1; y++) if (isBlack(...s4.at(x, y))) n++; return n; };
    const w8 = across4(1000, 4 * 485, 4 * 515), w18 = across4(1000, 4 * 535, 4 * 565);
    ok(w8 >= 30 && w8 <= 34, "zehn Werte, Zweitskala 1: 8 breit (Breite · Zweitskala · 2)", w8 / 4);
    ok(w18 >= 5 && w18 <= 9, "weitergegebener Browser-Strich (2,9 und 0,31): 1,8 breit", w18 / 4);
    const dot = s1.find((r, g, b) => r > 150 && g < 90 && b < 90);
    ok(dot.box && dot.box[2] - dot.box[0] >= 6 && dot.box[2] - dot.box[0] <= 10 && Math.abs((dot.box[0] + dot.box[2]) / 2 - 600) <= 2,
      "Tippen: ein Punkt, so breit wie der Stift", dot);
    // Als gefüllter Kreis: Eine Linie ohne Länge zeigen manche Programme (pdf.js, also Firefox) gar nicht
    ok((pageContent(file, 1).match(/ c f\n/g) || []).length === 1, "Tippen: als gefüllter Kreis im PDF");
    const thick = s1.find(isBlue);
    ok(thick.box && thick.box[3] >= s1.h - 2 && thick.box[2] <= 310, "dicker Strich am Seitenende da, der in der Lücke nicht", { thick, h: s1.h });
    const names = await page.evaluate(() => [
      fileName("Notizen\r\nTeil 2"), fileName("a".repeat(196) + "🇦🇹"), fileName("a".repeat(190) + "👨‍👩‍👧‍👦"),
      fileName("a".repeat(196) + "👍🏽"), fileName("a".repeat(199) + "é"), fileName("﻿Skript"), fileName("  ..Versteckt. "),
      fileName("Vorlesung 3: Analysis/Übung"), fileName("a*?\"<>b|c\\d"), fileName("x\u0007y"), fileName(" . ")]);
    const want = ["Notizen Teil 2", "a".repeat(196), "a".repeat(190), "a".repeat(196), "a".repeat(199), "﻿Skript", "Versteckt",
      "Vorlesung 3. Analysis-Übung", "ab-c-d", "x y", "Notizen"];
    names.forEach((name, i) => ok(name === want[i], `Dateiname wie in der App (${JSON.stringify(want[i]).slice(0, 30)})`, name));
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }

  console.log("== Bedienung: Doppelklick, Doppeltippen am Telefon, Hinweise");
  {
    const { context, page, errors } = await open(nbToken);
    let downloads = 0;
    page.on("download", () => downloads++);
    await page.dblclick("#export");
    const saved = await until(page, () => document.getElementById("toast").textContent === "PDF gesichert");
    await page.waitForTimeout(1500);
    ok(saved && downloads === 1, "Doppelklick sichert nur einmal", { downloads, toast: await toastText(page) });
    // pdf-lib ist jetzt da, ein Sichern dauert nur Millisekunden: Der zweite Klick (120 ms später) sichert trotzdem nicht
    const box = await page.locator("#export").boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down({ clickCount: 1 }); await page.mouse.up({ clickCount: 1 });
    await page.waitForTimeout(120);
    await page.mouse.down({ clickCount: 2 }); await page.mouse.up({ clickCount: 2 });
    await page.waitForTimeout(1500);
    ok(downloads === 2, "Doppelklick, wenn alles geladen ist: auch nur einmal", { downloads });
    // Tastatur: Der Fokus bleibt auf dem Knopf, auch während des Sicherns
    await page.evaluate(() => toast(""));
    await page.focus("#export");
    await page.keyboard.press("Enter");
    await until(page, () => document.getElementById("toast").textContent === "PDF gesichert", null, 15000);
    await page.waitForTimeout(300);
    const focused = await page.evaluate(() => document.activeElement?.id);
    ok(focused === "export" && downloads === 3, "Tastatur: Enter sichert, der Fokus bleibt auf dem Knopf", { focused, downloads });
    ok(await page.getAttribute("#toast", "role") === "status" && await page.getAttribute("#toast", "aria-live") === "polite", "Hinweise werden vorgelesen (role=status)");
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }
  {
    const { context, page, errors } = await open(nbToken, { phone: true });
    let downloads = 0;
    page.on("download", () => downloads++);
    const results = [];
    for (const at of [0.1, 0.25, 0.5, 0.8]) {
      const edit = await page.locator("#edit").boundingBox();
      const x = edit.x + edit.width * at, y = edit.y + edit.height / 2;
      await page.touchscreen.tap(x, y);
      await page.waitForTimeout(150);
      await page.touchscreen.tap(x, y);
      await page.waitForTimeout(1200);
      results.push({ at, editing: await page.evaluate(() => document.body.classList.contains("editing")), exportHidden: await page.isHidden("#export") });
      await page.click("#view");
      await page.waitForTimeout(700);
    }
    ok(downloads === 0 && results.every((r) => r.editing && r.exportHidden), "Telefon: Doppeltippen auf „Bearbeiten“ sichert nichts, beim Bearbeiten kein Sichern-Knopf", { downloads, results });
    const wide = await page.evaluate(() => { toast("PDF-Export geht gerade nicht: Ein Baustein dafür lädt nicht (Internet?)"); return document.getElementById("toast").getBoundingClientRect().width; });
    const vw = page.viewportSize().width;
    ok(wide > vw * 0.6 && wide <= vw - 32 + 0.5, "Telefon: langer Hinweis nutzt die Breite", { wide, vw });
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }
  {
    // Umgekehrt: Doppeltippen aufs Auge („Nur sehen“). Mit zwei Gästen und mittellangem Namen liegt nach dem ersten
    // Tippen genau Sichern unter dem Finger. Zweites Tippen 150 ms später: ein Doppelklick (Klick-Zahl 2). 450 ms
    // später: kein Doppelklick mehr (Chromium zählt bis 400 ms), nur die 500 ms nach dem Wechsel halten es auf. Eine
    // Runde zählt nur, wenn der zweite Klick wirklich so ankam (sonst bis zu dreimal)
    const hw = await newDoc({ title: "Hausaufgaben Mathe", kind: "notebook", pageCount: 1 });
    await add(hw, [["h1", appLine(100, pageTop(0) + 100, 300, pageTop(0) + 100, blue)]]);
    const hwToken = await share(hw);
    const second = await open(hwToken);
    const { context, page, errors } = await open(hwToken, { phone: true });
    const eye = await until(page, () => !!document.querySelector("#status svg"), null, 10000);
    let downloads = 0;
    page.on("download", () => downloads++);
    // Klicks mitschreiben, bevor die Ansicht sie sieht: Zeit seit dem Wechsel, Klick-Zahl, getroffener Knopf
    await page.evaluate(() => addEventListener("click", (e) => window.clicks?.push({ dt: Math.round(performance.now() - switched),
      detail: e.detail, id: e.target.closest?.("button")?.id }), true));
    const rounds = [];
    for (const [gap, want] of [[450, 1], [150, 2]]) {
      for (let attempt = 0; attempt < 3; attempt++) {
        await page.tap("#edit");
        await page.waitForTimeout(800);
        const view = await page.locator("#view").boundingBox();
        const x = view.x + view.width / 2, y = view.y + view.height / 2;
        await page.evaluate(() => { window.clicks = []; });
        const before = downloads, t = Date.now();
        await page.touchscreen.tap(x, y);
        const under = await page.evaluate(([x, y]) => document.elementFromPoint(x, y)?.closest("button")?.id, [x, y]);
        await page.waitForTimeout(Math.max(0, gap - (Date.now() - t)));
        await page.touchscreen.tap(x, y);
        await page.waitForTimeout(1500);
        const hit = (await page.evaluate(() => window.clicks))[1];
        const r = { gap, under, hit, saved: downloads - before, editing: await page.evaluate(() => document.body.classList.contains("editing")), toast: await toastText(page) };
        r.valid = !!hit && hit.id === "export" && hit.detail === want && hit.dt < 500;
        rounds.push(r);
        // Kam es außerhalb der 500 ms an, durfte es sichern: abwarten, dann noch einmal
        await until(page, () => !document.getElementById("export").hasAttribute("aria-disabled"), null, 10000);
        await page.evaluate(() => toast(""));
        if (r.editing) { await page.waitForTimeout(600); await page.tap("#view"); await page.waitForTimeout(600); }
        if (r.valid) break;
      }
    }
    const valid = rounds.filter((r) => r.valid);
    ok(eye && valid.length === 2 && valid.every((r) => r.under === "export"), "Aufbau: nach dem Tippen aufs Auge liegt Sichern unter dem Finger, zweites Tippen nach 150 und 450 ms", { eye, rounds });
    ok(valid.every((r) => !r.saved && !r.editing && r.toast === ""), "Telefon: Doppeltippen aufs Auge sichert nichts", { downloads, rounds });
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
    await second.context.close();
  }

  console.log("== Teilen beendet, ungültiger Link, neues PDF während des Sicherns");
  {
    const g = await newDoc({ title: "Bald beendet", kind: "notebook", pageCount: 1 });
    await add(g, [["g1", appLine(100, pageTop(0) + 100, 300, pageTop(0) + 100, blue)]]);
    const { context, page, errors } = await open(await share(g), { delay: 3000 });
    let downloads = 0;
    page.on("download", () => downloads++);
    await page.click("#export");
    await page.waitForTimeout(300);
    const during = await busy(page);
    await api("DELETE", `/api/share/${g}`);
    await until(page, () => /beendet|gesichert|geklappt/.test(document.getElementById("toast").textContent));
    const told = await toastText(page);
    await page.waitForTimeout(1000);
    ok(during === "true", "während des Sicherns: Knopf gesperrt", during);
    ok(told === "Das Teilen wurde beendet." && downloads === 0 && await busy(page) === null && await page.isHidden("#export"),
      "Teilen beendet, während gesichert wird: keine Datei, Hinweis, Knopf weg wie in der Ansicht", { told, downloads });
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }
  {
    const context = await browserContext();
    const page = await context.newPage();
    await page.goto(`${BASE}/s/UngueltigerLink000000000`);
    await page.waitForFunction(() => /nicht \(mehr\) gültig/.test(document.getElementById("msg").textContent), null, { timeout: 20000 });
    ok(await page.isHidden("#export"), "ungültiger Link: kein Sichern-Knopf");
    // Käme es doch zum Sichern (Tastatur, Rennen): Der Hinweis sagt, was die Ansicht sagt (nicht „Teilen beendet“)
    await page.evaluate(() => exportPDF());
    ok(await page.evaluate(() => document.getElementById("toast").textContent) === "Dieser Link ist nicht (mehr) gültig.", "ungültiger Link: Der Hinweis sagt das (nicht „Teilen beendet“)");
    await context.close();
  }
  {
    // Verschlüsselt (also als Bild, das dauert) und lang genug, dass das neue PDF mitten hinein kommt
    const many = Array.from({ length: 40 }, () => ({ media: [0, 0, 595, 842] }));
    const plain40 = path.join(TMP, "plain40.pdf"), locked40 = path.join(TMP, "locked40.pdf");
    fs.writeFileSync(plain40, testPDF(many));
    encrypt(plain40, locked40);
    const v = 1763900000000, created = Date.now() / 1000;
    const id = await newDoc({ title: "Wechselt", kind: "pdf", pageCount: 40, created, pdfVersion: v, pagesVersion: v, layoutVersion: 2 });
    await api("PUT", `/api/pdf/${id}`, { body: fs.readFileSync(locked40), type: "application/pdf" });
    const { context, page, errors } = await open(await share(id));
    await page.waitForFunction(() => document.querySelectorAll(".page").length === 40, null, { timeout: 30000 });
    let downloads = 0;
    page.on("download", () => downloads++);
    await page.click("#export");
    const rastering = await until(page, () => /Seiten als Bilder/.test(document.getElementById("toast").textContent));
    ok(rastering, "verschlüsselt: Die Seiten werden zu Bildern", await toastText(page));
    if (rastering) {
      // Das iPad schickt ein neues PDF (eine Seite weniger)
      await api("PUT", `/api/pdf/${id}`, { body: testPDF(many.slice(1)), type: "application/pdf" });
      await api("PUT", `/api/library/${id}`, { json: { id, title: "Wechselt", kind: "pdf", created, modified: Date.now() / 1000 + 1, pageCount: 39, pdfVersion: v + 1000, pagesVersion: v + 1000, layoutVersion: 2 } });
      await until(page, () => /geändert|gesichert|geklappt/.test(document.getElementById("toast").textContent), null, 60000);
      const told = await toastText(page);
      const free = await until(page, () => !document.getElementById("export").hasAttribute("aria-disabled"), null, 10000);
      ok(/geändert/.test(told) && downloads === 0 && free, "neues PDF während des Sicherns: keine halbe Datei, Hinweis „noch einmal sichern“", { told, downloads, free });
      await page.waitForFunction(() => document.querySelectorAll(".page").length === 39, null, { timeout: 30000 });
      const { file } = await exportNow(page, "wechselt.pdf");
      ok(/Pages:\s+39\n/.test(run("pdfinfo", [file])), "danach: das neue PDF gesichert (39 Seiten)", run("pdfinfo", [file]));
    }
    ok(!errors.length, "keine Fehler im Browser", errors);
    await context.close();
  }
} finally {
  await browser.close();
  // KEEP=1: die erzeugten PDFs zum Ansehen behalten
  if (process.env.KEEP) console.log("PDFs in", TMP);
  else fs.rmSync(TMP, { recursive: true, force: true });
}
console.log(`\n${passes} ok, ${failures} fehlgeschlagen`);
process.exit(failures ? 1 : 0);
