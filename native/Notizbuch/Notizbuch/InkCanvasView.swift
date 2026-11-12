import UIKit
import PencilKit
import ObjectiveC

/// Die Schreibfläche: PencilKits Menü nur im Lasso-Modus, und nie mit „Alles auswählen“ oder „Leerzeile einfügen“.
///
/// PencilKit zeigt ein Menü, wenn man die Fläche lange berührt (am iPad etwa mit dem Finger, der eigentlich
/// scrollen will) oder mit dem Lasso auf eine leere Stelle oder eine Auswahl tippt. Dieses Menü baut PencilKits
/// innere Fläche (PKTiledView) selbst, als Delegate ihrer UIEditMenuInteraction; öffentliche Wege (canPerformAction,
/// buildMenu, ein eigener Delegate) erreichen es nicht. Deshalb wird genau diese eine Methode einmal umgeleitet:
/// - Außerhalb des Lasso-Modus (Stift, Radierer, Zeigestift) und im Nur-Sehen-Modus kommt gar kein Menü, auch nicht,
///   wenn kopierte Striche zum Einsetzen bereitliegen.
/// - Mit dem Lasso bleiben Ausschneiden, Kopieren, Löschen, Duplizieren und Einsetzen.
/// - „Alles auswählen“ fällt immer weg. Bleibt nichts übrig, kommt kein Menü.
/// - „Leerzeile (oben) einfügen“ fällt anhand von PencilKits eigenen Übersetzungen weg (die Einträge tragen zufällige
///   Kennungen), falls PencilKits Schalter dafür (siehe unten) fehlt.
/// Ändert Apple die Methode oder die Klasse, wird nichts umgeleitet: Dann ist nur das Menü wieder wie früher.
///
/// „Leerzeile einfügen“ ist ganz aus: PencilKits eigener Schalter insertSpaceEnabled steuert den Menüeintrag und eine
/// Lasso-Geste ohne Menü (vom äußersten Zehntel einer Seite bis ins äußerste Zehntel der anderen gezogen, fügt sie
/// Platz ein, statt auszuwählen). PencilKit schaltet ihn beim Erzeugen der Fläche ein; hier geht er aus, sobald die
/// Fläche im Fenster ist, also vor der ersten Berührung. Eine eingefügte Leerzeile verschiebt jeden Strich darunter,
/// beim Abgleich ist das für jeden eine Änderung.
final class InkCanvasView: PKCanvasView {
    /// Darf man auf der Fläche bearbeiten (nicht Nur-Sehen)? Setzt CanvasController; ohne Bearbeiten kein Menü.
    /// drawingGestureRecognizer taugt dafür nicht: PencilKit schaltet ihn beim Lasso selbst aus.
    var editingAllowed = true

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
            let lasso = lassoIsActive(around: me)
            #if DEBUG
            NSLog("InkCanvasView: Menü für %@ über %@, Lasso: %@", "\(type(of: me))",
                  interaction.map { "\(type(of: $0))" } ?? "nil", lasso ? "ja" : "nein")
            #endif
            // Außerhalb des Lasso-Modus gehört ein langer Finger zum Scrollen: kein Menü
            guard lasso else { return UIMenu(children: []) }
            guard let menu = result else {
                // Ohne Menü von PencilKit zeigt UIKit die vorgeschlagenen Einträge: dieselben Regeln für diese
                debugLog("PencilKit gab kein Menü zurück")
                guard let kept = filtered((suggested as? [UIMenuElement]) ?? []) else { return nil }
                return UIMenu(children: kept)
            }
            guard let kept = filtered(menu.children) else { return menu }
            return kept.isEmpty ? UIMenu(children: []) : menu.replacingChildren(kept)
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

    /// Steht die Fläche, zu der PencilKits innere Ansicht gehört, im Lasso-Modus, und darf man darauf bearbeiten?
    /// Findet sich keine Fläche, wird nur gefiltert, wie im Lasso-Modus.
    private static func lassoIsActive(around tiledView: AnyObject) -> Bool {
        var view = (tiledView as? UIView)?.superview
        while let current = view, !(current is PKCanvasView) { view = current.superview }
        guard let canvas = view as? PKCanvasView else {
            debugLog("keine Fläche über PKTiledView")
            return true
        }
        return canvas.tool is PKLassoTool && ((canvas as? InkCanvasView)?.editingAllowed ?? true)
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
