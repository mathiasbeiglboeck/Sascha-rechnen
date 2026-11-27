// Entscheidung nach einem ∞ mit dem Lasso: spiegelt lassoBegan, lassoEnded, infinityDrawn, infinitySettled,
// strokesMoved, strokePrints und undoInfinityMove aus Notizbuch/CanvasController.swift und prüft sie mit simulierter
// Zeit an Abläufen: Antippen der Auswahl, ein neuer Weg, zwei ∞ hintereinander, Tab-Wechsel, eine verschobene Auswahl
// (seit 171 mit Rückgängig zurückgenommen, nicht während eines anderen Werkzeugs), fremde Änderungen (auch fremd
// verschobene Striche, wie sie ein anderes Gerät, der Browser oder eingefügte Seiten bringen), Drehen.
// PencilKit ist dabei nur nachgebildet (Annahmen bei `touch` und `remote`); das ersetzt keinen Test am Gerät.
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
const prints = between(swift, "private struct StrokePrint", "private func undoInfinityMove(");
const undoRegion = between(swift, "private func undoInfinityMove(", "private static func strokesForLog(");
const whenIdle = between(swift, "private func applyPendingWhenIdle(", "private func applyPending(");
const applyP = between(swift, "private func applyPending(", "private func setDrawing(");
const toolEnd = between(swift, "func canvasViewDidEndUsingTool(", "private func moveCursor(");
order("lassoBegan", began, ["let start = (drawing: canvas.drawing, k: k)", "lassoStart = start",
  "for path in infinitiesWaiting where infinityNext[path] == nil { infinityNext[path] = start }"]);
order("lassoEnded", ended, ["lastLassoEnd = Date()", "guard points.count >= 8 else { return }", "lassoPaths += 1",
  "if let match = InfinityGesture.detect(raw, scale: s) {", "lastInfinity = lassoPaths", "infinitiesWaiting.insert(lassoPaths)",
  "ended: Date(), toolUses: toolUses))", "return", "canvas.menuBlockedUntil = .distantPast"]);
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
  "let undone = newPath ? nil : undoInfinityMove(pending)", "if undone == true {", "} else {",
  "if newest { canvas.menuBlockedUntil = .distantPast }",
  "let back = undone == nil && toolUses == pending.toolUses && canvas.undoManager?.canUndo == true ? \"Rückgängig\" : \"zurückschieben\"",
  "onFlashTimed(\"∞ hat die Auswahl verschoben – \\(back), dann die Auswahl aufheben\", 3)", "return",
  "if newPath {", "if newest { canvas.menuBlockedUntil = .distantPast }", "} else {",
  "canvas.menuBlockedUntil = Date().addingTimeInterval(0.3)", "endLassoSelection()", "askMeaning(match)"]);
lines("strokesMoved", moved, ["let old = strokePrints(before, k: kBefore), new = strokePrints(now, k: k)",
  "for (p, n) in old where (new[p] ?? 0) < n { gone.insert(p.shape) }", "guard !gone.isEmpty else { return false }",
  "return new.contains { p, n in (old[p] ?? 0) < n && gone.contains(p.shape) }"]);
lines("strokePrints", prints, ["var shape: [CGFloat] { [dx, dy, CGFloat(points)] }",
  "func q(_ v: CGFloat) -> CGFloat { (v / k * 4).rounded() }", "for stroke in drawing.strokes {",
  "guard let first = stroke.path.first?.location.applying(stroke.transform), let last = stroke.path.last?.location.applying(stroke.transform) else { return nil }",
  "return StrokePrint(x: q(first.x), y: q(first.y), dx: q(last.x - first.x), dy: q(last.y - first.y), points: stroke.path.count)",
  "if let p = strokePrint(stroke, k: k) { prints[p, default: 0] += 1 }"]);
// Nach dem Hinweis endet der Zweig, nach dem Zurücknehmen geht es weiter zur Frage
lines("infinitySettled", settled, ["onFlashTimed(\"∞ hat die Auswahl verschoben – \\(back), dann die Auswahl aufheben\", 3) return } } Log.ink.info(\"Lasso-∞: "]);
order("undoInfinityMove", undoRegion, [
  "guard !toolBusy, toolUses == pending.toolUses, let undo = canvas.undoManager, undo.canUndo else { return nil }",
  "undo.undo()", "if Self.strokePrints(canvas.drawing, k: k) == Self.strokePrints(pending.before, k: pending.k) { return true }",
  "if undo.canRedo { undo.redo() }", "return false"]);
