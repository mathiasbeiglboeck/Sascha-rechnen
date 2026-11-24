// Prüft am Mac hintergrund.js (BG_SCRIPT aus weitere-seiten.mjs) direkt mit osascript, Schritt für Schritt wie der
// Helfer (probeOK): hoehen, bilder (klein, wie die Prüfung), farben (an den Stellen der Prüfung und als Karte je Seite),
// dann jedes weitere PDF in voller Größe (wie für eine Frage). Schreibt nur in <ordner>.
//   node native/Notizbuch/claude-fragen/test/hintergrund-pruefen.mjs <ordner> [<pdf> …]
// OSASCRIPT=<pfad> nimmt einen anderen osascript (unter Linux test/fake-osascript), SCRIPT=<datei> ein anderes
// hintergrund.js (zum Ausprobieren einer Variante); sonst /usr/bin/osascript und BG_SCRIPT unverändert
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const [dir, ...pdfs] = process.argv.slice(2);
if (!dir) {
  console.error("Aufruf: node hintergrund-pruefen.mjs <ordner> [<pdf> …]");
  process.exit(2);
}
const W = await import(new URL("../weitere-seiten.mjs", import.meta.url));
const OSA = process.env.OSASCRIPT || "/usr/bin/osascript";
fs.mkdirSync(dir, { recursive: true });
const script = path.resolve(dir, "hintergrund.js");
if (process.env.SCRIPT) fs.copyFileSync(process.env.SCRIPT, script);
else fs.writeFileSync(script, W.BG_SCRIPT);
console.log(`hintergrund.js ${process.env.SCRIPT ? `= ${process.env.SCRIPT}` : "= BG_SCRIPT aus weitere-seiten.mjs"}, osascript ${OSA}`);

let bad = 0;
const say = (good, what, detail = "") => {
  if (!good) bad++;
  console.log(`${good ? "✓" : "✗"} ${what}${detail ? `: ${detail}` : ""}`);
};
function osa(args) {
  const t0 = Date.now();
  try {
    const out = execFileSync(OSA, ["-l", "JavaScript", script, ...args], { encoding: "utf8", timeout: 120000, stdio: ["ignore", "pipe", "pipe"] });
    return { ms: Date.now() - t0, out: out.trim() };
  } catch (e) {
    return { ms: Date.now() - t0, err: String(e.stderr || e.message).trim().slice(0, 600) || "keine Ausgabe" };
  }
}
const parse = (r) => {
  try {
    return JSON.parse(r.out);
  } catch {
    return null;
  }
};
const show = (r) => (r.err ? `FEHLER ${r.err}` : r.out.slice(0, 400));
// Antwort von hoehen kurz: je Seite Breite × Höhe der CropBox und Drehung, dann die Höhen (gleiche hintereinander als „× n“)
function shortHeights(r) {
  const h = parse(r);
  if (!Array.isArray(h?.heights)) return show(r);
  const runs = [];
  for (const [k, v] of h.heights.entries()) {
    const box = h.pages?.[k] ? `${h.pages[k].w} × ${h.pages[k].h}${h.pages[k].rot ? ` gedreht ${h.pages[k].rot}` : ""}` : "?";
    const last = runs.at(-1);
    const text = `${Number(v).toFixed(2)} (${box})`;
    if (last && last.text === text) last.n++;
    else runs.push({ text, n: 1 });
  }
  return `${h.heights.length} Seiten, Höhen ${runs.map((x) => (x.n > 1 ? `${x.text} × ${x.n}` : x.text)).join(", ")}`;
}

// ---------- 1. Prüf-PDF wie probeOK ----------
const { pdf, heights, marks } = W.probePDF();
const probe = path.resolve(dir, "probe.pdf");
fs.writeFileSync(probe, pdf);
console.log("\n== Prüf-PDF (4 Seiten: hoch 200 × 283, quer 283 × 200, /Rotate 90, CropBox [30 100 200 283])");

let r = osa(["hoehen", probe]);
const h = parse(r);
say(Array.isArray(h?.heights) && h.heights.length === heights.length && h.heights.every((v, i) => Math.abs(v - heights[i]) < 0.5),
  `hoehen in ${r.ms} ms`, `${shortHeights(r)}\n    erwartet ${heights.map((v) => v.toFixed(2)).join(", ")}`);

const small = path.resolve(dir, "klein");
fs.rmSync(small, { recursive: true, force: true });
fs.mkdirSync(small, { recursive: true });
const want = heights.map((v, i) => [i, 96, Math.round(v / 8)]);
r = osa(["bilder", probe, small, ...want.map((x) => x.join(":"))]);
const b = parse(r);
say(Array.isArray(b?.ok) && b.ok.length === 4 && !(b.fail || []).length, `bilder (96 breit) in ${r.ms} ms`, show(r));
for (const [i, pw, ph] of want) {
  let info = null;
  try {
    info = W.jpegInfo(fs.readFileSync(path.join(small, `bg-${i}.jpg`)));
  } catch {}
  say(Boolean(info && info.w === pw && info.h === ph), `  bg-${i}.jpg`, info ? `${info.w} × ${info.h}, ${info.comps} Farbkanäle (verlangt ${pw} × ${ph})` : "fehlt");
}

