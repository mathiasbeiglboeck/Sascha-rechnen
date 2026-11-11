import UIKit
import PencilKit

/// Die Schreibfläche, ohne „Alles auswählen“ und „Leerzeile einfügen“ in PencilKits Menü.
///
/// PencilKit zeigt die beiden, wenn man die Fläche lange berührt (am iPad etwa mit dem Finger, der eigentlich
/// scrollen will) oder mit dem Lasso auf eine leere Stelle tippt; „Leerzeile einfügen“ steht auch im Menü einer
/// Lasso-Auswahl. Beides ist hier abgeschaltet: Alles auswählen braucht niemand, und eine eingefügte Leerzeile
/// verschiebt jeden Strich darunter, was beim Abgleich für jeden davon eine Änderung bedeutet.
/// Ausschneiden, Kopieren, Einsetzen, Duplizieren und Löschen bleiben. Bleibt nichts übrig, kommt gar kein Menü.
final class InkCanvasView: PKCanvasView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if Self.isHidden(action) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Alles auswählen, und PencilKits eigenes Leerzeile-Einfügen (der Name ist nicht öffentlich, etwa insertSpace:)
    static func isHidden(_ action: Selector) -> Bool {
        if action == #selector(UIResponderStandardEditActions.selectAll(_:)) { return true }
        return NSStringFromSelector(action).lowercased().contains("insertspace")
    }
}
