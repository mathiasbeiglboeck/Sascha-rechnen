import UIKit

/// Markierungen von „Claude fragen“: eine kleine Sprechblase rechts oben neben jeder Frage. Grau mit Uhr, solange
/// sie wartet; grau mit Pünktchen, während Claude am Mac nachdenkt; blau, sobald die Antwort da ist (gefüllt, bis sie
/// gelesen ist); orange, wenn es nicht geklappt hat.
///
/// Liegt im Scrollbereich der Leinwand über der Tinte, wird aber nicht mitskaliert: Die Blasen bleiben bei jedem
/// Zoom gleich groß, nur ihre Stelle folgt den Seiten (`layout(scale:)`). Nur Anzeige: Antippen erkennt die
/// Leinwand (MarkTapGesture). Gehört nie zur Zeichnung, also auch nicht in Export, Briefkasten oder Teilen.
final class AskOverlay: UIView {
    static let size: CGFloat = 26

    private var marks: [String: AskMarkView] = [:]
    /// Ecke rechts oben der Frage, in Seitenpunkten (alle Seiten untereinander)
    private var anchors: [String: CGPoint] = [:]
    /// Rechteck der Frage in Seitenpunkten (für die Hervorhebung, solange ihre Karte offen ist)
    private var rects: [String: CGRect] = [:]
    /// Von oben nach unten
    private var order: [String] = []
    private var scale: CGFloat = 0
    private var highlighted: String?
    private let highlight = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false
        highlight.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        highlight.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        highlight.lineWidth = 1.5
        highlight.lineDashPattern = [5, 4]
        highlight.isHidden = true
        layer.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Zeigt die Fragen, die zu diesen Seiten passen: Seite vorhanden, und ihre Stelle gehört nicht zu einem
    /// neueren Seitenstand als dem hier (sonst stünde sie kurz auf der falschen Seite, bis die neuen Seiten da sind)
    func set(_ asks: [Ask], frames: [CGRect], pagesVersion: Int) {
        var keep = Set<String>()
        for ask in asks where ask.isVisible && frames.indices.contains(ask.anchor.page) && ask.pv <= pagesVersion {
            let page = frames[ask.anchor.page]
            let rect = ask.anchor.rect.offsetBy(dx: page.minX, dy: page.minY)
            keep.insert(ask.id)
            anchors[ask.id] = CGPoint(x: rect.maxX, y: rect.minY)
            rects[ask.id] = rect
            let mark = marks[ask.id] ?? {
                let m = AskMarkView()
                addSubview(m)
                marks[ask.id] = m
                return m
            }()
            mark.show(ask)
        }
        for (id, mark) in marks where !keep.contains(id) {
            mark.removeFromSuperview()
            marks[id] = nil
            anchors[id] = nil
            rects[id] = nil
        }
        order = keep.sorted { (anchors[$0]?.y ?? 0, $0) < (anchors[$1]?.y ?? 0, $1) }
        if let highlighted, !keep.contains(highlighted) { self.highlighted = nil }
        if scale > 0 { layout(scale: scale) }
    }

    /// Stellen in Inhaltspunkten der Leinwand; `s` = Bildschirmpunkte je Seitenpunkt (k · Zoom). An denselben Stellen
    /// aufrufen wie das Skalieren der Seiten
    func layout(scale s: CGFloat) {
        guard s > 0 else { return }
        scale = s
        let w = Self.size
        let maxX = PageLayout.width * s - w - 2
        var placed: [CGRect] = []
        for id in order {
            guard let a = anchors[id], let mark = marks[id] else { continue }
            var f = CGRect(x: a.x * s + 4, y: a.y * s - 4, width: w, height: w)
            // Kein Platz rechts der Frage: über ihr rechtem Ende
            if f.minX > maxX { f.origin = CGPoint(x: maxX, y: a.y * s - w - 4) }
            // Nicht übereinander: die nächste darunter
            while let hit = placed.first(where: { $0.intersects(f) }) { f.origin.y = hit.maxY + 4 }
            mark.frame = f
            placed.append(f)
        }
        updateHighlight()
    }

    /// Markierung unter `p` (Inhaltspunkte der Leinwand), mit `padding` Punkten Spielraum für den Finger
    func mark(at p: CGPoint, padding: CGFloat) -> String? {
        order.last { marks[$0]?.frame.insetBy(dx: -padding, dy: -padding).contains(p) == true }
    }

    func view(for id: String) -> UIView? { marks[id] }

    /// Umrandet die Frage, solange ihre Karte offen ist (nil: keine)
    func highlight(_ id: String?) {
        highlighted = id
        updateHighlight()
    }

    private func updateHighlight() {
        guard let id = highlighted, let r = rects[id], scale > 0 else {
            highlight.isHidden = true
            return
        }
        let box = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            .insetBy(dx: -6, dy: -6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.path = UIBezierPath(roundedRect: box, cornerRadius: 6).cgPath
        highlight.isHidden = false
        CATransaction.commit()
    }
}

/// Eine Sprechblase auf weißem Grund (auch auf dunklen PDF-Seiten zu sehen)
final class AskMarkView: UIView {
    private let symbol = UIImageView()
    private let badge = UIImageView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: AskOverlay.size, height: AskOverlay.size))
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.cornerRadius = AskOverlay.size / 2
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        symbol.contentMode = .center
        symbol.frame = bounds
        symbol.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(symbol)
        badge.contentMode = .center
        badge.frame = CGRect(x: AskOverlay.size - 10, y: -4, width: 14, height: 14)
        badge.backgroundColor = .white
        badge.layer.cornerRadius = 7
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    func show(_ ask: Ask) {
        let name: String, color: UIColor, clock: Bool, label: String
        switch ask.status {
        case "answered":
            name = ask.seen == true ? "text.bubble" : "text.bubble.fill"
            color = .systemBlue
            clock = false
            label = "Antwort von Claude"
        case "failed":
            name = "exclamationmark.bubble.fill"
            color = .systemOrange
            clock = false
            label = "Frage an Claude, fehlgeschlagen"
        case "claimed":
            name = "ellipsis.bubble.fill"
            color = .systemGray
            clock = false
            label = "Claude denkt nach"
        default:
            name = "bubble.left.fill"
            color = .systemGray2
            clock = true
            label = "Frage an Claude, wartet"
        }
        symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        symbol.tintColor = color
        badge.image = clock
            ? UIImage(systemName: "clock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
            : nil
        badge.tintColor = .systemGray
        badge.isHidden = !clock
        accessibilityLabel = label
    }
}