order("applyPendingWhenIdle", whenIdle, ["pendingWork?.cancel()", "guard !pending.isEmpty else { return }",
  "guard toolBusy || waitForPages || idWarmup != nil else {", "applyPending()", "return",
  "let work = DispatchWorkItem { [weak self] in self?.applyPendingWhenIdle() }",
  "DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)"]);
order("applyPending", applyP, ["guard !pending.isEmpty, k > 0 else { return }", "pending = RemoteChanges()",
  "for path in infinitiesWaiting where infinityNext[path] == nil { infinityNext[path] = (drawing: canvas.drawing, k: k) }",
  "StrokeCodec.apply(changes, to: canvas.drawing", "setDrawing(result.drawing)", "canvas.undoManager?.removeAllActions()"]);
order("canvasViewDidEndUsingTool", toolEnd, ["usingTool = false", "lastToolEnd = Date()", "applyPendingWhenIdle()"]);
lines("detach", between(swift, "private func detach(", "private func reattach("), ["applyPending()"]);
lines("toolBusy", swift, ["private var toolBusy: Bool { usingTool || Date().timeIntervalSince(lastToolEnd) < 0.5 }"]);
lines("toolUses", swift, ["private var usingTool = false { didSet { if usingTool, !oldValue { toolUses += 1 } } }"]);
lines("toolUses", swift, ["toolUses += 1"], 2);
order("Antippen mit dem Radierer", between(swift, "if eraseStart == nil, g.state == .ended {", "usingTool = false"),
  ["toolUses += 1", "eraseStart = canvas.drawing", "erase(at: p)"]);
order("canvasViewDidBeginUsingTool", between(swift, "func canvasViewDidBeginUsingTool(", "func canvasViewDidEndUsingTool("),
  ["usingTool = true"]);
order("Radierer setzt auf", between(swift, "@objc private func handleErase(", "case .changed:"), ["case .began:", "usingTool = true"]);
lines("LassoTracker", gestures, ["var isTracking: Bool { tracked != nil }"]);
lines("ohne weak", swift, ["[weak self] in self?.infinitySettled"], 0);
const mirrorBad = bad;
console.log(mirrorBad ? `Spiegel: ${mirrorBad} Unterschiede zum Swift-Code` : "Spiegel: gleich wie im Swift-Code");

// ---- Teil 2: Modell. Striche: x, y (erster Punkt), w, h (Weg vom ersten zum letzten Punkt), Leinwandpunkte, und n
// Punkte
const K = 1.34; // iPad 13 bei Zoom 1: Leinwandpunkte je Seitenpunkt

/// strokePrints: je Strich erster Punkt und Weg bis zum letzten in ¼ Seitenpunkten (.rounded(): ab ,5 von 0 weg) und
/// Zahl der Punkte; Striche ohne Punkte zählen nicht
const q = (v, k) => { const x = v / k * 4; return Math.sign(x) * Math.round(Math.abs(x)) + 0; };
function strokePrints(drawing, k) {
  const m = new Map();
  if (!(k > 0)) return m;
  for (const s of drawing) {
    if (!s.n) continue;
    const key = [q(s.x, k), q(s.y, k), q(s.w, k), q(s.h, k), s.n].join(",");
    m.set(key, (m.get(key) || 0) + 1);
  }
  return m;
}
const shapeOf = (key) => key.split(",").slice(2).join(",");
/// strokesMoved: ein Strich fehlt, und ein gleich geformter mit gleich vielen Punkten kam anderswo dazu
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

