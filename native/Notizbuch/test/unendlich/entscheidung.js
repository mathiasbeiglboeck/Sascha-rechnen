// Entscheidung nach einem ∞ mit dem Lasso: spiegelt lassoBegan, lassoEnded, infinityDrawn, infinitySettled,
// strokesMoved, strokePrints, undoInfinityMove, endLassoSelection und redrawAfterInfinity aus
// Notizbuch/CanvasController.swift, dazu setDrawing, redrawInkNow, canvasViewDrawingDidChange und saveNow, soweit
// Neuzeichnen und Speichern davon abhängen, und redrawInkSoon, soweit Drehen es anstößt. Geprüft mit simulierter Zeit an
// Abläufen: Antippen der Auswahl, ein neuer Weg, zwei ∞ hintereinander, Tab-Wechsel, eine verschobene Auswahl (seit 171
// mit Rückgängig zurückgenommen, nicht während eines anderen Werkzeugs; seit 172 erst nach dem Aufheben der Auswahl;
// seit 181 danach einmal neu gezeichnet, frühestens 0,5 s danach und erst, wenn kein Werkzeug arbeitet, das Lasso keine
// Berührung verfolgt und deren Ende (Weg oder Antippen) 0,5 s her ist, der Pencil nicht nah und keine Liste offen ist;
// es entfällt nach einem neuen Weg des Lassos, dem Verlassen der Leinwand und wenn das Neuzeichnen vom Drehen ansteht),
// fremde Änderungen (auch fremd verschobene Striche, wie sie ein anderes Gerät, der Browser oder eingefügte Seiten
// bringen), Drehen.
// PencilKit ist dabei nur nachgebildet (Annahmen bei `touch`, `paste` und `remote`), ebenso das Schweben des Pencils
// und die Liste einer Auswahl; das ersetzt keinen Test am Gerät. Ob das Neuzeichnen die leere Seite aus dem Simulator
// behebt (28.11.), zeigt es nicht. redrawInkSoon ist nur nach dem Drehen nachgebildet, nicht nach dem Radieren, einem
// Seitensprung, einer neuen Seitenordnung oder fremden Strichen auf leerer Leinwand; dass ein anstehendes das
// Neuzeichnen nach dem ∞ entfallen lässt, gilt für alle gleich (redrawWork). Nicht nachgebildet ist eine verdeckte
// Leinwand (detached ohne left, etwa unter einem Vollbild): Dass redrawAfterInfinity dann entfällt und reattach die
// Zeichnung neu setzt, prüft nur Teil 1.
// Teil 1 vergleicht die gespiegelten Zeilen mit dem Swift-Code: Ändert sich dort etwas, hier nachziehen. Jeder Ablauf
// läuft auch mit der Fassung vor den Korrekturen („vorher“, Commit 9f28905); sie muss an den genannten Stellen scheitern.
// Aufruf: node entscheidung.js; erwartet am Ende „Entscheidung: … alle gut“.
"use strict";
const fs = require("fs");
const path = require("path");

let bad = 0;
const fail = (text) => { bad++; console.log("FALSCH: " + text); };
// Warum das Neuzeichnen nach dem ∞ entfällt: die beiden Gründe aus seinem Protokoll (Teil 1 vergleicht sie wörtlich mit
// redrawAfterInfinity) und das Verlassen der Leinwand (ohne Protokoll)
const DROP_PATH = "neuer Weg des Lassos", DROP_OTHER = "ein anderes steht an", DROP_LEFT = "verlassen";

