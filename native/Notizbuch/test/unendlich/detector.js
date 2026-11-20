// ∞-Erkennung auf dem Weg des Lassos: spiegelt Notizbuch/InfinityGesture.swift der App Schritt für Schritt.
// Jede Schwelle (T hier, dort die private static let) und jede Zahl in der Logik in beiden Dateien gleich ändern;
// danach node schwellen.js (vergleicht die Schwellen), node run.js und node rand.js.
// Eingabe: Punkte in Seitenpunkten (wie LassoTracker sie liefert) und s = Bildschirmpunkte je Seitenpunkt (k · Zoom).
// Alle Schwellen gelten in Bildschirmpunkten (gleich in jeder Zoomstufe), außer maxPage (Seitenpunkte).
"use strict";

const T = {
  minPoints: 24,        // nach dem Neuabtasten
  minSide: 24,          // Durchmesser ≥ 24 Bildschirmpunkte (≈ 4–5 mm)
  maxSide: 640,         // Durchmesser ≤ 640 Bildschirmpunkte (≈ 11–12 cm), nur Plausibilität
  maxPage: 260,         // Durchmesser ≤ 260 Seitenpunkte (≈ 7 cm auf A4, ein Drittel der Seitenbreite)
  minLength: 2.0,       // Weglänge ≥ 2 × lange Seite (ein ∞ hat 2,5–3,2; Strich, Antippen ≈ 1)
  maxLength: 12,        // Weglänge ≤ 12 × lange Seite (Gekritzel, viele Runden)
  closeWindow: 0.12,    // Überhang am Ende: erste/letzte 12 % der Weglänge
  maxGap: 0.4,          // Lücke zwischen Anfang und Ende ≤ 40 % des Durchmessers
  maxOpenTurn: 0.4,     // |Drehung des gezeichneten Wegs| ≤ 0,4 Umdrehungen (∞ ≤ 0,32 in 99,5 %, α-Lasso ≥ 0,53, Schleife ≈ 1)
  maxStepTurn: 0.9,     // keine Kehrtwende (|Δθ| > 0,9 π) im geglätteten Weg, auch nicht an der Schließkante
  minRatio: 0.2,        // kleinere Schleife ≥ 20 % der Fläche der größeren
  minRound: 0.35,       // jede Schleife: 4πA/U² ≥ 0,35 (Kreis 1, Ellipse 6:1 ≈ 0,38; Sicheln, Gekritzel darunter)
  minLoopArea: 40,      // jede Schleife ≥ 40 Bildschirmpunkte² …
  minLoopShare: 0.02,   // … und ≥ 2 % von Durchmesser²
  minSeparation: 0.6,   // Abstand der Schwerpunkte ≥ 0,6 (r1 + r2): nebeneinander, nicht ineinander
  maxAxis: 50,          // Achse der beiden Schleifen höchstens 50° gegen die Waagrechte („liegende“ Acht)
};

const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const wrap = (a) => { while (a > Math.PI) a -= 2 * Math.PI; while (a <= -Math.PI) a += 2 * Math.PI; return a; };

function pathLength(p) { let L = 0; for (let i = 1; i < p.length; i++) L += dist(p[i - 1], p[i]); return L; }

function bounds(p) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const q of p) { x0 = Math.min(x0, q.x); x1 = Math.max(x1, q.x); y0 = Math.min(y0, q.y); y1 = Math.max(y1, q.y); }
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/// Über je 5 Abtastpunkte mitteln (1-4-6-4-1): Rauschen von Punkt zu Punkt (Finger) fällt weg, bevor Längen zählen
function binomial5(p) {
  const g = [1, 4, 6, 4, 1];
  return p.map((_, i) => {
    let sx = 0, sy = 0, sw = 0;
    for (let k = -2; k <= 2; k++) {
      const j = i + k;
      if (j < 0 || j >= p.length) continue;
      sx += g[k + 2] * p[j].x; sy += g[k + 2] * p[j].y; sw += g[k + 2];
    }
    return { x: sx / sw, y: sy / sw };
  });
}

/// Gleichmäßig neu abtasten (Abstand `step` entlang des Wegs)
function resample(p, step) {
  const out = [p[0]];
  let carry = 0;
  for (let i = 1; i < p.length; i++) {
    const a = p[i - 1], b = p[i], seg = dist(a, b);
    if (seg === 0) continue;
    let t = step - carry;
    while (t <= seg) {
      out.push({ x: a.x + (b.x - a.x) * t / seg, y: a.y + (b.y - a.y) * t / seg });
      t += step;
    }
    carry = seg - (t - step);
  }
  const last = p[p.length - 1];
  if (dist(out[out.length - 1], last) > step * 0.3) out.push(last);
  return out;
}

