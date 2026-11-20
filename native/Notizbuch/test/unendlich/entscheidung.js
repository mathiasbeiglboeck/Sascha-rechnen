// Entscheidung nach einem ∞ mit dem Lasso: spiegelt lassoBegan, lassoEnded, infinityDrawn, infinitySettled,
// strokesMoved und strokePrints aus Notizbuch/CanvasController.swift und prüft sie mit simulierter Zeit an Abläufen:
// Antippen der Auswahl, ein neuer Weg, zwei ∞ hintereinander, Tab-Wechsel, eine verschobene Auswahl, fremde Änderungen,
// Drehen. PencilKit ist dabei nur nachgebildet (Annahmen bei `touch` und `remote`); das ersetzt keinen Test am Gerät.
// Teil 1 vergleicht die gespiegelten Zeilen mit dem Swift-Code: Ändert sich dort etwas, hier nachziehen. Jeder Ablauf
// läuft auch mit der Fassung vor den Korrekturen („vorher“, Commit 9f28905); sie muss an den genannten Stellen scheitern.
// Aufruf: node entscheidung.js; erwartet am Ende „Entscheidung: … alle gut“.
"use strict";
const fs = require("fs");
const path = require("path");

let bad = 0;
const fail = (text) => { bad++; console.log("FALSCH: " + text); };

// ---- Teil 1: Stimmt der Spiegel noch mit dem Swift-Code überein?
const app = path.join(__dirname, "..", "..", "Notizbuch");
const swift = fs.readFileSync(path.join(app, "CanvasController.swift"), "utf8");
const gestures = fs.readFileSync(path.join(app, "Gestures.swift"), "utf8");
const flat = (s) => s.replace(/\s+/g, " ");
const between = (text, from, to) => {
  const a = text.indexOf(from), b = text.indexOf(to, a + from.length);
  if (a < 0 || b < 0) throw new Error(`Stelle nicht gefunden: ${from} … ${to}`);
  return text.slice(a, b);
};
const count = (text, snippet) => flat(text).split(flat(snippet)).length - 1;
function lines(where, text, snippets, times = 1) {
  for (const s of snippets) {
    const n = count(text, s);
    if (n !== times) fail(`${where}: „${s}“ ${n}-mal statt ${times}-mal im Swift-Code`);
  }
}
function order(where, text, snippets) {
  const f = flat(text);
  let last = -1;
  for (const s of snippets) {
    const i = f.indexOf(flat(s), last + 1);
    if (i < 0) return fail(`${where}: „${s}“ fehlt oder steht an anderer Stelle`);
    last = i;
  }
}
const began = between(swift, "private func lassoBegan(", "private func lassoEnded(");
const ended = between(swift, "private func lassoEnded(", "private func inkPrint(");
const drawn = between(swift, "private func infinityDrawn(", "private func infinitySettled(");
const settled = between(swift, "private func infinitySettled(", "private static func strokesMoved(");
const moved = between(swift, "private static func strokesMoved(", "private struct StrokePrint");
const prints = between(swift, "private struct StrokePrint", "private func askMeaning(");
order("lassoBegan", began, ["let start = (drawing: canvas.drawing, k: k)", "lassoStart = start",
  "for path in infinitiesWaiting where infinityNext[path] == nil { infinityNext[path] = start }"]);
order("lassoEnded", ended, ["lastLassoEnd = Date()", "guard points.count >= 8 else { return }", "lassoPaths += 1",
  "if let match = InfinityGesture.detect(raw, scale: s) {", "lastInfinity = lassoPaths", "infinitiesWaiting.insert(lassoPaths)",
  "return", "canvas.menuBlockedUntil = .distantPast"]);
lines("infinityDrawn", drawn, ["canvas.menuBlockedUntil = Date().addingTimeInterval(3)",
  "DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.infinitySettled(pending) }"]);