// Die Stellen der Prüfung (wie probeOK) und eine Karte je Seite: B blau, R rot, . weiß, ? anders, x keine Farbe
const looks = (color, c) => {
  if (!Array.isArray(c) || c.length !== 3 || !c.every((x) => typeof x === "number")) return false;
  const [R, G, B] = c;
  if (color === "blau") return B > 100 && B - Math.max(R, G) > 60;
  if (color === "rot") return R > 120 && R - Math.max(G, B) > 60;
  return Math.min(R, G, B) > 200;
};
const spots = want.flatMap(([i, pw, ph]) => marks[i].map((m) => ({
  i, color: m.color, x: Math.min(pw - 1, Math.floor(m.fx * pw)), y: Math.min(ph - 1, Math.floor(m.fy * ph)),
})));
r = osa(["farben", small, ...spots.map((m) => `${m.i}:${m.x}:${m.y}`)]);
const got = parse(r)?.c;
say(Array.isArray(got) && got.length === spots.length, `farben (${spots.length} Stellen der Prüfung) in ${r.ms} ms`, Array.isArray(got) ? "" : show(r));
spots.forEach((m, k) => say(looks(m.color, got?.[k]), `  Seite ${m.i + 1}: ${m.color} bei ${m.x}, ${m.y}`, JSON.stringify(got?.[k] ?? null)));

// Wo die Rechtecke sein müssen: Punkt (fx, fy) im Bild (ab oben links) zurück auf die PDF-Seite, wie probePDF sie baut
const PAGES = [
  { box: [0, 0, 200, 283] },
  { box: [0, 0, 283, 200] },
  { box: [0, 0, 200, 283], rotate: 90 },
  { box: [30, 100, 200, 283] },
];
const inRect = (x, y, [rx, ry, rw, rh]) => x >= rx && x <= rx + rw && y >= ry && y <= ry + rh;
function expected(i, fx, fy) {
  const { box: [x0, y0, x1, y1], rotate } = PAGES[i];
  const x = rotate === 90 ? x0 + fy * (x1 - x0) : x0 + fx * (x1 - x0);
  const y = rotate === 90 ? y0 + fx * (y1 - y0) : y0 + (1 - fy) * (y1 - y0);
  if (inRect(x, y, [10, 10, 60, 40])) return "B";
  if (inRect(x, y, [120, 150, 50, 30])) return "R";
  return ".";
}
const classify = (c) => {
  if (!Array.isArray(c)) return "x";
  if (looks("blau", c)) return "B";
  if (looks("rot", c)) return "R";
  if (looks("weiß", c)) return ".";
  return "?";
};
for (const [i, pw, ph] of want) {
  const cols = 16, rows = Math.max(4, Math.round((cols * ph) / pw));
  const cells = [];
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      const x = Math.min(pw - 1, Math.floor(((col + 0.5) / cols) * pw)), y = Math.min(ph - 1, Math.floor(((row + 0.5) / rows) * ph));
      // Erwartet in der Mitte des Pixels; liegt 1,5 Pixel daneben etwas anderes, ist es ein Rand (~, zählt nicht)
      const at = (dx, dy) => expected(i, (x + 0.5 + dx) / pw, (y + 0.5 + dy) / ph);
      const all = [at(0, 0), at(-1.5, 0), at(1.5, 0), at(0, -1.5), at(0, 1.5)];
      cells.push({ x, y, e: all.every((v) => v === all[0]) ? all[0] : "~" });
    }
  }
  const rr = osa(["farben", small, ...cells.map((c) => `${i}:${c.x}:${c.y}`)]);
  const cs = parse(rr)?.c;
  let differ = 0;
  const lines = [];
  for (let row = 0; row < rows; row++) {
    let want1 = "", got1 = "";
    for (let col = 0; col < cols; col++) {
      const c = cells[row * cols + col];
      const g = classify(cs?.[row * cols + col]);
      want1 += c.e;
      got1 += g;
      if (c.e !== "~" && c.e !== g) differ++;
    }
    lines.push(`    ${want1}   ${got1}`);
  }
  say(differ <= 2, `  Karte Seite ${i + 1} (${cols} × ${rows}; links erwartet, ~ Rand; rechts gezeichnet)`, `${differ} Zellen anders\n${lines.join("\n")}`);
}

// ---------- 2. Weitere PDFs in voller Größe, wie für eine Frage ----------
for (const file of pdfs) {
  const name = path.basename(file, ".pdf");
  console.log(`\n== ${file}`);
  r = osa(["hoehen", path.resolve(file)]);
  const hh = parse(r);
  say(Array.isArray(hh?.heights) && hh.heights.length > 0, `hoehen in ${r.ms} ms`, shortHeights(r));
  if (!Array.isArray(hh?.heights)) continue;
  const out = path.resolve(dir, `gross-${name}`);
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const pages = hh.heights.slice(0, 4).map((v, i) => [i, W.pageGeometry(v).PW, W.pageGeometry(v).PH]);
  r = osa(["bilder", path.resolve(file), out, ...pages.map((x) => x.join(":"))]);
  say(Array.isArray(parse(r)?.ok), `bilder in voller Größe, ${pages.length} Seiten in ${r.ms} ms (${Math.round(r.ms / pages.length)} ms je Seite)`, show(r));
  for (const [i, pw, ph] of pages) {
    const f = path.join(out, `bg-${i}.jpg`);
    let info = null, size = 0;
    try {
      const buf = fs.readFileSync(f);
      size = buf.length;
      info = W.jpegInfo(buf);
    } catch {}
    say(Boolean(info && info.w === pw && info.h === ph), `  ${f}`, info ? `${info.w} × ${info.h}, ${Math.round(size / 1024)} KB (verlangt ${pw} × ${ph})` : "fehlt");
  }
}

console.log(`\n${bad ? `✗ ${bad} Prüfungen gescheitert` : "✓ alles wie erwartet"}`);
process.exit(bad ? 1 : 0);
