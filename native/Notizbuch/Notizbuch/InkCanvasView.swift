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
/// - Das Menü einer Auswahl zeigt alle Einträge auf einmal, nebeneinander als kurze Reihe (Claudes Einträge als Kürzel
///   wie „C?“, PencilKits als Symbole), in einer eigenen Liste neben der Auswahl (siehe `presentSelectionPanel`): Das
///   Bearbeiten-Menü zeigt seit iPadOS 26 nur etwa drei davon und den Rest hinter einem Pfeil.
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
    /// Rechteck der Striche, die seit dem letzten Lasso dazukamen oder sich bewegten, in den Koordinaten dieser Fläche
    /// (nil: keine): nach Einsetzen, Duplizieren oder Verschieben die Auswahl. Setzt CanvasController
    var selectionInk: (() -> CGRect?)?
    /// Gleich beginnt eine Auswahl ohne eigenes Lasso: PencilKit zeigt ein Menü ohne Auswahl (etwa nur „Einsetzen“ an
    /// einer leeren Stelle), oder in der Liste wurde Duplizieren gewählt. Setzt CanvasController
    var onSelectionAhead: (() -> Void)?
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
        // Höchstens 520 breit: Mit üblicher Schrift ist das eine Reihe, mit großer Schrift oder am schmalen iPhone brechen
        // die Abschnitte um (siehe SelectionMenuPanel)
        let list = SelectionMenuPanel(sections: sections, maxWidth: min(520, max(region.width, 0)),
                                      scale: host.traitCollection.displayScale)
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
    /// Bearbeiten-Menü, weil die Liste nicht passt): Die Auswahl der offenen Liste ist dann weg oder eine andere.
    /// `selection`: Es ist das Menü einer Auswahl (die Liste passte nicht)
    fileprivate func editMenuWillShow(selection: Bool) {
        if panel != nil { dismissSelectionMenu("anderes Menü") }
        if !selection { onSelectionAhead?() }
    }

    private func show(_ panel: SelectionMenuPanel, from space: UIView, source: CGPoint, target: CGRect?) {
        guard let host = superview, let window else { return }
        let point = space.convert(source, to: self)
        // Einmal pro Liste: Dafür wird die ganze Tinte durchgesehen
        let lasso = selectionArea?()
        let estimate = selectionEstimate(at: point, target: target.map { space.convert($0, to: self) }, lasso: lasso)
        let area = estimate.area.union(CGRect(origin: point, size: .zero))
        var touchArea = area
        // Nur das Lasso dieser Auswahl (siehe menuBelongs): Nach einem Verschieben liegt es, wo die Auswahl vorher war
        if let lasso, Self.menuBelongs(at: point, to: lasso) {
            touchArea = touchArea.union(lasso.rect)
        }
        let region = visibleRegion(in: host)
        guard panel.bounds.width <= region.width, panel.bounds.height <= region.height else { return }
        panel.frame = Self.onPixels(Self.place(panel.bounds.size, near: convert(point, to: host),
                                               avoiding: convert(area, to: host), within: region),
                                    scale: host.traitCollection.displayScale)
        panel.onChoose = { [weak self, weak panel] action in
            guard let self, let panel, self.panel === panel else { return }
            self.closePanel(animated: true, reason: "gewählt: \(action.title)")
            // Duplizieren: Dann ist die Kopie die Auswahl, und nur sie kommt neu dazu (selectionInk)
            if Self.symbolName(for: action.title) == "plus.square.on.square" { self.onSelectionAhead?() }
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
        UIAccessibility.post(notification: .layoutChanged, argument: panel.firstButton)
        Self.debugLog("Menü mit allen Einträgen bei \(panel.frame), Auswahl etwa \(convert(area, to: host)) "
                      + "(\(estimate.kind))")
        Self.debugLog("Menü mit allen Einträgen in \(panel.lineCount) Reihe(n)")
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

    /// Wo die Auswahl ungefähr liegt, deren Menü bei `point` (Mitte oben der Auswahl, ohne Platz darüber Mitte unten;
    /// Koordinaten dieser Fläche) aufgehen soll, der Reihe nach: das zuletzt gezogene Lasso, wenn das Menü zu ihm gehört
    /// (menuBelongs; PencilKit zeigt die Auswahl dann mit diesem Lasso); PencilKits eigene Angabe `target`, wenn sie eine
    /// Fläche ist und zum Punkt passt; die Striche, die seit dem Lasso dazukamen oder sich bewegten (selectionInk), wenn
    /// der Punkt an ihrer Ober- oder Unterkante liegt; die Auswahl der vorigen Liste, mitgewandert (verschoben, oder eine
    /// eingesetzte Kopie); ein Rechteck so groß wie das Lasso, oben mittig am Punkt (die Auswahl wurde verschoben oder
    /// dupliziert, bevor eine Liste aufging); sonst nur dieser Punkt. `lasso`: was selectionArea lieferte. `kind` fürs
    /// Protokoll
    private func selectionEstimate(at point: CGPoint, target: CGRect?,
                                   lasso: (rect: CGRect, unchanged: Bool)?) -> (area: CGRect, kind: String) {
        let z = max(zoomScale, 0.01)
        let unzoomed = CGPoint(x: point.x / z, y: point.y / z)
        // Mitwandern rechnet von der Mitte oben aus: Nannte PencilKit die Mitte unten (über der Auswahl kein Platz),
        // läge die Schätzung um die Höhe der Auswahl daneben, sobald ihr nächstes Menü wieder oben aufgeht
        func remembered(_ rect: CGRect, _ kind: String) -> (area: CGRect, kind: String) {
            if point.y > rect.midY {
                knownSelection = nil
            } else {
                knownSelection = (unzoomed, rect.applying(CGAffineTransform(scaleX: 1 / z, y: 1 / z)))
            }
            return (rect, kind)
        }
        if let lasso, Self.menuBelongs(at: point, to: lasso) {
            return remembered(lasso.rect, "Lasso")
        }
        // Der Punkt ist die Mitte oben der Auswahl (ohne Platz darüber die Mitte unten): Eine Angabe, deren Ober- oder
        // Unterkante nicht dort liegt, gehört nicht dazu. Unter 24 pt in beiden Richtungen ist sie keine Fläche: Im
        // Simulator mit iOS 27 nennt PencilKit nur ein Quadrat von 5 pt an diesem Punkt (27.11.); die Liste lag dann auf
        // der Auswahl
        if let target, !target.isNull, !target.isInfinite, target.width >= 1, target.height >= 1,
           max(target.width, target.height) >= 24, Self.atEdge(point, of: target) {
            return remembered(target, "von PencilKit")
        }
        // Eingesetzt, dupliziert oder verschoben: Die Auswahl sind die Striche, die seit dem Lasso dazukamen oder sich
        // bewegten. PencilKit zeigt sie im Umriss des Lassos, so groß wie das Lasso, der Punkt mittig an seiner Ober-
        // oder Unterkante: Liegen die Striche darin, gilt dieser Umriss samt den Strichen (auch bei locker gezogenem
        // Lasso, und Tippen auf seinen Rand zählt als Tippen auf die Auswahl). Sonst die Striche allein, wenn der Punkt
        // mittig an ihrem Rand liegt. Andernfalls gehören auch andere Striche dazu (etwa eben geschriebene)
        if let ink = selectionInk?() {
            if let lasso, let outline = Self.outline(of: lasso.rect.size, at: point, holding: ink) {
                return remembered(outline.union(ink), "Striche seit dem Lasso")
            }
            if Self.atEdge(point, of: ink), abs(point.x - ink.midX) <= 40 {
                return remembered(ink, "Striche seit dem Lasso")
            }
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
        let frame = Self.onPixels(Self.place(panel.bounds.size, near: convert(anchor.point, to: host),
                                             avoiding: convert(anchor.area, to: host), within: region),
                                  scale: host.traitCollection.displayScale)
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

    /// `rect` mit dem Ursprung auf ganzen Bildpunkten (`scale` Bildpunkte je Punkt): Innen liegt die Liste schon so,
    /// sonst wären Kürzel und Symbole leicht unscharf
    private static func onPixels(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let s = max(scale, 1)
        return CGRect(x: (rect.minX * s).rounded() / s, y: (rect.minY * s).rounded() / s,
                      width: rect.width, height: rect.height)
    }

    /// Gehört das Menü bei `point` (Mitte oben der Auswahl, ohne Platz darüber Mitte unten; Koordinaten dieser Fläche)
    /// zum zuletzt gezogenen Lasso (selectionArea)? Die Tinte darunter ist dieselbe, und der Punkt liegt höchstens 60 pt
    /// daneben, aber höchstens 24 pt unter seiner Unterkante: Jeder ausgewählte Strich liegt zum Teil im Lasso, die
    /// Oberkante der Auswahl also höher. Ist über der Auswahl kein Platz für PencilKits Menü, nennt PencilKit die Mitte
    /// unten, knapp unter dem Lasso (27.11., iPhone mit sehr großer Schrift: 1 pt darunter). Eine eingesetzte oder
    /// duplizierte Kopie gehört nie dazu, auch knapp darunter nicht: Mit ihr ändert sich die Zahl der Striche, also der
    /// Abdruck der Tinte (`unchanged` falsch, siehe inkPrint im CanvasController)
    private static func menuBelongs(at point: CGPoint, to lasso: (rect: CGRect, unchanged: Bool)) -> Bool {
        lasso.unchanged && !lasso.rect.isNull && !lasso.rect.isInfinite
            && lasso.rect.insetBy(dx: -60, dy: -60).contains(point) && point.y <= lasso.rect.maxY + 24
    }

    /// Liegt `point` (wo PencilKit sein Menü zeigen will) an der Ober- oder Unterkante von `rect`, waagrecht darüber oder
    /// darunter, mit 40 pt Spiel? Dann kann `rect` die Auswahl dieses Menüs sein
    private static func atEdge(_ point: CGPoint, of rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && (abs(rect.minY - point.y) <= 40 || abs(rect.maxY - point.y) <= 40)
            && point.x >= rect.minX - 40 && point.x <= rect.maxX + 40
    }

    /// Der Umriss einer Auswahl so groß wie `size` (das Lasso), deren Menü PencilKit bei `point` zeigen will (Mitte
    /// oben, ohne Platz darüber Mitte unten), wenn die Striche `ink` darin liegen; sonst nil. Erst genau, dann mit 16 pt
    /// Spiel (ein Strich ragt etwas über das Lasso): Sonst nähme eine flache Auswahl knapp über dem Punkt den Umriss
    /// darunter
    private static func outline(of size: CGSize, at point: CGPoint, holding ink: CGRect) -> CGRect? {
        guard size.width > 0, size.height > 0, !ink.isNull, !ink.isInfinite else { return nil }
        let below = CGRect(x: point.x - size.width / 2, y: point.y, width: size.width, height: size.height)
        let boxes = [below, below.offsetBy(dx: 0, dy: -size.height)]
        return boxes.first { $0.contains(ink) } ?? boxes.first { $0.insetBy(dx: -16, dy: -16).contains(ink) }
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
    /// scrollen beginnt (CanvasController). Am iPhone nie, solange ein Eintrag der Liste gedrückt ist: Dessen Wahl ginge
    /// sonst verloren. Am iPad drückt dann ein Finger oder der Handballen den Eintrag (der Pencil kann nicht zugleich
    /// woanders aufsetzen): Der Pencil schließt trotzdem, ebenso ein kurzes Tippen mit einem anderen Finger, und der
    /// Eintrag wählt beim Abheben nichts mehr
    private func touchDownWhilePanelOpen(_ touch: UITouch) {
        guard let panel, !isFingerOnPencilCanvas(touch), drawingPolicy == .pencilOnly || !panel.isPressingButton,
              !panel.bounds.contains(touch.location(in: panel)) else { return }
        closeByTouch(at: touch.location(in: self))
    }

    /// Ein kurzes Tippen (unter 0,35 s, kaum bewegt) endete, während die Liste offen ist; `start`: wo es begann, in
    /// Fensterkoordinaten. So schließt am iPad ein Finger die Liste. Einen aufliegenden Handballen bricht iPadOS meist ab
    /// oder er bleibt länger liegen; beides zählt nicht als Tippen. Auch während ein Handballen oder Daumen einen Eintrag
    /// drückt (der tippende Finger auf der Fläche ist nicht die Berührung auf dem Eintrag): Sonst führte dessen Abheben
    /// den Eintrag aus
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
                ink.editMenuWillShow(selection: !extra.isEmpty)
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

    /// Kennung für einen Eintrag (`selectionMenuItems`), den die Liste einer Auswahl als Kürzel `short` zeigt, etwa
    /// „C?“ für „Claude fragen“. Der volle Titel bleibt für Bedienungshilfen und UIKits Bearbeiten-Menü
    static func shortTitleIdentifier(_ short: String) -> UIAction.Identifier {
        UIAction.Identifier(shortTitlePrefix + short)
    }

    /// Das Kürzel eines Eintrags (siehe shortTitleIdentifier), nil ohne
    fileprivate static func shortTitle(of action: UIAction) -> String? {
        let id = action.identifier.rawValue
        guard id.hasPrefix(shortTitlePrefix), id.count > shortTitlePrefix.count else { return nil }
        return String(id.dropFirst(shortTitlePrefix.count))
    }

    private static let shortTitlePrefix = "de.beiglboeck.notizbuch.kurz."

    /// Das Symbol für einen von PencilKits Einträgen, an seinem Titel erkannt (sie tragen zufällige Kennungen):
    /// Ausschneiden, Kopieren, Löschen, Duplizieren, Einsetzen. nil für andere, die Liste zeigt dann den Titel
    fileprivate static func symbolName(for title: String) -> String? {
        symbolNames[title.lowercased()]
    }

    /// Die Titel auf Englisch, auf Deutsch und so, wie PencilKit und UIKit sie selbst übersetzen (wie hiddenTitles)
    private static let symbolNames: [String: String] = {
        let known: [(english: String, german: String, symbol: String)] = [
            ("Cut", "Ausschneiden", "scissors"), ("Copy", "Kopieren", "doc.on.doc"), ("Delete", "Löschen", "trash"),
            ("Duplicate", "Duplizieren", "plus.square.on.square"), ("Paste", "Einsetzen", "doc.on.clipboard"),
        ]
        let bundles = [Bundle(for: PKCanvasView.self), Bundle(for: UIView.self)]
        var names: [String: String] = [:]
        for entry in known {
            let titles = [entry.english, entry.german]
                + bundles.map { $0.localizedString(forKey: entry.english, value: entry.english, table: "Localizable") }
            for title in titles { names[title.lowercased()] = entry.symbol }
        }
        return names
    }()

    private static func debugLog(_ text: String) {
        #if DEBUG
        NSLog("InkCanvasView: %@", text)
        #endif
    }
}

/// Das Menü einer Auswahl mit allen Einträgen (InkCanvasView.presentSelectionPanel): alle nebeneinander in einer
/// kurzen Reihe wie UIKits Bearbeiten-Menü, aber ohne Pfeil zum Weiterblättern. Claudes Einträge stehen als Kürzel da
/// („C?“, „C?+“, „CS“, „CS+“), PencilKits als Symbole (Schere, Kopieren, Papierkorb, Duplizieren), unbekannte mit
/// ihrem Titel; Bedienungshilfen lesen immer den vollen Titel. Zwischen zwei Abschnitten liegt ein breiterer Strich.
/// Passt nicht alles in eine Reihe (`maxWidth`: große Schrift, schmales iPhone), beginnt ein Abschnitt, der nicht mehr
/// daneben passt, eine neue Reihe, und ein Abschnitt, der allein zu breit ist, bricht um. Die Liste liegt in der Ansicht
/// über der Fläche, nicht in ihr: PencilKits Gesten (Lasso, Schreiben, Scrollen) sehen keine Berührung darin
private final class SelectionMenuPanel: UIView {
    /// Ein Eintrag wurde angetippt
    var onChoose: ((UIAction) -> Void)?
    /// Der Pencil schwebt über der Liste (true) oder nicht mehr (false); ein Zeiger zählt nicht
    var onHover: ((Bool) -> Void)?
    /// VoiceOver: Wischen mit zwei Fingern (Z-Form) schließt die Liste
    var onEscape: (() -> Void)?
    /// Am iPad (nur der Pencil zeichnet): Schwebt der Pencil über der Liste oder tat er es eben noch, nimmt kein Eintrag
    /// eine Berührung mit dem Finger an. Das ist dann fast immer der Handballen
    var palmGuard = false
    /// Für Bedienungshilfen: Dorthin springt der Fokus, wenn die Liste aufgeht
    private(set) var firstButton: UIView?
    /// In wie vielen Reihen die Einträge stehen (fürs Protokoll)
    private(set) var lineCount = 0
    /// Schwebt der Pencil gerade über der Liste?
    private(set) var isHovered = false
    private var hoverEnded = Date.distantPast
    private var buttons: [SelectionMenuButton] = []
    /// Wird gerade ein Eintrag gedrückt?
    var isPressingButton: Bool { buttons.contains { $0.isTracking } }

    /// Ein Eintrag in einer Reihe: Nummer seines Abschnitts und seine Nummer darin
    private struct Slot {
        let section: Int
        let index: Int
    }

    /// Eine Reihe der Liste: ihre Einträge, ihre Breite, und ob sie mit einem neuen Abschnitt beginnt
    private struct Line {
        var slots: [Slot] = []
        var width: CGFloat = 0
        var startsSection = true
    }

    /// `scale`: Bildpunkte je Punkt. Feine Striche sind einen Bildpunkt breit, und alles liegt auf ganzen Bildpunkten
    /// (scharf)
    init(sections: [[UIAction]], maxWidth: CGFloat, scale: CGFloat) {
        super.init(frame: .zero)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 4)
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        background.layer.cornerRadius = Self.cornerRadius
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        addSubview(background)

        // Jeder Eintrag so schmal, wie sein Inhalt es erlaubt (gemessen, solange er noch für sich steht), mindestens 44,
        // alle so hoch wie der höchste. Einer, der allein breiter als die ganze Liste wäre (ein sehr langer Titel), wird
        // gekürzt
        let limit = max(floor(maxWidth), 44)
        var widths: [[CGFloat]] = []
        var sectionButtons: [[SelectionMenuButton]] = []
        var height: CGFloat = 44
        for section in sections where !section.isEmpty {
            var row: [SelectionMenuButton] = []
            var rowWidths: [CGFloat] = []
            for action in section {
                let button = SelectionMenuButton(action)
                let size = button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
                rowWidths.append(min(max(ceil(size.width), 44), limit))
                height = max(height, ceil(size.height))
                button.addAction(UIAction { [weak self] _ in self?.onChoose?(action) }, for: .touchUpInside)
                button.ignoresTouch = { [weak self] touch in self?.isPalm(touch) ?? false }
                row.append(button)
            }
            widths.append(rowWidths)
            sectionButtons.append(row)
        }
        buttons = sectionButtons.flatMap { $0 }
        firstButton = buttons.first

        let pixel = 1 / max(scale, 1)
        let thin = pixel, wide: CGFloat = 6
        let lines = Self.arrange(widths, maxWidth: limit, thin: thin, wide: wide)
        lineCount = lines.count
        let width = lines.map(\.width).max() ?? 0
        let content = background.contentView
        func separator(_ frame: CGRect, wide isWide: Bool) {
            let line = UIView(frame: frame)
            line.backgroundColor = UIColor.label.withAlphaComponent(isWide ? 0.08 : 0.18)
            line.isUserInteractionEnabled = false
            content.addSubview(line)
        }
        var y: CGFloat = 0
        for (n, line) in lines.enumerated() {
            if n > 0 {
                separator(CGRect(x: 0, y: y, width: width, height: line.startsSection ? wide : thin),
                          wide: line.startsSection)
                y += line.startsSection ? wide : thin
            }
            // Eine kürzere Reihe verteilt den Rest ihrer Breite auf ihre Einträge, auf ganze Bildpunkte, den Rest bekommt
            // der letzte: Alle Reihen enden rechts gleich
            let spare = max(0, width - line.width) / CGFloat(line.slots.count)
            let extra = floor(spare / pixel + 0.001) * pixel
            var x: CGFloat = 0
            for (j, slot) in line.slots.enumerated() {
                if j > 0 {
                    let newSection = slot.section != line.slots[j - 1].section
                    separator(CGRect(x: x, y: y, width: newSection ? wide : thin, height: height), wide: newSection)
                    x += newSection ? wide : thin
                }
                let w = j == line.slots.count - 1 ? width - x : widths[slot.section][slot.index] + extra
                let button = sectionButtons[slot.section][slot.index]
                button.frame = CGRect(x: x, y: y, width: w, height: height)
                content.addSubview(button)
                x += w
            }
            y += height
        }
        frame = CGRect(x: 0, y: 0, width: width, height: y)
        background.frame = bounds
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Verteilt die Einträge (ihre Breiten, je Abschnitt) auf Reihen von höchstens `maxWidth`: Ein Abschnitt kommt ganz
    /// neben den vorigen, wenn er dort noch passt, sonst in eine neue Reihe. Ist er allein zu breit, bricht er auf so
    /// wenige Reihen wie möglich um, gleich voll (sonst stünde am Ende vielleicht einer allein). Zwischen zwei Einträgen
    /// eines Abschnitts liegt `thin`, zwischen zwei Abschnitten `wide`. Jeder Eintrag ist höchstens `maxWidth` breit
    private static func arrange(_ widths: [[CGFloat]], maxWidth: CGFloat, thin: CGFloat, wide: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for (section, row) in widths.enumerated() where !row.isEmpty {
            func span(_ range: Range<Int>) -> CGFloat {
                row[range].reduce(0, +) + thin * CGFloat(range.count - 1)
            }
            let whole = span(row.indices)
            if !current.slots.isEmpty {
                if current.width + wide + whole <= maxWidth {
                    current.slots += row.indices.map { Slot(section: section, index: $0) }
                    current.width += wide + whole
                    continue
                }
                lines.append(current)
            }
            // Je Reihe `size` Einträge, so viele wie möglich (ein einzelner passt immer)
            var size = 1
            for rows in 1...row.count {
                let candidate = (row.count + rows - 1) / rows
                let ranges = stride(from: 0, to: row.count, by: candidate).map { $0..<min($0 + candidate, row.count) }
                if ranges.allSatisfy({ span($0) <= maxWidth }) {
                    size = candidate
                    break
                }
            }
            let ranges = stride(from: 0, to: row.count, by: size).map { $0..<min($0 + size, row.count) }
            for (n, range) in ranges.enumerated() {
                current = Line(slots: range.map { Slot(section: section, index: $0) }, width: span(range),
                               startsSection: n == 0)
                if n < ranges.count - 1 { lines.append(current) }
            }
        }
        if !current.slots.isEmpty { lines.append(current) }
        return lines
    }

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
}

/// Ein Eintrag der Liste: sein Kürzel, sein Symbol oder (unbekannt) sein Titel, in der Mitte. Ein Knopf, damit UIKit ihn
/// als einen behandelt (Bedienungshilfen, Antippen); Bedienungshilfen lesen den vollen Titel
private final class SelectionMenuButton: UIButton {
    /// Berührungen, die der Eintrag nicht annimmt (Handballen am iPad, siehe SelectionMenuPanel.palmGuard): Er drückt
    /// sich dann nicht und wählt nichts
    var ignoresTouch: ((UITouch) -> Bool)?
    private var ignored = Set<ObjectIdentifier>()

    init(_ action: UIAction) {
        super.init(frame: .zero)
        let enabled = !action.attributes.contains(.disabled)
        let color: UIColor = !enabled ? .tertiaryLabel : action.attributes.contains(.destructive) ? .systemRed : .label
        let body = UIFontMetrics(forTextStyle: .body)
        let short = InkCanvasView.shortTitle(of: action)
        // Das Symbol in der Schriftgröße der Kürzel, fest beim Bauen (die Liste wird für jedes Menü neu gebaut und
        // gemessen, bevor sie im Fenster liegt). Ohne seine Einzüge (alignmentRectInsets) rechnet Auto Layout mit dem
        // ganzen Bild: Mit ihnen ragte es bei sehr großer Schrift unten über den Rand der Leiste (27.11.)
        var symbol: UIImage?
        if short == nil, let name = InkCanvasView.symbolName(for: action.title) {
            let config = UIImage.SymbolConfiguration(font: body.scaledFont(for: UIFont.systemFont(ofSize: 17)),
                                                     scale: .large)
            symbol = UIImage(systemName: name, withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate).withAlignmentRectInsets(.zero)
        }
        let content: UIView
        var size: [NSLayoutConstraint] = []
        if let symbol {
            let icon = UIImageView(image: symbol)
            icon.tintColor = color
            icon.contentMode = .center
            // Alle Symbole gleich breit: Die Reihe wirkt ruhiger
            let side = icon.widthAnchor.constraint(equalToConstant: ceil(body.scaledValue(for: 26)))
            side.priority = UILayoutPriority(999)
            size.append(side)
            content = icon
        } else {
            let label = UILabel()
            label.text = short ?? action.title
            label.font = short != nil ? body.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
                : UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byTruncatingTail
            label.textColor = color
            content = label
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isUserInteractionEnabled = false
        addSubview(content)
        NSLayoutConstraint.activate(size + [
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
        ])
        isEnabled = enabled
        // Liegt der Handballen (nicht angenommen) schon auf dem Eintrag, käme der Pencil sonst gar nicht an
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
