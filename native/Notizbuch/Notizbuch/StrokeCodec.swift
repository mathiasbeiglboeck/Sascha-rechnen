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
/// alias: Die ID stammt aus einem Alias (siehe `StrokeCodec.apply`), nicht aus PencilKits Werten; Empfänger prüfen
/// sie wie bei einem Strich aus dem Browser. Ältere Apps übergehen das Feld.
struct WireStroke: Codable {
    var ink: String
    var c: [Double]
    var p: [[Double]]
    var pk: String?
    var dx: Double?
    var dy: Double?
    var alias: Bool?
}

/// Entfernte Änderungen an einem Dokument: neue Striche (in Server-Reihenfolge) und gelöschte IDs
struct RemoteChanges {
    var added: [(id: String, data: String)] = []
    var removed: Set<String> = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    /// Neuere Änderungen (`other`) gewinnen. Linear statt quadratisch: nach einer Seitenänderung
    /// kommen Tausende Striche auf einmal
    mutating func merge(_ other: RemoteChanges) {
        guard !other.isEmpty else { return }
        guard !isEmpty else {
            self = other
            return
        }
        var replaced = other.removed
        for a in other.added { replaced.insert(a.id) }
        added.removeAll { replaced.contains($0.id) }
        removed.formUnion(other.removed)
        // Pro ID gilt die letzte Hinzufügung in `other`, in ihrer Reihenfolge
        var last: [String: Int] = [:]
        for (i, a) in other.added.enumerated() { last[a.id] = i }
        for (i, a) in other.added.enumerated() where last[a.id] == i {
            removed.remove(a.id)
            added.append(a)
        }
    }
}

/// Merkt sich die ID jedes Strichs. Die ID ist ein Hash über alle Punkte und damit teuer; ohne diesen
/// Speicher würde jeder Abgleich alle Striche des Dokuments neu hashen, im 100-Seiten-Skriptum Zehntausende.
/// So kostet ein Abgleich nur noch einen kurzen Blick auf jeden Strich, gehasht werden nur neue.
/// Nur auf dem Hauptthread verwenden.
final class StrokeIDCache {
    static let shared = StrokeIDCache()

    /// Was einen Strich ausmacht, ohne alle Punkte anzusehen: derselbe Pfad (Entstehungszeit, Zahl und
    /// Lage der Endpunkte), dieselbe Tintenart, dieselbe Lage auf der Seite. Die Zahlen sind exakt, nicht
    /// gerundet: Weicht etwas auch nur im letzten Bit ab, wird eben neu gehasht.
    struct Key: Hashable, Sendable {
        let created: Double
        let count: Int
        let x0: Double, y0: Double, t0: Double
        let x1: Double, y1: Double, t1: Double
        let a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
        let ink: String
    }

    private var digests: [Key: String] = [:]
    /// So groß wird der Speicher höchstens, solange die offene Leinwand nicht selbst aufräumt
    private static let maxWithoutPrune = 150_000

    /// Wer den Speicher aufräumen darf (dann bleiben nur die Striche dieses Aufrufs)
    enum Pruning {
        /// Die offene Leinwand: ab dem Dreifachen ihrer Striche, mindestens 60 000 Einträgen
        case canvas
        /// Ein geschlossenes Dokument, während keine Leinwand offen ist: erst ab `maxWithoutPrune`
        case closed
        /// Ein anderes Dokument, während eine Leinwand offen ist: nie (sonst verlöre sie ihre IDs und müsste beim
        /// nächsten Strich alles neu hashen); über `maxWithoutPrune` wird dann nichts mehr dazugemerkt
        case never
    }

    static func key(_ stroke: PKStroke, _ toPage: CGAffineTransform) -> Key {
        let t = StrokeCodec.pageTransform(stroke, toPage)
        let path = stroke.path
        let first = path.first, last = path.last
        return Key(created: path.creationDate.timeIntervalSinceReferenceDate, count: path.count,
                   x0: Double(first?.location.x ?? 0), y0: Double(first?.location.y ?? 0), t0: first?.timeOffset ?? 0,
                   x1: Double(last?.location.x ?? 0), y1: Double(last?.location.y ?? 0), t1: last?.timeOffset ?? 0,
                   a: Double(t.a), b: Double(t.b), c: Double(t.c), d: Double(t.d), tx: Double(t.tx), ty: Double(t.ty),
                   ink: stroke.ink.inkType.rawValue)
    }