/// Gauß-Glättung entlang des Wegs (Punkte im Abstand 1, `sigma` in Punkten); an den Enden wird das Fenster kürzer
function smooth(p, sigma) {
  const rad = Math.ceil(2.5 * sigma);
  const w = [];
  for (let k = -rad; k <= rad; k++) w.push(Math.exp(-(k * k) / (2 * sigma * sigma)));
  const out = [];
  for (let i = 0; i < p.length; i++) {
    let sx = 0, sy = 0, sw = 0;
    for (let k = Math.max(-rad, -i); k <= Math.min(rad, p.length - 1 - i); k++) {
      const g = w[k + rad];
      sx += g * p[i + k].x; sy += g * p[i + k].y; sw += g;
    }
    out.push({ x: sx / sw, y: sy / sw });
  }
  return out;
}

function signedArea(p) {
  let s = 0;
  for (let i = 0; i < p.length; i++) { const a = p[i], b = p[(i + 1) % p.length]; s += a.x * b.y - b.x * a.y; }
  return s / 2;
}

function perimeter(p) { let L = 0; for (let i = 0; i < p.length; i++) L += dist(p[i], p[(i + 1) % p.length]); return L; }

function centroid(p, area) {
  if (Math.abs(area) < 1e-9) { const b = bounds(p); return { x: b.x + b.w / 2, y: b.y + b.h / 2 }; }
  let cx = 0, cy = 0;
  for (let i = 0; i < p.length; i++) {
    const a = p[i], b = p[(i + 1) % p.length], c = a.x * b.y - b.x * a.y;
    cx += (a.x + b.x) * c; cy += (a.y + b.y) * c;
  }
  return { x: cx / (6 * area), y: cy / (6 * area) };
}

/// Schnittpunkt der Strecken a→b und c→d (je halboffen [0, 1)), sonst null
function intersect(a, b, c, d) {
  const rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y;
  const den = rx * sy - ry * sx;
  if (Math.abs(den) < 1e-12) return null;
  const qx = c.x - a.x, qy = c.y - a.y;
  const t = (qx * sy - qy * sx) / den, u = (qx * ry - qy * rx) / den;
  if (t < 0 || t >= 1 || u < 0 || u >= 1) return null;
  return { x: a.x + t * rx, y: a.y + t * ry };
}

