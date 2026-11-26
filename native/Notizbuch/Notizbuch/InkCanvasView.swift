import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import ObjectiveC

/// Wo PencilKit das Menü einer Lasso-Auswahl zeigt: `sourcePoint` in den Koordinaten von `space` (PencilKits innere
/// Fläche). „Claude fragen“ prüft damit, ob das Menü zum zuletzt gezogenen Lasso gehört
struct SelectionMenuContext {
    weak var space: UIView?
    let sourcePoint: CGPoint
}

/// Die Schreibfläche: PencilKits Menü nur im Lasso-Modus, und nie mit „Alles auswählen“ oder „Leerzeile einfügen“.
///
/// PencilKit zeigt ein Menü, wenn man die Fläche lange berührt (am iPad etwa mit dem Finger, der eigentlich
/// scrollen will) oder mit dem Lasso auf eine leere Stelle oder eine Auswahl tippt. Dieses Menü baut PencilKits
/// innere Fläche (PKTiledView) selbst, als Delegate ihrer UIEditMenuInteraction; öffentliche Wege (canPerformAction,
/// buildMenu, ein eigener Delegate) erreichen es nicht. Deshalb wird genau diese eine Methode einmal umgeleitet:
/// - Außerhalb des Lasso-Modus (Stift, Radierer, Zeigestift) und im Nur-Sehen-Modus kommt gar kein Menü, auch nicht,
///   wenn kopierte Striche zum Einsetzen bereitliegen.
/// - Mit dem Lasso bleiben Ausschneiden, Kopieren, Löschen, Duplizieren und Einsetzen; im Menü einer Auswahl
///   kommen vorn die Einträge für Claude dazu (`selectionMenuItems`).
/// - Das Menü einer Auswahl zeigt alle Einträge auf einmal, untereinander, in einer eigenen Liste neben der Auswahl
///   (siehe `presentSelectionPanel`): Das Bearbeiten-Menü zeigt seit iPadOS 26 nur etwa drei davon und den Rest hinter
///   einem Pfeil.
/// - „Alles auswählen“ fällt immer weg. Bleibt nichts übrig, kommt kein Menü.
/// - „Leerzeile (oben) einfügen“ fällt anhand von PencilKits eigenen Übersetzungen weg (die Einträge tragen zufällige
///   Kennungen), falls PencilKits Schalter dafür (siehe unten) fehlt.
/// Ändert Apple Klasse, Methode oder Schalter, ist schlimmstenfalls alles wieder wie früher: das Menü und
/// „Leerzeile einfügen“ samt Geste.
///
/// „Leerzeile einfügen“ ist ganz aus: PencilKits eigener Schalter insertSpaceEnabled steuert den Menüeintrag und eine
/// Lasso-Geste ohne Menü (vom äußersten Zehntel einer Seite bis ins äußerste Zehntel der anderen gezogen, fügt sie
/// Platz ein, statt auszuwählen). PencilKit schaltet ihn beim Erzeugen der Fläche ein; hier geht er aus, sobald die
/// Fläche im Fenster ist, also vor der ersten Berührung. Eine eingefügte Leerzeile verschiebt jeden Strich darunter,
/// beim Abgleich ist das für jeden eine Änderung.
final class InkCanvasView: PKCanvasView {
    /// Darf man auf der Fläche bearbeiten (nicht Nur-Sehen)? Setzt CanvasController; ohne Bearbeiten kein Menü.
    /// drawingGestureRecognizer taugt dafür nicht: PencilKit schaltet ihn beim Lasso selbst aus.
    var editingAllowed = true {
        didSet { if !editingAllowed { dismissSelectionMenu() } }
    }
    /// Weitere Einträge vorn im Menü einer Lasso-Auswahl („Claude fragen“); setzt CanvasController
    var selectionMenuItems: ((SelectionMenuContext) -> [UIMenuElement])?
    /// Rechteck des zuletzt gezogenen Lassos in den Koordinaten dieser Fläche (nil: keins). Das Menü einer Auswahl geht
    /// daneben auf statt darüber; setzt CanvasController
    var selectionArea: (() -> CGRect?)?
    /// Bis dahin kein Menü: Gleich nach einem ∞ mit dem Lasso fragt CanvasController Claude selbst
    var menuBlockedUntil = Date.distantPast