order("infinitySettled", settled, [
  "let late = Date().timeIntervalSince(pending.ended) >= 2",
  "let newPath = lassoPaths != pending.path || (late && lassoTracker.isTracking)",
  "if !newPath, !late, lassoTracker.isTracking || toolBusy || Date().timeIntervalSince(lastLassoEnd) < 0.5 {",
  "DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.infinitySettled(pending) }", "return",
  "infinitiesWaiting.remove(pending.path)",
  "let after = infinityNext.removeValue(forKey: pending.path) ?? (drawing: canvas.drawing, k: k)",
  "let newest = pending.path == lastInfinity",
  "if Self.strokesMoved(before: pending.before, kBefore: pending.k, now: after.drawing, k: after.k) {",
  "if newest { canvas.menuBlockedUntil = .distantPast }",
  "canvas.undoManager?.canUndo == true ? \"Rückgängig\" : \"zurückschieben\"",
  "onFlashTimed(\"∞ hat die Auswahl verschoben – \\(back), dann die Auswahl aufheben\", 3)", "return",
  "if newPath {", "if newest { canvas.menuBlockedUntil = .distantPast }", "} else {",
  "canvas.menuBlockedUntil = Date().addingTimeInterval(0.3)", "endLassoSelection()", "askMeaning(match)"]);
lines("strokesMoved", moved, ["let old = strokePrints(before, k: kBefore), new = strokePrints(now, k: k)",
  "for (p, n) in old where (new[p] ?? 0) < n { gone.insert(p.shape) }", "guard !gone.isEmpty else { return false }",
  "return new.contains { p, n in (old[p] ?? 0) < n && gone.contains(p.shape) }"]);
lines("strokePrints", prints, ["var shape: [CGFloat] { [w, h, CGFloat(points)] }",
  "func q(_ v: CGFloat) -> CGFloat { (v / k * 4).rounded() }", "for stroke in drawing.strokes {",
  "StrokePrint(x: q(b.minX), y: q(b.minY), w: q(b.width), h: q(b.height), points: stroke.path.count)"]);
lines("toolBusy", swift, ["private var toolBusy: Bool { usingTool || Date().timeIntervalSince(lastToolEnd) < 0.5 }"]);
lines("LassoTracker", gestures, ["var isTracking: Bool { tracked != nil }"]);
lines("ohne weak", swift, ["[weak self] in self?.infinitySettled"], 0);
const mirrorBad = bad;
console.log(mirrorBad ? `Spiegel: ${mirrorBad} Unterschiede zum Swift-Code` : "Spiegel: gleich wie im Swift-Code");

// ---- Teil 2: Modell. Striche: x, y, w, h (renderBounds, Leinwandpunkte) und n Punkte
const K = 1.34; // iPad 13 bei Zoom 1: Leinwandpunkte je Seitenpunkt

/// strokePrints: je Strich Lage und Größe in ¼ Seitenpunkten (.rounded(): ab ,5 von 0 weg) und Zahl der Punkte
const q = (v, k) => { const x = v / k * 4; return Math.sign(x) * Math.round(Math.abs(x)) + 0; };
function strokePrints(drawing, k) {
  const m = new Map();
  if (!(k > 0)) return m;
  for (const s of drawing) {
    const key = [q(s.x, k), q(s.y, k), q(s.w, k), q(s.h, k), s.n].join(",");
    m.set(key, (m.get(key) || 0) + 1);
  }
  return m;
}
const shapeOf = (key) => key.split(",").slice(2).join(",");
/// strokesMoved: ein Strich fehlt, und ein gleich großer mit gleich vielen Punkten kam anderswo dazu
function strokesMoved(before, kBefore, now, k) {
  const old = strokePrints(before, kBefore), neu = strokePrints(now, k);
  const gone = new Set();
  for (const [p, n] of old) if ((neu.get(p) || 0) < n) gone.add(shapeOf(p));
  if (!gone.size) return false;
  for (const [p, n] of neu) if ((old.get(p) || 0) < n && gone.has(shapeOf(p))) return true;
  return false;
}
/// Vorher: nur Striche, die den Umriss des ∞ samt Rand max(20, Seite/2) berühren; jeder fehlende Abdruck zählt
function movedNear(match, before, kBefore, now, k) {
  const side = Math.max(match.w, match.h), pad = Math.max(20, side / 2);
  const near = { x: match.x - pad, y: match.y - pad, w: match.w + 2 * pad, h: match.h + 2 * pad };
  const printsNear = (drawing, k) => {
    const m = new Map();
    for (const s of drawing) {
      const r = { x: s.x / k, y: s.y / k, w: s.w / k, h: s.h / k };
      if (r.x > near.x + near.w || r.x + r.w < near.x || r.y > near.y + near.h || r.y + r.h < near.y) continue;
      const key = [q(s.x, k), q(s.y, k), q(s.x + s.w, k), q(s.y + s.h, k), s.n].join(",");
      m.set(key, (m.get(key) || 0) + 1);
    }
    return m;
  };
  const was = printsNear(before, kBefore), is = printsNear(now, k);
  for (const [p, n] of was) if ((is.get(p) || 0) < n) return true;
  return false;
}

