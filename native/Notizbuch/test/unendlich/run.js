// Tabelle: feste ∞ und Lasso-Wege durch detect() aus detector.js, das Notizbuch/InfinityGesture.swift spiegelt
// (Schwellen immer in beiden Dateien ändern). Aufruf: node run.js; erwartet am Ende „Falsch: 0 von 51“.
"use strict";
const { detect, T } = require("./detector.js");
const S = require("./shapes.js");

const IPAD13 = 1.34, MINI = 1.0, PHONE = 0.51;
const cases = [];
/// Fall: Weg in Bildschirmpunkten, s = Bildschirmpunkte je Seitenpunkt
function add(name, expect, s, pts) { cases.push({ name, expect, s, pts }); }
const inf = (opts) => {
  const { w = 100, h = 1, right = 1, rot = 0, t0 = 0, t1 = 2 * Math.PI, jitter = 0.3, wobble = 0.02, seed = 1, secs = 1.0, hz = 240, curve = "g", tremor = 0 } = opts;
  const f = curve === "b" ? S.bernoulli() : S.gerono(right, h);
  const sx = curve === "b" ? w / 2 : w / (1 + right);
  return S.sample(S.place(f, { sx, sy: sx, rot }), t0, t1, { jitter, wobble, seed, secs, hz, size: w, tremor });
};

// ---- ∞ (soll erkennen)
add("∞ 100×50, Start Mitte (iPad 13)", true, IPAD13, inf({}));
add("∞ 40×20 klein (iPhone)", true, PHONE, inf({ w: 40, jitter: 0.6, hz: 120 }));
add("∞ 30×15 sehr klein (iPad mini)", true, MINI, inf({ w: 30, jitter: 0.3 }));
add("∞ 300×150 groß (iPad 13)", true, IPAD13, inf({ w: 300, jitter: 0.4, secs: 1.5 }));
add("∞ geneigt +20°", true, IPAD13, inf({ rot: 20 }));
add("∞ geneigt −35°", true, IPAD13, inf({ rot: -35 }));
add("∞ geneigt +45°", true, IPAD13, inf({ rot: 45 }));
add("∞ zittrig (Finger, σ 1,2, Wackeln 4 %)", true, PHONE, inf({ w: 90, jitter: 1.2, wobble: 0.04, hz: 120, seed: 3 }));
add("∞ sehr zittrig (σ 2,5, Wackeln 6 %) [Stress]", null, PHONE, inf({ w: 110, jitter: 2.5, wobble: 0.06, hz: 120, seed: 4 }));
add("∞ rechte Schleife 1,6× größer", true, IPAD13, inf({ right: 1.6, w: 120 }));
add("∞ rechte Schleife 2× größer", true, IPAD13, inf({ right: 2.0, w: 130 }));
add("∞ linke Schleife 2× größer", true, IPAD13, inf({ right: 0.5, w: 130 }));
add("∞ Start am linken Ende", true, IPAD13, inf({ t0: 1.5 * Math.PI, t1: 3.5 * Math.PI }));
add("∞ endet 25° vor der Mitte (nicht zu)", true, IPAD13, inf({ t1: 2 * Math.PI - 0.45 }));
add("∞ Überhang über die Mitte hinaus", true, IPAD13, inf({ t1: 2 * Math.PI + 0.5 }));
add("∞ flach (Höhe 0,28 × Breite)", true, IPAD13, inf({ h: 0.55 }));
add("∞ hoch (Höhe 0,8 × Breite)", true, IPAD13, inf({ h: 1.6 }));
add("∞ Bernoulli (spitz in der Mitte)", true, IPAD13, inf({ curve: "b", t0: Math.PI / 2, t1: Math.PI / 2 + 2 * Math.PI }));
add("∞ zweimal nachgezogen", null, IPAD13, inf({ t1: 4 * Math.PI, secs: 1.8, wobble: 0.04 }));
add("∞ andersherum gezeichnet", true, IPAD13, inf({ t0: 2 * Math.PI, t1: 0 }));
add("∞ gezoomt (Zoom 3, 150 Seitenpunkte)", true, IPAD13 * 3, inf({ w: 150 * IPAD13 * 3 / 1.0 * 0.95, jitter: 0.5, secs: 1.6 }));
add("∞ iPad mini, Pencil 1 (σ 0,5)", true, MINI, inf({ w: 120, jitter: 0.5, wobble: 0.03, seed: 7 }));
add("∞ mit Handzittern (2 Pkt, 9 Hz)", true, IPAD13, inf({ w: 110, jitter: 0.2, tremor: 2, seed: 8 }));
add("∞ endet 40° vor der Mitte [Grenze]", null, IPAD13, inf({ t1: 2 * Math.PI - 0.7 }));

