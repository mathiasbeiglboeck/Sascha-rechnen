// Zufallsreihen: ∞ realistisch und unter Stress; Lasso-Wege; Ablation (welche Regel hält welche Fehlauslösung ab).
// Prüft detector.js, das Notizbuch/InfinityGesture.swift spiegelt (Schwellen immer in beiden Dateien ändern).
// Aufruf: node rand.js (gut eine Minute). Erwartet: ∞ realistisch mindestens 98 %, Fehlauslösungen auf den 15 000
// Lasso-Wegen höchstens 1.
"use strict";
const { detect, T } = require("./detector.js");
const S = require("./shapes.js");
const IPAD13 = 1.34, MINI = 1.0, PHONE = 0.51;
const inf = (o) => {
  const f = o.curve === "b" ? S.bernoulli() : S.gerono(o.right, o.h);
  const sx = o.curve === "b" ? o.w / 2 : o.w / (1 + o.right);
  return S.sample(S.place(f, { sx, sy: sx, rot: o.rot }), o.t0, o.t1, o);
};
function infinities(n, seed, stress) {
  const r = S.rng(seed), U = (a, b) => a + (b - a) * r(), pick = (a) => a[Math.floor(r() * a.length)];
  const out = [];
  for (let i = 0; i < n; i++) {
    const s = pick([PHONE, MINI, IPAD13, 2 * IPAD13]);
    const finger = s === PHONE;
    const curve = r() < 0.75 ? "g" : "b";
    const w = U(40, Math.min(250 * s, 560));
    const start = pick(["mitte", "links", "rechts", "zufall"]);
    const base = curve === "b" ? Math.PI / 2 : 0;
    const t0 = base + (start === "mitte" ? 0 : start === "links" ? 1.5 * Math.PI : start === "rechts" ? 0.5 * Math.PI : U(0, 2 * Math.PI));
    const dir = r() < 0.5 ? 1 : -1;
    const t1 = t0 + dir * (2 * Math.PI + U(-0.45, 0.5));
    const o = { curve, w, h: U(0.6, 1.5), right: curve === "g" ? Math.exp(U(Math.log(0.6), Math.log(1.7))) : 1, rot: U(-40, 40), t0, t1,
      jitter: stress ? U(0, finger ? 2.2 : 1.0) : U(0, finger ? 0.8 : 0.3), tremor: U(0, stress ? 3 : 1.5), wobble: U(0, 0.06),
      seed: seed * 7 + i, hz: finger ? 120 : 240, secs: U(0.6, 1.8), size: w };
    out.push({ s, pts: inf(o), o });
  }
  return out;
}
function lassos(n, seed) {
  const r = S.rng(seed), U = (a, b) => a + (b - a) * r(), pick = (a) => a[Math.floor(r() * a.length)];
  const out = [];
  for (let i = 0; i < n; i++) {
    const s = pick([PHONE, MINI, IPAD13, 2 * IPAD13]);
    const finger = s === PHONE;
    const kind = pick(["kreis", "ellipse", "niere", "herz", "überlappt", "lücke", "doppelt", "spirale", "kringel", "alpha", "gekritzel", "zickzack", "stern", "acht-steil", "acht-groß"]);
    const size = U(30, 600);
    const o = { sx: size / 2, sy: size / 2 * U(0.35, 1), rot: U(-90, 90) };
    const jit = { jitter: U(0, finger ? 2.2 : 1.0), tremor: U(0, 3), wobble: U(0, 0.1), seed: seed * 13 + i, hz: finger ? 120 : 240, secs: U(0.5, 2), size };
    const dir = r() < 0.5 ? 1 : -1, a0 = U(0, 2 * Math.PI);
    let pts;
    switch (kind) {
      case "kreis": pts = S.sample(S.place(S.circle(), { sx: size / 2, sy: size / 2 }), a0, a0 + dir * 2 * Math.PI * U(0.9, 1.1), jit); break;
      case "ellipse": pts = S.sample(S.place(S.circle(), o), a0, a0 + dir * 2 * Math.PI * U(0.9, 1.1), jit); break;
      case "niere": pts = S.sample(S.place(S.kidney(U(0.2, 0.75), U(0, 6.28), U(0.3, 0.9)), o), a0, a0 + dir * 2 * Math.PI * U(0.92, 1.1), jit); break;
      case "herz": pts = S.sample(S.place(S.heart(), o), a0, a0 + dir * 2 * Math.PI * U(0.95, 1.08), jit); break;
      case "überlappt": pts = S.sample(S.place(S.circle(), o), a0, a0 + dir * 2 * Math.PI * U(1.1, 1.5), jit); break;
      case "lücke": pts = S.sample(S.place(S.circle(), o), a0, a0 + dir * 2 * Math.PI * U(0.6, 0.9), jit); break;
      case "doppelt": { const grow = U(-0.12, 0.12); pts = S.sample(S.place((t) => { const k = 1 + grow * (t - a0) / (4 * Math.PI); return { x: k * Math.cos(t), y: k * Math.sin(t) }; }, o), a0, a0 + dir * 2 * Math.PI * U(1.8, 2.3), jit); break; }
      case "spirale": { const tr = U(1.5, 3); pts = S.sample(S.place(S.spiral(tr), o), 0, 2 * Math.PI * tr, jit); break; }
      case "kringel": pts = S.pigtail(size / 2, size / 2 * U(0.05, 0.4), { seed: seed * 13 + i, jitter: jit.jitter }); break;
      case "alpha": pts = S.sample(S.place(S.alpha(), o), -U(1.05, 1.8), U(1.05, 1.8), jit); break;
      case "gekritzel": pts = S.scribble(size, seed * 13 + i, Math.round(U(100, 500))); break;
      case "zickzack": pts = S.zigzag(size, size * U(0.2, 0.8), Math.round(U(3, 9))); break;
      case "stern": pts = S.sample((t) => { const k = 1 + 0.25 * Math.cos(5 * t); return S.place((u) => ({ x: k * Math.cos(u), y: k * Math.sin(u) }), o)(t); }, a0, a0 + dir * 2 * Math.PI * U(0.95, 1.08), jit); break;
      // Achten, die keine ∞ sein sollen: steil (55–90°) oder groß (über 270 Seitenpunkte)
      case "acht-steil": pts = inf({ curve: "g", w: Math.min(size, 250 * s), h: U(0.6, 1.5), right: U(0.7, 1.4), rot: (r() < 0.5 ? 1 : -1) * U(55, 90), t0: 0, t1: 2 * Math.PI, ...jit }); break;
      case "acht-groß": pts = inf({ curve: "g", w: U(275, 700) * s, h: U(0.6, 1.5), right: U(0.7, 1.4), rot: U(-40, 40), t0: 0, t1: 2 * Math.PI, ...jit, secs: 2 }); break;
    }
    out.push({ s, kind, pts });
  }
  return out;
}
const run = (set, skip) => set.map((c) => detect(c.pts.map((p) => ({ x: p.x / c.s, y: p.y / c.s })), c.s, skip));
const tally = (res) => { const t = {}; for (const m of res) if (!m.ok) t[m.reason] = (t[m.reason] || 0) + 1; return t; };
module.exports = { infinities, lassos, run, tally };