    /// Das Menü einer Auswahl mit allen Einträgen, solange es offen ist (siehe presentSelectionPanel)
    private var panel: SelectionMenuPanel?
    /// Wo PencilKit sein Menü zeigen wollte (Mitte oben der Auswahl, in PencilKits innerer Fläche)
    private var panelSource: CGPoint?
    /// Zählt jedes Öffnen und Schließen: Eine Liste, die noch auf ihre Runde wartet, geht danach nicht mehr auf
    private var panelRequest = 0
    /// Eine Berührung neben der Liste hat sie geschlossen: wann, und an welcher Auswahl (siehe presentSelectionPanel)
    private var panelClosedByTouch: (time: Date, source: CGPoint)?
    /// Bemerkt Berührungen im Fenster, solange die Liste offen ist
    private var panelWatcher: PanelTouchWatcher?
    /// Die Auswahl der zuletzt gezeigten Liste ohne Zoom: Mitte oben und ungefähre Fläche. Verschiebt man die Auswahl,
    /// zeigt PencilKit sein Menü an der neuen Stelle, die Fläche wandert dann mit
    private var knownSelection: (source: CGPoint, area: CGRect)?
    /// Breite beim letzten Layout: Dreht sich das Gerät, geht die Liste zu
    private var laidOutWidth: CGFloat = 0

    override init(frame: CGRect) {
        _ = Self.menuHook
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        _ = Self.menuHook
        super.init(coder: coder)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // PencilKit legt seine innere Fläche beim Erzeugen direkt unter diese
        let tiledViews = NSClassFromString("PKTiledView").map { cls in subviews.filter { $0.isKind(of: cls) } } ?? []
        if tiledViews.isEmpty { return Self.debugLog("PKTiledView nicht unter der Fläche") }
        for tiledView in tiledViews { Self.switchOffInsertSpace(tiledView) }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        dismissSelectionMenu()
        if let watcher = panelWatcher {
            watcher.view?.removeGestureRecognizer(watcher)
            panelWatcher = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Die Liste steht fest im Fenster: Nach dem Drehen passte sie nicht mehr zur Auswahl
        guard abs(bounds.width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = bounds.width
        if panel != nil { closePanel(animated: false, reason: "andere Breite") }
    }

    // MARK: Menü einer Auswahl mit allen Einträgen

    /// Zeigt das Menü einer Auswahl mit allen Einträgen auf einmal: vorn `claude`, darunter PencilKits Einträge, je als
    /// Abschnitt, in einer eigenen Liste (SelectionMenuPanel) neben der Auswahl. Menüs von UIKit taugen dafür nicht: Das
    /// Bearbeiten-Menü zeigt nur etwa drei Einträge, und ein Knopf-Menü (Version 161) hält die nächste Berührung fest,
    /// Tippen daneben schloss dann nur das Menü (die Auswahl blieb), und Ziehen verschob die Auswahl nicht (im Simulator
    /// geprüft, 26.11.). Die Liste hält nichts fest: Jede Berührung daneben schließt sie und tut, was sie sonst täte
    /// (Tippen daneben hebt die Auswahl auf, Ziehen verschiebt sie, ein neues Lasso beginnt). Tippen auf die Auswahl
    /// schließt sie, wie PencilKits Menü.
    /// true: PencilKits Bearbeiten-Menü bleibt leer, die Liste geht gleich auf (oder bleibt zu, siehe
    /// panelClosedByTouch). false: das Bearbeiten-Menü wie früher, etwa mit Befehlen (UICommand) darin, die die Liste
    /// nicht ausführen kann, oder wenn sie nicht ganz auf den Bildschirm passt
    fileprivate func presentSelectionPanel(claude: [UIMenuElement], pencilKit: [UIMenuElement], space: UIView,
                                           source: CGPoint) -> Bool {
        let elements: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: claude)] + pencilKit
        guard window != nil, let host = superview, let sections = Self.panelSections(elements), !sections.isEmpty
        else { return false }
        // Tippen auf die Auswahl, während die Liste offen war: Die Berührung hat sie geschlossen, PencilKit fragt nach
        // dem Tippen nach seinem Menü. Es bleibt zu, wie PencilKits eigenes Menü beim Tippen auf die Auswahl
        if let closed = panelClosedByTouch {
            panelClosedByTouch = nil
            if Date().timeIntervalSince(closed.time) < 0.6,
               hypot(source.x - closed.source.x, source.y - closed.source.y) < 4 {
                Self.debugLog("Menü mit allen Einträgen: eben erst zu, bleibt zu")
                return true
            }
        }
        // Schon offen für dieselbe Auswahl
        if panel != nil, let shown = panelSource, hypot(source.x - shown.x, source.y - shown.y) < 1 { return true }
        let region = visibleRegion(in: host)
        let list = SelectionMenuPanel(sections: sections, maxWidth: min(360, max(region.width, 0)))
        guard list.bounds.width <= region.width, list.bounds.height <= region.height else {
            Self.debugLog("Menü mit allen Einträgen passt nicht (\(list.bounds.size) in \(region.size)), "
                          + "Bearbeiten-Menü wie früher")
            return false
        }
        closePanel(animated: false, reason: "neue Auswahl")
        panelRequest += 1
        let request = panelRequest
        Self.debugLog("Menü mit allen Einträgen: "
                      + sections.map { $0.map(\.title).joined(separator: " | ") }.joined(separator: " ‖ "))
        // Erst nach dieser Runde: Dann hat UIKit das leere Bearbeiten-Menü verworfen, und CanvasController kennt den Weg
        // eines Lassos, das eben endete (lassoEnded), für den Platz neben der Auswahl
        DispatchQueue.main.async { [weak self, weak space] in
            guard let self, let space, request == self.panelRequest else { return }
            self.show(list, from: space, source: source)
        }
        return true
    }