// ---- normale Lasso-Wege (darf nie auslösen)
const at = (f, o = {}) => S.place(f, o);
add("Kreis r 60 (gegen Uhrzeiger)", false, IPAD13, S.sample(at(S.circle(), { sx: 60, sy: 60 }), 0, 2 * Math.PI, { jitter: 0.4 }));
add("Kreis r 150 (im Uhrzeiger)", false, IPAD13, S.sample(at(S.circle(), { sx: 150, sy: 150 }), 2 * Math.PI, 0, { jitter: 0.4 }));
add("Ellipse 3:1, 30° geneigt", false, IPAD13, S.sample(at(S.circle(), { sx: 150, sy: 50, rot: 30 }), 0, 2 * Math.PI, { jitter: 0.4 }));
add("Niere (Delle 45 %)", false, IPAD13, S.sample(at(S.kidney(0.45), { sx: 100, sy: 70 }), 0, 2 * Math.PI, { jitter: 0.5, wobble: 0.03 }));
add("Niere tief (Delle 70 %)", false, IPAD13, S.sample(at(S.kidney(0.7, Math.PI / 2, 0.5), { sx: 120, sy: 80 }), 0, 2 * Math.PI, { jitter: 0.5, wobble: 0.03 }));
add("Herz", false, IPAD13, S.sample(at(S.heart(), { sx: 90, sy: 90 }), 0, 2 * Math.PI, { jitter: 0.5 }));
add("Schleife, am Ende 15 % überlappt", false, IPAD13, S.sample(at(S.circle(), { sx: 80, sy: 60 }), 0, 2 * Math.PI * 1.15, { jitter: 0.5, wobble: 0.03 }));
add("Schleife, am Ende 40 % überlappt", false, IPAD13, S.sample(at(S.circle(), { sx: 80, sy: 60 }), 0, 2 * Math.PI * 1.4, { jitter: 0.5, wobble: 0.03 }));
add("Schleife, Lücke 15 %", false, IPAD13, S.sample(at(S.circle(), { sx: 80, sy: 60 }), 0, 2 * Math.PI * 0.85, { jitter: 0.5 }));
add("Kreis doppelt umrundet", false, IPAD13, S.sample((t) => { const r = 70 * (1 + 0.06 * t / (4 * Math.PI)); return { x: 300 + r * Math.cos(t), y: 300 + r * Math.sin(t) }; }, 0, 4 * Math.PI, { jitter: 0.4, secs: 1.6 }));
add("Spirale (2,5 Umdrehungen)", false, IPAD13, S.sample(at(S.spiral(2.5), { sx: 90, sy: 90 }), 0, 2 * Math.PI * 2.5, { jitter: 0.4, secs: 1.6 }));
add("Zickzack offen", false, IPAD13, S.zigzag(200, 60, 6));
add("S-Kurve offen", false, IPAD13, S.sample((t) => ({ x: 300 + 40 * t, y: 300 + 50 * Math.sin(t) }), -3, 3, { jitter: 0.4 }));
add("Lasso mit Kringel am Ende (ρ 0,15 R)", false, IPAD13, S.pigtail(80, 12));
add("Lasso mit Kringel am Ende (ρ 0,3 R)", false, IPAD13, S.pigtail(80, 24));
add("Lasso mit Kringel am Ende (ρ 0,4 R)", false, IPAD13, S.pigtail(80, 32));
add("α-Lasso, lange Schwänze", false, IPAD13, S.sample(at(S.alpha(), { sx: 60, sy: 40 }), -1.6, 1.6, { jitter: 0.4 }));
add("α-Lasso, kurze Schwänze", false, IPAD13, S.sample(at(S.alpha(), { sx: 60, sy: 40 }), -1.15, 1.15, { jitter: 0.4 }));
add("große Acht über halbe Seite (iPad 13)", false, IPAD13, inf({ w: 420 * IPAD13, jitter: 0.5, secs: 2 }));
add("große Acht über halbe Seite (iPhone)", false, PHONE, inf({ w: 400 * PHONE, jitter: 0.8, hz: 120, secs: 2 }));
add("kleine Acht als Auswahl zweier Wörter (240 Seitenpkt)", true, IPAD13, inf({ w: 240 * IPAD13, jitter: 0.4, secs: 1.6 }));
add("Acht über zwei Zeilen (stehend, 90°)", false, IPAD13, inf({ w: 160, rot: 90 }));
add("Acht steil (65°)", false, IPAD13, inf({ w: 160, rot: 65 }));
add("Gekritzel", false, IPAD13, S.scribble(80, 5));
add("Antippen", false, IPAD13, [{ x: 300, y: 300 }, { x: 301, y: 300 }, { x: 301, y: 301 }]);
add("Auswahl verschieben (gerade)", false, IPAD13, S.sample((t) => ({ x: 300 + t * 120, y: 300 + t * 40 }), 0, 1, { jitter: 0.3 }));
add("nachlässiger Kreis (σ 2,5, Wackeln 8 %)", false, MINI, S.sample(at(S.circle(), { sx: 70, sy: 55 }), 0, 2 * Math.PI * 1.05, { jitter: 2.5, wobble: 0.08, hz: 120, seed: 9 }));