// ---- Teil 1: Stimmt der Spiegel noch mit dem Swift-Code überein?
const app = path.join(__dirname, "..", "..", "Notizbuch");
const swift = fs.readFileSync(path.join(app, "CanvasController.swift"), "utf8");
const gestures = fs.readFileSync(path.join(app, "Gestures.swift"), "utf8");
const inkView = fs.readFileSync(path.join(app, "InkCanvasView.swift"), "utf8");
const store = fs.readFileSync(path.join(app, "DocumentStore.swift"), "utf8");
const flat = (s) => s.replace(/\s+/g, " ");
const between = (text, from, to) => {
  const a = text.indexOf(from), b = text.indexOf(to, a + from.length);
  if (a < 0 || b < 0) throw new Error(`Stelle nicht gefunden: ${from} … ${to}`);
  return text.slice(a, b);
};
const count = (text, snippet) => flat(text).split(flat(snippet)).length - 1;
/// Swift ohne Kommentare (// bis zum Zeilenende außerhalb von Zeichenketten, /* … */), zum Zählen von Aufrufen:
/// Kommentare nennen redrawAfterInfinity, redrawInkSoon und andere, mit und ohne Klammer
const code = (text) => {
  let out = "", str = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (str) {
      out += c;
      if (c === "\\") out += text[++i] ?? "";
      else if (c === "\"") str = false;
    } else if (c === "\"") { str = true; out += c; }
    else if (c === "/" && text[i + 1] === "/") { while (i + 1 < text.length && text[i + 1] !== "\n") i++; }
    else if (c === "/" && text[i + 1] === "*") { const e = text.indexOf("*/", i + 2); i = e < 0 ? text.length : e + 1; out += " "; }
    else out += c;
  }
  return out;
};
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
/// Die ganze Stelle wörtlich wie `expected` (Leerraum zählt nicht), nicht nur darin enthalten
function exact(where, text, expected) {
  const f = flat(text).trim(), e = flat(expected).trim();
  if (f === e) return;
  let i = 0;
  while (i < f.length && f[i] === e[i]) i++;
  fail(`${where}: weicht ab bei „${f.slice(Math.max(0, i - 30), i + 40)}“, gespiegelt „${e.slice(Math.max(0, i - 30), i + 40)}“`);
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
// Seit 172 hebt undoInfinityMove die Auswahl vor dem Rückgängig auf (Modell `endLasso`), erst nach dem Wächter. Nach dem
// Zurücknehmen läuft das in infinitySettled noch einmal: Dann zählt das Lasso ab der zurückgeschobenen Zeichnung
order("undoInfinityMove", undoRegion, [
  "guard !toolBusy, toolUses == pending.toolUses, let undo = canvas.undoManager, undo.canUndo else { return nil }",
  "toolUsedSinceSave = true", "endLassoSelection() undo.undo()",
  "if Self.strokePrints(canvas.drawing, k: k) == Self.strokePrints(pending.before, k: pending.k) { return true }",
  "if undo.canRedo { undo.redo() }", "return false"]);
lines("endLassoSelection", settled + undoRegion, ["endLassoSelection()"], 2);
// endLassoSelection: Werkzeug hin und zurück; applyTool setzt dabei lassoDrawing neu (rebaseLassoDrawing). Setzt die
// Zeichnung nicht und zählt nicht als Werkzeug: Rückgängig trifft danach noch das Verschieben, kein Strich unterwegs geht
// verloren, und Wächter und Hinweis (toolUses) merken nichts davon
const endSel = between(swift, "private func endLassoSelection(", "private static var answerPageWarm");
order("endLassoSelection", endSel, ["guard canvas.tool is PKLassoTool else { return }", "canvas.tool = inkingTool()",
  "applyTool()", "canvas.endEditing(true)"]);
lines("endLassoSelection", endSel, ["setDrawing(", "canvas.drawing =", "usingTool", "toolUses", "undoManager", "lastToolEnd", "async"], 0);
// Seit 181 wird nach dem Zurücknehmen neu gezeichnet, aber nicht schon beim Entscheiden oder Zurücknehmen selbst: erst
// 0,5 s danach (redrawAfterInfinity, Modell `redrawAfter`), und nur nach gelungenem Zurücknehmen (undone == true).
// Aufrufe gezählt im Code ohne Kommentare
lines("infinitySettled, undoInfinityMove", code(settled + undoRegion), ["setDrawing(", "redrawInkNow(", "redrawInkSoon("], 0);
order("infinitySettled: neu zeichnen", settled, ["let undone = newPath ? nil : undoInfinityMove(pending)", "if undone == true {",
  "Log.ink.info(\"Lasso-∞ verschob Striche: zurückgenommen\")", "redrawAfterInfinity(path: pending.path)", "} else {"]);
lines("infinitySettled: neu zeichnen", code(between(settled, "if undone == true {", "} else {")),
  ["Log.ink.info(\"Lasso-∞ verschob Striche: zurückgenommen\")", "redrawAfterInfinity(path: pending.path)"]);
// Nur dort angestoßen; sonst ruft es nur sich selbst auf (alle 0,5 s neu). Ganz wie gespiegelt, wörtlich: in 0,5 s;
// entfällt ohne Protokoll, wenn die Leinwand verlassen ist (left; mit [weak self] auch, wenn sie weg ist) oder verdeckt
// (detached, nicht nachgebildet), mit Protokoll, wenn seither ein Weg des Lassos fertig ist (DROP_PATH) oder schon ein
// Neuzeichnen von redrawInkSoon ansteht (DROP_OTHER; redrawWork, nachgebildet nur nach dem Drehen); wartet, solange ein
// Werkzeug arbeitet, der Pencil nah ist, die Liste einer Auswahl offen ist, das Lasso eine Berührung verfolgt oder ihr
// Ende (Weg oder Antippen, lastLassoEnd) keine 0,5 s her ist
lines("redrawAfterInfinity", code(swift), ["redrawAfterInfinity("], 3);
const afterInf = between(swift, "private func redrawAfterInfinity(", "/// Baut die Tinte sofort neu auf");
exact("redrawAfterInfinity", afterInf,
  "private func redrawAfterInfinity(path: Int) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in " +
  "guard let self, !self.left, !self.detached else { return } " +
  "guard self.lassoPaths == path, self.redrawWork == nil else { #if DEBUG NSLog(\"Asks-Debug: ∞: kein Neuzeichnen, %@\", " +
  `self.lassoPaths == path ? "${DROP_OTHER}" : "${DROP_PATH}") #endif return } ` +
  "if self.toolBusy || self.pencilNear || self.canvas.isShowingSelectionPanel || self.lassoTracker.isTracking " +
  "|| Date().timeIntervalSince(self.lastLassoEnd) < 0.5 { self.redrawAfterInfinity(path: path) } else { " +
  "#if DEBUG NSLog(\"Asks-Debug: ∞: Tinte neu aufbauen, %ld Striche\", self.canvas.drawing.strokes.count) #endif " +
  "self.redrawInkNow() } } }");
// lassoPaths zählt nur fertige Wege (lassoEnded, ab 8 Punkten, siehe oben; Antippen nicht) und wird nie zurückgesetzt.
// lastLassoEnd setzt nur lassoEnded, vor dem Wächter der 8 Punkte (siehe oben): auch nach Antippen und nach dem Ziehen
// einer Auswahl, das PencilKit nicht als Werkzeug meldet
lines("lassoPaths", swift, ["private var lassoPaths = 0", "lassoPaths += 1", "lassoPaths = "]);
lines("lastLassoEnd", code(swift), ["lastLassoEnd = Date()", "private var lastLassoEnd = Date.distantPast"]);
lines("lastLassoEnd", code(swift), ["lastLassoEnd = "], 2);
// left setzt nur leave, vor detach (Modell `leave`: einfügen, speichern, Rückgängig abräumen)
lines("left", swift, ["private var left = false", "left = true"]);
order("leave", between(swift, "func leave() {", "var isSettling"), ["left = true", "detach()"]);
// detached (nicht nachgebildet): setzt nur detach, zurück nur reattach, und das setzt die Zeichnung aus der Datei neu
lines("detached", code(swift), ["detached = true", "private var detached = false"]);
lines("detached", code(swift), ["detached = false"], 2);
order("detach", between(swift, "private func detach(", "private func reattach("), ["guard !detached else { return }", "detached = true"]);
order("reattach", between(swift, "private func reattach(", "// MARK: Sync"), ["detached = false",
  "setDrawing(store.loadDrawing(current).transformed(using: CGAffineTransform(scaleX: k, y: k)))"]);
// redrawInkNow (Modell `redrawNow`), wörtlich wie in 180 und ohne Protokoll: ein ausstehendes Neuzeichnen von
// redrawInkSoon entfällt (redrawWork wieder nil), dann die Zeichnung leer und wieder dieselbe; kein Rückgängig, kein
// Speichern, kein Abgleich
const inkNow = between(swift, "private func redrawInkNow(", "override func viewWillDisappear(");
exact("redrawInkNow", inkNow, "private func redrawInkNow() { redrawWork?.cancel() redrawWork = nil redrawWaitsForPencil = false " +
  "let drawing = canvas.drawing setDrawing(PKDrawing()) setDrawing(drawing) }");
lines("redrawInkNow", inkNow, ["NSLog", "undoManager", "dirty", "syncSoon", "saveNow", "toolUsedSinceSave", "baseline"], 0);
// redrawInkSoon (Modell `redrawSoon`, nur ohne waitForPencil, wie nach dem Drehen): ein früheres entfällt; in 0,5 s,
// solange ein Werkzeug arbeitet alle 0,5 s neu, dann redrawInkNow. redrawWork steht von da bis redrawInkNow
order("redrawInkSoon", between(swift, "private func redrawInkSoon(", "private func redrawAfterInfinity("), [
  "redrawWaitsForPencil = waitForPencil && (redrawWork == nil || redrawWaitsForPencil)", "redrawWork?.cancel()",
  "let work = DispatchWorkItem { [weak self] in", "guard let self else { return }",
  "if self.toolBusy || (self.redrawWaitsForPencil && (self.pencilNear || self.canvas.isShowingSelectionPanel)) {",
  "self.redrawInkSoon(waitForPencil: self.redrawWaitsForPencil)", "return", "self.redrawInkNow()", "redrawWork = work",
  "DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)"]);
lines("redrawWork", code(swift), ["redrawWork = work", "redrawWork = nil"]);
lines("redrawWork", code(swift), ["redrawWork = "], 2);
// Drehen (Modell `rotate`): den Vergleichsstand mit umrechnen, wenn etwas ungespeichert ist, die umgerechnete
// Zeichnung setzen, Rückgängig abräumen, dann redrawInkSoon ohne waitForPencil
order("Drehen", between(swift, "// Drehen: Zeichnung auf die neue Breite umrechnen", "applyTool()"), ["let f = newK / k",
  "if dirty { baseline = baseline?.transformed(using: scale) }", "setDrawing(canvas.drawing.transformed(using: scale))",
  "canvas.undoManager?.removeAllActions()", "k = newK", "redrawInkSoon()"]);
// setDrawing (Modell `setDrawingM`): schließt die Liste, PencilKits Meldung der neuen Zeichnung übergeht
// canvasViewDrawingDidChange (settingDrawing), lassoDrawing neu; den Vergleichsstand fürs Speichern nur, wenn nichts
// ungespeichert ist. Dass es PencilKits Auswahl aufhebt, ist eine Annahme (wie bei `remote`)
order("setDrawing", between(swift, "private func setDrawing(", "// MARK: Werkzeuge"), ["canvas.dismissSelectionMenu()",
  "settingDrawing = true", "canvas.drawing = drawing", "settingDrawing = false", "rebaseLassoDrawing()",
  "guard !dirty else { return }", "baseline = canvas.drawing", "toolUsedSinceSave = false"]);
lines("rebaseLassoDrawing", between(swift, "private func rebaseLassoDrawing(", "/// Wo die Striche liegen"),
  ["guard k > 0 else { return } lassoDrawing = (canvas.drawing, k)"]);
// canvasViewDrawingDidChange (Modell `drawingChanged`): nicht beim Setzen der Zeichnung; sonst ungespeichert, gleich
// abgleichen (syncSoon: in 0,03 s) und in 1 s speichern (ein früher geplantes Speichern entfällt)
order("canvasViewDrawingDidChange", between(swift, "func canvasViewDrawingDidChange(", "func scrollViewDidZoom("),
  ["guard !settingDrawing else { return }", "dirty = true", "localChanged = true", "syncSoon()", "pendingSave?.cancel()",
    "pendingSave = work", "DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)"]);
order("syncSoon", between(swift, "private func syncSoon(", "/// Sync-Stand bald sichern"), ["syncSoonWork?.cancel()",
  "syncSoonWork = work", "DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)"]);
lines("canSync", swift, ["sync.isConfigured && k > 0 && !restructuring && !detached &&"]);
// saveNow (Modell `saveNow`): ohne Werkzeug seit dem letzten Stand mit dem Vergleichsstand als Basis (saveDrawing
// schreibt gleiche Daten nicht), eingefügte fremde Striche immer
order("saveNow", between(swift, "@objc func saveNow(", "@objc private func appWillResignActive("),
  ["pendingSave?.cancel()", "remoteSave?.cancel()", "guard dirty || remoteUnsaved, k > 0 else { return }",
    "let base = dirty && !toolUsedSinceSave ? baseline : nil", "let force = remoteUnsaved", "dirty = false", "remoteUnsaved = false",
    "unlessEqualTo: base, force: force)", "baseline = current", "toolUsedSinceSave = false"]);
lines("saveDrawing", store, ["if let base { same = base.dataRepresentation() == drawing.dataRepresentation() }",
  "let write = !same || force"]);
// pencilNear (Modell `pencilNear`): schwebt über der Fläche oder der Liste, oder schwebte bis vor 0,25 s. Die
// Schwebe-Geste der Fläche nimmt jede Art (keine allowedTouchTypes): auch Maus und Trackpad zählen
lines("Schwebe-Geste", between(swift, "let hover = UIHoverGestureRecognizer(", "appHover = hover"), ["allowedTouchTypes"], 0);
lines("pencilNear", swift, ["private var pencilNear: Bool { pencilHovering || panelHovered || Date().timeIntervalSince(lastHoverEnd) < 0.25 }"]);
order("handleHover", between(swift, "@objc private func handleHover(", "private func rolled("),
  ["pencilHovering = true", "if pencilHovering { lastHoverEnd = Date() }", "pencilHovering = false"]);
// Liste einer Auswahl (Modell `panel`): offen nach dem Menü einer Auswahl; zu nach einer Wahl, wenn der Pencil neben ihr
// aufsetzt, und beim Setzen der Zeichnung (dismissSelectionMenu)
lines("isShowingSelectionPanel", inkView, ["var isShowingSelectionPanel: Bool { panel != nil }"]);
order("Liste: gewählt", between(inkView, "panel.onChoose = {", "panel.onHover ="), ["self.closePanel(animated: true"]);
order("Liste: Berührung daneben", between(inkView, "private func touchDownWhilePanelOpen(", "/// Ein kurzes Tippen endete"),
  ["!panel.bounds.contains(touch.location(in: panel)) else { return }", "closeByTouch(at: touch.location(in: self))"]);
order("dismissSelectionMenu", between(inkView, "func dismissSelectionMenu(", "/// Einmal beim ersten Erzeugen"), ["closePanel(animated: false"]);
const toolApply = between(swift, "private func applyTool(", "private var pausedPencilKitHover");
order("applyTool", toolApply, ["if lasso && !viewOnly {", "if !(canvas.tool is PKLassoTool) {", "canvas.tool = PKLassoTool()",
  "rebaseLassoDrawing()"]);
lines("applyTool", toolApply, ["setDrawing(", "canvas.drawing =", "usingTool", "toolUses", "undoManager"], 0);
order("applyPendingWhenIdle", whenIdle, ["pendingWork?.cancel()", "guard !pending.isEmpty else { return }",
  "guard toolBusy || waitForPages || idWarmup != nil else {", "applyPending()", "return",
  "let work = DispatchWorkItem { [weak self] in self?.applyPendingWhenIdle() }",
  "DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)"]);
order("applyPending", applyP, ["guard !pending.isEmpty, k > 0 else { return }", "pending = RemoteChanges()",
  "for path in infinitiesWaiting where infinityNext[path] == nil { infinityNext[path] = (drawing: canvas.drawing, k: k) }",
  "StrokeCodec.apply(changes, to: canvas.drawing", "setDrawing(result.drawing)", "canvas.undoManager?.removeAllActions()"]);
order("canvasViewDidEndUsingTool", toolEnd, ["usingTool = false", "lastToolEnd = Date()", "applyPendingWhenIdle()"]);
lines("detach", between(swift, "private func detach(", "private func reattach("), ["applyPending()", "saveNow()"]);
order("detach", between(swift, "private func detach(", "private func reattach("), ["applyPending()", "saveNow()",
  "canvas.undoManager?.removeAllActions()"]);
lines("toolBusy", swift, ["private var toolBusy: Bool { usingTool || Date().timeIntervalSince(lastToolEnd) < 0.5 }"]);
lines("toolUses", swift, ["private var usingTool = false { didSet { if usingTool, !oldValue { toolUses += 1 } } }"]);
lines("toolUses", swift, ["toolUses += 1"], 2);
order("Antippen mit dem Radierer", between(swift, "if eraseStart == nil, g.state == .ended {", "usingTool = false"),
  ["toolUses += 1", "eraseStart = canvas.drawing", "erase(at: p)"]);
order("canvasViewDidBeginUsingTool", between(swift, "func canvasViewDidBeginUsingTool(", "func canvasViewDidEndUsingTool("),
  ["usingTool = true", "toolUsedSinceSave = true"]);
order("Radierer setzt auf", between(swift, "@objc private func handleErase(", "case .changed:"), ["case .began:", "usingTool = true",
  "toolUsedSinceSave = true"]);
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
/// Aufbau: etwas Früheres, das hier nichts ändert; `undoStroke`: zuletzt wurde dieser Strich geschrieben. `hover`: Zeiten
/// [von, bis], in denen der Pencil schwebt (über der Fläche oder der Liste einer Auswahl)
function makeState(version, setup) {
  const st = {
    version, now: 0, queue: [], seq: 0, k: K, drawing: clone(setup.drawing || []), pdf: !!setup.pdf,
    sel: setup.sel ? { name: setup.sel.name, ids: new Set(setup.sel.ids), region: { ...setup.sel.region } } : null,
    undo: [], redo: [], undoCalls: 0, toolUses: 0, lassoPaths: 0, lastInfinity: 0, lastLassoEnd: -Infinity, tracking: false,
    lassoStart: null, usingTool: false, lastToolEnd: -Infinity, menuBlockedUntil: -Infinity, left: false,
    waiting: new Set(), next: new Map(), pending: [], pendingWork: 0,
    questions: [], hints: [], menus: [], decisions: [], reverted: [],
    lassoBase: null, undoUnderSel: 0,                            // lassoDrawing; Rückgängig bei bestehender Auswahl
    hover: setup.hover || [], panel: false,                      // Pencil schwebt; Liste einer Auswahl offen
    dirty: false, settingDrawing: false, toolUsedSinceSave: false, remoteUnsaved: false,   // Speichern und Abgleich
    work: 0, pendingSave: 0, remoteSave: 0, syncSoonWork: 0, syncs: [], sent: null, writes: [],
    redrawsPlanned: 0, redraws: [], redrawDrops: [],             // Neuzeichnen nach dem ∞ (redrawAfterInfinity)
    redrawWork: 0, soonRedraws: [],                              // Neuzeichnen von redrawInkSoon (nach dem Drehen)
  };
  st.baseline = clone(st.drawing);                              // beim Öffnen gesetzt (setDrawing), so in der Datei
  st.saved = clone(st.drawing);
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
/// Gezählt wird auch, ob dabei noch PencilKits Auswahl bestand (seit 172 nie: darunter blieb die Seite einmal leer).
/// PencilKit meldet Rückgängig und Wiederholen gleich als Änderung der Zeichnung (im Simulator stand „Zeichnung geändert
/// (Lasso)“ zwischen „∞ entschieden“ und „zurückgenommen“, 28.11.)
const doUndo = (st) => {
  st.undoCalls++; if (st.sel) st.undoUnderSel++; const step = st.undo.pop(); step.undo(); st.redo.push(step); drawingChanged(st);
};
const doRedo = (st) => { const step = st.redo.pop(); step.redo(); st.undo.push(step); drawingChanged(st); };
const clearUndo = (st) => { st.undo = []; st.redo = []; };            // removeAllActions
/// usingTool = true (canvasViewDidBeginUsingTool, Radierer der App); didSet zählt toolUses, wenn das Werkzeug vorher
/// ruhte; seit dem letzten Stand mit einem Werkzeug gearbeitet (toolUsedSinceSave)
const useTool = (st) => { if (!st.usingTool) st.toolUses++; st.usingTool = true; st.toolUsedSinceSave = true; };
/// endLassoSelection: Werkzeug hin und zurück hebt PencilKits Auswahl auf, ohne als Werkzeug zu zählen und ohne
/// Rückgängig; applyTool setzt lassoDrawing auf die Zeichnung von jetzt (rebaseLassoDrawing)
const endLasso = (st) => { st.sel = null; st.lassoBase = clone(st.drawing); };
const at = (st, t, f) => st.queue.push({ t, seq: st.seq++, f });
/// Ein Ablauf endet nach 30 s simulierter Zeit (ein wartendes Neuzeichnen sähe sonst endlos alle 0,5 s nach)
const END = 30;
function runAll(st) {
  while (st.queue.length) {
    st.queue.sort((a, b) => a.t - b.t || a.seq - b.seq);
    const e = st.queue.shift();
    if (e.t > END) { st.queue = []; break; }
    st.now = e.t;
    e.f();
  }
}
const toolBusy = (st) => st.usingTool || st.now - st.lastToolEnd < 0.5;
/// DispatchQueue.main.asyncAfter: vorher mit [weak self] (nach dem Verlassen des Tabs ist die Leinwand weg), jetzt ohne
const later = (st, dt, f) => at(st, st.now + dt, () => { if (!(st.version === "vorher" && st.left)) f(); });
/// pencilNear: schwebt (`hover`), oder schwebte bis vor 0,25 s
const pencilNear = (st) => st.hover.some(([from, until]) => st.now >= from && st.now < until + 0.25);
/// Gleiche Daten wie dataRepresentation (Reihenfolge und alle Werte der Striche)
const sameData = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/// canvasViewDrawingDidChange: nicht beim Setzen der Zeichnung (settingDrawing); sonst ungespeichert, zum Abgleich
/// (syncSoon: 0,03 s später erfasst der Abgleich die Leinwand, Modell `sent`; nach dem Verlassen nicht mehr, canSync)
/// und in 1 s speichern (ein früher geplantes Speichern entfällt)
function drawingChanged(st) {
  if (st.settingDrawing) return;
  st.dirty = true;
  st.syncs.push(st.now);
  const sync = st.syncSoonWork = ++st.work;
  at(st, st.now + 0.03, () => { if (st.syncSoonWork === sync && !st.left) st.sent = clone(st.drawing); });
  const save = st.pendingSave = ++st.work;
  at(st, st.now + 1, () => { if (st.pendingSave === save) saveNow(st); });
}
/// saveNow: ein geplantes Speichern entfällt. Ohne Werkzeug seit dem letzten Stand schreibt es nur, was sich vom
/// Vergleichsstand unterscheidet (saveDrawing), eingefügte fremde Striche immer
function saveNow(st) {
  st.pendingSave = 0;
  st.remoteSave = 0;
  if (!st.dirty && !st.remoteUnsaved) return;
  const base = st.dirty && !st.toolUsedSinceSave ? st.baseline : null;
  const force = st.remoteUnsaved;
  st.dirty = false;
  st.remoteUnsaved = false;
  if (force || !base || !sameData(base, st.drawing)) { st.saved = clone(st.drawing); st.writes.push(st.now); }
  st.baseline = clone(st.drawing);
  st.toolUsedSinceSave = false;
}
/// setDrawing: schließt die Liste einer Auswahl (dismissSelectionMenu); PencilKit meldet die neue Zeichnung, das
/// übergeht canvasViewDrawingDidChange; lassoDrawing neu; den Vergleichsstand nur, wenn nichts ungespeichert ist.
/// Annahme wie bei `remote`: hebt PencilKits Auswahl auf
function setDrawingM(st, d) {
  st.panel = false;
  st.sel = null;
  st.settingDrawing = true;
  st.drawing = d;
  drawingChanged(st);
  st.settingDrawing = false;
  st.lassoBase = clone(st.drawing);
  if (st.dirty) return;
  st.baseline = clone(st.drawing);
  st.toolUsedSinceSave = false;
}
/// redrawAfterInfinity: in 0,5 s. Entfällt, wenn die Leinwand verlassen ist (verdeckt ist hier nicht nachgebildet), wenn
/// seither ein Weg des Lassos fertig ist (lassoPaths) oder schon ein Neuzeichnen von redrawInkSoon ansteht (redrawWork);
/// solange ein Werkzeug arbeitet, der Pencil nah ist, die Liste einer Auswahl offen ist, das Lasso eine Berührung verfolgt
/// (`tracking`) oder deren Ende keine 0,5 s her ist (lastLassoEnd, auch nach Antippen), alle 0,5 s neu; dann redrawInkNow
function redrawAfter(st, path) {
  at(st, st.now + 0.5, () => {
    if (st.left) return st.redrawDrops.push({ t: st.now, why: DROP_LEFT });
    if (st.lassoPaths !== path || st.redrawWork) {
      return st.redrawDrops.push({ t: st.now, why: st.lassoPaths === path ? DROP_OTHER : DROP_PATH });
    }
    if (toolBusy(st) || pencilNear(st) || st.panel || st.tracking || st.now - st.lastLassoEnd < 0.5) return redrawAfter(st, path);
    redrawNow(st, "∞");
  });
}
/// redrawInkSoon ohne waitForPencil (so nach dem Drehen): ein früher geplantes entfällt; in 0,5 s, solange ein Werkzeug
/// arbeitet alle 0,5 s neu, dann redrawInkNow. Bis dahin steht redrawWork
function redrawSoon(st) {
  const mine = st.redrawWork = ++st.work;
  at(st, st.now + 0.5, () => {
    if (st.redrawWork !== mine) return;
    if (toolBusy(st)) return redrawSoon(st);
    redrawNow(st, "bald");
  });
}
/// redrawInkNow: ein ausstehendes redrawInkSoon entfällt (redrawWork leer), dann die Zeichnung leer und wieder dieselbe
/// (zweimal setDrawing; Rückgängig fasst es nicht an). Gezählt (nach dem ∞ in `redraws`, von redrawInkSoon in
/// `soonRedraws`) mit Zeit, der Auswahl, die es dabei aufhebt, und dem, worauf das Neuzeichnen nach dem ∞ wartet
function redrawNow(st, by) {
  (by === "∞" ? st.redraws : st.soonRedraws).push({ t: st.now, sel: st.sel ? st.sel.name : null, busy: toolBusy(st),
    near: pencilNear(st), panel: st.panel, tracking: st.tracking, sinceLasso: st.now - st.lastLassoEnd, left: st.left });
  st.redrawWork = 0;
  const d = st.drawing;
  setDrawingM(st, []);
  setDrawingM(st, d);
}

/// Eine Berührung mit dem Lasso von t0 bis t1 (Seitenpunkte): Antippen („tap“, unter 8 Punkten: kein Weg), ein Weg
/// („path“) oder ein ∞ („inf“, Umriss `match`). `region`: was ein neuer Weg umschließt. Annahmen über PencilKit (wie in
/// Notizen): Beginnt ein Weg in der Auswahl, zieht er sie um Ende − Anfang mit, sie bleibt ausgewählt, Rückgängig kennt
/// das als Letztes (mit `noUndo` nicht: dann nimmt Rückgängig etwas Unbekanntes zurück); sonst wählt er aus, was er
/// umschließt. Antippen der Auswahl fragt nach dem Menü, daneben hebt es sie auf; ein
/// „Ruck“ ist für die App ein Antippen (unter 8 Punkten), zieht aber eine Auswahl ein Stück mit. Das Werkzeug meldet
/// PencilKit vom Aufsetzen bis kurz nach dem Abheben (nicht beim Antippen), das Verschieben als Änderung der Zeichnung.
/// Mit `noTool` meldet es kein Werkzeug: so das Ziehen einer Auswahl laut einer Durchsicht von PencilKit
/// (PKSelectionView); das ∞ und der Ruck, die hier eine Auswahl ziehen, melden wie seit 171 angenommen eins.
/// Das Menü einer Auswahl ist die Liste (`panel`); sie geht zu, sobald der Pencil neben ihr aufsetzt (ging sie dabei auf
/// der Auswahl zu, bleibt PencilKits Menü zu)
function touch(st, t0, t1, o) {
  let drag = false, panelWasOpen = false;
  const tool = o.kind !== "tap" && !o.noTool;
  at(st, t0, () => {
    st.tracking = true;                                           // LassoTracker.touchesBegan → lassoBegan
    panelWasOpen = st.panel;                                      // touchDownWhilePanelOpen
    st.panel = false;
    const start = { drawing: clone(st.drawing), k: st.k };
    st.lassoStart = start;
    if (st.version === "neu") for (const p of st.waiting) if (!st.next.has(p)) st.next.set(p, start);
    drag = o.kind !== "tap" && !!st.sel && inside(st.sel.region, o.from);
    if (tool) useTool(st);                                        // canvasViewDidBeginUsingTool
  });
  at(st, t1, () => {
    st.tracking = false;                                          // LassoTracker.touchesEnded → lassoEnded
    lassoEnded(st, o);
  });
  at(st, t1 + 0.01, () => {
    if (o.kind === "tap" || (o.kind === "nudge" && !drag)) {
      if (st.sel && inside(st.sel.region, o.from)) {
        const shown = st.now >= st.menuBlockedUntil && !panelWasOpen;
        st.menus.push({ t: st.now, sel: st.sel.name, shown });
        if (shown) st.panel = true;
      } else st.sel = null;
    } else if (drag && st.sel) {
      const dx = o.to.x - o.from.x, dy = o.to.y - o.from.y, ids = new Set(st.sel.ids), k = st.k;
      const shift = (f) => { for (const s of st.drawing) if (ids.has(s.id)) { s.x += f * dx * k; s.y += f * dy * k; } };
      shift(1);
      st.sel.region = { ...st.sel.region, x: st.sel.region.x + dx, y: st.sel.region.y + dy };
      if (!o.noUndo) register(st, { undo: () => shift(-1), redo: () => shift(1) });
      drawingChanged(st);
    } else {
      const ids = st.drawing.filter((s) => strokeIn(o.region, s, st.k)).map((s) => s.id);
      st.sel = ids.length ? { name: o.name, ids: new Set(ids), region: { ...o.region } } : null;
    }
  });
  if (tool) at(st, t1 + 0.02, () => { st.usingTool = false; st.lastToolEnd = st.now; applyPendingWhenIdle(st); });
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
    if (undone === true) {
      st.reverted.push({ t: st.now, name: p.name });
      // Seit 181: danach einmal neu zeichnen, ab dem Weg dieses ∞ gezählt (nicht nach dem wiederholten Zurücknehmen)
      st.redrawsPlanned++;
      redrawAfter(st, p.path);
    } else {
      if (newest) st.menuBlockedUntil = -Infinity;
      const back = undone === null && st.toolUses === p.toolUses && canUndo(st) ? "Rückgängig" : "zurückschieben";
      const text = st.version === "neu" ? `${back}, dann die Auswahl aufheben` : "erst die Auswahl aufheben";
      st.hints.push({ t: st.now, name: p.name, text: "∞ hat die Auswahl verschoben – " + text });
      return;
    }
  }
  if (newPath) { if (newest) st.menuBlockedUntil = -Infinity; }
  else { st.menuBlockedUntil = st.now + 0.3; endLasso(st); }    // nach dem Zurücknehmen: Auswahl schon weg
  // askMeaning: im Notizbuch muss unter dem ∞ etwas stehen
  if (!st.pdf && !st.drawing.some((s) => touches(p.match, s, st.k))) return st.hints.push({ t: st.now, name: p.name, text: "Unter dem ∞ steht nichts" });
  st.questions.push({ t: st.now, name: p.name });
}

const samePrints = (a, b) => a.size === b.size && [...a].every(([key, n]) => b.get(key) === n);
/// undoInfinityMove: nicht, solange ein Werkzeug arbeitet oder seit dem Ende des ∞ eins begann (null: nicht versucht,
/// die Auswahl bleibt); sonst erst die Auswahl aufheben, dann Rückgängig (zählt wie ein Werkzeug fürs Speichern). Gilt
/// nur, wenn danach alles wie beim Aufsetzen des ∞ liegt, sonst wiederholt (false; die Auswahl bleibt aufgehoben)
function undoMove(st, p) {
  if (toolBusy(st) || st.toolUses !== p.toolUses || !canUndo(st)) return null;
  st.toolUsedSinceSave = true;
  endLasso(st);
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
  const d = clone(st.drawing);
  for (const change of st.pending) change(d);
  st.pending = [];
  setDrawingM(st, d);
  clearUndo(st);
  // Gespeichert wird höchstens einmal pro Sekunde, dann jedenfalls (remoteUnsaved)
  st.remoteUnsaved = true;
  if (!st.remoteSave) {
    const save = st.remoteSave = ++st.work;
    at(st, st.now + 1, () => { if (st.remoteSave === save) saveNow(st); });
  }
}
/// Tab gewechselt: leave() setzt left, dann detach: Wartendes einfügen, speichern, Rückgängig abräumen. Die Leinwand ist
/// danach weg, außer etwas hält sie
const leave = (st, t) => at(st, t, () => { st.left = true; applyPending(st); saveNow(st); clearUndo(st); });
/// Einsetzen aus PencilKits Menü an einer leeren Stelle: kein Weg des Lassos, kein Werkzeug. Annahmen wie in Notizen:
/// Die eingesetzten Striche sind danach die Auswahl, Rückgängig kennt das Einsetzen, PencilKit meldet die Änderung
function paste(st, t, strokes, region) {
  at(st, t, () => {
    const put = () => { for (const s of strokes) st.drawing.push({ ...s }); };
    put();
    register(st, { undo: () => { for (const s of strokes) removeId(st.drawing, s.id); }, redo: put });
    st.sel = { name: "eingesetzt", ids: new Set(strokes.map((s) => s.id)), region: { ...region } };
    drawingChanged(st);
  });
}
/// In der offenen Liste etwas gewählt, das die Auswahl lässt (etwa Kopieren): Die Liste geht zu (onChoose)
const choose = (st, t) => at(st, t, () => { st.panel = false; });
/// Ein Strich mit dem Stift (nach dem Wechsel vom Lasso; der LassoTracker ist dann aus): PencilKit meldet das Werkzeug
/// vom Aufsetzen bis zum Abheben und übernimmt den Strich kurz danach in die Zeichnung; Rückgängig kennt ihn
function pen(st, t0, t1, stroke) {
  at(st, t0, () => useTool(st));
  at(st, t1, () => { st.usingTool = false; st.lastToolEnd = st.now; applyPendingWhenIdle(st); });
  at(st, t1 + 0.01, () => {
    st.drawing.push({ ...stroke });
    register(st, { undo: () => removeId(st.drawing, stroke.id), redo: () => st.drawing.push({ ...stroke }) });
    drawingChanged(st);
  });
}
/// Drehen (viewDidLayoutSubviews): den Vergleichsstand mit umrechnen, wenn etwas ungespeichert ist, die auf die neue
/// Breite umgerechnete Zeichnung setzen (hebt die Auswahl auf), Rückgängig abräumen, k mit, dann redrawInkSoon
const rotate = (st, t, f) => at(st, t, () => {
  const scaled = (d) => d.map((s) => ({ ...s, x: s.x * f, y: s.y * f, w: s.w * f, h: s.h * f }));
  if (st.dirty) st.baseline = scaled(st.baseline);
  setDrawingM(st, scaled(st.drawing));
  clearUndo(st);
  st.k *= f;
  redrawSoon(st);
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
// Frage geht (im Simulator mit iOS 27 legte PencilKit das Verschieben 13 ms nach dem Ende des Wegs ab, 27.11.). Seit
// 172 fällt die Auswahl vor dem Rückgängig weg: Darunter blieb die Seite im Simulator einmal leer (27.11.)
const selWord = { name: "Lasso vorher", ids: ["w1", "w2", "w3", "w4"], region: { x: 295, y: 395, w: 90, h: 40 } };
const movedHint = (want) => (st) => {
  if (st.questions.length) return `${st.questions.length} Fragen, obwohl Striche verschoben`;
  return st.hints.length === 1 && st.hints[0].text.includes(want) ? "" : `Hinweis: ${st.hints.map((h) => h.text).join(" | ") || "keiner"}`;
};
const withoutHint = (st) => (st.hints.length ? `Hinweis: ${st.hints.map((h) => h.text).join(" | ")}` : "");
const backInPlace = (initial) => (st) => (samePrints(strokePrints(st.drawing, st.k), strokePrints(initial, K)) ? "" : "Striche nicht zurückgeschoben");
const notUnderSel = (st) => (st.undoUnderSel ? "Rückgängig bei noch bestehender Auswahl" : "");
/// Das Lasso zählt ab der Zeichnung von jetzt (lassoDrawing, für selectionInkOnCanvas)
const baseIsNow = (st) => (st.lassoBase && samePrints(strokePrints(st.lassoBase, st.k), strokePrints(st.drawing, st.k)) ? ""
  : "Lasso zählt nicht ab der Zeichnung von jetzt");
add("∞ beginnt in der Auswahl und zieht sie mit: Auswahl weg, dann zurückgenommen, Frage geht", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })),
  all(oneQuestion, withoutHint, backInPlace(word()), (st) => (st.reverted.length === 1 ? "" : `${st.reverted.length}-mal zurückgenommen`),
    (st) => (st.sel ? "Auswahl blieb" : ""), notUnderSel, baseIsNow));