    private func show(_ panel: SelectionMenuPanel, from space: UIView, source: CGPoint) {
        guard let host = superview, let window else { return }
        let point = space.convert(source, to: self)
        let area = selectionEstimate(at: point).union(CGRect(origin: point, size: .zero))
        let region = visibleRegion(in: host)
        guard panel.bounds.width <= region.width, panel.bounds.height <= region.height else { return }
        panel.frame = Self.place(panel.bounds.size, near: convert(point, to: host), avoiding: convert(area, to: host),
                                 within: region)
        panel.onChoose = { [weak self, weak panel] action in
            guard let self, let panel, self.panel === panel else { return }
            self.closePanel(animated: true, reason: "gewählt: \(action.title)")
            // Erst danach, wie bei UIKits Menüs
            DispatchQueue.main.async { action.performWithSender(nil, target: nil) }
        }
        host.addSubview(panel)
        self.panel = panel
        panelSource = source
        watchTouches(in: window)
        panel.alpha = 0
        UIView.animate(withDuration: 0.12) { panel.alpha = 1 }
        UIAccessibility.post(notification: .layoutChanged, argument: panel.firstRow)
        Self.debugLog("Menü mit allen Einträgen bei \(panel.frame), Auswahl etwa \(convert(area, to: host))")
        Self.debugLog("Menü mit allen Einträgen geht auf")
    }