const clone = (d) => d.map((s) => ({ ...s }));
const inside = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
const strokeIn = (r, s, k) => s.x / k >= r.x && (s.x + s.w) / k <= r.x + r.w && s.y / k >= r.y && (s.y + s.h) / k <= r.y + r.h;
const touches = (r, s, k) => !(s.x / k > r.x + r.w || (s.x + s.w) / k < r.x || s.y / k > r.y + r.h || (s.y + s.h) / k < r.y);

function makeState(version, setup) {
  return {
    version, now: 0, queue: [], seq: 0, k: K, drawing: clone(setup.drawing || []), pdf: !!setup.pdf,
    sel: setup.sel ? { name: setup.sel.name, ids: new Set(setup.sel.ids), region: { ...setup.sel.region } } : null,
    canUndo: !!setup.canUndo, lassoPaths: 0, lastInfinity: 0, lastLassoEnd: -Infinity, tracking: false,
    lassoStart: null, usingTool: false, lastToolEnd: -Infinity, menuBlockedUntil: -Infinity, left: false,
    waiting: new Set(), next: new Map(),
    questions: [], hints: [], menus: [], decisions: [],
  };
}
const at = (st, t, f) => st.queue.push({ t, seq: st.seq++, f });
function runAll(st) {
  while (st.queue.length) {
    st.queue.sort((a, b) => a.t - b.t || a.seq - b.seq);
    const e = st.queue.shift();
    st.now = e.t;
    e.f();
  }
}
const toolBusy = (st) => st.usingTool || st.now - st.lastToolEnd < 0.5;
/// DispatchQueue.main.asyncAfter: vorher mit [weak self] (nach dem Verlassen des Tabs ist die Leinwand weg), jetzt ohne
const later = (st, dt, f) => at(st, st.now + dt, () => { if (!(st.version === "vorher" && st.left)) f(); });

/// Eine Berührung mit dem Lasso von t0 bis t1 (Seitenpunkte): Antippen („tap“, unter 8 Punkten: kein Weg), ein Weg
/// („path“) oder ein ∞ („inf“, Umriss `match`). `region`: was ein neuer Weg umschließt. Annahmen über PencilKit (wie in
/// Notizen): Beginnt ein Weg in der Auswahl, zieht er sie um Ende − Anfang mit, sie bleibt ausgewählt, Rückgängig kennt
/// das; sonst wählt er aus, was er umschließt. Antippen der Auswahl fragt nach dem Menü, daneben hebt es sie auf; ein
/// „Ruck“ ist für die App ein Antippen (unter 8 Punkten), zieht aber eine Auswahl ein Stück mit. Das Werkzeug meldet
/// PencilKit vom Aufsetzen bis kurz nach dem Abheben (nicht beim Antippen)
function touch(st, t0, t1, o) {
  let drag = false;
  at(st, t0, () => {
    st.tracking = true;                                           // LassoTracker.touchesBegan → lassoBegan
    const start = { drawing: clone(st.drawing), k: st.k };
    st.lassoStart = start;
    if (st.version === "neu") for (const p of st.waiting) if (!st.next.has(p)) st.next.set(p, start);
    drag = o.kind !== "tap" && !!st.sel && inside(st.sel.region, o.from);
    if (o.kind !== "tap") st.usingTool = true;                    // canvasViewDidBeginUsingTool
  });
  at(st, t1, () => {
    st.tracking = false;                                          // LassoTracker.touchesEnded → lassoEnded
    lassoEnded(st, o);
  });
  at(st, t1 + 0.01, () => {
    if (o.kind === "tap" || (o.kind === "nudge" && !drag)) {
      if (st.sel && inside(st.sel.region, o.from)) {
        st.menus.push({ t: st.now, sel: st.sel.name, shown: st.now >= st.menuBlockedUntil });
      } else st.sel = null;
    } else if (drag && st.sel) {
      const dx = o.to.x - o.from.x, dy = o.to.y - o.from.y;
      for (const s of st.drawing) if (st.sel.ids.has(s.id)) { s.x += dx * st.k; s.y += dy * st.k; }
      st.sel.region = { ...st.sel.region, x: st.sel.region.x + dx, y: st.sel.region.y + dy };
      st.canUndo = true;
    } else {
      const ids = st.drawing.filter((s) => strokeIn(o.region, s, st.k)).map((s) => s.id);
      st.sel = ids.length ? { name: o.name, ids: new Set(ids), region: { ...o.region } } : null;
    }
  });
  if (o.kind !== "tap") at(st, t1 + 0.02, () => { st.usingTool = false; st.lastToolEnd = st.now; });
}