// Seit 181 danach einmal neu gezeichnet (im Simulator mit iOS 27 blieb die Seite nach dem Zurücknehmen beim ersten ∞
// nach dem Booten leer, bis Drehen die Zeichnung neu setzte, 28.11.): frühestens 0,5 s danach, wenn kein Werkzeug
// arbeitet, das Lasso keine Berührung verfolgt und deren Ende 0,5 s her ist, der Pencil nicht nah und keine Liste offen
// ist. Das Neuzeichnen meldet keine Änderung: Abgleich und Speichern kommen vom Zurücknehmen selbst, gleich und wie in 180
const dragInf = (name = "∞") => inf(name, INF, { x: 340, y: 414 }, { x: 346, y: 417 });
const redrawCount = (n) => (st) => (st.redraws.length === n ? "" : `${st.redraws.length}-mal neu gezeichnet statt ${n}-mal`);
const noDrop = (st) => (st.redrawDrops.length ? `Neuzeichnen entfiel ${st.redrawDrops.map((x) => `bei ${x.t.toFixed(2)} s (${x.why})`).join(", ")}` : "");
/// Das i-te Neuzeichnen from bis to s nach dem Ende der letzten Berührung mit dem Lasso (Weg oder Antippen)
const redrawSinceLasso = (from, to, i = 0) => (st) => {
  const r = st.redraws[i];
  return !r || (r.sinceLasso >= from && r.sinceLasso <= to) ? ""
    : `neu gezeichnet ${r.sinceLasso.toFixed(2)} s nach dem Ende der letzten Berührung statt ${from} bis ${to} s`;
};
const redrawNotDuring = (from, to) => (st) => {
  const r = st.redraws.find((x) => x.t >= from && x.t <= to);
  return r ? `neu gezeichnet bei ${r.t.toFixed(2)} s, während der Berührung ${from}–${to} s` : "";
};
/// Neugezeichnet von redrawInkSoon (nach dem Drehen) zu diesen Zeiten
const soonAt = (times) => (st) => (st.soonRedraws.length === times.length && st.soonRedraws.every((r, i) => Math.abs(r.t - times[i]) < 1e-6)
  ? "" : `vom Drehen neu gezeichnet bei ${st.soonRedraws.map((r) => r.t.toFixed(2)).join(", ") || "nie"} statt ${times.join(", ")} s`);