    /// Wo die Auswahl ungefähr liegt, deren Menü bei `point` (Mitte oben der Auswahl, Koordinaten dieser Fläche)
    /// aufgehen soll: das zuletzt gezogene Lasso, wenn das Menü an ihm aufgeht; sonst die Auswahl der vorigen Liste,
    /// mitgewandert (verschoben); sonst nur dieser Punkt
    private func selectionEstimate(at point: CGPoint) -> CGRect {
        let z = max(zoomScale, 0.01)
        let unzoomed = CGPoint(x: point.x / z, y: point.y / z)
        if let lasso = selectionArea?(), !lasso.isNull, !lasso.isInfinite,
           lasso.insetBy(dx: -60, dy: -60).contains(point) {
            knownSelection = (unzoomed, lasso.applying(CGAffineTransform(scaleX: 1 / z, y: 1 / z)))
            return lasso
        }
        if let known = knownSelection {
            let moved = known.area.offsetBy(dx: unzoomed.x - known.source.x, dy: unzoomed.y - known.source.y)
            knownSelection = (unzoomed, moved)
            return moved.applying(CGAffineTransform(scaleX: z, y: z))
        }
        return CGRect(origin: point, size: .zero)
    }

    /// Wo die Liste ganz zu sehen ist, in den Koordinaten von `host`: der sichtbare Teil der Fläche unter der Leiste
    /// (sie liegt über dem oberen contentInset) und in der Safe Area, mit etwas Abstand zum Rand
    private func visibleRegion(in host: UIView) -> CGRect {
        let safe = host.safeAreaInsets
        let insets = UIEdgeInsets(top: max(contentInset.top, safe.top), left: safe.left, bottom: safe.bottom,
                                  right: safe.right)
        return convert(bounds, to: host).inset(by: insets).insetBy(dx: 8, dy: 8)
    }

