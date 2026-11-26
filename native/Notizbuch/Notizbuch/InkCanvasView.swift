import UIKit
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
/// - Das Menü einer Auswahl zeigt alle Einträge auf einmal, untereinander (siehe `presentWholeMenu`): Das
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
        didSet { if !editingAllowed { dismissSelectionMenu() } }
    }
    /// Weitere Einträge vorn im Menü einer Lasso-Auswahl („Claude fragen“); setzt CanvasController
    var selectionMenuItems: ((SelectionMenuContext) -> [UIMenuElement])?
    /// Bis dahin kein Menü: Gleich nach einem ∞ mit dem Lasso fragt CanvasController Claude selbst
    var menuBlockedUntil = Date.distantPast

    /// Das Menü einer Auswahl mit allen Einträgen, solange es aufgeht oder offen ist (siehe presentWholeMenu)
    private var wholeMenu: WholeMenuAnchor?
    /// Kurz nach dem Schließen dieses Menüs kein neues: Tippen auf die Auswahl schließt es dann, statt es gleich wieder
    /// zu öffnen (so blendet PencilKit sein Bearbeiten-Menü beim Tippen auf die Auswahl aus und ein)
    private var wholeMenuQuietUntil = Date.distantPast
    /// Einmal PencilKits Bearbeiten-Menü wie früher: Das Menü mit allen Einträgen ging nicht auf
    private var compactMenuOnce = false

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
        if newWindow == nil { dismissSelectionMenu() }
    }

    // MARK: Menü einer Auswahl mit allen Einträgen

    /// Zeigt das Menü einer Auswahl mit allen Einträgen auf einmal: vorn `claude`, darunter PencilKits Einträge, je als
    /// Abschnitt. Es ist das Menü eines Knopfs (UIButton mit Menü), das öffentliche performPrimaryAction (ab iOS 17.4)
    /// öffnet es: Wie das Bearbeiten-Menü, wenn man dort den Pfeil antippt, stehen alle Einträge untereinander. Der
    /// Knopf ist unsichtbar, liegt über der Auswahl und bekommt nie eine Berührung (WholeMenuAnchor). Tippen neben das
    /// Menü geht wie beim Bearbeiten-Menü an die Fläche durch und schließt es (im Simulator geprüft, 26.11.).
    /// true: PencilKits Bearbeiten-Menü bleibt leer, das Menü geht gleich auf (oder ging eben erst zu, siehe
    /// wholeMenuQuietUntil). false: das Bearbeiten-Menü wie früher, etwa vor iOS 17.4 oder mit Befehlen (UICommand) darin,
    /// die vom Knopf aus nicht an PencilKits Fläche gingen
    fileprivate func presentWholeMenu(claude: [UIMenuElement], pencilKit: [UIMenuElement],
                                      interaction: UIEditMenuInteraction, configuration: UIEditMenuConfiguration) -> Bool {
        if compactMenuOnce {
            compactMenuOnce = false
            return false
        }
        guard #available(iOS 17.4, *) else { return false }
        guard !Self.containsCommand(pencilKit), let space = interaction.view, window != nil else { return false }
        if Date() < wholeMenuQuietUntil {
            Self.debugLog("Menü mit allen Einträgen: eben erst zu, bleibt zu")
            return true
        }
        dismissSelectionMenu()

        // Wohin PencilKit sein Menü setzen würde: neben die Auswahl (sonst an die Stelle des Menüs), im sichtbaren Teil
        let point = configuration.sourcePoint
        var target = interaction.delegate?.editMenuInteraction?(interaction, targetRectFor: configuration) ?? .null
        if target.isNull || target.isInfinite { target = CGRect(origin: point, size: .zero) }
        var place = space.convert(target, to: self).intersection(bounds)
        if place.isNull || place.isEmpty {
            let p = space.convert(point, to: self)
            place = CGRect(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY),
                           width: 0, height: 0)
        }
        place = place.insetBy(dx: min(0, (place.width - 2) / 2), dy: min(0, (place.height - 2) / 2))

        let anchor = WholeMenuAnchor(frame: place)
        anchor.menu = UIMenu(children: [UIMenu(title: "", options: .displayInline, children: claude),
                                        UIMenu(title: "", options: .displayInline, children: pencilKit)])
        anchor.showsMenuAsPrimaryAction = true
        // Sonst dreht UIKit die Reihenfolge um, wenn das Menü über der Auswahl aufgeht
        anchor.preferredMenuElementOrder = .fixed
        anchor.onEnd = { [weak self, weak anchor] in
            guard let self, let anchor, self.wholeMenu === anchor else { return }
            self.wholeMenu = nil
            self.wholeMenuQuietUntil = Date().addingTimeInterval(0.25)
        }
        addSubview(anchor)
        wholeMenu = anchor
        // Nach dieser Runde: Dann hat UIKit das leere Bearbeiten-Menü verworfen
        DispatchQueue.main.async { [weak self, weak anchor, weak interaction] in
            guard let self, let anchor, self.wholeMenu === anchor else { return }
            if anchor.window != nil { anchor.performPrimaryAction() }
            // Ging es nicht auf, einmal das Bearbeiten-Menü wie früher (sonst bliebe die Auswahl ganz ohne Menü)
            DispatchQueue.main.asyncAfter(deadline: .now() + (anchor.window != nil ? 0.6 : 0)) { [weak self, weak anchor] in
                guard let self, let anchor, self.wholeMenu === anchor, !anchor.shown else { return }
                Self.debugLog("Menü mit allen Einträgen ging nicht auf, Bearbeiten-Menü wie früher")
                self.wholeMenu = nil
                anchor.removeFromSuperview()
                guard let interaction, interaction.view?.window != nil else { return }
                self.compactMenuOnce = true
                interaction.presentEditMenu(with: configuration)
            }
        }
        Self.debugLog("Menü mit allen Einträgen bei \(place)")
        return true
    }

    /// Schließt das Menü einer Auswahl mit allen Einträgen, falls es offen ist (anderes Werkzeug, Nur-Sehen, Fläche
    /// weg). Kein „eben erst zu“: Ein neues Menü darf gleich wieder aufgehen
    func dismissSelectionMenu() {
        guard let anchor = wholeMenu else { return }
        wholeMenu = nil
        if anchor.shown && !anchor.ended {
            anchor.contextMenuInteraction?.dismissMenu()
        } else if !anchor.shown {
            anchor.removeFromSuperview()
        }
    }

    /// Befehle (UICommand) im Menü, auch in Abschnitten: UIKit schickt sie an den Knopf und die Ansichten über ihm, nicht
    /// an PencilKits Fläche darunter. PencilKits eigene Einträge sind UIActions; Befehle kommen, wenn PencilKit kein
    /// Menü baut und UIKit seine Vorschläge zeigt
    private static func containsCommand(_ elements: [UIMenuElement]) -> Bool {
        elements.contains { element in
            if let menu = element as? UIMenu { return containsCommand(menu.children) }
            return element is UICommand
        }
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
            // Menü einer Auswahl: alle Einträge auf einmal statt des Bearbeiten-Menüs (siehe presentWholeMenu)
            if !extra.isEmpty, let ink = canvas as? InkCanvasView,
               let editInteraction = interaction as? UIEditMenuInteraction,
               let editConfiguration = configuration as? UIEditMenuConfiguration,
               ink.presentWholeMenu(claude: extra, pencilKit: kept, interaction: editInteraction,
                                    configuration: editConfiguration) {
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

/// Der unsichtbare Knopf, von dem das Menü einer Auswahl mit allen Einträgen aufgeht (InkCanvasView.presentWholeMenu).
/// Ohne Titel und Bild zeichnet er nichts; er nimmt nie eine Berührung an (point(inside:) ist immer false), so geht
/// jedes Tippen an die Fläche unter ihm. Nach dem Schließen nimmt er sich selbst weg
private final class WholeMenuAnchor: UIButton {
    /// Wenn das Menü zugeht, gleich zu Beginn (gewählt, daneben getippt oder geschlossen)
    var onEnd: (() -> Void)?
    private(set) var shown = false
    private(set) var ended = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        shown = true
        #if DEBUG
        NSLog("InkCanvasView: Menü mit allen Einträgen geht auf")
        #endif
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         willEndFor configuration: UIContextMenuConfiguration,
                                         animator: (any UIContextMenuInteractionAnimating)?) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        guard !ended else { return }
        ended = true
        onEnd?()
        #if DEBUG
        NSLog("InkCanvasView: Menü mit allen Einträgen geht zu")
        #endif
        // Erst nach dem Zugehen weg (und nach dem gewählten Eintrag, den UIKit dabei ausführt)
        let remove = { [weak self] in DispatchQueue.main.async { self?.removeFromSuperview() } }
        if let animator { animator.addCompletion(remove) } else { remove() }
    }
}