/// Nur die Striche aus `initial` (nach ID) liegen wieder wie dort
const backInPlaceIds = (initial) => (st) => {
  const ids = new Set(initial.map((s) => s.id));
  return samePrints(strokePrints(st.drawing.filter((s) => ids.has(s.id)), st.k), strokePrints(initial, K)) ? "" : "Striche nicht zurückgeschoben";
};
/// Das i-te Neuzeichnen d s nach dem j-ten Zurücknehmen, oder zwischen from und to (Sekunden)
const redrawAfterUndo = (d, i = 0, j = i) => (st) => {
  const r = st.redraws[i], u = st.reverted[j];
  return !r || !u || Math.abs(r.t - u.t - d) < 1e-6 ? "" : `neu gezeichnet ${(r.t - u.t).toFixed(2)} s nach dem Zurücknehmen statt ${d} s`;
};
const redrawBetween = (from, to, i = 0) => (st) => {
  const r = st.redraws[i];
  return !r || (r.t >= from && r.t < to) ? "" : `neu gezeichnet bei ${r.t.toFixed(2)} s statt zwischen ${from} und ${to} s`;
};
const redrawKeepsSel = (st) => {
  const r = st.redraws.find((x) => x.sel);
  return r ? `Neuzeichnen bei ${r.t.toFixed(2)} s hob die Auswahl „${r.sel}“ auf` : "";
};
const redrawQuiet = (st) => (st.redraws.some((r) => st.syncs.includes(r.t)) ? "Neuzeichnen meldete eine Änderung (Abgleich, Speichern)" : "");
const redrawDropped = (why) => (st) => (st.redrawDrops.length === 1 && st.redrawDrops[0].why === why ? ""
  : `Neuzeichnen entfiel ${st.redrawDrops.map((x) => `bei ${x.t.toFixed(2)} s (${x.why})`).join(", ") || "nie"} statt einmal (${why})`);