function lassoEnded(st, o) {
  st.lastLassoEnd = st.now;
  const start = st.lassoStart;
  st.lassoStart = null;
  if (o.kind === "tap" || o.kind === "nudge") return;
  st.lassoPaths += 1;
  if (o.kind === "inf") {
    if (st.version === "neu") { st.lastInfinity = st.lassoPaths; st.waiting.add(st.lassoPaths); }
    const before = start || { drawing: clone(st.drawing), k: st.k };
    const pending = { name: o.name, match: o.match, before: before.drawing, k: before.k, path: st.lassoPaths, ended: st.now };
    st.menuBlockedUntil = st.now + 3;                             // infinityDrawn
    later(st, 0.5, () => settle(st, pending));
    return;
  }
  st.menuBlockedUntil = -Infinity;
}

function settle(st, p) {
  let newPath, wait;
  if (st.version === "neu") {
    const late = st.now - p.ended >= 2;
    newPath = st.lassoPaths !== p.path || (late && st.tracking);
    wait = !newPath && !late && (st.tracking || toolBusy(st) || st.now - st.lastLassoEnd < 0.5);
  } else {
    newPath = st.lassoPaths !== p.path || st.tracking;
    wait = !newPath && (toolBusy(st) || st.now - st.lastLassoEnd < 0.5) && st.now - p.ended < 2;
  }
  if (wait) return later(st, 0.1, () => settle(st, p));
  const newest = st.version === "vorher" || p.path === st.lastInfinity;
  st.decisions.push({ t: st.now, name: p.name, newPath });
  let isMoved;
  if (st.version === "neu") {
    st.waiting.delete(p.path);
    const after = st.next.get(p.path) || { drawing: st.drawing, k: st.k };
    st.next.delete(p.path);
    isMoved = strokesMoved(p.before, p.k, after.drawing, after.k);
  } else isMoved = movedNear(p.match, p.before, p.k, st.drawing, st.k);
  if (isMoved) {
    if (newest) st.menuBlockedUntil = -Infinity;
    const text = st.version === "neu" ? `${st.canUndo ? "Rückgängig" : "zurückschieben"}, dann die Auswahl aufheben` : "erst die Auswahl aufheben";
    st.hints.push({ t: st.now, name: p.name, text: "∞ hat die Auswahl verschoben – " + text });
    return;
  }
  if (newPath) { if (newest) st.menuBlockedUntil = -Infinity; }
  else { st.menuBlockedUntil = st.now + 0.3; st.sel = null; }   // endLassoSelection
  // askMeaning: im Notizbuch muss unter dem ∞ etwas stehen
  if (!st.pdf && !st.drawing.some((s) => touches(p.match, s, st.k))) return st.hints.push({ t: st.now, name: p.name, text: "Unter dem ∞ steht nichts" });
  st.questions.push({ t: st.now, name: p.name });
}

