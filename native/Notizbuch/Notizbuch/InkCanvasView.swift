import UIKit
import PencilKit
import ObjectiveC

/// Die Schreibfläche, ohne „Leerzeile einfügen“ und ohne ein Menü, das nur „Alles auswählen“ anbietet.
///
/// PencilKit zeigt ein Menü, wenn man die Fläche lange berührt (am iPad etwa mit dem Finger, der eigentlich
/// scrollen will) oder mit dem Lasso auf eine leere Stelle tippt. Dieses Menü baut PencilKits innere Fläche
/// (PKTiledView) selbst, als Delegate ihrer UIEditMenuInteraction; öffentliche Wege (canPerformAction, buildMenu,
/// ein eigener Delegate) erreichen es nicht. Deshalb wird genau diese eine Methode einmal umgeleitet:
/// - „Leerzeile (oben) einfügen“ schaltet PencilKits eigener Schalter insertSpaceEnabled ab; wo es ihn nicht gibt,
///   fallen die Einträge anhand von PencilKits eigenen Übersetzungen weg (die Einträge tragen zufällige Kennungen).
///   Eine eingefügte Leerzeile verschiebt jeden Strich darunter, beim Abgleich ist das für jeden eine Änderung.
/// - „Alles auswählen“ fällt nur weg, wenn es allein übrig bliebe: Dann kommt gar kein Menü.
/// Ausschneiden, Kopieren, Einsetzen, Duplizieren und Löschen bleiben.
/// Ändert Apple die Methode oder die Klasse, wird nichts umgeleitet: Dann ist nur das Menü wieder wie früher.
final class InkCanvasView: PKCanvasView {
    override init(frame: CGRect) {
        _ = Self.menuHook
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        _ = Self.menuHook
        super.init(coder: coder)
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

        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, NSArray) -> UIMenu?
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: Original.self)
        let setter = NSSelectorFromString("setInsertSpaceEnabled:")
        let replacement: @convention(block) (AnyObject, AnyObject, AnyObject, NSArray) -> UIMenu? = { me, interaction, configuration, suggested in
            // PencilKits eigener Schalter für „Leerzeile einfügen“
            if me.responds(to: setter), (me.value(forKey: "insertSpaceEnabled") as? Bool) == true {
                me.setValue(false, forKey: "insertSpaceEnabled")
            }
            #if DEBUG
            NSLog("InkCanvasView: Menü für %@ über %@", String(describing: type(of: me)), String(describing: type(of: interaction)))
            #endif
            guard let menu = original(me, sel, interaction, configuration, suggested) else {
                // Ohne Menü von PencilKit zeigt UIKit die vorgeschlagenen Einträge: dieselben Regeln für diese
                debugLog("PencilKit gab kein Menü zurück")
                guard let kept = filtered(suggested as? [UIMenuElement] ?? []) else { return nil }
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

    /// Die Einträge ohne „Leerzeile einfügen“, und leer, wenn nur „Alles auswählen“ bliebe; nil, wenn nichts wegfällt
    private static func filtered(_ elements: [UIMenuElement]) -> [UIMenuElement]? {
        var kept = withoutInsertSpace(elements)
        if kept.count == 1, isSelectAll(kept[0]) { kept = [] }
        return kept.count == elements.count && zip(kept, elements).allSatisfy({ $0 === $1 }) ? nil : kept
    }

    /// Entfernt jedes „Leerzeile (oben) einfügen“, auch in Untermenüs; leer gewordene Untermenüs fallen weg
    private static func withoutInsertSpace(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        elements.compactMap { element in
            if let menu = element as? UIMenu {
                let kids = withoutInsertSpace(menu.children)
                if kids.count == menu.children.count { return menu }
                return kids.isEmpty ? nil : menu.replacingChildren(kids)
            }
            if let action = element as? UIAction, insertSpaceTitles.contains(action.title) { return nil }
            if let command = element as? UICommand,
               NSStringFromSelector(command.action).lowercased().contains("insertspace") { return nil }
            return element
        }
    }

    private static func isSelectAll(_ element: UIMenuElement) -> Bool {
        if let action = element as? UIAction { return action.title == selectAllTitle }
        if let command = element as? UICommand { return command.action == #selector(UIResponderStandardEditActions.selectAll(_:)) }
        return false
    }

    /// Die Titel so, wie PencilKit sie selbst übersetzt (Schlüssel aus PencilKit.framework/…/Localizable.strings)
    private static func pencilKitTitle(_ key: String) -> String {
        Bundle(for: PKCanvasView.self).localizedString(forKey: key, value: key, table: "Localizable")
    }
    private static let selectAllTitle = pencilKitTitle("Select All")
    private static let insertSpaceTitles: Set<String> = [pencilKitTitle("Insert Space"), pencilKitTitle("Insert Space Above")]

    private static func debugLog(_ text: String) {
        #if DEBUG
        NSLog("InkCanvasView: %@", text)
        #endif
    }
}