const syncAtUndo = (st) => (st.reverted.length && st.reverted.every((u) => st.syncs.includes(u.t)) ? "" : "Abgleich nicht gleich beim Zurücknehmen");
const sentAs = (want) => (st) => (st.sent && samePrints(strokePrints(st.sent, st.k), strokePrints(want, K)) ? "" : "Zurückgenommenes nicht abgeglichen");
const savedAs = (want) => (st) => (!st.dirty && samePrints(strokePrints(st.saved, st.k), strokePrints(want, K)) ? "" : "Zurückgenommenes nicht gespeichert");
const writes = (n) => (st) => (st.writes.length === n ? "" : `${st.writes.length}-mal geschrieben statt ${n}-mal`);
const writesAt = (st) => st.writes.map((t) => t.toFixed(2)).join(", ") || "nie";
add("… 0,5 s nach dem Zurücknehmen einmal neu gezeichnet; das Zurückgenommene gleich abgeglichen und gespeichert", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => touch(st, -1, 0, dragInf()),
  all(oneQuestion, backInPlace(word()), (st) => (st.sel ? "Auswahl blieb" : ""), redrawCount(1), redrawAfterUndo(0.5), redrawKeepsSel,
    redrawQuiet, syncAtUndo, sentAs(word()), savedAs(word()), writes(1), baseIsNow));