/// Rückgängig wie PencilKits undoManager: `undo`/`redo` sind Stapel von Schritten { undo(), redo() }. `canUndo` im
/// Aufbau: etwas Früheres, das hier nichts ändert; `undoStroke`: zuletzt wurde dieser Strich geschrieben
function makeState(version, setup) {
  const st = {
    version, now: 0, queue: [], seq: 0, k: K, drawing: clone(setup.drawing || []), pdf: !!setup.pdf,
    sel: setup.sel ? { name: setup.sel.name, ids: new Set(setup.sel.ids), region: { ...setup.sel.region } } : null,
    undo: [], redo: [], undoCalls: 0, toolUses: 0, lassoPaths: 0, lastInfinity: 0, lastLassoEnd: -Infinity, tracking: false,
    lassoStart: null, usingTool: false, lastToolEnd: -Infinity, menuBlockedUntil: -Infinity, left: false,
    waiting: new Set(), next: new Map(), pending: [], pendingWork: 0,
    questions: [], hints: [], menus: [], decisions: [], reverted: [],
  };
  if (setup.canUndo) st.undo.push({ undo() {}, redo() {} });
  if (setup.undoStroke) {
    const s = { ...st.drawing.find((x) => x.id === setup.undoStroke) };
    st.undo.push({ undo: () => removeId(st.drawing, s.id), redo: () => st.drawing.push({ ...s }) });
  }
  return st;
}
const removeId = (d, id) => { const i = d.findIndex((s) => s.id === id); if (i >= 0) d.splice(i, 1); };
const canUndo = (st) => st.undo.length > 0;
const register = (st, step) => { st.undo.push(step); st.redo = []; };
const doUndo = (st) => { st.undoCalls++; const step = st.undo.pop(); step.undo(); st.redo.push(step); };
const doRedo = (st) => { const step = st.redo.pop(); step.redo(); st.undo.push(step); };
const clearUndo = (st) => { st.undo = []; st.redo = []; };            // removeAllActions
/// usingTool = true; didSet zählt toolUses, wenn das Werkzeug vorher ruhte
const useTool = (st) => { if (!st.usingTool) st.toolUses++; st.usingTool = true; };
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
/// das als Letztes (mit `noUndo` nicht: dann nimmt Rückgängig etwas Unbekanntes zurück); sonst wählt er aus, was er
/// umschließt. Antippen der Auswahl fragt nach dem Menü, daneben hebt es sie auf; ein
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
    if (o.kind !== "tap") useTool(st);                            // canvasViewDidBeginUsingTool
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
      const dx = o.to.x - o.from.x, dy = o.to.y - o.from.y, ids = new Set(st.sel.ids), k = st.k;
      const shift = (f) => { for (const s of st.drawing) if (ids.has(s.id)) { s.x += f * dx * k; s.y += f * dy * k; } };
      shift(1);
      st.sel.region = { ...st.sel.region, x: st.sel.region.x + dx, y: st.sel.region.y + dy };
      if (!o.noUndo) register(st, { undo: () => shift(-1), redo: () => shift(1) });
    } else {
      const ids = st.drawing.filter((s) => strokeIn(o.region, s, st.k)).map((s) => s.id);
      st.sel = ids.length ? { name: o.name, ids: new Set(ids), region: { ...o.region } } : null;
    }
  });
  if (o.kind !== "tap") at(st, t1 + 0.02, () => { st.usingTool = false; st.lastToolEnd = st.now; applyPendingWhenIdle(st); });
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
    const pending = { name: o.name, match: o.match, before: before.drawing, k: before.k, path: st.lassoPaths, ended: st.now,
      toolUses: st.toolUses };
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
    const undone = st.version === "neu" && !newPath ? undoMove(st, p) : null;   // null: nicht versucht
    if (undone === true) st.reverted.push({ t: st.now, name: p.name });
    else {
      if (newest) st.menuBlockedUntil = -Infinity;
      const back = undone === null && st.toolUses === p.toolUses && canUndo(st) ? "Rückgängig" : "zurückschieben";
      const text = st.version === "neu" ? `${back}, dann die Auswahl aufheben` : "erst die Auswahl aufheben";
      st.hints.push({ t: st.now, name: p.name, text: "∞ hat die Auswahl verschoben – " + text });
      return;
    }
  }
  if (newPath) { if (newest) st.menuBlockedUntil = -Infinity; }
  else { st.menuBlockedUntil = st.now + 0.3; st.sel = null; }   // endLassoSelection
  // askMeaning: im Notizbuch muss unter dem ∞ etwas stehen
  if (!st.pdf && !st.drawing.some((s) => touches(p.match, s, st.k))) return st.hints.push({ t: st.now, name: p.name, text: "Unter dem ∞ steht nichts" });
  st.questions.push({ t: st.now, name: p.name });
}