    /// Platz für die Liste (Größe `size`) in `region`: über der Auswahl `area` wie PencilKits Menü (waagrecht mittig zu
    /// `point`), sonst darunter, rechts oder links daneben. Passt sie nirgends ganz daneben, dort, wo sie am wenigsten
    /// von der Auswahl verdeckt. `size` passt in `region`
    private static func place(_ size: CGSize, near point: CGPoint, avoiding area: CGRect, within region: CGRect) -> CGRect {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, region.minX), region.maxX - size.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, region.minY), region.maxY - size.height) }
        let gap: CGFloat = 10
        let x = clampX(point.x - size.width / 2)
        let candidates = [CGPoint(x: x, y: area.minY - gap - size.height),
                          CGPoint(x: x, y: area.maxY + gap),
                          CGPoint(x: area.maxX + gap, y: clampY(area.minY)),
                          CGPoint(x: area.minX - gap - size.width, y: clampY(area.minY))]
            .map { CGRect(origin: $0, size: size) }
        if let free = candidates.first(where: { region.contains($0) }) { return free }
        func covered(_ rect: CGRect) -> CGFloat {
            let common = rect.intersection(area)
            return common.isNull ? 0 : common.width * common.height
        }
        let inside = candidates.map { CGRect(x: clampX($0.minX), y: clampY($0.minY), width: size.width, height: size.height) }
        return inside.min { covered($0) < covered($1) } ?? inside[0]
    }

    /// Die Einträge als Abschnitte der Liste: Jedes Untermenü (auch inline) wird ein Abschnitt, ausgeblendete Einträge
    /// fallen weg. nil bei Einträgen, die die Liste nicht selbst ausführen kann (Befehle, nachgeladene Einträge): Dann
    /// kommt das Bearbeiten-Menü wie früher. Befehle (UICommand) gingen über die Responder-Kette, nicht sicher an
    /// PencilKits Fläche; PencilKits eigene Einträge sind UIActions, Befehle kommen, wenn PencilKit kein Menü baut und
    /// UIKit seine Vorschläge zeigt
    private static func panelSections(_ elements: [UIMenuElement]) -> [[UIAction]]? {
        var sections: [[UIAction]] = []
        var current: [UIAction] = []
        for element in elements {
            if let menu = element as? UIMenu {
                guard let inner = panelSections(menu.children) else { return nil }
                if !current.isEmpty {
                    sections.append(current)
                    current = []
                }
                sections += inner
            } else if let action = element as? UIAction {
                if !action.attributes.contains(.hidden) { current.append(action) }
            } else {
                return nil
            }
        }
        if !current.isEmpty { sections.append(current) }
        return sections
    }

    /// Jede Berührung im Fenster neben der Liste schließt sie, ohne dass die Berührung verloren geht (PanelTouchWatcher)
    private func watchTouches(in window: UIWindow) {
        let watcher = panelWatcher ?? PanelTouchWatcher(target: nil, action: nil)
        watcher.onTouchDown = { [weak self] touches in self?.touchDownWhilePanelOpen(touches) }
        if watcher.view !== window {
            watcher.view?.removeGestureRecognizer(watcher)
            window.addGestureRecognizer(watcher)
        }
        watcher.isEnabled = true
        panelWatcher = watcher
    }

    private func touchDownWhilePanelOpen(_ touches: Set<UITouch>) {
        guard let panel else { return }
        // In der Liste wählt sie selbst
        guard touches.contains(where: { !panel.point(inside: $0.location(in: panel), with: nil) }) else { return }
        panelClosedByTouch = panelSource.map { (time: Date(), source: $0) }
        closePanel(animated: false, reason: "Berührung daneben")
    }

    /// Schließt die Liste, falls sie offen ist, und verwirft eine, die noch auf ihre Runde wartet
    private func closePanel(animated: Bool, reason: String) {
        panelRequest += 1
        guard let panel else { return }
        self.panel = nil
        panelSource = nil
        panel.isUserInteractionEnabled = false
        if animated {
            UIView.animate(withDuration: 0.1, animations: { panel.alpha = 0 }, completion: { _ in panel.removeFromSuperview() })
        } else {
            panel.removeFromSuperview()
        }
        // Der Beobachter ruht bis zur nächsten Liste (nicht mitten in seiner eigenen Berührung abschalten)
        if let watcher = panelWatcher {
            DispatchQueue.main.async { [weak self] in
                if self?.panel == nil { watcher.isEnabled = false }
            }
        }
        Self.debugLog("Menü mit allen Einträgen geht zu (\(reason))")
    }

    /// Schließt das Menü einer Auswahl mit allen Einträgen, falls es offen ist (anderes Werkzeug, Nur-Sehen, Fläche
    /// weg). Kein „eben erst zu“: Ein neues darf gleich wieder aufgehen
    func dismissSelectionMenu() {
        panelClosedByTouch = nil
        closePanel(animated: false, reason: "Werkzeug oder Fläche")
    }

    /// Einmal beim ersten Erzeugen, vor dem ersten Menü
    private static let menuHook: Void = installMenuFilter()

    private static func installMenuFilter() {
        let sel = NSSelectorFromString("editMenuInteraction:menuForConfiguration:suggestedActions:")
        guard let cls = NSClassFromString("PKTiledView") else { return debugLog("PKTiledView fehlt") }
        // Nur die eigene Methode der Klasse (nicht geerbt), mit Objekt-Rückgabe und drei Objekt-Argumenten
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return debugLog("keine Methoden") }
        defer { free(list) }
        guard let method = (0..<Int(count)).map({ list[$0] }).first(where: { method_getName($0) == sel }),
              method_getNumberOfArguments(method) == 5,
              typeIs(method_copyReturnType(method), "@"),
              (2...4).allSatisfy({ typeIs(method_copyArgumentType(method, UInt32($0)), "@") })
        else { return debugLog("Methode fehlt oder hat eine andere Form") }

        // Die Argumente sind optional getippt: UIKit übergibt nie nil, ein nil in einem nicht-optionalen Typ wäre aber
        // in Swift undefiniert
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, NSArray?) -> UIMenu?
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?, NSArray?) -> UIMenu? = { me, interaction, configuration, suggested in
            // Sicherheitsnetz, falls der Schalter beim Erscheinen der Fläche noch nicht zu erreichen war
            switchOffInsertSpace(me)
            // PencilKit baut sein Menü immer, auch wenn es danach nicht erscheint, damit sein Zustand wie sonst ist
            let result = original(me, sel, interaction, configuration, suggested)
            let canvas = enclosingCanvas(of: me)
            let lasso = lassoIsActive(canvas)
            #if DEBUG
            NSLog("InkCanvasView: Menü für %@ über %@, Lasso: %@", "\(type(of: me))",
                  interaction.map { "\(type(of: $0))" } ?? "nil", lasso ? "ja" : "nein")
            #endif
            // Außerhalb des Lasso-Modus gehört ein langer Finger zum Scrollen: kein Menü
            guard lasso else { return UIMenu(children: []) }
            // Gleich nach einem ∞ auch nicht (PencilKit hat seines oben trotzdem gebaut, sein Zustand ist wie sonst)
            if let ink = canvas as? InkCanvasView, Date() < ink.menuBlockedUntil { return UIMenu(children: []) }
            // Ohne Menü von PencilKit zeigt UIKit die vorgeschlagenen Einträge: dieselben Regeln für diese
            let base = result?.children ?? ((suggested as? [UIMenuElement]) ?? [])
            let removed = filtered(base)
            var kept = removed ?? base
            // Menü einer Auswahl (nicht nur „Einsetzen“ auf einer leeren Stelle): vorn „Claude fragen“. Das gilt auch,
            // wenn PencilKit kein eigenes Menü baut und UIKit seine Vorschläge zeigt
            var extra: [UIMenuElement] = []
            let space = (interaction as? UIEditMenuInteraction)?.view ?? (me as? UIView)
            let point = (configuration as? UIEditMenuConfiguration)?.sourcePoint ?? .zero
            // UIKit prüft seine Vorschläge an der Stelle des Menüs: ab der Ansicht dort (sie liegt in PencilKits Fläche)
            let checked = space?.hitTest(point, with: nil) ?? space
            if let ink = canvas as? InkCanvasView, let make = ink.selectionMenuItems, isSelectionMenu(kept, shownFrom: checked) {
                extra = make(SelectionMenuContext(space: space, sourcePoint: point))
                #if DEBUG
                NSLog("InkCanvasView: Auswahl-Menü, Quelle %@ in %@", "\(point)", space.map { "\(type(of: $0))" } ?? "nil")
                #endif
            }
            // Menü einer Auswahl: alle Einträge auf einmal in einer eigenen Liste (siehe presentSelectionPanel)
            if !extra.isEmpty, let ink = canvas as? InkCanvasView, let space,
               ink.presentSelectionPanel(claude: extra, pencilKit: kept, space: space, source: point) {
                return UIMenu(children: [])
            }
            // Nichts geändert: PencilKits Menü wie es ist (oder nil: UIKit zeigt seine Vorschläge)
            if removed == nil, extra.isEmpty { return result }
            if result == nil { debugLog("PencilKit gab kein Menü zurück") }
            if !extra.isEmpty { kept.insert(UIMenu(title: "", options: .displayInline, children: extra), at: 0) }
            if kept.isEmpty { return UIMenu(children: []) }
            return result?.replacingChildren(kept) ?? UIMenu(children: kept)
        }
        let previous = method_setImplementation(method, imp_implementationWithBlock(replacement))
        assert(previous == originalIMP)
    }

    private static func typeIs(_ type: UnsafeMutablePointer<CChar>?, _ expected: String) -> Bool {
        guard let type else { return false }
        defer { free(type) }
        return String(cString: type) == expected
    }

    /// Schaltet PencilKits Schalter für „Leerzeile einfügen“ aus, wenn es ihn gibt und er an ist. PencilKit schaltet
    /// ihn nur beim Erzeugen der Fläche ein. Ohne Getter würde value(forKey:) abstürzen
    private static func switchOffInsertSpace(_ tiledView: AnyObject) {
        guard tiledView.responds(to: NSSelectorFromString("insertSpaceEnabled")),
              tiledView.responds(to: NSSelectorFromString("setInsertSpaceEnabled:")),
              (tiledView.value(forKey: "insertSpaceEnabled") as? Bool) == true
        else { return }
        tiledView.setValue(false, forKey: "insertSpaceEnabled")
        debugLog("Leerzeile einfügen abgeschaltet")
    }

    /// Die Fläche, zu der PencilKits innere Ansicht gehört
    private static func enclosingCanvas(of tiledView: AnyObject) -> PKCanvasView? {
        var view = (tiledView as? UIView)?.superview
        while let current = view, !(current is PKCanvasView) { view = current.superview }
        return view as? PKCanvasView
    }

    /// Steht die Fläche im Lasso-Modus, und darf man darauf bearbeiten? Findet sich keine Fläche, wird nur
    /// gefiltert, wie im Lasso-Modus.
    private static func lassoIsActive(_ canvas: PKCanvasView?) -> Bool {
        guard let canvas else {
            debugLog("keine Fläche über PKTiledView")
            return true
        }
        return canvas.tool is PKLassoTool && ((canvas as? InkCanvasView)?.editingAllowed ?? true)
    }

    /// Menü einer Auswahl (Ausschneiden, Kopieren, Löschen, Duplizieren …) statt nur „Einsetzen“: zählt die Einträge,
    /// die erscheinen (ohne die ausgeblendeten), statt Titel zu vergleichen, gilt also in jeder Sprache
    private static func isSelectionMenu(_ elements: [UIMenuElement], shownFrom view: UIView?) -> Bool {
        shownCount(elements, from: view) >= 3
    }

    /// PencilKits eigene Einträge (UIActions) erscheinen immer. Befehle (UICommand, etwa UIKits Vorschläge, wenn
    /// PencilKit kein Menü baut) zeigt UIKit nur, wenn die Fläche oder jemand über ihr sie gerade ausführen kann;
    /// Ausschneiden und Kopieren also nur mit einer Auswahl. Ohne diese Prüfung sähe jeder lange Finger auf einer
    /// leeren Stelle wie eine Auswahl aus
    private static func shownCount(_ elements: [UIMenuElement], from view: UIView?) -> Int {
        elements.reduce(0) { n, element in
            if let menu = element as? UIMenu { return n + shownCount(menu.children, from: view) }
            guard let command = element as? UICommand else { return n + 1 }
            return n + (view?.target(forAction: command.action, withSender: command) != nil ? 1 : 0)
        }
    }

    /// Die Einträge ohne „Alles auswählen“ und „Leerzeile (oben) einfügen“, auch in Untermenüs; leer gewordene
    /// Untermenüs fallen weg. nil, wenn nichts wegfällt
    private static func filtered(_ elements: [UIMenuElement]) -> [UIMenuElement]? {
        var changed = false
        let kept = elements.compactMap { element -> UIMenuElement? in
            if let menu = element as? UIMenu {
                guard let children = filtered(menu.children) else { return menu }
                changed = true
                return children.isEmpty ? nil : menu.replacingChildren(children)
            }
            if isHidden(element) {
                changed = true
                return nil
            }
            return element
        }
        return changed ? kept : nil
    }

    /// PencilKits Einträge sind UIActions mit zufälliger Kennung, daher zählt ihr Titel; Befehle zählen am Selektor
    private static func isHidden(_ element: UIMenuElement) -> Bool {
        if let action = element as? UIAction { return hiddenTitles.contains(action.title) }
        if let command = element as? UICommand {
            return command.action == #selector(UIResponderStandardEditActions.selectAll(_:))
                || NSStringFromSelector(command.action).lowercased().contains("insertspace")
        }
        return false
    }

    /// „Alles auswählen“, „Leerzeile einfügen“ und „Leerzeile oben einfügen“, so wie PencilKit sie selbst übersetzt
    /// (Schlüssel aus PencilKit.framework/…/Localizable.strings)
    private static let hiddenTitles: Set<String> = Set(["Select All", "Insert Space", "Insert Space Above"].map {
        Bundle(for: PKCanvasView.self).localizedString(forKey: $0, value: $0, table: "Localizable")
    })

    private static func debugLog(_ text: String) {
        #if DEBUG
        NSLog("InkCanvasView: %@", text)
        #endif
    }
}

