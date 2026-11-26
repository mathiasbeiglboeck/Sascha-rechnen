#if DEBUG
import UIKit

/// Nur für Tests im Simulator (Debug-Build): Wie zeigt iPadOS ein Menü mit vielen Einträgen? Wunsch 26.11.: Nach dem
/// Markieren mit dem Lasso sollen alle Einträge sofort zu sehen sein; das Bearbeiten-Menü zeigt seit iPadOS 26 nur
/// einige davon und den Rest hinter einem Pfeil. Befehle über CanvasController.debugCommand:
/// - `debug/menutest?mode=edit&shape=S`: Bearbeiten-Menü (UIEditMenuInteraction), Einträge in der Form S
/// - `mode=button&shape=S`: unsichtbarer Knopf mit Menü, öffentliches `performPrimaryAction`, falls es das gibt
/// - `mode=buttonprivate&shape=S`: derselbe Knopf, Menü über das private `_presentMenuAtLocation:` seiner
///   Kontextmenü-Interaktion (so öffnet UIKit Knopf-Menüs)
/// - `mode=popover&shape=S`: eigene Liste als Popover
/// - `pick=N`: in der eigenen Liste den N-ten Eintrag (ab 0) wählen
/// - `close`: alles schließen
/// Formen S: now (wie heute: vorn „Claude fragen“, „Claude gründlich fragen“ als eigener Abschnitt, dann PencilKits
/// vier Einträge als Abschnitt), nowflat (PencilKits Einträge ohne Abschnitt), one (alle sechs in einem Abschnitt),
/// flat (alle sechs ohne Abschnitt), plain (wie flat, ohne Bilder), pkfirst (PencilKits vier vorn), pkonly (nur die
/// vier), pkimg (wie now, PencilKits Einträge mit Bildern), short (kurze Titel), many (zehn kurze Einträge).
/// Protokoll „Menü-Debug: …“; ein gewählter Eintrag schreibt „Menü-Debug: gewählt <Titel>“
@MainActor
enum MenuDebug {
    private static var editInteraction: UIEditMenuInteraction?
    private static let editDelegate = EditDelegate()
    private static var button: UIButton?
    private static weak var list: ListMenuController?

    static func run(_ items: [URLQueryItem], host: UIViewController) {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if items.contains(where: { $0.name == "close" }) {
            close(host)
            return log("geschlossen")
        }
        if let pick = value("pick").flatMap({ Int($0) }) {
            guard let list = Self.list else { return log("keine eigene Liste offen") }
            return list.choose(pick)
        }
        close(host)
        let shape = value("shape") ?? "now"
        let elements = Self.elements(shape)
        let view = host.view!
        let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        switch value("mode") ?? "edit" {
        case "edit":
            editDelegate.menu = UIMenu(children: elements)
            let interaction = UIEditMenuInteraction(delegate: editDelegate)
            view.addInteraction(interaction)
            editInteraction = interaction
            interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
            log("Bearbeiten-Menü \(shape) bei \(Int(point.x)), \(Int(point.y)), Breite \(Int(view.bounds.width))")
        case "button", "buttonprivate":
            let button = UIButton(type: .system)
            button.frame = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            button.menu = UIMenu(children: elements)
            button.showsMenuAsPrimaryAction = true
            view.addSubview(button)
            Self.button = button
            if value("mode") == "button" {
                let sel = NSSelectorFromString("performPrimaryAction")
                guard button.responds(to: sel) else { return log("Knopf: performPrimaryAction fehlt") }
                _ = button.perform(sel)
                log("Knopf \(shape): performPrimaryAction aufgerufen")
            } else {
                let sel = NSSelectorFromString("_presentMenuAtLocation:")
                guard let interaction = button.contextMenuInteraction else { return log("Knopf: keine Interaktion") }
                guard interaction.responds(to: sel) else { return log("Knopf: _presentMenuAtLocation: fehlt") }
                typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
                let present = unsafeBitCast(interaction.method(for: sel), to: Present.self)
                present(interaction, sel, CGPoint(x: 22, y: 22))
                log("Knopf \(shape): _presentMenuAtLocation: aufgerufen")
            }
        case "popover":
            let controller = ListMenuController(elements: elements)
            controller.modalPresentationStyle = .popover
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
                popover.permittedArrowDirections = [.down, .up]
                popover.delegate = controller
            }
            host.present(controller, animated: false)
            list = controller
            log("eigene Liste \(shape): \(controller.rows.count) Einträge")
        default:
            log("unbekannte Art")
        }
    }

    static func log(_ text: String) {
        NSLog("Menü-Debug: %@", text)
    }

    private static func close(_ host: UIViewController) {
        editInteraction?.dismissMenu()
        if let interaction = editInteraction { interaction.view?.removeInteraction(interaction) }
        editInteraction = nil
        button?.contextMenuInteraction?.dismissMenu()
        button?.removeFromSuperview()
        button = nil
        if host.presentedViewController is ListMenuController { host.dismiss(animated: false) }
    }

    private static func elements(_ shape: String) -> [UIMenuElement] {
        func action(_ title: String, _ symbol: String? = nil) -> UIAction {
            UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }) { _ in log("gewählt \(title)") }
        }
        let claude: [UIMenuElement] = [action("Claude fragen", "questionmark.bubble"),
                                       action("Claude gründlich fragen", "text.bubble")]
        let plainClaude: [UIMenuElement] = [action("Claude fragen"), action("Claude gründlich fragen")]
        let pencilKit: [UIMenuElement] = [action("Ausschneiden"), action("Kopieren"), action("Löschen"),
                                          action("Duplizieren")]
        let pencilKitImages: [UIMenuElement] = [action("Ausschneiden", "scissors"), action("Kopieren", "doc.on.doc"),
                                                action("Löschen", "trash"),
                                                action("Duplizieren", "plus.square.on.square")]
        func group(_ children: [UIMenuElement]) -> UIMenu { UIMenu(title: "", options: .displayInline, children: children) }
        switch shape {
        case "nowflat": return [group(claude)] + pencilKit
        case "one": return [group(claude + pencilKit)]
        case "flat": return claude + pencilKit
        case "plain": return plainClaude + pencilKit
        case "pkfirst": return pencilKit + [group(claude)]
        case "pkonly": return pencilKit
        case "pkimg": return [group(claude), group(pencilKitImages)]
        case "short": return [action("Fragen", "questionmark.bubble"), action("Gründlich", "text.bubble")] + pencilKit
        case "many":
            return ["Eins", "Zwei", "Drei", "Vier", "Fünf", "Sechs", "Sieben", "Acht", "Neun", "Zehn"].map { action($0) }
        default: return [group(claude), group(pencilKit)]
        }
    }

    private final class EditDelegate: NSObject, UIEditMenuInteractionDelegate {
        var menu: UIMenu?

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            menu
        }
    }
}