const samePrints = (a, b) => a.size === b.size && [...a].every(([key, n]) => b.get(key) === n);
/// undoInfinityMove: nicht, solange ein Werkzeug arbeitet oder seit dem Ende des ∞ eins begann (null: nicht versucht);
/// dann Rückgängig. Gilt nur, wenn danach alles wie beim Aufsetzen des ∞ liegt, sonst wiederholt (false)
function undoMove(st, p) {
  if (toolBusy(st) || st.toolUses !== p.toolUses || !canUndo(st)) return null;
  doUndo(st);
  if (samePrints(strokePrints(st.drawing, st.k), strokePrints(p.before, p.k))) return true;
  if (st.redo.length) doRedo(st);
  return false;
}

/// Fremde Änderung kommt an (enqueue); eingefügt, sobald das Werkzeug ruht (applyPendingWhenIdle: ein Auftrag, alle
/// 0,25 s neu, und gleich nach dem Ende des Werkzeugs). Danach gibt es kein Rückgängig mehr. Annahme: Setzen der
/// Zeichnung hebt PencilKits Auswahl auf
function remote(st, t, change) {
  at(st, t, () => { st.pending.push(change); applyPendingWhenIdle(st); });
}
function applyPendingWhenIdle(st) {
  const mine = ++st.pendingWork;                                // pendingWork?.cancel()
  if (!st.pending.length) return;
  if (!toolBusy(st)) return applyPending(st);
  at(st, st.now + 0.25, () => { if (st.pendingWork === mine) applyPendingWhenIdle(st); });
}
function applyPending(st) {
  if (!st.pending.length) return;
  // Jetzt: für ein ∞, über das noch nicht entschieden ist, der Stand vor den fremden Änderungen (vorher fehlte das)
  if (st.version === "neu") for (const p of st.waiting) if (!st.next.has(p)) st.next.set(p, { drawing: clone(st.drawing), k: st.k });
  for (const change of st.pending) change(st.drawing);
  st.pending = [];
  clearUndo(st);
  st.sel = null;
}
/// Tab gewechselt: leave() (detach fügt Wartendes ein und räumt Rückgängig ab); die Leinwand ist danach weg, außer
/// etwas hält sie
const leave = (st, t) => at(st, t, () => { applyPending(st); st.left = true; clearUndo(st); });
/// Drehen: die Zeichnung auf die neue Breite umgerechnet (viewDidLayoutSubviews), k mit
const rotate = (st, t, f) => at(st, t, () => {
  for (const s of st.drawing) { s.x *= f; s.y *= f; s.w *= f; s.h *= f; }
  st.k *= f;
  clearUndo(st);
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
// Befund 3 und 6: Das ∞ beginnt in einer Auswahl und zieht sie mit. Seit 171 nimmt Rückgängig das zurück, und die
// Frage geht (im Simulator mit iOS 27 legte PencilKit das Verschieben 13 ms nach dem Ende des Wegs ab, 27.11.)
const selWord = { name: "Lasso vorher", ids: ["w1", "w2", "w3", "w4"], region: { x: 295, y: 395, w: 90, h: 40 } };
const movedHint = (want) => (st) => {
  if (st.questions.length) return `${st.questions.length} Fragen, obwohl Striche verschoben`;
  return st.hints.length === 1 && st.hints[0].text.includes(want) ? "" : `Hinweis: ${st.hints.map((h) => h.text).join(" | ") || "keiner"}`;
};
const withoutHint = (st) => (st.hints.length ? `Hinweis: ${st.hints.map((h) => h.text).join(" | ")}` : "");
const backInPlace = (initial) => (st) => (samePrints(strokePrints(st.drawing, st.k), strokePrints(initial, K)) ? "" : "Striche nicht zurückgeschoben");
add("∞ beginnt in der Auswahl und zieht sie mit: zurückgenommen, Frage geht", "falsch", { drawing: word(), sel: selWord, canUndo: true },
  (st) => touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })),
  all(oneQuestion, withoutHint, backInPlace(word()), (st) => (st.reverted.length === 1 ? "" : `${st.reverted.length}-mal zurückgenommen`),
    (st) => (st.sel ? "Auswahl blieb" : "")));