    /// IDs in Zeichnungsreihenfolge; gleiche Striche zählen mit (#2, #3 …).
    /// `toPage` rechnet die Striche in Seitenpunkte um, denn die ID gilt in Seitenpunkten.
    /// `pruning` sagt, ob dieser Aufruf den Speicher aufräumen darf (siehe `Pruning`).
    /// `aliases`: die Aliase des Dokuments (eigene Prüfsumme → ID des Servers, siehe `StrokeCodec.apply`). Der Speicher
    /// hält nur eigene Prüfsummen, die Aliase gelten je Aufruf: Fällt einer weg, bleibt nichts Veraltetes zurück.
    /// Den Alias bekommt nur der erste Strich mit dieser Prüfsumme; weitere gleiche behalten ihre eigene. So heißen sie
    /// wie am Server, etwa eine Kopie, die ein anderes Gerät nach Verlust seines Sync-Stands unter ihr hochgeladen hat
    /// (sonst träfe sein Löschen sie nicht). Ohne Aliase (fast immer) läuft alles wie bisher
    func ids(for strokes: [PKStroke], toPage: CGAffineTransform = .identity, pruning: Pruning = .never,
             aliases: [String: String]) -> [String] {
        var seen: [String: Int] = [:]
        seen.reserveCapacity(strokes.count)
        var result: [String] = []
        result.reserveCapacity(strokes.count)
        let aliased = !aliases.isEmpty
        for stroke in strokes {
            let key = Self.key(stroke, toPage)
            var digest: String
            if let hit = digests[key] {
                digest = hit
            } else {
                digest = StrokeCodec.digest(stroke, toPage: toPage)
                if pruning != .never || digests.count < Self.maxWithoutPrune { digests[key] = digest }
            }
            if aliased, let server = aliases[digest], seen[server] == nil { digest = server }
            let n = (seen[digest] ?? 0) + 1
            seen[digest] = n
            result.append(n == 1 ? digest : "\(digest)#\(n)")
        }
        // Viele alte Einträge (verschobene Striche, andere Dokumente): nur die aktuellen behalten
        let limit: Int
        switch pruning {
        case .canvas: limit = max(3 * strokes.count, 60_000)
        case .closed: limit = max(3 * strokes.count, Self.maxWithoutPrune)
        case .never: limit = .max
        }
        if digests.count > limit {
            var keep: [Key: String] = [:]
            keep.reserveCapacity(strokes.count)
            for stroke in strokes {
                let key = Self.key(stroke, toPage)
                if let d = digests[key] { keep[key] = d }
            }
            digests = keep
        }
        return result
    }

    /// Merkt sich die eigene Prüfsumme eines eben eingefügten Strichs, die `StrokeCodec.apply` schon berechnet hat:
    /// Der nächste Abgleich hasht ihn dann nicht noch einmal
    func pin(_ stroke: PKStroke, toPage: CGAffineTransform, digest: String, pruning: Pruning) {
        guard pruning != .never || digests.count < Self.maxWithoutPrune else { return }
        digests[Self.key(stroke, toPage)] = digest
    }

    /// Berechnet fehlende IDs im Hintergrund, etwa beim Öffnen eines großen Dokuments, damit der erste
    /// Abgleich die App nicht anhält
    @MainActor
    func prewarm(_ strokes: [PKStroke], toPage: CGAffineTransform = .identity) async {
        var missing: [(Key, PKStroke)] = []
        for stroke in strokes {
            let key = Self.key(stroke, toPage)
            if digests[key] == nil { missing.append((key, stroke)) }
        }
        guard !missing.isEmpty else { return }
        let box = UncheckedBox(missing)
        let computed = await Task.detached(priority: .userInitiated) { () -> [(Key, String)] in
            box.value.map { ($0.0, StrokeCodec.digest($0.1, toPage: toPage)) }
        }.value
        for (key, digest) in computed { digests[key] = digest }
    }
}

/// Für Werte, die nur gelesen über Threads gehen (PencilKit-Striche und -Zeichnungen sind Werttypen)
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

enum StrokeCodec {
    private static func r(_ v: Double, _ scale: Double) -> Double { (v * scale).rounded() / scale }

    private static let inkTypes: [PKInk.InkType] = [.pen, .pencil, .marker, .monoline, .fountainPen, .watercolor, .crayon]

    /// Die zehn Werte eines Kontrollpunkts in Seitenpunkten (Transformation `t`, Größenfaktor `s`)
    private static func values(_ pt: PKStrokePoint, _ t: CGAffineTransform, _ s: Double) -> [Double] {
        let q = pt.location.applying(t)
        return [r(Double(q.x), 100), r(Double(q.y), 100), r(pt.timeOffset, 1000),
                r(Double(pt.size.width) * s, 100), r(Double(pt.size.height) * s, 100),
                r(Double(pt.opacity), 1000), r(Double(pt.force), 1000),
                r(Double(pt.azimuth), 1000), r(Double(pt.altitude), 1000),
                r(Double(pt.secondaryScale), 1000)]
    }