if (require.main === module) {
  const real = infinities(3000, 11, false), stress = infinities(3000, 12, true), neg = lassos(15000, 13);
  const rr = run(real), rs = run(stress), rn = run(neg);
  const pct = (a, n) => (100 * a / n).toFixed(1) + " %";
  console.log(`∞ realistisch (Pencil σ ≤ 0,3, Finger σ ≤ 0,8, Zittern ≤ 1,5 Pkt): ${rr.filter((m) => m.ok).length}/${rr.length} = ${pct(rr.filter((m) => m.ok).length, rr.length)}`, JSON.stringify(tally(rr)));
  console.log(`∞ Stress (Finger σ ≤ 2,2, Zittern ≤ 3 Pkt): ${rs.filter((m) => m.ok).length}/${rs.length} = ${pct(rs.filter((m) => m.ok).length, rs.length)}`, JSON.stringify(tally(rs)));
  const fp = rn.map((m, i) => (m.ok ? neg[i].kind : null)).filter(Boolean);
  console.log(`Lasso-Wege ${rn.length}: Fehlauslösungen ${fp.length}`, JSON.stringify(fp.reduce((t, k) => ((t[k] = (t[k] || 0) + 1), t), {})));
  // Ablation: je eine Regel weglassen
  for (const k of ["offen", "umlauf", "dreht", "kehrt", "sinn", "ungleich", "sichel", "klein", "ineinander", "steht"]) {
    const res = run(neg, new Set([k]));
    const kinds = res.map((m, i) => (m.ok ? neg[i].kind : null)).filter(Boolean);
    const hits = run(real, new Set([k])).filter((m) => m.ok).length;
    console.log(`ohne „${k}“: Fehlauslösungen ${kinds.length} ${JSON.stringify(kinds.reduce((t, x) => ((t[x] = (t[x] || 0) + 1), t), {}))}; ∞ erkannt ${pct(hits, real.length)}`);
  }
}