add("… und Antippen der Auswahl in der Wartezeit: zurückgenommen, kein Menü", "falsch", { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); touch(st, 0.2, 0.3, tap(346, 417)); },
  all(oneQuestion, withoutHint, backInPlace(word()), noMenuOn("Lasso vorher")));
// Rückgängig nimmt statt des Verschiebens den zuletzt geschriebenen Strich e1 zurück: wiederholen bringt ihn wieder
const withE1 = () => [...word(), S("e1", 200, 300, 20, 10, 30)];
add("… Rückgängig kennt das Verschieben nicht: wiederholt, Hinweis nennt zurückschieben", "falsch", { drawing: withE1(), sel: selWord, undoStroke: "e1" },
  (st) => touch(st, -1, 0, { ...inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }), noUndo: true }),
  all(movedHint("zurückschieben"), (st) => (backInPlace(withE1())(st) ? "" : "Striche zurückgeschoben, obwohl Rückgängig nicht passte"),
    (st) => (st.drawing.some((s) => s.id === "e1") ? "" : "Strich e1 fehlt (nicht wiederholt)"),
    (st) => (st.undo.length === 1 && !st.redo.length ? "" : `Rückgängig ${st.undo.length}, Wiederholen ${st.redo.length} statt 1 und 0`)));
// Ein neuer Weg zählt als Werkzeug: Ob Rückgängig dann noch das Verschieben träfe, ist nicht sicher
add("∞ zieht die Auswahl mit, dann ein neuer Weg anderswo: nichts zurückgenommen, Auswahl des Wegs bleibt", "falsch",
  { drawing: [...word(), ...word2()], sel: selWord, canUndo: true },
  (st) => {
    touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }));
    touch(st, 0.3, 0.9, { kind: "path", name: "Lasso", region: INF2, from: { x: 90, y: 590 }, to: { x: 92, y: 592 } });
  },
  all(movedHint("zurückschieben"), (st) => (st.reverted.length ? "zurückgenommen trotz neuem Weg" : ""),
    (st) => (st.sel && st.sel.name === "Lasso" ? "" : "Auswahl des neuen Wegs fehlt")));
add("∞ zieht die Auswahl mit, in der Wartezeit ein Ruck an ihr: nichts zurückgenommen, Hinweis nennt zurückschieben", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => {
    touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }));
    touch(st, 0.3, 0.42, { kind: "nudge", from: { x: 346, y: 417 }, to: { x: 348, y: 418 } });
  },
  all(movedHint("zurückschieben"), (st) => (st.reverted.length ? "zurückgenommen trotz Ruck" : "")));
add("∞ zieht die Auswahl mit, dann liegt der Pencil 0,4–3,0 s auf ihr: nach 2 s nichts zurückgenommen, Hinweis nennt Rückgängig", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); touch(st, 0.4, 3.0, tap(346, 417)); },
  all(movedHint("Rückgängig"), (st) => (st.undoCalls ? "Rückgängig, während PencilKit die Berührung verfolgte" : "")));
// Doppeltippen mit dem Pencil: gleich der Radierer der App. Rückgängig träfe sein Radieren; es bleibt unberührt
add("∞ zieht die Auswahl mit, dann radiert der Radierer der App kurz (0,1–0,2 s): Rückgängig unberührt, Hinweis nennt zurückschieben", "falsch",
  { drawing: [...word(), S("r2", 288, 380, 12, 10, 18)], sel: selWord, canUndo: true },
  (st) => {
    touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }));
    at(st, 0.1, () => { useTool(st); });
    at(st, 0.2, () => {
      const r2 = { ...st.drawing.find((s) => s.id === "r2") };
      removeId(st.drawing, "r2");
      register(st, { undo: () => st.drawing.push({ ...r2 }), redo: () => removeId(st.drawing, "r2") });
      st.usingTool = false;
      st.lastToolEnd = st.now;
    });
  },
  all(movedHint("zurückschieben"), (st) => (st.undoCalls ? `${st.undoCalls}-mal Rückgängig nach dem Radieren` : ""),
    (st) => (st.drawing.some((s) => s.id === "r2") ? "r2 wieder da" : "")));