/// Fremde Änderung kommt an; eingefügt, sobald das Werkzeug ruht (applyPendingWhenIdle, alle 0,25 s). Danach gibt es
/// kein Rückgängig mehr. Annahme: Setzen der Zeichnung hebt PencilKits Auswahl auf
function remote(st, t, change) {
  const apply = () => {
    if (toolBusy(st)) return at(st, st.now + 0.25, apply);
    change(st.drawing);
    st.canUndo = false;
    st.sel = null;
  };
  at(st, t, apply);
}
/// Tab gewechselt: leave() (detach räumt Rückgängig ab); die Leinwand ist danach weg, außer etwas hält sie
const leave = (st, t) => at(st, t, () => { st.left = true; st.canUndo = false; });
/// Drehen: die Zeichnung auf die neue Breite umgerechnet (viewDidLayoutSubviews), k mit
const rotate = (st, t, f) => at(st, t, () => {
  for (const s of st.drawing) { s.x *= f; s.y *= f; s.w *= f; s.h *= f; }
  st.k *= f;
  st.canUndo = false;
  st.sel = null;
});

// ---- Teil 3: Abläufe. Seitenpunkte; die Zeit 0 ist das Ende des ∞ (es dauert eine Sekunde)
const S = (id, x, y, w, h, n) => ({ id, x: x * K, y: y * K, w: w * K, h: h * K, n });
const word = () => [S("w1", 300, 402, 18, 26, 41), S("w2", 320, 400, 20, 30, 37), S("w3", 343, 404, 15, 24, 29), S("w4", 361, 401, 19, 28, 44)];
const word2 = () => [S("v1", 110, 610, 22, 25, 33), S("v2", 136, 608, 25, 30, 52), S("v3", 165, 611, 20, 22, 27)];
const INF = { x: 290, y: 388, w: 100, h: 52 };
const INF2 = { x: 100, y: 596, w: 100, h: 52 };
const inf = (name = "∞", match = INF, from = { x: 340, y: 414 }, to = { x: 343, y: 416 }) => ({ kind: "inf", name, match, region: match, from, to });
const tap = (x = 340, y = 415) => ({ kind: "tap", from: { x, y }, to: { x, y } });

const scenarios = [];
const add = (name, vorher, setup, script, check) => scenarios.push({ name, vorher, setup, script, check });
const oneQuestion = (st) => (st.questions.length === 1 ? "" : `${st.questions.length} Fragen statt 1`);
const noMenuOn = (sel) => (st) => {
  const m = st.menus.find((x) => x.sel === sel && x.shown);
  return m ? `Menü bei ${m.t.toFixed(2)} s auf der Auswahl des ${sel}` : "";
};
const all = (...checks) => (st) => checks.map((c) => c(st)).filter(Boolean).join("; ");

// Befund 1: Antippen der Auswahl, das gerade über einen Prüfzeitpunkt läuft
for (const [a, b, vorher] of [[0.2, 0.3, "gut"], [0.42, 0.52, "falsch"], [0.45, 0.57, "falsch"], [0.52, 0.62, "falsch"], [0.75, 0.85, "gut"]]) {
  add(`Antippen der Auswahl ${a.toFixed(2)}–${b.toFixed(2)} s`, vorher, { drawing: word() },
    (st) => { touch(st, -1, 0, inf()); touch(st, a, b, tap()); },
    all(noMenuOn("∞"), oneQuestion, (st) => (st.sel ? "Auswahl des ∞ blieb" : "")));
}
add("Pencil liegt 0,4–3,0 s auf der Auswahl: nach 2 s ein neuer Weg", "egal", { drawing: word() },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.4, 3.0, tap()); },
  all(oneQuestion, (st) => {
    const d = st.decisions[0];
    return d && d.newPath && d.t >= 2 && d.t < 2.15 ? "" : `entschieden ${d ? d.t.toFixed(2) + " s, neuer Weg " + d.newPath : "nie"}`;
  }, (st) => (st.sel && st.sel.name === "∞" ? "" : "Auswahl des ∞ aufgehoben, obwohl der Pencil noch lag")));
add("neuer Weg 0,3–0,9 s anderswo: bleibt ungestört", "gut", { drawing: [...word(), ...word2()] },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.3, 0.9, { kind: "path", name: "Lasso", region: INF2, from: { x: 90, y: 590 }, to: { x: 92, y: 592 } }); },
  all(oneQuestion, (st) => (st.sel && st.sel.name === "Lasso" ? "" : "Auswahl des neuen Wegs fehlt"),
    (st) => (st.menuBlockedUntil === -Infinity ? "" : "Menü des neuen Wegs gesperrt")));
