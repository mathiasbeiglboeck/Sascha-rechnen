import UIKit

/// Wo eine Notiz von „Claude schreiben lassen“ steht, in Seitenpunkten (alle Seiten untereinander): der gesetzte Text
/// und der Rahmen um eine Stelle (beides wahlweise)
struct NotePlacement {
    var text: CGRect?
    var box: CGRect?

    var bounds: CGRect { (text ?? .null).union(box ?? .null) }

    /// `size`: Größe des gesetzten Texts (Breite = Breite der Notiz), nil = noch nicht gesetzt
    static func of(_ note: AskNote, frame: CGRect, size: CGSize?) -> NotePlacement {
        var p = NotePlacement()
        if let size, size.width > 0, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let w = CGFloat(NoteTypesetter.width(note))
            p.text = CGRect(x: frame.minX + CGFloat(note.x) * frame.width, y: frame.minY + CGFloat(note.y) * frame.height,
                            width: w, height: w * size.height / size.width)
        }
        if let b = note.box, b.count == 4 {
            p.box = CGRect(x: frame.minX + CGFloat(min(b[0], b[2])) * frame.width,
                           y: frame.minY + CGFloat(min(b[1], b[3])) * frame.height,
                           width: CGFloat(abs(b[2] - b[0])) * frame.width,
                           height: CGFloat(abs(b[3] - b[1])) * frame.height)
        }
        return p
    }

    /// Strichbreite des Rahmens in Seitenpunkten
    static let boxLine: CGFloat = 1.6
}

/// Die Notizen von „Claude schreiben lassen“ auf den Seiten: gedruckter Text ohne Hintergrund und Rahmen um Stellen.
/// Liegt im Scrollbereich über den Seiten und unter der Tinte und wird wie die Seiten mitskaliert (gleiche
/// Koordinaten: Seitenpunkte). Nur Anzeige: Antippen erkennt die Leinwand (`hit`)
final class NotesOverlay: UIView {
    /// Eine angezeigte Notiz: zu welcher Frage, ihre Nummer dort, wo sie steht
    struct Placed {
        let ask: String
        let index: Int
        let note: AskNote
        let place: NotePlacement
    }

    private(set) var placed: [Placed] = []
    private var textViews: [String: NoteTextView] = [:]
    private let boxLayer = CALayer()

    var pixelScale: CGFloat = 0 {
        didSet {
            guard pixelScale != oldValue else { return }
            for v in textViews.values { v.pixelScale = pixelScale }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        layer.addSublayer(boxLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Alle Notizen der sichtbaren, beantworteten Fragen; was noch nicht gesetzt ist, wird gesetzt und kommt mit
    /// `typeset` (dann `set` noch einmal aufrufen)
    @MainActor
    func set(_ asks: [Ask], frames: [CGRect], typeset: @escaping () -> Void) {
        var list: [Placed] = []
        var missing: [AskNote] = []
        for ask in asks where ask.isWrite {
            for (index, note) in ask.shownNotes where frames.indices.contains(note.page) {
                let t = NoteTypesetter.cached(note)
                if t == nil, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(note) }
                list.append(Placed(ask: ask.id, index: index, note: note,
                                   place: .of(note, frame: frames[note.page], size: t?.size)))
            }
        }
        placed = list
        if !missing.isEmpty { NoteTypesetter.prepare(missing, done: typeset) }

        // Texte: vorhandene Ansichten behalten, wenn Text und Stelle gleich sind (sonst zeichnen sie neu)
        var keep: [String: NoteTextView] = [:]
        for p in list {
            guard let rect = p.place.text, let t = NoteTypesetter.cached(p.note) else { continue }
            let key = "\(p.ask)#\(p.index)"
            let view: NoteTextView
            if let old = textViews[key], old.note == p.note {
                view = old
            } else {
                textViews[key]?.removeFromSuperview()
                view = NoteTextView(note: p.note, typeset: t)
                view.pixelScale = pixelScale
                addSubview(view)
            }
            if view.frame != rect { view.frame = rect }
            keep[key] = view
        }
        for (key, v) in textViews where keep[key] == nil { v.removeFromSuperview() }
        textViews = keep

        // Rahmen
        boxLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for p in list {
            guard let box = p.place.box else { continue }
            let shape = CAShapeLayer()
            shape.path = UIBezierPath(roundedRect: box, cornerRadius: 4).cgPath
            shape.fillColor = nil
            shape.strokeColor = NoteTypesetter.uiColor(p.note.color).withAlphaComponent(0.85).cgColor
            shape.lineWidth = NotePlacement.boxLine
            boxLayer.addSublayer(shape)
        }
        bringBoxesToFront()
    }

    private func bringBoxesToFront() {
        boxLayer.removeFromSuperlayer()
        layer.addSublayer(boxLayer)
    }

    /// Die Notiz an `point` (Koordinaten dieser Ansicht, also Seitenpunkte), die oberste zuerst
    func hit(_ point: CGPoint, padding: CGFloat = 4) -> Placed? {
        placed.reversed().first { p in
            if let t = p.place.text, t.insetBy(dx: -padding, dy: -padding).contains(point) { return true }
            if let b = p.place.box, b.insetBy(dx: -padding, dy: -padding).contains(point) { return true }
            return false
        }
    }

    /// Wo Notizen auf einer Seite stehen, für den Export: je Seite die Notizen mit Lage relativ zur Seite
    @MainActor
    static func forExport(_ asks: [Ask], frames: [CGRect]) -> [Int: [PageExport.Note]] {
        var out: [Int: [PageExport.Note]] = [:]
        for ask in asks where ask.isWrite {
            for (_, note) in ask.shownNotes where frames.indices.contains(note.page) {
                let frame = frames[note.page]
                let t = NoteTypesetter.cached(note)
                let p = NotePlacement.of(note, frame: frame, size: t?.size)
                let local = { (r: CGRect?) in r.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) } }
                out[note.page, default: []].append(PageExport.Note(
                    text: t.flatMap { t in local(p.text).map { ($0, t) } }, box: local(p.box),
                    color: NoteTypesetter.uiColor(note.color).cgColor))
            }
        }
        return out
    }
}

/// Der gesetzte Text einer Notiz. CATiledLayer zeichnet beim Hineinzoomen schärfer nach (wie die Seiten)
final class NoteTextView: UIView {
    override class var layerClass: AnyClass { CATiledLayer.self }

    let note: AskNote
    private let typeset: NoteTypesetter.Typeset

    init(note: AskNote, typeset: NoteTypesetter.Typeset) {
        self.note = note
        self.typeset = typeset
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 3
        tiled.tileSize = CGSize(width: 512, height: 512)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Bildschirmpunkte je Seitenpunkt bei Zoom 1 (wie PageView)
    var pixelScale: CGFloat = 0 {
        didSet { if pixelScale != oldValue { applyPixelScale() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPixelScale()
    }

    private func applyPixelScale() {
        guard pixelScale > 0, let screen = window?.windowScene?.screen else { return }
        let scale = screen.scale * pixelScale
        guard abs(layer.contentsScale - scale) > 0.0001 else { return }
        layer.contentsScale = scale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        typeset.draw(in: ctx, rect: bounds)
    }
}