// Der Radierer der App merkt sich die Zeichnung beim Aufsetzen und setzt sie am Ende ohne das Radierte: Ein Rückgängig
// dazwischen (nach 2 s wird ohne Warten entschieden) ginge verloren, und Rückgängig träfe danach das Falsche
add("∞ zieht die Auswahl mit, gleich danach radiert der Radierer der App bis 3 s: nichts zurückgenommen, Hinweis nennt zurückschieben", "falsch",
  { drawing: [...word(), S("r2", 288, 380, 12, 10, 18)], sel: selWord, canUndo: true },
  (st) => {
    touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }));
    let start;
    at(st, 0.25, () => { useTool(st); start = clone(st.drawing); });
    at(st, 3.0, () => {
      const was = clone(st.drawing), now = start.filter((s) => s.id !== "r2");
      st.drawing = clone(now);
      register(st, { undo: () => { st.drawing = clone(was); }, redo: () => { st.drawing = clone(now); } });
      st.usingTool = false;
      st.lastToolEnd = st.now;
    });
  },
  all(movedHint("zurückschieben"), (st) => (st.reverted.length ? "zurückgenommen, während der Radierer arbeitete" : ""),
    (st) => (st.decisions[0] && st.decisions[0].t >= 2 && st.decisions[0].t < 2.15 ? "" : "nicht nach 2 s entschieden")));
add("… dabei kamen fremde Striche (kein Rückgängig mehr)", "falsch", { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); remote(st, 0.3, (d) => d.push(S("r9", 500, 900, 30, 20, 25))); },
  movedHint("zurückschieben"));
add("zweites ∞ auf der frischen Auswahl zieht sie mit: zurückgenommen, beide fragen", "falsch", { drawing: word(), canUndo: true },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.3, 1.3, inf("zweites ∞", INF, { x: 340, y: 414 }, { x: 347, y: 418 })); },
  all((st) => (st.questions.map((x) => x.name).join(", ") === "∞, zweites ∞" ? "" : `Fragen: ${st.questions.map((x) => x.name).join(", ") || "keine"}`),
    withoutHint, backInPlace(word())));
add("kleiner Ruck beim Antippen der frischen Auswahl: nicht dem ∞ angelastet", "falsch", { drawing: word(), canUndo: true },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.3, 0.42, { kind: "nudge", from: { x: 340, y: 415 }, to: { x: 342, y: 416 } }); },
  all(oneQuestion, (st) => (st.hints.length ? `Hinweis: ${st.hints[0].text}` : ""), (st) => (st.sel ? "Auswahl blieb" : "")));
// Befund 2b: Auswahl weit weg vom ∞ (über Gedrucktem im PDF), ihr Bereich reicht bis unter den Anfang des ∞
const notes = () => [S("a1", 120, 640, 30, 18, 61), S("a2", 160, 642, 40, 20, 75), S("a3", 600, 680, 35, 15, 48)];
add("∞ in großer Auswahl, ihre Striche weit weg: erkannt und zurückgenommen", "falsch",
  { pdf: true, drawing: notes(), sel: { name: "Lasso vorher", ids: ["a1", "a2", "a3"], region: { x: 100, y: 350, w: 600, h: 350 } }, canUndo: true },
  (st) => touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })), all(oneQuestion, withoutHint, backInPlace(notes())));
// Befund 2a: Änderungen nahe am ∞ in der Wartezeit, die nichts verschieben
add("fremdes Gerät löscht neben dem Wort: Frage geht", "falsch", { drawing: [...word(), S("r1", 392, 405, 14, 20, 23)] },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => d.splice(d.findIndex((s) => s.id === "r1"), 1)); }, oneQuestion);
add("eigener Radierer neben dem Wort (Werkzeug gewechselt): Frage geht", "falsch", { drawing: [...word(), S("r2", 288, 380, 12, 10, 18)] },
  (st) => {
    touch(st, -1, 0, inf());
    at(st, 0.25, () => { useTool(st); });
    at(st, 0.4, () => {
      const r2 = { ...st.drawing.find((s) => s.id === "r2") };
      removeId(st.drawing, "r2");
      register(st, { undo: () => st.drawing.push({ ...r2 }), redo: () => removeId(st.drawing, "r2") });
      st.usingTool = false;
      st.lastToolEnd = st.now;
    });
  }, oneQuestion);