/// Das Menü einer Auswahl mit allen Einträgen (InkCanvasView.presentSelectionPanel): Abschnitte untereinander, je
/// Eintrag eine Zeile mit Titel und Symbol wie in UIKits Menüs. Es liegt in der Ansicht über der Fläche, nicht in ihr:
/// PencilKits Gesten (Lasso, Schreiben, Scrollen) sehen keine Berührung darin
private final class SelectionMenuPanel: UIView {
    /// Ein Eintrag wurde angetippt
    var onChoose: ((UIAction) -> Void)?
    /// Für Bedienungshilfen: Dorthin springt der Fokus, wenn die Liste aufgeht
    private(set) var firstRow: UIView?

    init(sections: [[UIAction]], maxWidth: CGFloat) {
        super.init(frame: .zero)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 4)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, section) in sections.enumerated() {
            if index > 0 { stack.addArrangedSubview(Self.line(height: 8, alpha: 0.08)) }
            for (row, action) in section.enumerated() {
                if row > 0 { stack.addArrangedSubview(Self.line(height: 0.5, alpha: 0.18)) }
                let button = SelectionMenuRow(action)
                button.addAction(UIAction { [weak self] _ in self?.onChoose?(action) }, for: .touchUpInside)
                stack.addArrangedSubview(button)
                if firstRow == nil { firstRow = button }
            }
        }
        // Gemessen, solange die Liste noch für sich steht (ohne Bindung an die noch leere Ansicht): so breit wie der
        // längste Eintrag (mindestens 220, höchstens maxWidth), so hoch wie alle zusammen
        let natural = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        let width = ceil(min(max(natural, 220), maxWidth))
        let height = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel).height
        frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))

        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        background.layer.cornerRadius = Self.cornerRadius
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        background.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    private static let cornerRadius: CGFloat = 14

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
    }

    private static func line(height: CGFloat, alpha: CGFloat) -> UIView {
        let line = UIView()
        line.backgroundColor = UIColor.label.withAlphaComponent(alpha)
        line.heightAnchor.constraint(equalToConstant: height).isActive = true
        return line
    }
}