/// Erkennt ein ∞. `page`: Punkte in Seitenpunkten; `s`: Bildschirmpunkte je Seitenpunkt. `skip`: Regeln, die für einen
/// Versuch wegfallen (Ablation). Gibt immer die Messwerte zurück; `ok` sagt, ob es ein ∞ ist, `reason` warum nicht.
function detect(page, s, skip = new Set()) {
  const m = { ok: false, reason: "" };
  const fail = (r) => { m.reason = r; return m; };
  const no = (k) => !skip.has(k);
  if (page.length < 3 || !(s > 0)) return fail("zu kurz");
  const raw = binomial5(page.map((q) => ({ x: q.x * s, y: q.y * s })));
  const rb = bounds(raw), rawSide = Math.max(rb.w, rb.h), L = pathLength(raw);
  // Billige Ausschlüsse zuerst (die lange Seite ist höchstens der Durchmesser; Glätten verkleinert kaum)
  if (rawSide < T.minSide) return fail("zu klein");
  if (no("groß") && (rawSide / s > T.maxPage * 1.1 || rawSide > T.maxSide * 1.1)) return fail("zu groß (früh)");
  if (L < T.minLength * rawSide) return fail("zu kurz");
  if (L > T.maxLength * rawSide) return fail("zu lang");
  // Fein abtasten (1 Punkt), glätten (σ wächst mit der Größe), grob abtasten (etwa 40 Punkte je lange Seite)
  const step = Math.max(2.5, rawSide / 40);
  const pts = resample(smooth(resample(raw, 1), Math.max(1.5, rawSide / 60)), step);
  if (pts.length < T.minPoints) return fail("zu kurz");

  // Ende schließen: Überhang abschneiden (nächstes Paar aus den ersten und letzten 12 % der Weglänge)
  const arc = [0];
  for (let i = 1; i < pts.length; i++) arc.push(arc[i - 1] + dist(pts[i - 1], pts[i]));
  const total = arc[arc.length - 1];
  let bi = 0, bj = pts.length - 1, best = dist(pts[0], pts[pts.length - 1]);
  for (let i = 0; i < pts.length && arc[i] <= T.closeWindow * total; i++) {
    for (let j = pts.length - 1; j > i + 2 && arc[j] >= (1 - T.closeWindow) * total; j--) {
      const d = dist(pts[i], pts[j]);
      if (d < best) { best = d; bi = i; bj = j; }
    }
  }
  const poly = pts.slice(bi, bj + 1);
  if (poly.length > 3 && dist(poly[0], poly[poly.length - 1]) < step * 0.5) poly.pop();
  const n = poly.length;
  if (n < T.minPoints) return fail("zu kurz");
  const box = bounds(poly);
  m.box = { x: box.x / s, y: box.y / s, w: box.w / s, h: box.h / s }; // Umriss in Seitenpunkten (die „Stelle“)

  // Drehung zuerst (billig, schließt fast jedes Lasso aus): Umlaufzahl des geschlossenen Vielecks (ganzzahlig),
  // Drehung des gezeichneten Wegs, Kehrtwenden
  const dirs = [];
  for (let i = 0; i < n; i++) { const a = poly[i], b = poly[(i + 1) % n]; dirs.push(Math.atan2(b.y - a.y, b.x - a.x)); }
  let open = 0, closed = 0, maxStep = 0, absTurn = 0;
  for (let i = 0; i < n; i++) {
    const d = wrap(dirs[(i + 1) % n] - dirs[i]);
    closed += d;
    absTurn += Math.abs(d);
    maxStep = Math.max(maxStep, Math.abs(d));
    if (i < n - 2) open += d; // ohne die beiden Knicke an der Schließkante (Kante n−1)
  }
  m.winding = Math.round(closed / (2 * Math.PI));
  m.turnOpen = open / (2 * Math.PI);
  m.maxStep = maxStep / Math.PI;
  m.absTurn = absTurn / (2 * Math.PI);
  if (no("umlauf") && m.winding !== 0) return fail(`Umlauf ${m.winding > 0 ? "+" : ""}${m.winding}`);
  if (no("dreht") && Math.abs(m.turnOpen) > T.maxOpenTurn) return fail("dreht");
  if (no("kehrt") && m.maxStep > T.maxStepTurn) return fail("Kehrtwende");

  // Größe: Durchmesser (größter Abstand zweier Punkte), gleich in jeder Neigung
  let side = 0;
  for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) side = Math.max(side, dist(poly[i], poly[j]));
  m.sideScreen = side; m.sidePage = side / s;
  m.gap = best / side;
  if (side < T.minSide) return fail("zu klein");
  if (no("offen") && m.gap > T.maxGap) return fail("offen");

  // Selbstschnitte; Teilung in zwei Schleifen an dem Schnitt, der die kleinere Schleife am größten macht
  let crossings = 0, split = null;
  for (let a = 0; a < n; a++) {
    for (let b = a + 2; b < n; b++) {
      if (a === 0 && b === n - 1) continue;
      const x = intersect(poly[a], poly[(a + 1) % n], poly[b], poly[(b + 1) % n]);
      if (!x) continue;
      crossings++;
      const l1 = [x, ...poly.slice(a + 1, b + 1)];
      const l2 = [x, ...poly.slice(b + 1), ...poly.slice(0, a + 1)];
      const A1 = signedArea(l1), A2 = signedArea(l2);
      const small = Math.min(Math.abs(A1), Math.abs(A2));
      if (!split || small > split.small) split = { l1, l2, A1, A2, small };
    }
  }
  m.crossings = crossings;
  if (!split) return fail("kein Schnitt");
  const { l1, l2, A1, A2 } = split;
  m.opposite = A1 * A2 < 0;
  m.ratio = split.small / Math.max(Math.abs(A1), Math.abs(A2));
  const P1 = perimeter(l1), P2 = perimeter(l2);
  m.round = Math.min(4 * Math.PI * Math.abs(A1) / (P1 * P1), 4 * Math.PI * Math.abs(A2) / (P2 * P2));
  m.loopArea = split.small;
  const c1 = centroid(l1, A1), c2 = centroid(l2, A2);
  m.separation = dist(c1, c2) / (Math.sqrt(Math.abs(A1) / Math.PI) + Math.sqrt(Math.abs(A2) / Math.PI));
  const ang = Math.abs(Math.atan2(c2.y - c1.y, c2.x - c1.x)) * 180 / Math.PI;
  m.axis = Math.min(ang, 180 - ang);
  if (no("sinn") && !m.opposite) return fail("gleichsinnig");
  if (no("ungleich") && m.ratio < T.minRatio) return fail("ungleich");
  if (no("sichel") && m.round < T.minRound) return fail("Sichel");
  if (no("klein") && m.loopArea < Math.max(T.minLoopArea, T.minLoopShare * side * side)) return fail("Schleife klein");
  if (no("ineinander") && m.separation < T.minSeparation) return fail("ineinander");
  if (no("steht") && m.axis > T.maxAxis) return fail("steht");
  // Die Form ist ein ∞; jetzt nur noch die Größe
  m.shape = true;
  if (no("groß") && m.sidePage > T.maxPage) return fail("zu groß (Seite)");
  if (no("groß") && side > T.maxSide) return fail("zu groß (Schirm)");
  m.ok = true;
  return m;
}

module.exports = { detect, T, resample, smooth, binomial5, signedArea, intersect, bounds };