add("Doppel: einer von zwei gleichen Strichen gelöscht", "falsch", { drawing: [...word(), S("d1", 395, 410, 12, 12, 20), S("d2", 600, 900, 12, 12, 20)] },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => d.splice(d.findIndex((s) => s.id === "d1"), 1)); }, oneQuestion);
add("fremdes Gerät fügt neben dem Wort etwas hinzu: Frage geht", "gut", { drawing: word() },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => d.push(S("r3", 395, 405, 14, 20, 23))); }, oneQuestion);
// Durchsicht 123: Ein anderes Gerät oder der Browser verschiebt Striche (mit dem Lasso, oder eingefügte Seiten schieben
// sie hinunter). Das kommt als „alte ID weg, gleicher Strich anderswo neu“ an und darf nicht dem ∞ angelastet werden
const moveTo = (id, dx, dy) => (d) => {
  const i = d.findIndex((s) => s.id === id);
  const s = d[i];
  d.splice(i, 1);
  d.push({ ...s, id: id + "'", x: s.x + dx * K, y: s.y + dy * K });
};
const far = () => [...word(), S("g1", 500, 900, 30, 20, 25)];
const noHint = (st) => (st.hints.length ? `Hinweis: ${st.hints.map((h) => h.text).join(" | ")}` : "");
for (const t of [-0.8, -0.3, 0.1, 0.3, 0.45, 0.52, 0.7, 1.5]) {
  add(`fremdes Gerät verschiebt einen Strich weit weg, kommt bei ${t.toFixed(2)} s an: Frage geht`, "gut", { drawing: far() },
    (st) => { touch(st, -1, 0, inf()); remote(st, t, moveTo("g1", 40, 10)); }, all(oneQuestion, noHint));
}
add("Browser verschiebt: erst neu, gleich danach alt weg (zwei Nachrichten): Frage geht", "gut", { drawing: far() },
  (st) => {
    touch(st, -1, 0, inf());
    remote(st, 0.3, (d) => d.push({ ...d.find((s) => s.id === "g1"), id: "g1'", x: 540 * K, y: 910 * K }));
    remote(st, 0.35, (d) => d.splice(d.findIndex((s) => s.id === "g1"), 1));
  }, all(oneQuestion, noHint));
add("Browser verschiebt: alt weg erst nach dem Einfügen des neuen: Frage geht", "gut", { drawing: far() },
  (st) => {
    touch(st, -1, 0, inf());
    remote(st, 0.3, (d) => d.push({ ...d.find((s) => s.id === "g1"), id: "g1'", x: 540 * K, y: 910 * K }));
    remote(st, 0.56, (d) => d.splice(d.findIndex((s) => s.id === "g1"), 1));
  }, all(oneQuestion, noHint));
add("anderes Gerät fügt eine Seite ein, die Striche darunter rücken: Frage geht", "gut",
  { drawing: [...word(), S("p1", 120, 1200, 30, 20, 25), S("p2", 160, 1240, 45, 18, 31)] },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, (d) => { moveTo("p1", 0, 1024)(d); moveTo("p2", 0, 1024)(d); }); },
  all(oneQuestion, noHint));
add("fremdes Gerät verschiebt einen Strich neben dem Wort: Frage geht", "falsch", { drawing: [...word(), S("r1", 392, 405, 14, 20, 23)] },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, moveTo("r1", 12, 0)); }, all(oneQuestion, noHint));
add("∞ verschiebt die Auswahl, dabei verschiebt ein anderes Gerät etwas: Hinweis nennt zurückschieben", "falsch",
  { drawing: far(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); remote(st, 0.3, moveTo("g1", 40, 10)); },
  movedHint("zurückschieben"));
add("Tab gewechselt nach dem ∞, dabei kam eine fremde Verschiebung: Frage geht", "falsch", { drawing: far() },
  (st) => { touch(st, -1, 0, inf()); remote(st, 0.3, moveTo("g1", 40, 10)); leave(st, 0.53); }, all(oneQuestion, noHint));
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
  ["Strich ohne Punkte (zählt nicht)", [{ id: "z", x: Infinity, y: Infinity, w: 0, h: 0, n: 0 }, ...word()], [{ id: "z", x: Infinity, y: Infinity, w: 0, h: 0, n: 0 }, ...word()], false],
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
