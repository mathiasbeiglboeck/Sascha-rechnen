// Synthetische Wege wie von Pencil oder Finger: Bildschirmpunkte, ungleichmäßig schnell, mit Zittern und Wackeln.
// Für run.js und rand.js, die detector.js prüfen (spiegelt Notizbuch/InfinityGesture.swift; Schwellen immer in beiden
// Dateien ändern).
"use strict";

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function gauss(r) { let u = 0, v = 0; while (u === 0) u = r(); while (v === 0) v = r(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); }

/// Eine Kurve f(t), t ∈ [t0, t1], als Abtastpunkte eines Stifts: `hz` Punkte je Sekunde über `secs` Sekunden, das
/// Tempo schwankt (langsamer in Kurven ist hier nicht nachgebildet, aber ungleiche Abstände sind es)
function sample(f, t0, t1, { secs = 1.0, hz = 240, seed = 1, jitter = 0, wobble = 0, size = 100, tremor = 0 } = {}) {
  const r = rng(seed);
  const n = Math.max(8, Math.round(secs * hz));
  const ph = [r() * 6.28, r() * 6.28, r() * 6.28, r() * 6.28];
  const out = [];
  for (let i = 0; i <= n; i++) {
    let u = i / n;
    u = u + 0.06 * Math.sin(2 * Math.PI * u * 3 + ph[0]) / (2 * Math.PI * 3) * 6; // Tempo schwankt
    u = Math.min(1, Math.max(0, u));
    const t = t0 + (t1 - t0) * u;
    const p = f(t);
    const w = wobble * size;
    p.x += w * (0.6 * Math.sin(2.3 * t + ph[1]) + 0.4 * Math.sin(5.1 * t + ph[2]));
    p.y += w * (0.6 * Math.sin(1.9 * t + ph[3]) + 0.4 * Math.sin(4.3 * t + ph[0]));
    if (tremor) { // Zittern der Hand: 8–11 Hz, Amplitude `tremor` Punkte
      const tt = i / hz;
      p.x += tremor * Math.sin(2 * Math.PI * (8 + 3 * ((ph[1] / 6.28))) * tt + ph[2]);
      p.y += tremor * Math.sin(2 * Math.PI * (8 + 3 * ((ph[3] / 6.28))) * tt + ph[0]);
    }
    if (jitter) { p.x += jitter * gauss(r); p.y += jitter * gauss(r); }
    out.push(p);
  }
  return out;
}

function place(f, { cx = 300, cy = 300, sx = 1, sy = 1, rot = 0 } = {}) {
  const c = Math.cos(rot * Math.PI / 180), s = Math.sin(rot * Math.PI / 180);
  return (t) => {
    const p = f(t);
    const x = p.x * sx, y = p.y * sy;
    return { x: cx + c * x - s * y, y: cy + s * x + c * y };
  };
}

// ∞ (Gerono): x = sin t, y = sin t cos t; Mitte bei t = 0, rechte Schleife t ∈ [0, π], linke [π, 2π].
// `right`: Maßstab der rechten Schleife (ungleich große Schleifen), `h`: Höhe relativ zur Breite (1 = 2:1)
const gerono = (right = 1, h = 1) => (t) => {
  const k = Math.sin(t) >= 0 ? right : 1;
  return { x: k * Math.sin(t), y: k * h * Math.sin(t) * Math.cos(t) };
};
// ∞ (Bernoulli): spitzer in der Mitte (Schleifen kreuzen sich unter 90°); Mitte bei t = π/2
const bernoulli = () => (t) => {
  const d = 1 + Math.sin(t) ** 2;
  return { x: Math.cos(t) / d, y: Math.sin(t) * Math.cos(t) / d };
};
const circle = () => (t) => ({ x: Math.cos(t), y: Math.sin(t) });
const kidney = (depth, at = Math.PI / 2, width = 0.6) => (t) => {
  let d = t - at; d = Math.atan2(Math.sin(d), Math.cos(d));
  const r = 1 - depth * Math.exp(-((d / width) ** 2));
  return { x: r * Math.cos(t), y: r * Math.sin(t) };
};
const heart = () => (t) => ({ x: (16 * Math.sin(t) ** 3) / 16, y: -(13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t)) / 16 });
const spiral = (turns) => (t) => { const r = 1 - 0.85 * t / (2 * Math.PI * turns); return { x: r * Math.cos(t), y: r * Math.sin(t) }; };
const alpha = () => (t) => ({ x: (t * t - 1) / 1.2, y: (t * t * t - t) / 1.2 });

/// Lasso (Kreis gegen den Uhrzeigersinn) mit einem kleinen Kringel im anderen Sinn am Ende („Schweinchenschwanz“)
function pigtail(R, rho, { cx = 300, cy = 300, seed = 1, jitter = 0 } = {}) {
  const pts = [];
  const r = rng(seed);
  const over = 0.35;
  for (let i = 0; i <= 260; i++) {
    const a = (2 * Math.PI + over) * i / 260;
    pts.push({ x: cx + R * Math.cos(a), y: cy + R * Math.sin(a) });
  }
  // Kringel: Mittelpunkt außen neben dem Endpunkt, im Uhrzeigersinn, 1,15 Umdrehungen
  const a = 2 * Math.PI + over, ex = cx + R * Math.cos(a), ey = cy + R * Math.sin(a);
  const tx = -Math.sin(a), ty = Math.cos(a); // Richtung am Ende (gegen den Uhrzeigersinn)
  const nx = Math.cos(a), ny = Math.sin(a);  // nach außen
  const kx = ex + nx * rho, ky = ey + ny * rho; // Mittelpunkt des Kringels
  const phi0 = Math.atan2(ey - ky, ex - kx);
  for (let i = 1; i <= 90; i++) {
    const phi = phi0 - (2 * Math.PI * 1.15) * i / 90;
    pts.push({ x: kx + rho * Math.cos(phi), y: ky + rho * Math.sin(phi) });
  }
  void tx; void ty;
  if (jitter) for (const p of pts) { p.x += jitter * gauss(r); p.y += jitter * gauss(r); }
  return pts;
}

function zigzag(w, h, n, { cx = 300, cy = 300 } = {}) {
  const pts = [];
  for (let i = 0; i <= n; i++) pts.push({ x: cx - w / 2 + w * i / n, y: cy + (i % 2 ? h / 2 : -h / 2) });
  // dicht abtasten
  const out = [];
  for (let i = 1; i < pts.length; i++) for (let j = 0; j < 30; j++) {
    const u = j / 30; out.push({ x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * u, y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * u });
  }
  out.push(pts[pts.length - 1]);
  return out;
}

/// Gekritzel: Zufallsweg (geglättet), um einen Punkt herum
function scribble(size, seed, steps = 300) {
  const r = rng(seed);
  let x = 300, y = 300, vx = 0, vy = 0;
  const out = [];
  for (let i = 0; i < steps; i++) {
    vx = 0.85 * vx + gauss(r) * size * 0.02 - (x - 300) * 0.004;
    vy = 0.85 * vy + gauss(r) * size * 0.02 - (y - 300) * 0.004;
    x += vx; y += vy; out.push({ x, y });
  }
  return out;
}

module.exports = { rng, gauss, sample, place, gerono, bernoulli, circle, kidney, heart, spiral, alpha, pigtail, zigzag, scribble };