add("… der Pencil schwebt danach bis 2,5 s: erst danach neu gezeichnet, gespeichert war schon", "falsch",
  { drawing: word(), sel: selWord, canUndo: true, hover: [[0, 2.5]] },
  (st) => touch(st, -1, 0, dragInf()),
  all(oneQuestion, backInPlace(word()), redrawCount(1), redrawBetween(2.75, 3.25), redrawKeepsSel, redrawQuiet, savedAs(word()), writes(1),
    (st) => (sameData(st.baseline, st.drawing) ? "" : "Vergleichsstand nach dem Neuzeichnen nicht die Zeichnung")));
// Gleich danach ein neues Lasso: Seine Auswahl bleibt, das Neuzeichnen entfällt (es höbe sie auf; so das Neuzeichnen
// nach dem Radieren, redrawInkSoon, im Spiegel eines Entwurfs vom 27.11.)
add("… gleich danach (0,7–0,9 s) ein neues Lasso anderswo: seine Auswahl bleibt, das Neuzeichnen entfällt", "falsch",
  { drawing: [...word(), ...word2()], sel: selWord, canUndo: true },
  (st) => {
    touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }));
    touch(st, 0.7, 0.9, { kind: "path", name: "Lasso", region: INF2, from: { x: 90, y: 590 }, to: { x: 92, y: 592 } });
  },
  all(oneQuestion, (st) => (st.reverted.length === 1 && st.reverted[0].t < 0.7 ? "" : "nicht vor dem neuen Lasso zurückgenommen"),
    notUnderSel, (st) => (st.sel && st.sel.name === "Lasso" ? "" : "Auswahl des neuen Lassos fehlt"), redrawCount(0),
    redrawDropped(DROP_PATH)));
add("… das neue Lasso läuft über die Wartezeit (0,95–1,3 s): es wartet, dann entfällt es, die Auswahl bleibt", "falsch",
  { drawing: [...word(), ...word2()], sel: selWord, canUndo: true },
  (st) => {
    touch(st, -1, 0, dragInf());
    touch(st, 0.95, 1.3, { kind: "path", name: "Lasso", region: INF2, from: { x: 90, y: 590 }, to: { x: 92, y: 592 } });
  },
  all(oneQuestion, (st) => (st.sel && st.sel.name === "Lasso" ? "" : "Auswahl des neuen Lassos fehlt"), redrawCount(0),
    redrawDropped(DROP_PATH), (st) => (st.redrawDrops.length && st.redrawDrops[0].t > 1.3 ? "" : "entfiel nicht erst nach dem Lasso")));
// Antippen ist kein Weg (unter 8 Punkten): Das Neuzeichnen entfällt nicht, wartet aber wie das Entscheiden bis 0,5 s
// nach seinem Ende (lastLassoEnd; beim Antippen meldet PencilKit kein Werkzeug) und kommt so erst beim nächsten
// Nachsehen; verfolgt das Lasso beim Nachsehen noch eine Berührung, wartet es auch (isTracking). Ein Ruck zählt hier
// als Werkzeug: dann danach
add("… Antippen daneben in der Wartezeit (0,8–0,85 s, kein Weg): entfällt nicht, neu gezeichnet erst beim nächsten Nachsehen, 0,75 s nach dem Antippen", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 0.8, 0.85, tap(150, 300)); },
  all(oneQuestion, backInPlace(word()), redrawCount(1), redrawAfterUndo(1.0), redrawSinceLasso(0.74, 0.76), redrawKeepsSel, noDrop));
add("… Antippen 0,4 s nach dem Zurücknehmen (1,0–1,05 s, kein Weg): neu gezeichnet 0,5–1,0 s danach, nicht 0,5 s nach dem Zurücknehmen", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 1.0, 1.05, tap(150, 300)); },
  all(oneQuestion, backInPlace(word()), redrawCount(1), redrawSinceLasso(0.5, 1.0),
    (st) => (st.redraws.length && st.reverted.length && Math.abs(st.redraws[0].t - st.reverted[0].t - 0.5) < 1e-6
      ? "neu gezeichnet 0,5 s nach dem Zurücknehmen, gleich nach dem Antippen" : ""), redrawKeepsSel, noDrop));