/// Eigene Liste als Popover (Versuch): alle Einträge untereinander, Abschnitte durch Linien getrennt
final class ListMenuController: UIViewController, UIPopoverPresentationControllerDelegate {
    /// Die Einträge in Reihenfolge; nil steht für eine Trennlinie
    private(set) var rows: [UIMenuLeaf?] = []

    init(elements: [UIMenuElement]) {
        super.init(nibName: nil, bundle: nil)
        rows = Self.flatten(elements)
    }

    required init?(coder: NSCoder) { fatalError("nicht benutzt") }

    /// Blätter der Reihe nach; vor und nach einem Abschnitt eine Trennlinie (nie doppelt, nie am Rand)
    private static func flatten(_ elements: [UIMenuElement]) -> [UIMenuLeaf?] {
        var out: [UIMenuLeaf?] = []
        for element in elements {
            if let menu = element as? UIMenu {
                if let last = out.last, last != nil { out.append(nil) }
                out += flatten(menu.children)
                out.append(nil)
            } else if let leaf = element as? UIMenuLeaf {
                out.append(leaf)
            }
        }
        while let last = out.last, last == nil { out.removeLast() }
        return out
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            guard let leaf = row else {
                let line = UIView()
                line.backgroundColor = .separator
                line.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
                stack.addArrangedSubview(line)
                continue
            }
            var config = UIButton.Configuration.plain()
            config.title = leaf.title
            config.image = leaf.image
            config.imagePadding = 10
            config.baseForegroundColor = leaf.attributes.contains(.destructive) ? .systemRed : .label
            config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.choose(index) })
            button.contentHorizontalAlignment = .leading
            button.isEnabled = !leaf.attributes.contains(.disabled)
            stack.addArrangedSubview(button)
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        preferredContentSize = CGSize(width: max(size.width, 240), height: size.height + 8)
    }

    /// Eintrag N (ab 0, Trennlinien mitgezählt wie in `rows`) wählen: Liste zu, dann ausführen
    func choose(_ index: Int) {
        guard rows.indices.contains(index), let leaf = rows[index] else { return MenuDebug.log("kein Eintrag \(index)") }
        dismiss(animated: false) {
            leaf.performWithSender(nil, target: nil)
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
#endif
