import PencilKit
import CryptoKit
import UIKit

/// Ein Strich als JSON für den Server (und später die Web-Ansicht für Gäste).
/// Koordinaten in Seitenpunkten (Seite = 768 breit), die Transformation ist eingerechnet.
/// p: je Kontrollpunkt [x, y, Zeit, Breite, Höhe, Deckkraft, Druck, Azimut, Neigung, Zweitskala]
/// Die ID hängt nur an den ersten neun Werten, damit bestehende Striche ihre IDs behalten.
///
/// pk: der Strich im Originalformat von PencilKit (Base64). Aus den Punkten neu aufgebaut zeichnet
/// PencilKit einen Strich etwa doppelt so dick wie das Original; mit pk sieht er überall gleich aus.
/// Die Punkte bleiben für den Browser und für Striche ohne pk (aus dem Browser).
/// dx, dy: Verschiebung, die der Browser per Lasso angebracht hat (pk selbst kann er nicht ändern).
struct WireStroke: Codable {
    var ink: String
    var c: [Double]
    var p: [[Double]]
    var pk: String?
    var dx: Double?
    var dy: Double?
}

/// Entfernte Änderungen an einem Dokument: neue Striche (in Server-Reihenfolge) und gelöschte IDs
struct RemoteChanges {
    var added: [(id: String, data: String)] = []
    var removed: Set<String> = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    mutating func merge(_ other: RemoteChanges) {
        for id in other.removed {
            added.removeAll { $0.id == id }
            removed.insert(id)
        }
        for a in other.added {
            removed.remove(a.id)
            added.removeAll { $0.id == a.id }
            added.append(a)
        }
    }
}

enum StrokeCodec {
    private static func r(_ v: Double, _ scale: Double) -> Double { (v * scale).rounded() / scale }

    private static let inkTypes: [PKInk.InkType] = [.pen, .pencil, .marker, .monoline, .fountainPen, .watercolor, .crayon]

    static func wire(_ stroke: PKStroke, withPK: Bool = true) -> WireStroke {
        let t = stroke.transform
        let s = Double(sqrt(abs(t.a * t.d - t.b * t.c)))
        let points = stroke.path.map { pt -> [Double] in
            let q = pt.location.applying(t)
            return [r(Double(q.x), 100), r(Double(q.y), 100), r(pt.timeOffset, 1000),
                    r(Double(pt.size.width) * s, 100), r(Double(pt.size.height) * s, 100),
                    r(Double(pt.opacity), 1000), r(Double(pt.force), 1000),
                    r(Double(pt.azimuth), 1000), r(Double(pt.altitude), 1000),
                    r(Double(pt.secondaryScale), 1000)]
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let color = [red, green, blue, alpha].map { r(Double($0), 1000) }
        let pk = withPK ? PKDrawing(strokes: [stroke]).dataRepresentation().base64EncodedString() : nil
        return WireStroke(ink: stroke.ink.inkType.rawValue, c: color, p: points, pk: pk)
    }

    /// Kodiert alle Striche; die ID hängt nur von Form und Tintenart ab, gleiche Striche zählen mit (#2, #3 …)
    /// JSON eines Strichs für den Server (mit PencilKit-Original); nur für Striche, die hochgeladen werden
    static func data(_ stroke: PKStroke) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(wire(stroke))).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// IDs aller Striche (ohne das teure JSON); `data(_:)` liefert bei Bedarf den Inhalt
    static func encodeAll(_ strokes: [PKStroke]) -> [(id: String, stroke: PKStroke)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var seen: [String: Int] = [:]
        return strokes.map { stroke in
            let w = wire(stroke, withPK: false)
            let geometry = (try? encoder.encode([w.ink] + w.p.map { $0.prefix(9).map { String($0) }.joined(separator: ",") })) ?? Data()
            let digest = SHA256.hash(data: geometry).prefix(12).map { String(format: "%02x", $0) }.joined()
            let n = (seen[digest] ?? 0) + 1
            seen[digest] = n
            let id = n == 1 ? digest : "\(digest)#\(n)"
            return (id, stroke)
        }
    }

    static func decode(_ json: String) -> PKStroke? {
        guard let w = try? JSONDecoder().decode(WireStroke.self, from: Data(json.utf8)), !w.p.isEmpty else { return nil }
        if let pk = w.pk, let data = Data(base64Encoded: pk),
           var stroke = (try? PKDrawing(data: data))?.strokes.first {
            if w.dx != nil || w.dy != nil {
                stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: w.dx ?? 0, y: w.dy ?? 0))
            }
            return stroke
        }
        let points = w.p.compactMap { a -> PKStrokePoint? in
            guard a.count >= 9 else { return nil }
            if a.count >= 10 {
                return PKStrokePoint(location: CGPoint(x: a[0], y: a[1]), timeOffset: a[2],
                                     size: CGSize(width: a[3], height: a[4]), opacity: CGFloat(a[5]),
                                     force: CGFloat(a[6]), azimuth: CGFloat(a[7]), altitude: CGFloat(a[8]),
                                     secondaryScale: CGFloat(a[9]))
            }
            return PKStrokePoint(location: CGPoint(x: a[0], y: a[1]), timeOffset: a[2],
                                 size: CGSize(width: a[3], height: a[4]), opacity: CGFloat(a[5]),
                                 force: CGFloat(a[6]), azimuth: CGFloat(a[7]), altitude: CGFloat(a[8]))
        }
        guard !points.isEmpty else { return nil }
        let c = w.c.count >= 4 ? w.c : [0, 0, 0, 1]
        let color = UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
        let type = inkTypes.first { $0.rawValue == w.ink } ?? .pen
        return PKStroke(ink: PKInk(type, color: color),
                        path: PKStrokePath(controlPoints: points, creationDate: Date()),
                        transform: .identity, mask: nil)
    }

    /// Wendet entfernte Änderungen auf eine Zeichnung (Seitenpunkte) an; nil, wenn sich nichts ändert
    static func apply(_ changes: RemoteChanges, to drawing: PKDrawing) -> PKDrawing? {
        guard !changes.isEmpty else { return nil }
        let ids = encodeAll(drawing.strokes).map(\.id)
        var strokes: [PKStroke] = []
        var present = Set<String>()
        var changed = false
        for (i, stroke) in drawing.strokes.enumerated() {
            if changes.removed.contains(ids[i]) {
                changed = true
                continue
            }
            strokes.append(stroke)
            present.insert(ids[i])
        }
        for a in changes.added where !present.contains(a.id) {
            if let stroke = decode(a.data) {
                strokes.append(stroke)
                present.insert(a.id)
                changed = true
            }
        }
        return changed ? PKDrawing(strokes: strokes) : nil
    }
}