add("… Antippen über dem ersten Nachsehen (1,05–1,15 s): nicht währenddessen neu gezeichnet, erst 0,5–1,0 s nach seinem Ende", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 1.05, 1.15, tap(150, 300)); },
  all(oneQuestion, backInPlace(word()), redrawCount(1), redrawNotDuring(1.05, 1.15), redrawSinceLasso(0.5, 1.0), noDrop));
add("… ein kurzer Ruck daneben (0,8–0,9 s; kein Weg, aber ein Werkzeug): neu gezeichnet, sobald es ruht", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 0.8, 0.9, { kind: "nudge", from: { x: 150, y: 300 }, to: { x: 152, y: 301 } }); },
  all(oneQuestion, backInPlace(word()), redrawCount(1), redrawBetween(1.42, 1.65), redrawKeepsSel,
    (st) => (st.lassoPaths === 1 ? "" : `${st.lassoPaths} Wege statt 1`)));
// Zum Stift gewechselt, verfolgt das Lasso nichts mehr: Dann hält nur das Werkzeug (toolBusy) das Neuzeichnen auf, bis
// 0,5 s nach dem Strich (hier ohne Schweben, wie an einem iPad ohne diese Erkennung)
add("… dann zum Stift gewechselt und geschrieben (0,9–1,3 s, ohne Schweben): neu gezeichnet beim ersten Nachsehen, nachdem das Werkzeug 0,5 s ruht (2,1 s), der Strich bleibt", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); pen(st, 0.9, 1.3, S("p1", 200, 500, 40, 12, 33)); },
  all(oneQuestion, backInPlaceIds(word()), redrawCount(1), redrawNotDuring(0.9, 1.8), redrawAfterUndo(1.5), noDrop,
    (st) => (st.drawing.some((s) => s.id === "p1") ? "" : "Strich fehlt nach dem Neuzeichnen"),
    (st) => (st.saved.some((s) => s.id === "p1") ? "" : "Strich nicht gespeichert")));
add("… Tab gewechselt 0,2 s nach dem Zurücknehmen: das Neuzeichnen entfällt, das Zurückgenommene beim Verlassen gespeichert", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); leave(st, 0.8); },
  all(oneQuestion, backInPlace(word()), redrawCount(0), redrawDropped(DROP_LEFT), sentAs(word()), savedAs(word()),
    (st) => (st.writes.length === 1 && st.writes[0] === 0.8 ? "" : `geschrieben bei ${writesAt(st)} statt beim Verlassen (0,80 s)`)));
// Das Verschieben war schon gespeichert (Antippen hielt die Entscheidung bis nach 1 s auf), neu gezeichnet wird, bevor
// das Zurückgenommene gespeichert ist: Der Vergleichsstand bleibt der gespeicherte (setDrawing: guard !dirty), das
// Zurückgenommene wird trotzdem geschrieben
add("… Antippen der Auswahl 0,5–0,6 s: Verschobenes schon gespeichert, neu gezeichnet vor dem Speichern, Zurückgenommenes trotzdem geschrieben", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 0.5, 0.6, tap(346, 417)); },
  all(oneQuestion, backInPlace(word()), redrawCount(1), redrawAfterUndo(0.5), redrawQuiet, sentAs(word()), savedAs(word()), writes(2),
    (st) => (st.reverted.length && st.redraws.length && st.writes[0] < st.reverted[0].t && st.redraws[0].t < st.writes[1] ? ""
      : `geschrieben bei ${writesAt(st)}: nicht vor dem Zurücknehmen und nach dem Neuzeichnen`)));
// Grenze des Wächters: Eine Auswahl ohne neuen Weg (Einsetzen aus dem Menü an einer leeren Stelle) hält das Neuzeichnen
// nicht auf. Es wartet, solange der Pencil schwebt und ihre Liste offen ist, und hebt sie danach auf
add("… dann eingesetzt (kein Weg), dessen Liste bis 4,3 s offen: erst danach neu gezeichnet, das hebt die eingesetzte Auswahl auf", "falsch",
  { drawing: word(), sel: selWord, canUndo: true, hover: [[0, 3.2]] },
  (st) => {
    touch(st, -1, 0, dragInf());
    touch(st, 1.5, 1.55, tap(150, 300));                        // PencilKits Menü nur mit Einsetzen (keine Liste)
    paste(st, 2.0, [S("c1", 150, 300, 18, 26, 41), S("c2", 170, 298, 20, 30, 37)], { x: 140, y: 290, w: 60, h: 45 });
    touch(st, 2.6, 2.65, tap(160, 310));                        // Antippen der eingesetzten Auswahl: ihre Liste
    choose(st, 4.3);                                            // etwa Kopieren: die Liste geht zu, die Auswahl bleibt
  },
  all(oneQuestion, redrawCount(1), redrawBetween(4.3, 4.65),
    (st) => (st.menus.some((m) => m.sel === "eingesetzt" && m.shown) ? "" : "Liste der eingesetzten Auswahl ging nicht auf"),
    (st) => (st.redraws.length && st.redraws[0].sel === "eingesetzt" ? "" : "Neuzeichnen traf nicht die eingesetzte Auswahl"),
    (st) => (st.sel ? `Auswahl „${st.sel.name}“ blieb nach dem Neuzeichnen` : ""),
    (st) => (["c1", "c2"].every((id) => st.saved.some((s) => s.id === id)) ? "" : "Eingesetztes nicht gespeichert")));
// Das Ziehen einer Auswahl meldet PencilKit nicht als Werkzeug (`noTool`): Das Neuzeichnen wartet, solange das Lasso die
// Berührung verfolgt, und bis 0,5 s danach. Mit weniger als 8 Punkten ist es kein Weg: Danach kommt das Neuzeichnen
// und hebt die eingesetzte Auswahl auf (Grenze wie oben). So wenige Punkte hat ein Ziehen von fast einer Sekunde nur,
// wenn kaum Lagen gemeldet werden (der LassoTracker zählt jede gemeldete Lage, auch zusammengefasste); sonst ist es ein
// Weg wie im zweiten Ablauf: Das Neuzeichnen entfällt, die Auswahl bleibt
const pasted = () => [S("c1", 150, 300, 18, 26, 41), S("c2", 170, 298, 20, 30, 37)];
const pastedRegion = { x: 140, y: 290, w: 60, h: 45 };
const pasteAndDrag = (o) => (st) => {
  touch(st, -1, 0, dragInf());
  touch(st, 0.62, 0.66, tap(150, 300));                         // PencilKits Menü nur mit Einsetzen
  paste(st, 0.72, pasted(), pastedRegion);
  touch(st, 0.8, 1.7, { from: { x: 160, y: 310 }, noTool: true, ...o });
};
const pastedSavedAt = (dx, dy) => (st) => (pasted().every((p) => {
  const s = st.saved.find((x) => x.id === p.id);
  return s && Math.abs(s.x - p.x - dx * K) < 1e-6 && Math.abs(s.y - p.y - dy * K) < 1e-6;
}) ? "" : "Eingesetztes nicht gezogen gespeichert");
add("… eingesetzt, die eingesetzte Auswahl ein Stück gezogen (0,8–1,7 s, unter 8 Punkten: kein Weg, kein Werkzeug): nicht währenddessen neu gezeichnet, 0,5–1,0 s nach dem Abheben, das hebt die eingesetzte Auswahl auf", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  pasteAndDrag({ kind: "nudge", to: { x: 163, y: 312 } }),
  all(oneQuestion, backInPlaceIds(word()), redrawCount(1), redrawNotDuring(0.8, 1.7), redrawSinceLasso(0.5, 1.0), noDrop,
    (st) => (st.redraws.length && st.redraws[0].sel === "eingesetzt" ? "" : "Neuzeichnen traf nicht die eingesetzte Auswahl"),
    (st) => (st.sel ? `Auswahl „${st.sel.name}“ blieb nach dem Neuzeichnen` : ""), pastedSavedAt(3, 2),
    (st) => (st.toolUses === 1 ? "" : `${st.toolUses} Werkzeuge statt 1 (nur das ∞)`)));
add("… dieselbe Auswahl weiter gezogen (ab 8 Punkten: ein Weg, kein Werkzeug): nicht währenddessen neu gezeichnet, danach entfällt es, die eingesetzte Auswahl bleibt", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  pasteAndDrag({ kind: "path", name: "Ziehen", region: pastedRegion, to: { x: 200, y: 340 } }),
  all(oneQuestion, backInPlaceIds(word()), redrawCount(0), redrawDropped(DROP_PATH),
    (st) => (st.redrawDrops.length && st.redrawDrops[0].t > 1.7 ? "" : "entfiel nicht erst nach dem Ziehen"),
    (st) => (st.sel && st.sel.name === "eingesetzt" ? "" : "eingesetzte Auswahl nicht mehr da"), pastedSavedAt(40, 30)));