add("zwei ∞: das ältere gibt das Menü des neueren nicht frei", "falsch", { drawing: [...word(), ...word2()] },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.02, 0.45, inf("zweites ∞", INF2, { x: 150, y: 622 }, { x: 152, y: 624 })); touch(st, 0.6, 0.7, tap(150, 622)); },
  all(noMenuOn("zweites ∞"), (st) => (st.questions.length === 2 ? "" : `${st.questions.length} Fragen statt 2`), (st) => (st.sel ? "eine Auswahl blieb" : "")));
// Befund 4
add("Tab gewechselt 0,3 s nach dem ∞: die Frage geht trotzdem", "falsch", { drawing: word() },
  (st) => { touch(st, -1, 0, inf()); leave(st, 0.3); }, oneQuestion);
// Befund 3 und 6: Das ∞ beginnt in einer Auswahl und zieht sie mit
const selWord = { name: "Lasso vorher", ids: ["w1", "w2", "w3", "w4"], region: { x: 295, y: 395, w: 90, h: 40 } };
const movedHint = (want) => (st) => {
  if (st.questions.length) return `${st.questions.length} Fragen, obwohl Striche verschoben`;
  return st.hints.length === 1 && st.hints[0].text.includes(want) ? "" : `Hinweis: ${st.hints.map((h) => h.text).join(" | ") || "keiner"}`;
};
add("∞ beginnt in der Auswahl: Hinweis nennt Rückgängig", "falsch", { drawing: word(), sel: selWord, canUndo: true },
  (st) => touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })), movedHint("Rückgängig"));
add("… dabei kamen fremde Striche (kein Rückgängig mehr)", "falsch", { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); remote(st, 0.3, (d) => d.push(S("r9", 500, 900, 30, 20, 25))); },
  movedHint("zurückschieben"));
add("zweites ∞ auf der frischen Auswahl verschiebt sie: Frage 1 geht, Hinweis vom zweiten", "falsch", { drawing: word(), canUndo: true },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.3, 1.3, inf("zweites ∞", INF, { x: 340, y: 414 }, { x: 347, y: 418 })); },
  all((st) => (st.questions.length === 1 && st.questions[0].name === "∞" ? "" : `Fragen: ${st.questions.map((x) => x.name).join(", ") || "keine"}`),
    (st) => (st.hints.length === 1 && st.hints[0].name === "zweites ∞" && st.hints[0].text.includes("Rückgängig") ? "" : `Hinweise: ${st.hints.map((h) => h.name + ": " + h.text).join(" | ") || "keine"}`)));
add("kleiner Ruck beim Antippen der frischen Auswahl: nicht dem ∞ angelastet", "falsch", { drawing: word(), canUndo: true },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.3, 0.42, { kind: "nudge", from: { x: 340, y: 415 }, to: { x: 342, y: 416 } }); },
  all(oneQuestion, (st) => (st.hints.length ? `Hinweis: ${st.hints[0].text}` : ""), (st) => (st.sel ? "Auswahl blieb" : "")));
// Befund 2b: Auswahl weit weg vom ∞ (über Gedrucktem im PDF), ihr Bereich reicht bis unter den Anfang des ∞
const notes = () => [S("a1", 120, 640, 30, 18, 61), S("a2", 160, 642, 40, 20, 75), S("a3", 600, 680, 35, 15, 48)];
add("∞ in großer Auswahl, ihre Striche weit weg: erkannt", "falsch",
  { pdf: true, drawing: notes(), sel: { name: "Lasso vorher", ids: ["a1", "a2", "a3"], region: { x: 100, y: 350, w: 600, h: 350 } }, canUndo: true },
  (st) => touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })), movedHint("Rückgängig"));
// Befund 2a: Änderungen nahe am ∞ in der Wartezeit, die nichts verschieben
add("fremdes Gerät löscht neben dem Wort: Frage geht", "falsch", { drawing: [...word(), S("r1", 392, 405, 14, 20, 23)] },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => d.splice(d.findIndex((s) => s.id === "r1"), 1)); }, oneQuestion);
add("eigener Radierer neben dem Wort (Werkzeug gewechselt): Frage geht", "falsch", { drawing: [...word(), S("r2", 288, 380, 12, 10, 18)] },
  (st) => {
    touch(st, -1, 0, inf());
    at(st, 0.25, () => { st.usingTool = true; });
    at(st, 0.4, () => { st.drawing.splice(st.drawing.findIndex((s) => s.id === "r2"), 1); st.usingTool = false; st.lastToolEnd = st.now; st.canUndo = true; });
  }, oneQuestion);