/// Eine Zeile der Liste: Titel vorn, Symbol hinten, wie in UIKits Menüs. Ein Knopf, damit UIKit sie als einen
/// behandelt (Bedienungshilfen, Antippen)
private final class SelectionMenuRow: UIButton {
    init(_ action: UIAction) {
        super.init(frame: .zero)
        let enabled = !action.attributes.contains(.disabled)
        let color: UIColor = !enabled ? .tertiaryLabel : action.attributes.contains(.destructive) ? .systemRed : .label
        let title = UILabel()
        title.text = action.title
        title.font = UIFont.preferredFont(forTextStyle: .body)
        title.adjustsFontForContentSizeCategory = true
        title.lineBreakMode = .byTruncatingTail
        title.textColor = color
        let icon = UIImageView(image: action.image)
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        for view in [title, icon] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 11),
            title.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -11),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 16),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
        ])
        isEnabled = enabled
        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.12) : .clear }
    }
}

/// Bemerkt den Beginn jeder Berührung im Fenster, solange das Menü einer Auswahl offen ist, und schlägt sofort fehl:
/// hält nichts auf, verzögert nichts, bricht nichts ab (wie der Beobachter von KeepAwake). So schließt eine Berührung
/// neben der Liste sie und tut trotzdem, was sie sonst täte
private final class PanelTouchWatcher: UIGestureRecognizer {
    var onTouchDown: ((Set<UITouch>) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchDown?(touches)
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
