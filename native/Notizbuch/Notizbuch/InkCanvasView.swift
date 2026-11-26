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
        didSet { if !editingAllowed { dismissSelectionMenu("Nur-Sehen") } }
    }
    /// Weitere Einträge vorn im Menü einer Lasso-Auswahl („Claude fragen“); setzt CanvasController
    var selectionMenuItems: ((SelectionMenuContext) -> [UIMenuElement])?
    /// Rechteck des zuletzt gezogenen Lassos in den Koordinaten dieser Fläche, und ob die Tinte darunter noch dieselbe ist
    /// (nil: keins). Das Menü einer Auswahl geht daneben auf statt darüber; setzt CanvasController
    var selectionArea: (() -> (rect: CGRect, unchanged: Bool)?)?
    /// Der Pencil schwebt über der Liste einer Auswahl (true) oder nicht mehr (false). Die Liste liegt neben der Fläche,
    /// deren Schwebe-Geste dort endet; CanvasController hält die Seite dann trotzdem fest (Handballen)
    var onPanelHover: ((Bool) -> Void)?
    /// Bis dahin kein Menü: Gleich nach einem ∞ mit dem Lasso fragt CanvasController Claude selbst
    var menuBlockedUntil = Date.distantPast

    /// Das Menü einer Auswahl mit allen Einträgen, solange es offen ist (siehe presentSelectionPanel)
    private var panel: SelectionMenuPanel?
    /// Wo PencilKit sein Menü zeigen wollte (Mitte oben der Auswahl, in PencilKits innerer Fläche)
    private var panelSource: CGPoint?
    /// Wohin die offene Liste gehört, in den Koordinaten dieser Fläche: Mitte oben der Auswahl und ihre ungefähre Fläche
    /// (zum neu Legen, wenn die Tastatur kommt oder geht), dazu wo eine Berührung als auf der Auswahl zählt (die Fläche
    /// samt dem Lasso daran: PencilKit nimmt Tippen in dessen Rand als Tippen auf die Auswahl)
    private var panelAnchor: (point: CGPoint, area: CGRect, touchArea: CGRect)?
    /// Zählt jedes Öffnen und Schließen: Eine Liste, die noch auf ihre Runde wartet, geht danach nicht mehr auf
    private var panelRequest = 0
    /// Eine Berührung auf der Auswahl hat die Liste geschlossen: wann, und an welcher Auswahl (siehe presentSelectionPanel)
    private var panelClosedByTouch: (time: Date, source: CGPoint)?
    /// Bemerkt Berührungen im Fenster, solange die Liste offen ist
    private var panelWatcher: PanelTouchWatcher?
    /// Die Auswahl der zuletzt gezeigten Liste ohne Zoom: Mitte oben und ungefähre Fläche. Verschiebt man die Auswahl,
    /// zeigt PencilKit sein Menü an der neuen Stelle, die Fläche wandert dann mit
    private var knownSelection: (source: CGPoint, area: CGRect)?
    /// Größe beim letzten Layout: Dreht sich das Gerät oder ändert sich das Fenster, geht die Liste zu
    private var laidOutSize = CGSize.zero
    /// Wohin die Bildschirmtastatur zuletzt wollte (Bildschirmkoordinaten). Sie liegt in einem eigenen Fenster und ändert
    /// weder diese Fläche noch ihre Safe Area (die Leinwand reicht unter sie)
    private var keyboardFrame: CGRect?

    override init(frame: CGRect) {
        _ = Self.menuHook
        super.init(frame: frame)
        watchKeyboard()
    }

    required init?(coder: NSCoder) {
        _ = Self.menuHook
        super.init(coder: coder)
        watchKeyboard()
    }

    private func watchKeyboard() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    /// Die Tastatur kommt, geht oder ändert sich (auch Ein- und Ausblenden): die offene Liste neu legen
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        keyboardFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        if panel != nil { placePanelAgain() }
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
        // Die Liste steht fest im Fenster: Nach dem Drehen oder mit einer anderen Fenstergröße passte sie nicht mehr zur
        // Auswahl
        guard abs(bounds.width - laidOutSize.width) > 0.5 || abs(bounds.height - laidOutSize.height) > 0.5 else { return }
        laidOutSize = bounds.size
        if panel != nil { closePanel(animated: false, reason: "andere Größe") }
    }

    // MARK: Menü einer Auswahl mit allen Einträgen

    /// Zeigt das Menü einer Auswahl mit allen Einträgen auf einmal: vorn `claude`, darunter PencilKits Einträge, je als
    /// Abschnitt, in einer eigenen Liste (SelectionMenuPanel) neben der Auswahl. Menüs von UIKit taugen dafür nicht: Das
    /// Bearbeiten-Menü zeigt nur etwa drei Einträge, und ein Knopf-Menü (Version 161) hält die nächste Berührung fest,
    /// Tippen daneben schloss dann nur das Menü (die Auswahl blieb), und Ziehen verschob die Auswahl nicht (im Simulator
    /// geprüft, 26.11.). Die Liste hält nichts fest: Eine Berührung daneben schließt sie und tut, was sie sonst täte
    /// (Tippen daneben hebt die Auswahl auf, Ziehen verschiebt sie, ein neues Lasso beginnt). Am iPad gilt das für den
    /// Pencil; ein Finger oder der aufliegende Handballen schließt sie erst mit einem kurzen Tippen oder wenn die Seite
    /// zu scrollen beginnt (siehe touchDownWhilePanelOpen). Tippen auf die Auswahl schließt sie, wie PencilKits Menü.
    /// true: PencilKits Bearbeiten-Menü bleibt leer, die Liste geht gleich auf (oder bleibt zu, siehe
    /// panelClosedByTouch). false: das Bearbeiten-Menü wie früher, etwa mit Befehlen (UICommand) darin, die die Liste
    /// nicht ausführen kann, oder wenn sie nicht ganz auf den Bildschirm passt. `menu`: PencilKits Bearbeiten-Menü;
    /// `target`: wohin es nach PencilKit zeigen soll (in `space`), siehe selectionEstimate
    fileprivate func presentSelectionPanel(claude: [UIMenuElement], pencilKit: [UIMenuElement], space: UIView,
                                           source: CGPoint, menu: UIEditMenuInteraction?, target: CGRect?) -> Bool {
        let elements: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: claude)] + pencilKit
        guard window != nil, let host = superview, let sections = Self.panelSections(elements), !sections.isEmpty
        else { return false }
        // UIKit bekommt ein leeres Bearbeiten-Menü. Hält es das für offen, schließt das nächste Tippen auf die Auswahl
        // nur dieses, statt nach einem neuen zu fragen (Simulator, 26.11.: nach „bleibt zu“ öffnete erst das zweite
        // Tippen die Liste wieder). Gleich danach zu: Dann fragt PencilKit bei jedem Tippen auf die Auswahl
        func handled() -> Bool {
            Self.dismissSoon(menu)
            return true
        }
        // Tippen auf die Auswahl, während die Liste offen war: Die Berührung hat sie geschlossen, PencilKit fragt nach
        // dem Tippen nach seinem Menü (etwas später, wenn es auf ein zweites Tippen wartet). Es bleibt zu, wie
        // PencilKits eigenes Menü beim Tippen auf die Auswahl
        if let closed = panelClosedByTouch {
            panelClosedByTouch = nil
            if Date().timeIntervalSince(closed.time) < 1,
               hypot(source.x - closed.source.x, source.y - closed.source.y) < 4 {
                Self.debugLog("Menü mit allen Einträgen: eben erst zu, bleibt zu")
                return handled()
            }
        }
        // Schon offen für dieselbe Auswahl
        if panel != nil, let shown = panelSource, hypot(source.x - shown.x, source.y - shown.y) < 1 { return handled() }
        let region = visibleRegion(in: host)
        // Breiter, wo Platz ist: Mit großer Schrift würden die Einträge sonst abgeschnitten, bis zwei gleich aussehen
        let list = SelectionMenuPanel(sections: sections,
                                      maxWidth: min(region.width >= 700 ? 520 : 360, max(region.width, 0)))
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
            self.show(list, from: space, source: source, target: target)
        }
        return handled()
    }

    /// PencilKit zeigt ein anderes Menü als die Liste (etwa nur „Einsetzen“ an einer leeren Stelle, oder das
    /// Bearbeiten-Menü, weil die Liste nicht passt): Die Auswahl der offenen Liste ist dann weg oder eine andere
    fileprivate func editMenuWillShow() {
        if panel != nil { dismissSelectionMenu("anderes Menü") }
    }

    private func show(_ panel: SelectionMenuPanel, from space: UIView, source: CGPoint, target: CGRect?) {
        guard let host = superview, let window else { return }
        let point = space.convert(source, to: self)
        // Einmal pro Liste: Dafür wird die ganze Tinte durchgesehen
        let lasso = selectionArea?()
        let estimate = selectionEstimate(at: point, target: target.map { space.convert($0, to: self) }, lasso: lasso)
        let area = estimate.area.union(CGRect(origin: point, size: .zero))
        var touchArea = area
        // Nur ein Lasso, unter dem noch dieselbe Tinte liegt: Nach einem Verschieben liegt es, wo die Auswahl vorher war
        if let lasso, lasso.unchanged, !lasso.rect.isNull, !lasso.rect.isInfinite,
           lasso.rect.insetBy(dx: -60, dy: -60).contains(point) {
            touchArea = touchArea.union(lasso.rect)
        }
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
        panel.onHover = { [weak self] hovering in self?.onPanelHover?(hovering) }
        panel.onEscape = { [weak self] in self?.dismissSelectionMenu("VoiceOver") }
        // Am iPad zeichnet nur der Pencil: Schwebt er über der Liste, ist ein Finger darauf fast immer der Handballen
        panel.palmGuard = drawingPolicy == .pencilOnly
        host.addSubview(panel)
        self.panel = panel
        panelSource = source
        panelAnchor = (point, area, touchArea)
        watchTouches(in: window)
        panel.alpha = 0
        UIView.animate(withDuration: 0.12) { panel.alpha = 1 }
        UIAccessibility.post(notification: .layoutChanged, argument: panel.firstRow)
        Self.debugLog("Menü mit allen Einträgen bei \(panel.frame), Auswahl etwa \(convert(area, to: host)) "
                      + "(\(estimate.kind))")
        Self.debugLog("Menü mit allen Einträgen geht auf")
    }

    /// Ist die Liste einer Auswahl gerade offen?
    var isShowingSelectionPanel: Bool { panel != nil }

    /// Ein neues Lasso wurde gezogen (CanvasController): Die Auswahl der vorigen Liste taugt nicht mehr als Schätzung.
    /// Begann sein Weg auf ihr (`start`, Koordinaten dieser Fläche), hat er sie nur verschoben (ein Zug mit etwas Bogen
    /// hat auch eine Fläche): Dann wandert sie mit
    func forgetSelection(unlessStartingAt start: CGPoint) {
        let z = max(zoomScale, 0.01)
        if let known = knownSelection,
           known.area.applying(CGAffineTransform(scaleX: z, y: z)).insetBy(dx: -24, dy: -24).contains(start) { return }
        knownSelection = nil
    }

    /// Wo die Auswahl ungefähr liegt, deren Menü bei `point` (Mitte oben der Auswahl, Koordinaten dieser Fläche)
    /// aufgehen soll, der Reihe nach: PencilKits eigene Angabe `target`, wenn sie zum Punkt passt; das zuletzt gezogene
    /// Lasso, wenn die Tinte darunter dieselbe ist und das Menü an ihm aufgeht; die Auswahl der vorigen Liste,
    /// mitgewandert (verschoben); ein Rechteck so groß wie das Lasso, oben mittig am Punkt (die Auswahl wurde verschoben
    /// oder dupliziert, bevor eine Liste aufging); sonst nur dieser Punkt. `lasso`: was selectionArea lieferte.
    /// `kind` fürs Protokoll
    private func selectionEstimate(at point: CGPoint, target: CGRect?,
                                   lasso: (rect: CGRect, unchanged: Bool)?) -> (area: CGRect, kind: String) {
        let z = max(zoomScale, 0.01)
        let unzoomed = CGPoint(x: point.x / z, y: point.y / z)
        func remembered(_ rect: CGRect, _ kind: String) -> (area: CGRect, kind: String) {
            knownSelection = (unzoomed, rect.applying(CGAffineTransform(scaleX: 1 / z, y: 1 / z)))
            return (rect, kind)
        }
        // Der Punkt ist die Mitte oben der Auswahl: Eine Angabe, deren Oberkante nicht dort liegt, gehört nicht dazu
        if let target, !target.isNull, !target.isInfinite, target.width >= 1, target.height >= 1,
           abs(target.minY - point.y) <= 40, point.x >= target.minX - 40, point.x <= target.maxX + 40 {
            return remembered(target, "von PencilKit")
        }
        if let lasso, lasso.unchanged, !lasso.rect.isNull, !lasso.rect.isInfinite,
           lasso.rect.insetBy(dx: -60, dy: -60).contains(point) {
            return remembered(lasso.rect, "Lasso")
        }
        if let known = knownSelection {
            let moved = known.area.offsetBy(dx: unzoomed.x - known.source.x, dy: unzoomed.y - known.source.y)
            knownSelection = (unzoomed, moved)
            return (moved.applying(CGAffineTransform(scaleX: z, y: z)), "vorige Liste, mitgewandert")
        }
        if let lasso, !lasso.rect.isNull, !lasso.rect.isInfinite {
            let size = lasso.rect.size
            return (CGRect(x: point.x - size.width / 2, y: point.y, width: size.width, height: size.height),
                    "so groß wie das Lasso")
        }
        return (CGRect(origin: point, size: .zero), "nur der Punkt")
    }

    /// Wo die Liste ganz zu sehen ist, in den Koordinaten von `host`: der sichtbare Teil der Fläche unter der Leiste
    /// (sie liegt über dem oberen contentInset), in der Safe Area und über einer angedockten Bildschirmtastatur, mit
    /// etwas Abstand zum Rand
    private func visibleRegion(in host: UIView) -> CGRect {
        let safe = host.safeAreaInsets
        let insets = UIEdgeInsets(top: max(contentInset.top, safe.top), left: safe.left, bottom: safe.bottom,
                                  right: safe.right)
        var region = convert(bounds, to: host).inset(by: insets)
        // Angedockt: unten, über (fast) die ganze Breite. Eine schwebende kleine Tastatur zählt nicht, eine versteckte
        // liegt unter dem Bildschirm
        if let keyboard = keyboardFrame, let screen = window?.windowScene?.screen {
            let covered = host.convert(keyboard, from: screen.coordinateSpace)
            if covered.minY < region.maxY, covered.maxY >= region.maxY, covered.width >= region.width / 2 {
                region.size.height = max(0, covered.minY - region.minY)
            }
        }
        return region.insetBy(dx: 8, dy: 8)
    }

    /// Die Tastatur kam, ging oder wurde anders: die offene Liste neu legen, oder schließen, wenn sie nicht mehr ganz zu
    /// sehen wäre
    private func placePanelAgain() {
        guard let panel, let anchor = panelAnchor, let host = superview else { return }
        let region = visibleRegion(in: host)
        guard panel.bounds.width <= region.width, panel.bounds.height <= region.height else {
            return closePanel(animated: true, reason: "Tastatur, kein Platz mehr")
        }
        let frame = Self.place(panel.bounds.size, near: convert(anchor.point, to: host),
                               avoiding: convert(anchor.area, to: host), within: region)
        guard frame != panel.frame else { return }
        Self.debugLog("Menü mit allen Einträgen neu bei \(frame) (Tastatur)")
        UIView.animate(withDuration: 0.25) { panel.frame = frame }
    }

    /// Platz für die Liste (Größe `size`) in `region`: über der Auswahl `area` wie PencilKits Menü (waagrecht mittig zu
    /// `point`), sonst darunter, rechts oder links daneben. Passt sie nirgends ganz daneben, dort, wo sie am wenigsten
    /// von der Auswahl verdeckt; dieselben Plätze an den Rand geschoben oder in die Ecken nur, wenn sie deutlich weniger
    /// verdecken (sonst spränge die Liste für ein paar Punkte weit weg). `size` passt in `region`
    private static func place(_ size: CGSize, near point: CGPoint, avoiding area: CGRect, within region: CGRect) -> CGRect {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, region.minX), region.maxX - size.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, region.minY), region.maxY - size.height) }
        let gap: CGFloat = 10
        let x = clampX(point.x - size.width / 2)
        let above = area.minY - gap - size.height, below = area.maxY + gap
        let right = area.maxX + gap, left = area.minX - gap - size.width
        let candidates = [CGPoint(x: x, y: above), CGPoint(x: x, y: below),
                          CGPoint(x: right, y: clampY(area.minY)), CGPoint(x: left, y: clampY(area.minY))]
            .map { CGRect(origin: $0, size: size) }
        if let free = candidates.first(where: { region.contains($0) }) { return free }
        func covered(_ rect: CGRect) -> CGFloat {
            let common = rect.intersection(area)
            return common.isNull ? 0 : common.width * common.height
        }
        let top = region.minY, bottom = region.maxY - size.height
        let leftEdge = region.minX, rightEdge = region.maxX - size.width
        let corners = [CGPoint(x: leftEdge, y: above), CGPoint(x: rightEdge, y: above),
                       CGPoint(x: leftEdge, y: below), CGPoint(x: rightEdge, y: below),
                       CGPoint(x: right, y: top), CGPoint(x: right, y: bottom),
                       CGPoint(x: left, y: top), CGPoint(x: left, y: bottom)]
            .map { CGRect(origin: $0, size: size) }
        func clamped(_ rect: CGRect) -> CGRect {
            CGRect(x: clampX(rect.minX), y: clampY(rect.minY), width: size.width, height: size.height)
        }
        // Von gleich guten Plätzen der erste (Rundungsfehler unter 1 pt² zählen nicht)
        func least(_ rects: [CGRect]) -> CGRect {
            var best = rects[0]
            for rect in rects.dropFirst() where covered(rect) < covered(best) - 1 { best = rect }
            return best
        }
        let basic = least(candidates.map(clamped)), edge = least(corners.map(clamped))
        return covered(edge) < min(covered(basic) * 0.8, covered(basic) - 500) ? edge : basic
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

    /// Berührungen im Fenster neben der Liste schließen sie, ohne dass die Berührung verloren geht (PanelTouchWatcher)
    private func watchTouches(in window: UIWindow) {
        let watcher = panelWatcher ?? PanelTouchWatcher(target: nil, action: nil)
        watcher.onTouchDown = { [weak self] touch in self?.touchDownWhilePanelOpen(touch) }
        watcher.onTap = { [weak self] touch, start in self?.tapWhilePanelOpen(touch, startedAt: start) }
        if watcher.view !== window {
            watcher.view?.removeGestureRecognizer(watcher)
            window.addGestureRecognizer(watcher)
        }
        watcher.isEnabled = true
        panelWatcher = watcher
    }

    /// Ein Finger oder Handballen am iPad auf dieser Fläche, wo nur der Pencil zeichnet (drawingPolicy .pencilOnly).
    /// Nicht auf der Leiste, den Tabs oder anderen Ansichten darüber: Dort schließt ein Finger die Liste gleich (UIKit
    /// kennt die Ansicht unter der Berührung schon, wenn der Beobachter sie sieht)
    private func isFingerOnPencilCanvas(_ touch: UITouch) -> Bool {
        drawingPolicy == .pencilOnly && touch.type != .pencil && touch.type != .indirectPointer
            && touch.view?.isDescendant(of: self) == true
    }

    /// Eine Berührung beginnt, während die Liste offen ist. Neben der Liste schließt sie sie gleich. Nicht am iPad mit
    /// dem Finger auf der Fläche: Dort liegt beim Schreiben oft der Handballen auf, und das soll die Liste nicht
    /// schließen. Ein Finger schließt sie dort erst mit einem kurzen Tippen (tapWhilePanelOpen) oder wenn die Seite zu
    /// scrollen beginnt (CanvasController). Am iPhone nie, solange eine Zeile der Liste gedrückt ist: Deren Wahl ginge
    /// sonst verloren. Am iPad drückt dann ein Finger oder der Handballen die Zeile (der Pencil kann nicht zugleich
    /// woanders aufsetzen): Der Pencil schließt trotzdem, ebenso ein kurzes Tippen mit einem anderen Finger, und die
    /// Zeile wählt beim Abheben nichts mehr
    private func touchDownWhilePanelOpen(_ touch: UITouch) {
        guard let panel, !isFingerOnPencilCanvas(touch), drawingPolicy == .pencilOnly || !panel.isPressingRow,
              !panel.bounds.contains(touch.location(in: panel)) else { return }
        closeByTouch(at: touch.location(in: self))
    }

    /// Ein kurzes Tippen (unter 0,35 s, kaum bewegt) endete, während die Liste offen ist; `start`: wo es begann, in
    /// Fensterkoordinaten. So schließt am iPad ein Finger die Liste. Einen aufliegenden Handballen bricht iPadOS meist ab
    /// oder er bleibt länger liegen; beides zählt nicht als Tippen. Auch während ein Handballen oder Daumen eine Zeile
    /// drückt (der tippende Finger auf der Fläche ist nicht die Berührung auf der Zeile): Sonst führte deren Abheben die
    /// Zeile aus
    private func tapWhilePanelOpen(_ touch: UITouch, startedAt start: CGPoint) {
        guard let panel, isFingerOnPencilCanvas(touch),
              !panel.bounds.contains(panel.convert(start, from: nil)) else { return }
        closeByTouch(at: convert(start, from: nil))
    }

    /// Schließt die Liste wegen einer Berührung, die bei `point` (Koordinaten dieser Fläche) begann. Begann sie auf der
    /// Auswahl, fragt PencilKit gleich nach seinem Menü (Tippen auf die Auswahl öffnet und schließt es): Das bleibt dann
    /// zu, siehe presentSelectionPanel. Neben der Auswahl (ein neues Lasso, Tippen ins Leere) darf gleich wieder ein Menü
    /// kommen. Ist nicht bekannt, wo die Auswahl liegt, zählt jede Berührung als auf ihr
    private func closeByTouch(at point: CGPoint) {
        let onSelection = panelAnchor.map { anchor in
            let area = anchor.touchArea
            return area.width < 1 || area.height < 1 || area.insetBy(dx: -24, dy: -24).contains(point)
        } ?? true
        panelClosedByTouch = onSelection ? panelSource.map { (time: Date(), source: $0) } : nil
        closePanel(animated: false, reason: onSelection ? "Berührung auf der Auswahl" : "Berührung neben der Liste")
    }

    /// Schließt die Liste, falls sie offen ist, und verwirft eine, die noch auf ihre Runde wartet
    private func closePanel(animated: Bool, reason: String) {
        panelRequest += 1
        guard let panel else { return }
        self.panel = nil
        panelSource = nil
        panelAnchor = nil
        panel.isUserInteractionEnabled = false
        panel.onHover = nil
        // Schwebte der Pencil eben über ihr, endet das mit ihr (sonst bliebe die Seite fest)
        if panel.isHovered { onPanelHover?(false) }
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
    /// weg, Scrollen). Kein „eben erst zu“: Ein neues darf gleich wieder aufgehen
    func dismissSelectionMenu(_ reason: String = "Werkzeug oder Fläche") {
        panelClosedByTouch = nil
        closePanel(animated: false, reason: reason)
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
            // Gleich nach einem ∞ auch nicht (PencilKit hat seines oben trotzdem gebaut, sein Zustand ist wie sonst). Das
            // leere Menü gleich schließen, sonst schlösse das nächste Tippen auf die Auswahl nur dieses (siehe
            // presentSelectionPanel)
            if let ink = canvas as? InkCanvasView, Date() < ink.menuBlockedUntil {
                dismissSoon(interaction as? UIEditMenuInteraction)
                return UIMenu(children: [])
            }
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
            if let ink = canvas as? InkCanvasView {
                // Menü einer Auswahl: alle Einträge auf einmal in einer eigenen Liste (siehe presentSelectionPanel)
                let menu = interaction as? UIEditMenuInteraction
                if !extra.isEmpty, let space,
                   ink.presentSelectionPanel(claude: extra, pencilKit: kept, space: space, source: point, menu: menu,
                                             target: targetRect(of: menu, for: configuration)) {
                    return UIMenu(children: [])
                }
                // Sonst kommt ein Menü von UIKit oder keins: keine Liste einer anderen Auswahl daneben
                ink.editMenuWillShow()
            }
            // Nichts geändert: PencilKits Menü wie es ist (oder nil: UIKit zeigt seine Vorschläge)
            if removed == nil, extra.isEmpty { return result }
            if result == nil { debugLog("PencilKit gab kein Menü zurück") }
            if !extra.isEmpty { kept.insert(UIMenu(title: "", options: .displayInline, children: extra), at: 0) }
            if kept.isEmpty {
                dismissSoon(interaction as? UIEditMenuInteraction)
                return UIMenu(children: [])
            }
            return result?.replacingChildren(kept) ?? UIMenu(children: kept)
        }
        let previous = method_setImplementation(method, imp_implementationWithBlock(replacement))
        assert(previous == originalIMP)
    }

    /// Schließt UIKits Bearbeiten-Menü gleich nach dieser Runde, wenn es leer bleibt: Hält UIKit ein leeres Menü für
    /// offen, schließt das nächste Tippen auf die Auswahl nur dieses, statt nach einem neuen zu fragen
    private static func dismissSoon(_ menu: UIEditMenuInteraction?) {
        DispatchQueue.main.async { [weak menu] in menu?.dismissMenu() }
    }

    /// Wohin das Bearbeiten-Menü nach PencilKit zeigen soll (UIKit fragt das beim Zeigen ab), in den Koordinaten der
    /// Ansicht des Menüs; nil, wenn PencilKit nichts dazu sagt
    private static func targetRect(of menu: UIEditMenuInteraction?, for configuration: AnyObject?) -> CGRect? {
        guard let menu, let configuration = configuration as? UIEditMenuConfiguration else { return nil }
        let target = menu.delegate?.editMenuInteraction?(menu, targetRectFor: configuration)
        #if DEBUG
        NSLog("InkCanvasView: Ziel des Menüs nach PencilKit: %@, Quelle %@", target.map { "\($0)" } ?? "keins",
              "\(configuration.sourcePoint)")
        #endif
        return target
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
    /// Der Pencil schwebt über der Liste (true) oder nicht mehr (false); ein Zeiger zählt nicht
    var onHover: ((Bool) -> Void)?
    /// VoiceOver: Wischen mit zwei Fingern (Z-Form) schließt die Liste
    var onEscape: (() -> Void)?
    /// Am iPad (nur der Pencil zeichnet): Schwebt der Pencil über der Liste oder tat er es eben noch, nimmt keine Zeile
    /// eine Berührung mit dem Finger an. Das ist dann fast immer der Handballen
    var palmGuard = false
    /// Für Bedienungshilfen: Dorthin springt der Fokus, wenn die Liste aufgeht
    private(set) var firstRow: UIView?
    /// Schwebt der Pencil gerade über der Liste?
    private(set) var isHovered = false
    private var hoverEnded = Date.distantPast
    private var rows: [SelectionMenuRow] = []
    /// Wird gerade eine Zeile gedrückt?
    var isPressingRow: Bool { rows.contains { $0.isTracking } }

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
                button.ignoresTouch = { [weak self] touch in self?.isPalm(touch) ?? false }
                stack.addArrangedSubview(button)
                rows.append(button)
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
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    private func isPalm(_ touch: UITouch) -> Bool {
        palmGuard && touch.type == .direct && (isHovered || Date().timeIntervalSince(hoverEnded) < 0.5)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            // Nur der Pencil meldet beim Schweben eine Höhe; ein Zeiger (Trackpad, Maus) meldet 0. Über der Liste ruhend
            // sperrte er sonst Finger und Scrollen
            guard isHovered || g.zOffset > 0 else { return }
            isHovered = true
            onHover?(true)
        default:
            guard isHovered else { return }
            isHovered = false
            hoverEnded = Date()
            onHover?(false)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }

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
    /// Berührungen, die die Zeile nicht annimmt (Handballen am iPad, siehe SelectionMenuPanel.palmGuard): Sie drückt
    /// sich dann nicht und wählt nichts
    var ignoresTouch: ((UITouch) -> Bool)?
    private var ignored = Set<ObjectIdentifier>()

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
        // Liegt der Handballen (nicht angenommen) schon auf der Zeile, käme der Pencil sonst gar nicht an
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = action.title
        // .button allein löschte UIKits „abgeblendet“ für nicht wählbare Einträge
        accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? UIColor.label.withAlphaComponent(0.12) : .clear }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var rest = Set<UITouch>()
        for touch in touches {
            if ignoresTouch?(touch) == true { ignored.insert(ObjectIdentifier(touch)) } else { rest.insert(touch) }
        }
        if !rest.isEmpty { super.touchesBegan(rest, with: event) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let rest = touches.filter { !ignored.contains(ObjectIdentifier($0)) }
        if !rest.isEmpty { super.touchesMoved(rest, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let rest = unignored(touches)
        if !rest.isEmpty { super.touchesEnded(rest, with: event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let rest = unignored(touches)
        if !rest.isEmpty { super.touchesCancelled(rest, with: event) }
    }

    /// Die Berührungen ohne die nicht angenommenen; diese sind damit vorbei
    private func unignored(_ touches: Set<UITouch>) -> Set<UITouch> {
        var rest = Set<UITouch>()
        for touch in touches where ignored.remove(ObjectIdentifier(touch)) == nil { rest.insert(touch) }
        return rest
    }
}

/// Beobachtet die Berührungen im Fenster, solange das Menü einer Auswahl offen ist, ohne je etwas zu erkennen: hält
/// nichts auf, verzögert nichts, bricht nichts ab (wie LassoTracker). Meldet den Beginn jeder Berührung und jedes kurze
/// Tippen (unter 0,35 s, weniger als 10 Punkte bewegt; eine abgebrochene Berührung zählt nicht). So schließt eine
/// Berührung neben der Liste sie und tut trotzdem, was sie sonst täte
private final class PanelTouchWatcher: UIGestureRecognizer {
    var onTouchDown: ((UITouch) -> Void)?
    /// Ein kurzes Tippen endete: die Berührung und wo sie begann (Fensterkoordinaten)
    var onTap: ((UITouch, CGPoint) -> Void)?
    private var starts: [ObjectIdentifier: (time: TimeInterval, point: CGPoint)] = [:]

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // Pencil und Finger zugleich: Der Pencil schreibt, der Handballen liegt auf
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            starts[ObjectIdentifier(touch)] = (touch.timestamp, touch.location(in: nil))
            onTouchDown?(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            guard let start = starts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let end = touch.location(in: nil)
            if touch.timestamp - start.time < 0.35, hypot(end.x - start.point.x, end.y - start.point.y) < 10 {
                onTap?(touch, start.point)
            }
        }
        failIfIdle()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { starts.removeValue(forKey: ObjectIdentifier(touch)) }
        failIfIdle()
    }

    /// Erkennt nie; ohne Berührungen gibt es auf, dann setzt UIKit es zurück
    private func failIfIdle() {
        if starts.isEmpty, state == .possible { state = .failed }
    }

    override func reset() {
        super.reset()
        starts.removeAll()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