add("… und Antippen der Auswahl in der Wartezeit: zurückgenommen, kein Menü", "falsch", { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); touch(st, 0.2, 0.3, tap(346, 417)); },
  all(oneQuestion, withoutHint, backInPlace(word()), noMenuOn("Lasso vorher")));
// Rückgängig nimmt statt des Verschiebens den zuletzt geschriebenen Strich e1 zurück: wiederholen bringt ihn wieder
const withE1 = () => [...word(), S("e1", 200, 300, 20, 10, 30)];
// Die Auswahl ist dann schon aufgehoben; der Hinweis bleibt wie er war (nach dem Zurückschieben mit einem neuen Lasso
// gilt „dann die Auswahl aufheben“ wieder)
add("… Rückgängig kennt das Verschieben nicht: wiederholt, Auswahl bleibt aufgehoben, Hinweis nennt zurückschieben, nicht neu gezeichnet", "falsch",
  { drawing: withE1(), sel: selWord, undoStroke: "e1" },
  (st) => touch(st, -1, 0, { ...inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 }), noUndo: true }),
  all(movedHint("zurückschieben"), redrawCount(0),
    (st) => (st.redrawsPlanned ? "Neuzeichnen geplant, obwohl nicht zurückgenommen" : ""),
    (st) => (st.hints.length && st.hints[0].text === "∞ hat die Auswahl verschoben – zurückschieben, dann die Auswahl aufheben" ? ""
      : `Hinweis nicht genau wie bisher: ${st.hints.map((h) => h.text).join(" | ")}`),
    (st) => (st.sel ? "Auswahl blieb (wird vor dem Rückgängig aufgehoben)" : ""), notUnderSel, baseIsNow,
    (st) => (backInPlace(withE1())(st) ? "" : "Striche zurückgeschoben, obwohl Rückgängig nicht passte"),
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
  all(movedHint("zurückschieben, dann die Auswahl aufheben"), (st) => (st.reverted.length ? "zurückgenommen trotz Ruck" : ""),
    (st) => (st.sel && st.sel.name === "Lasso vorher" ? "" : "Auswahl weg, obwohl nichts versucht")));
add("∞ zieht die Auswahl mit, dann liegt der Pencil 0,4–3,0 s auf ihr: nach 2 s nichts zurückgenommen, Hinweis nennt Rückgängig", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, inf("∞", INF, { x: 340, y: 414 }, { x: 346, y: 417 })); touch(st, 0.4, 3.0, tap(346, 417)); },
  all(movedHint("Rückgängig, dann die Auswahl aufheben"), (st) => (st.undoCalls ? "Rückgängig, während PencilKit die Berührung verfolgte" : ""),
    (st) => (st.sel && st.sel.name === "Lasso vorher" ? "" : "Auswahl weg, obwohl nichts versucht")));
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
add("zweites ∞ auf der frischen Auswahl zieht sie mit: zurückgenommen, beide fragen, einmal neu gezeichnet", "falsch", { drawing: word(), canUndo: true },
  (st) => { touch(st, -1, 0, inf()); touch(st, 0.3, 1.3, inf("zweites ∞", INF, { x: 340, y: 414 }, { x: 347, y: 418 })); },
  all((st) => (st.questions.map((x) => x.name).join(", ") === "∞, zweites ∞" ? "" : `Fragen: ${st.questions.map((x) => x.name).join(", ") || "keine"}`),
    withoutHint, backInPlace(word()), redrawCount(1), redrawAfterUndo(0.5), redrawKeepsSel));
// Zwei ∞ ziehen nacheinander je eine Auswahl mit (dazwischen ein neues Lasso ums Wort): Jedes Zurücknehmen zeichnet
// höchstens einmal neu, 0,5 s danach. Ist das Lasso vor dem ersten Neuzeichnen fertig, entfällt dieses
const lassoWord = { kind: "path", name: "Lasso ums Wort", region: selWord.region, from: { x: 290, y: 390 }, to: { x: 292, y: 392 } };
const questionsAre = (names) => (st) => (st.questions.map((x) => x.name).join(", ") === names ? ""
  : `Fragen: ${st.questions.map((x) => x.name).join(", ") || "keine"}`);
const revertedTimes = (n) => (st) => (st.reverted.length === n ? "" : `${st.reverted.length}-mal zurückgenommen statt ${n}-mal`);
add("∞ zieht die Auswahl mit, nach dem Neuzeichnen ein Lasso ums Wort, ein zweites ∞ zieht es mit: beide zurückgenommen, je einmal neu gezeichnet", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 1.5, 2.0, lassoWord); touch(st, 2.5, 3.5, dragInf("zweites ∞")); },
  all(questionsAre("∞, zweites ∞"), backInPlace(word()), revertedTimes(2), redrawCount(2), redrawAfterUndo(0.5, 0, 0),
    redrawAfterUndo(0.5, 1, 1), redrawKeepsSel, redrawQuiet, savedAs(word())));
add("… das Lasso schon vor dem ersten Neuzeichnen (0,7–0,9 s): dieses entfällt, neu gezeichnet nur nach dem zweiten ∞", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); touch(st, 0.7, 0.9, lassoWord); touch(st, 1.3, 2.3, dragInf("zweites ∞")); },
  all(questionsAre("∞, zweites ∞"), backInPlace(word()), revertedTimes(2), redrawCount(1), redrawAfterUndo(0.5, 0, 1),
    redrawDropped(DROP_PATH), redrawKeepsSel, savedAs(word())));
// Drehen stößt redrawInkSoon an. Steht das beim Nachsehen noch an, entfällt das Neuzeichnen nach dem ∞ (das vom Drehen
// baut ohnehin neu auf); ist es schon erledigt (redrawInkNow leert redrawWork), kommt das nach dem ∞ trotzdem
add("∞ zieht die Auswahl mit, 0,2 s nach dem Zurücknehmen gedreht: das Neuzeichnen nach dem ∞ entfällt (ein anderes steht an), das vom Drehen kommt 0,5 s danach", "falsch",
  { drawing: word(), sel: selWord, canUndo: true },
  (st) => { touch(st, -1, 0, dragInf()); rotate(st, 0.8, 0.75); },
  all(oneQuestion, backInPlace(word()), revertedTimes(1), redrawCount(0), redrawDropped(DROP_OTHER), soonAt([1.3])));
add("gedreht, dann ein Lasso ums Wort und ein ∞, das es mitzieht: das Neuzeichnen vom Drehen war schon fertig, das nach dem ∞ kommt", "falsch",
  { drawing: word(), canUndo: true },
  (st) => { rotate(st, -4, 0.75); touch(st, -3, -2.5, lassoWord); touch(st, -1, 0, dragInf()); },
  all(oneQuestion, backInPlace(word()), revertedTimes(1), redrawCount(1), redrawAfterUndo(0.5), soonAt([-3.5]), noDrop));
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
/// In jedem Ablauf (jetzt): Jedes geplante Neuzeichnen nach dem ∞ kam oder entfiel bis zum Ende, höchstens eins je
/// Zurücknehmen, keins während eines Werkzeugs, unter dem nahen Pencil, bei offener Liste, während das Lasso eine
/// Berührung verfolgte, keine 0,5 s nach deren Ende oder nach dem Verlassen
const redrawRules = (st) => [
  st.redrawsPlanned === st.redraws.length + st.redrawDrops.length ? "" : "Neuzeichnen wartet am Ende noch",
  st.redraws.length <= st.reverted.length ? "" : "öfter neu gezeichnet als zurückgenommen",
  st.redraws.some((r) => r.busy || r.near || r.panel) ? "neu gezeichnet, während ein Werkzeug arbeitete, der Pencil nah oder die Liste offen war" : "",
  st.redraws.some((r) => r.tracking || r.sinceLasso < 0.5) ? "neu gezeichnet, während das Lasso eine Berührung verfolgte oder keine 0,5 s nach ihrem Ende" : "",
  st.redraws.some((r) => r.left) ? "neu gezeichnet nach dem Verlassen" : "",
].filter(Boolean).join("; ");
const rows = [];
let vorherWrong = 0, vorherExpected = 0;
for (const sc of scenarios) {
  const res = {};
  for (const version of ["neu", "vorher"]) {
    const st = makeState(version, sc.setup);
    sc.script(st);
    runAll(st);
    res[version] = sc.check(st);
    if (version === "neu") res.neu = [res.neu, redrawRules(st)].filter(Boolean).join("; ");
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
