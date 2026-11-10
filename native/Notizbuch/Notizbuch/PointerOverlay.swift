import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Zeigestift: leuchtende Linien, um Mitschauende auf etwas hinzuweisen.
/// Sie werden nie gespeichert und laufen nicht über den Strich-Abgleich, sondern gehen direkt
/// über die Live-Verbindung an alle anderen. Etwa zehn Sekunden nach dem Absetzen verblassen sie;
/// wer gleich weiterzeigt, hält alle seine Linien so lange sichtbar.
///
/// Koordinaten in Seitenpunkten (wie die Seiten), die Ansicht wird mit der Leinwand skaliert.
final class PointerOverlay: UIView {
    static let color = UIColor(red: 1.0, green: 0.12, blue: 0.56, alpha: 1)
    /// Breite in Seitenpunkten
    static let width: CGFloat = 4.5
    static let fadeAfter: TimeInterval = 10

    private struct Line {
        let author: String
        var points: [CGPoint]
        let halo: CAShapeLayer
        let core: CAShapeLayer
    }

    private var lines: [String: Line] = [:]
    private var fades: [String: DispatchWorkItem] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Punkte an eine Linie anhängen (neue Linie, wenn die ID unbekannt ist)
    func add(id: String, author: String, points: [CGPoint], end: Bool) {
        var line: Line
        if let existing = lines[id] {
            line = existing
        } else {
            let halo = CAShapeLayer(), core = CAShapeLayer()
            for (layer, w, alpha) in [(halo, Self.width * 3.2, CGFloat(0.22)), (core, Self.width, CGFloat(1))] {
                layer.fillColor = nil
                layer.strokeColor = Self.color.withAlphaComponent(alpha).cgColor
                layer.lineWidth = w
                layer.lineCap = .round
                layer.lineJoin = .round
                self.layer.addSublayer(layer)
            }
            line = Line(author: author, points: [], halo: halo, core: core)
        }
        line.points += points
        lines[id] = line
        if !line.points.isEmpty {
            let path = Self.path(line.points)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.halo.path = path
            line.core.path = path
            CATransaction.commit()
        }
        // Solange jemand zeigt, bleibt alles von ihm stehen; danach (oder wenn das Ende nie ankommt) verblassen
        fades[author]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fade(author) }
        fades[author] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (end ? Self.fadeAfter : 2 * Self.fadeAfter), execute: work)
    }

    private func fade(_ author: String) {
        fades[author] = nil
        let ids = lines.filter { $0.value.author == author }.map(\.key)
        let layers = ids.compactMap { lines[$0] }.flatMap { [$0.halo, $0.core] }
        for id in ids { lines[id] = nil }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        CATransaction.setCompletionBlock { for l in layers { l.removeFromSuperlayer() } }
        for l in layers { l.opacity = 0 }
        CATransaction.commit()
    }

    /// Weiche Linie durch die Punkte (Mittelpunkte als Stützstellen)
    private static func path(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p[0])
        if p.count < 3 {
            for q in p.dropFirst() { path.addLine(to: q) }
            if p.count == 1 { path.addLine(to: p[0]) }
            return path
        }
        for i in 1..<(p.count - 1) {
            let mid = CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: p[i])
        }
        path.addLine(to: p[p.count - 1])
        return path
    }
}

/// Sammelt alle Punkte (auch die zwischen zwei Bildern, „coalesced“) in den Koordinaten von `target`
final class PointerGesture: UIGestureRecognizer {
    weak var space: UIView?
    private var samples: [CGPoint] = []

    /// Neue Punkte seit dem letzten Abholen
    func takeSamples() -> [CGPoint] {
        defer { samples.removeAll() }
        return samples
    }

    private func collect(_ touch: UITouch, _ event: UIEvent) {
        let space = self.space ?? view
        for t in event.coalescedTouches(for: touch) ?? [touch] {
            samples.append(t.location(in: space))
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible, touches.count == 1, let t = touches.first else {
            state = .failed
            return
        }
        samples.append(t.location(in: space ?? view))
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { collect(t, event) }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first { samples.append(t.location(in: space ?? view)) }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        samples.removeAll()
    }
}