    /// Transformation des Strichs in Seitenpunkten (bei schon passender Zeichnung unverändert, auch im letzten Bit)
    static func pageTransform(_ stroke: PKStroke, _ toPage: CGAffineTransform) -> CGAffineTransform {
        toPage.isIdentity ? stroke.transform : stroke.transform.concatenating(toPage)
    }

    private static func scale(of t: CGAffineTransform) -> Double {
        Double(sqrt(abs(t.a * t.d - t.b * t.c)))
    }

    static func wire(_ stroke: PKStroke, withPK: Bool = true) -> WireStroke {
        let t = stroke.transform
        let s = scale(of: t)
        let points = stroke.path.map { values($0, t, s) }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let color = [red, green, blue, alpha].map { r(Double($0), 1000) }
        let pk = withPK ? PKDrawing(strokes: [stroke]).dataRepresentation().base64EncodedString() : nil
        return WireStroke(ink: stroke.ink.inkType.rawValue, c: color, p: points, pk: pk)
    }

    /// JSON eines Strichs für den Server (mit PencilKit-Original); nur für Striche, die hochgeladen werden.
    /// `alias`: Die ID stammt aus einem Alias (siehe `WireStroke.alias`)
    static func data(_ stroke: PKStroke, alias: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var w = wire(stroke)
        if alias { w.alias = true }
        return (try? encoder.encode(w)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Hash über Tintenart und die ersten neun Werte jedes Punkts (ohne Nummer für gleiche Striche).
    /// Gleiche Bytes wie früher JSONEncoder für ["Tinte", "x,y,…", …]: Die Texte enthalten nur Ziffern,
    /// Punkte, Kommas, Minus, „e“ und die Tintenart, nichts, was JSON maskieren müsste.
    /// Läuft auch im Hintergrund (kein UIKit).
    static func digest(_ stroke: PKStroke, toPage: CGAffineTransform = .identity) -> String {
        let t = pageTransform(stroke, toPage)
        let s = scale(of: t)
        var json = "[\"" + stroke.ink.inkType.rawValue + "\""
        for pt in stroke.path {
            json += ",\""
            json += values(pt, t, s).prefix(9).map { String($0) }.joined(separator: ",")
            json += "\""
        }
        json += "]"
        return SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ json: String) -> PKStroke? { decodeWire(json)?.stroke }

    /// Wie `decode`, dazu `check`: Die ID des Servers stammt womöglich nicht aus PencilKits Werten (aus Punkten gebaut,
    /// vom Browser verschoben oder unter einem Alias hochgeladen); `apply` prüft sie dann
    static func decodeWire(_ json: String) -> (stroke: PKStroke, check: Bool)? {
        guard let w = try? JSONDecoder().decode(WireStroke.self, from: Data(json.utf8)), !w.p.isEmpty else { return nil }
        if let pk = w.pk, let data = Data(base64Encoded: pk),
           var stroke = (try? PKDrawing(data: data))?.strokes.first {
            let moved = w.dx != nil || w.dy != nil
            if moved {
                stroke.transform = stroke.transform.concatenating(CGAffineTransform(translationX: w.dx ?? 0, y: w.dy ?? 0))
            }
            return (stroke, moved || w.alias == true)
        }
        let points = w.p.compactMap { a -> PKStrokePoint? in
            guard a.count >= 9 else { return nil }
            if a.count >= 10 {
                return PKStrokePoint(location: CGPoint(x: a[0], y: a[1]), timeOffset: a[2],
                                     size: CGSize(width: a[3], height: a[4]), opacity: CGFloat(a[5]),
                                     force: CGFloat(a[6]), azimuth: CGFloat(a[7]), altitude: CGFloat(a[8]),
                                     secondaryScale: CGFloat(a[9]))
            }
            // Nur neun Werte (aus dem Browser): PencilKit zeichnet einen so gebauten Strich 2 · Breite − 4 dick (in
            // Seitenpunkten, im Simulator gemessen; unter etwa 2 gar nicht). Mit halber Breite plus 2 also so dick wie
            // im Browser. Auf zwei Stellen gerundet wie in der ID: Genau auf der Rundungsgrenze (etwa 3,125) hinge die
            // ID sonst davon ab, ob der Strich auf der Leinwand oder in der Datei liegt. Die Zweitskala hält die Breite
            // des Browsers: Lädt die App den Strich später mit zehn Werten hoch, zeichnet der Browser ihn
            // Breite × Zweitskala × 2 dick, also wie vorher
            let width = r((max(a[3], 0) + 4) / 2, 100), height = r((max(a[4], 0) + 4) / 2, 100)
            return PKStrokePoint(location: CGPoint(x: a[0], y: a[1]), timeOffset: a[2],
                                 size: CGSize(width: width, height: height), opacity: CGFloat(a[5]),
                                 force: CGFloat(a[6]), azimuth: CGFloat(a[7]), altitude: CGFloat(a[8]),
                                 secondaryScale: CGFloat(max(a[3], 0) / (2 * width)))
        }
        guard !points.isEmpty else { return nil }
        let c = w.c.count >= 4 ? w.c : [0, 0, 0, 1]
        let color = UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
        let type = inkTypes.first { $0.rawValue == w.ink } ?? .pen
        let stroke = PKStroke(ink: PKInk(type, color: color),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()),
                              transform: .identity, mask: nil)
        return (stroke, true)
    }

    /// Wendet entfernte Änderungen (Striche in Seitenpunkten) auf eine Zeichnung an; nil, wenn sich nichts ändert.
    /// Unveränderte Striche bleiben, wie sie sind: Neue werden nur angehängt, ohne die ganze Zeichnung umzurechnen.
    /// - Parameter scale: Punkte der Zeichnung je Seitenpunkt (Leinwand: Faktor k; Datei: 1)
    /// - Parameter aliases: die Aliase des Dokuments (eigene Prüfsumme → ID des Servers, die des Sync-Stands). Sie
    ///   ändern sich hier, auch wenn die Zeichnung gleich bleibt
    /// - Parameter rekeyed: wird true, wenn ein schon vorhandener Strich nun unter der ID des Servers gilt (siehe
    ///   unten). Seine alte ID steht dann vielleicht noch am Server: Der nächste Abgleich muss die Zeichnung neu erfassen
    static func apply(_ changes: RemoteChanges, to drawing: PKDrawing, scale: CGFloat = 1,
                      pruning: StrokeIDCache.Pruning = .never,
                      aliases: inout [String: String], rekeyed: inout Bool) -> (drawing: PKDrawing, wasEmpty: Bool)? {
        guard !changes.isEmpty else { return nil }
        let strokes = drawing.strokes
        let toPage = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        let ids = StrokeIDCache.shared.ids(for: strokes, toPage: toPage, pruning: pruning, aliases: aliases)
        var present = Set<String>(minimumCapacity: ids.count + changes.added.count)
        var kept: [PKStroke] = []
        var removedAny = false
        if changes.removed.isEmpty {
            present.formUnion(ids)
        } else {
            kept.reserveCapacity(strokes.count)
            for (i, stroke) in strokes.enumerated() {
                if changes.removed.contains(ids[i]) {
                    removedAny = true
                    continue
                }
                kept.append(stroke)
                present.insert(ids[i])
            }
        }
        // Gelöschte brauchen ihren Alias nicht mehr. Kommt derselbe Strich später unter einer anderen ID wieder (etwa
        // von einem Gerät mit älterer App), gilt dann seine eigene Prüfsumme
        if !aliases.isEmpty, !changes.removed.isEmpty {
            aliases = aliases.filter { !changes.removed.contains($0.value) }
        }
        let toDrawing = CGAffineTransform(scaleX: scale, y: scale)
        var added: [PKStroke] = []
        for a in changes.added where !present.contains(a.id) {
            guard let decoded = decodeWire(a.data) else { continue }
            var stroke = decoded.stroke
            if scale != 1 { stroke.transform = stroke.transform.concatenating(toDrawing) }
            if decoded.check {
                // Die ID hat der Browser aus seinen Zahlen berechnet (oder ein Gerät unter einem Alias hochgeladen), die
                // App hasht, was PencilKit vom Strich behält. Weicht das ab, gilt trotzdem die ID des Servers: Sonst
                // griffe ein Löschen aus dem Browser hier nicht, und der nächste Abgleich lüde den Strich neu hoch
                let own = digest(stroke, toPage: toPage)
                let base = a.id.prefix(while: { $0 != "#" })
                if own != base {
                    aliases[own] = String(base)
                    // Schon da unter der eigenen Prüfsumme (Sync-Stand verloren oder älter als die Zeichnung): nicht
                    // noch einmal einfügen, der Alias genügt. Gleiche Striche zählen wie in `ids` (#2, #3 …)
                    if present.contains(own + String(a.id.dropFirst(base.count))) {
                        present.insert(a.id)
                        rekeyed = true
                        continue
                    }
                }
                // Seine Prüfsumme ist schon berechnet: nicht noch einmal hashen
                StrokeIDCache.shared.pin(stroke, toPage: toPage, digest: own, pruning: pruning)
            }
            added.append(stroke)
            present.insert(a.id)
        }
        guard removedAny || !added.isEmpty else { return nil }
        var result = drawing
        if removedAny { result.strokes = kept }
        if !added.isEmpty { result.append(PKDrawing(strokes: added)) }
        return (result, strokes.isEmpty)
    }
}