add("Doppel: einer von zwei gleichen Strichen gelöscht", "falsch", { drawing: [...word(), S("d1", 395, 410, 12, 12, 20), S("d2", 600, 900, 12, 12, 20)] },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => d.splice(d.findIndex((s) => s.id === "d1"), 1)); }, oneQuestion);
add("fremdes Gerät fügt neben dem Wort etwas hinzu: Frage geht", "gut", { drawing: word() },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => d.push(S("r3", 395, 405, 14, 20, 23))); }, oneQuestion);
add("Drehen in der Wartezeit: nichts verschoben", "gut", { drawing: word() },
  (st) => { touch(st, -1, 0, inf()); rotate(st, 0.3, 0.75); }, oneQuestion);
add("∞ ohne Auswahl, nichts los: Frage, Auswahl weg, kein Menü", "gut", { drawing: word() },
  (st) => touch(st, -1, 0, inf()), all(oneQuestion, noMenuOn("∞"), (st) => (st.sel ? "Auswahl blieb" : ""),
    (st) => (st.decisions[0].t > 0.5 && st.decisions[0].t < 0.65 ? "" : `entschieden erst ${st.decisions[0].t.toFixed(2)} s`)));

// Einzelprüfungen von strokesMoved
const unit = [
  ["gleich", word(), word(), false],
  ["alles um 5 Seitenpunkte verschoben", word(), word().map((s) => ({ ...s, x: s.x + 5 * K })), true],
  ["ein Strich gelöscht", word(), word().slice(1), false],
  ["einer dazu", word(), [...word(), S("x", 10, 10, 5, 5, 9)], false],
  ["verschoben und einer dazu", word(), [...word().map((s) => ({ ...s, y: s.y - 3 * K })), S("x", 10, 10, 5, 5, 9)], true],
  ["um ein Achtel Seitenpunkt (gerundet gleich)", word(), word().map((s) => ({ ...s, x: s.x + K / 10 })), false],
  ["Strich ohne Punkte (renderBounds null)", [{ id: "z", x: Infinity, y: Infinity, w: 0, h: 0, n: 0 }, ...word()], [{ id: "z", x: Infinity, y: Infinity, w: 0, h: 0, n: 0 }, ...word()], false],
];
for (const [name, a, b, want] of unit) {
  const got = strokesMoved(a, K, b, K);
  if (got !== want) fail(`strokesMoved, ${name}: ${got} statt ${want}`);
}

// ---- Auswertung
const rows = [];
let vorherWrong = 0, vorherExpected = 0;
for (const sc of scenarios) {
  const res = {};
  for (const version of ["neu", "vorher"]) {
    const st = makeState(version, sc.setup);
    sc.script(st);
    runAll(st);
    res[version] = sc.check(st);
  }
  if (res.neu) fail(`${sc.name}: ${res.neu}`);
  const vorherOk = !res.vorher;
  if (sc.vorher === "falsch") { vorherExpected++; if (!vorherOk) vorherWrong++; else fail(`${sc.name}: vorher erwartet falsch, ist aber gut`); }
  if (sc.vorher === "gut" && !vorherOk) fail(`${sc.name}: vorher erwartet gut, ist aber falsch (${res.vorher})`);
  rows.push([sc.name, res.neu ? "FALSCH: " + res.neu : "gut", vorherOk ? "gut" : "falsch: " + res.vorher]);
}
console.log("| Ablauf | jetzt | vorher (9f28905) |");
console.log("|---|---|---|");
for (const r of rows) console.log("| " + r.join(" | ") + " |");
console.log(`\nEinzelprüfungen strokesMoved: ${unit.length}`);
console.log(bad ? `Entscheidung: ${bad} Fehler` : `Entscheidung: ${scenarios.length} Abläufe und ${unit.length} Einzelprüfungen, alle gut (vorher falsch: ${vorherWrong} von ${vorherExpected} erwarteten)`);
process.exitCode = bad ? 1 : 0;