const f2 = (x, d = 2) => (x === undefined || x === null ? "–" : typeof x === "number" ? x.toFixed(d) : String(x));
const rows = [];
let bad = 0;
for (const c of cases) {
  const page = c.pts.map((p) => ({ x: p.x / c.s, y: p.y / c.s }));
  const m = detect(page, c.s);
  const good = c.expect === null || m.ok === c.expect;
  const shapeOnly = detect(page, c.s, new Set(["groß"]));
  if (!good) bad++;
  rows.push([c.name, f2(c.s), m.box ? `${Math.round(m.box.w)}×${Math.round(m.box.h)}` + (m.sidePage ? ` (Ø ${Math.round(m.sidePage)})` : "") : "–", c.expect === null ? "egal" : c.expect ? "∞" : "nein",
    m.ok ? "∞" : "nein", good ? "ok" : "FALSCH", m.ok ? "" : m.reason + (!m.shape && shapeOnly.ok ? " (Form allein: ∞)" : m.shape ? " (Form: ∞)" : ""),
    f2(m.winding, 0), f2(m.turnOpen), f2(m.crossings, 0), f2(m.ratio), f2(m.round), f2(m.separation), f2(m.axis, 0), f2(m.gap)]);
}
const head = ["Weg", "s", "Größe (Seitenpkt)", "soll", "ist", "", "Grund", "W", "Drehung/2π", "Schnitte", "Flächenverh.", "rund", "Abstand", "Achse°", "Lücke"];
console.log("| " + head.join(" | ") + " |");
console.log("|" + head.map(() => "---").join("|") + "|");
for (const r of rows) console.log("| " + r.join(" | ") + " |");
console.log(`\nFalsch: ${bad} von ${cases.length}`);

module.exports = { cases };
