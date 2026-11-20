#if DEBUG
import CryptoKit
import PencilKit
import UIKit

/// Nur im Debug-Build, zum Prüfen im Simulator (debug/browserids, debug/browserwidth, debug/idtime): Striche aus dem
/// Browser (Dicke, IDs unter Aliassen, Löschen aus dem Browser, Hochladen mit Vermerk, Kosten der Aliase und der
/// Prüfung beim Ankommen, bleibt der gemerkte Schlüssel gleich)
enum DebugMeasure {
    private static func r(_ v: Double, _ s: Double) -> Double { (v * s).rounded() / s }
    static let widths: [Double] = [1.8, 2.5, 3.2, 4.2, 6.5]

    /// ID eines Drahts wie im Browser (viewer.html strokeID)
    static func wireID(_ w: WireStroke) -> String {
        var json = "[\"" + w.ink + "\""
        for p in w.p { json += ",\"" + p.prefix(9).map { String($0) }.joined(separator: ",") + "\"" }
        json += "]"
        return SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Zehn Striche wie aus dem Browser, je Breite einer mit der Maus (Breite = Höhe = w) und einer mit dem Stift
    /// (Breite nach Druck wie penWidth im Viewer, Höhe w). `straight`: waagrecht, Stift mit festem Druck 0,6 (zum
    /// Nachmessen der Dicke), sonst geschwungen mit wechselndem Druck. `origin` in Seitenpunkten des Dokuments
    static func browserLike(origin: CGPoint, straight: Bool, color: [Double] = [0.8, 0.17, 0.15, 1]) -> [WireStroke] {
        (0..<10).map { i -> WireStroke in
            let pencil = i >= 5
            let w = widths[i % 5]
            let n = straight ? 20 : 60
            let points = (0...n).map { j -> [Double] in
                let x = r(Double(origin.x) + 100 + Double(j) * (straight ? 15 : 7.13), 100)
                let wave = straight ? 0 : sin(Double(j) / 5) * 9.7
                let y = r(Double(origin.y) + Double(i) * 24 + wave, 100)
                let pressure = straight ? 0.6 : 0.3 + 0.01 * Double(j % 40)
                let width = pencil ? r(w * (0.95 + 0.5 * pressure), 100) : w
                return [x, y, r(Double(j) * (straight ? 0.02 : 0.0517), 1000), width, w, 1, 1, 0, 1.571]
            }
            return WireStroke(ink: PKInk.InkType.pen.rawValue, c: color, p: points)
        }
    }

    /// Wie Änderungen vom Server: (ID des Browsers, JSON)
    static func changes(_ wires: [WireStroke]) -> [(id: String, data: String)] {
        wires.compactMap { w -> (id: String, data: String)? in
            guard let data = try? JSONEncoder().encode(w), let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return (id: wireID(w), data: json)
        }
    }

    /// IDs ohne Zwischenspeicher, wie nach einem Neustart: eigene Prüfsumme, dann die Aliase (wie StrokeIDCache.ids
    /// nur für den ersten Strich mit dieser Prüfsumme); gleiche zählen mit
    static func freshIDs(_ strokes: [PKStroke], toPage: CGAffineTransform, aliases: [String: String]) -> [String] {
        var seen: [String: Int] = [:]
        return strokes.map { s -> String in
            var d = StrokeCodec.digest(s, toPage: toPage)
            if let server = aliases[d], seen[server] == nil { d = server }
            let n = (seen[d] ?? 0) + 1
            seen[d] = n
            return n == 1 ? d : "\(d)#\(n)"
        }
    }

    /// Wie aus der Datei: gespeichert und wieder geladen
    static func roundTrip(_ drawing: PKDrawing) -> PKDrawing {
        (try? PKDrawing(data: drawing.dataRepresentation())) ?? PKDrawing()
    }

    /// Wie SyncEngine einen Strich hochlädt (in Seitenpunkten), mit oder ohne Vermerk
    static func upload(_ stroke: PKStroke, toPage: CGAffineTransform, alias: Bool) -> String {
        var s = stroke
        s.transform = StrokeCodec.pageTransform(stroke, toPage)
        return StrokeCodec.data(s, alias: alias)
    }

    /// So dick zeichnet der Viewer einen hochgeladenen Strich (pw): größte Abweichung von der Breite des Browsers
    static func viewerWidthDeviation(_ data: String, _ wire: WireStroke) -> Double {
        guard let w = try? JSONDecoder().decode(WireStroke.self, from: Data(data.utf8)) else { return -1 }
        var dev = 0.0
        for (q, a) in zip(w.p, wire.p) {
            let pw = q.count > 9 ? q[3] * q[9] * 2 : q[3]
            dev = max(dev, abs(pw - a[3]))
        }
        return dev
    }

    /// Wie ein anderes Gerät mit derselben App die Striche einfügt (StrokeCodec.apply auf eine leere Zeichnung, Faktor `scale`):
    /// wie viele es danach unter der ID des Servers kennt
    static func otherDevice(_ added: [(id: String, data: String)], scale: CGFloat) -> Int {
        var changes = RemoteChanges()
        changes.added = added
        var aliases: [String: String] = [:]
        var rekeyed = false
        guard let result = StrokeCodec.apply(changes, to: PKDrawing(), scale: scale, aliases: &aliases,
                                             rekeyed: &rekeyed) else { return 0 }
        let toPage = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        let ids = Set(StrokeIDCache.shared.ids(for: result.drawing.strokes, toPage: toPage, aliases: aliases))
        return added.filter { ids.contains($0.id) }.count
    }

    /// Welche Felder des Schlüssels im Speicher (StrokeIDCache.Key) weichen ab? Leer: gleich
    static func keyDiff(_ a: StrokeIDCache.Key, _ b: StrokeIDCache.Key) -> [String] {
        var out: [String] = []
        if a.created != b.created { out.append(String(format: "Entstehung %.9f→%.9f", a.created, b.created)) }
        if a.count != b.count { out.append("Punkte \(a.count)→\(b.count)") }
        if a.x0 != b.x0 || a.y0 != b.y0 || a.t0 != b.t0 { out.append("Anfang") }
        if a.x1 != b.x1 || a.y1 != b.y1 || a.t1 != b.t1 { out.append("Ende") }
        if a.a != b.a || a.b != b.b || a.c != b.c || a.d != b.d { out.append("Matrix") }
        if a.tx != b.tx || a.ty != b.ty {
            out.append(String(format: "Verschiebung %.9f,%.9f→%.9f,%.9f", a.tx, a.ty, b.tx, b.ty))
        }
        if a.ink != b.ink { out.append("Tinte") }
        return out
    }

    /// Schlüssel vorher und nachher, je Strich: gleich n/m, dazu die erste Abweichung
    private static func compareKeys(_ label: String, _ before: [PKStroke], _ after: [PKStroke],
                                    _ toPage: CGAffineTransform) -> String {
        guard before.count == after.count else { return "\(label): \(before.count) → \(after.count) Striche" }
        var same = 0
        var first = ""
        for (a, b) in zip(before, after) {
            let d = keyDiff(StrokeIDCache.key(a, toPage), StrokeIDCache.key(b, toPage))
            if d.isEmpty { same += 1 } else if first.isEmpty { first = d.joined(separator: ", ") }
        }
        return "\(label): Schlüssel gleich \(same)/\(before.count)"
            + (first.isEmpty ? "" : "; erste Abweichung " + first)
    }

    /// Trifft der Speicher später die Prüfsumme, die StrokeCodec.apply beim Einfügen gemerkt hat (Pin)? Gemerkt wird
    /// sie unter dem Schlüssel des eben dekodierten Strichs. Hier dieselben Schritte wie dort (dekodieren, Faktor,
    /// anhängen), dann wie auf der Leinwand (in eine PKCanvasView gesetzt und wieder gelesen) bzw. wie in einer
    /// geschlossenen Datei (gespeichert und geladen). Weicht der Schlüssel ab, wird derselbe Strich ein zweites Mal
    /// gehasht. Dazu im Browser verschobene App-Striche (pk mit dx/dy): Auch sie werden beim Ankommen geprüft
    static func pinKeys(_ added: [(id: String, data: String)], k: CGFloat) -> [String] {
        func check(_ label: String, _ data: [String], scale: CGFloat) -> String {
            let toPage = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
            let pinned = data.compactMap { json -> PKStroke? in
                guard var s = StrokeCodec.decodeWire(json)?.stroke else { return nil }
                if scale != 1 { s.transform = s.transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)) }
                return s
            }
            var drawing = PKDrawing()
            drawing.append(PKDrawing(strokes: pinned))
            var steps = [compareKeys("angehängt", pinned, drawing.strokes, toPage)]
            if scale == 1 {
                steps.append(compareKeys("gespeichert und geladen", pinned, roundTrip(drawing).strokes, toPage))
            } else {
                let probe = PKCanvasView()
                probe.drawing = drawing
                steps.append(compareKeys("in der Leinwand", pinned, probe.drawing.strokes, toPage))
            }
            return label + ": " + steps.joined(separator: "; ")
        }
        let data = added.map { $0.data }
        // Im Browser verschoben: wie eine App hochlädt (pk), dazu dx/dy wie im Viewer
        let moved = data.compactMap { json -> String? in
            guard let s = StrokeCodec.decodeWire(json)?.stroke,
                  var w = try? JSONDecoder().decode(WireStroke.self, from: Data(StrokeCodec.data(s).utf8)) else {
                return nil
            }
            w.dx = 23.45
            w.dy = -7.5
            guard let encoded = try? JSONEncoder().encode(w) else { return nil }
            return String(data: encoded, encoding: .utf8)
        }
        let canvas = String(format: "Leinwand (k %.3f)", Double(k))
        return [check(canvas, data, scale: k), check("Datei", data, scale: 1),
                check("im Browser verschoben, " + canvas, moved, scale: k),
                check("im Browser verschoben, Datei", moved, scale: 1)]
    }

    /// Gleich nach dem Einfügen auf der Leinwand: Trifft der Speicher die gemerkten Prüfsummen der neuen Striche?
    /// Erstes Erfassen gegen ein zweites (sicher aus dem Speicher) und gegen neues Hashen. Getroffen: das erste etwa so
    /// schnell wie das zweite, weit unter dem Hashen
    static func cacheHits(_ strokes: [PKStroke], toPage: CGAffineTransform, aliases: [String: String]) -> String {
        func ms(_ body: () -> Void) -> Double {
            let t = CACurrentMediaTime()
            body()
            return (CACurrentMediaTime() - t) * 1000
        }
        let first = ms { _ = StrokeIDCache.shared.ids(for: strokes, toPage: toPage, aliases: aliases) }
        let again = ms { _ = StrokeIDCache.shared.ids(for: strokes, toPage: toPage, aliases: aliases) }
        let hash = ms { for s in strokes { _ = StrokeCodec.digest(s, toPage: toPage) } }
        return String(format: "Speicher nach dem Einfügen (%ld neue Striche): erstes Erfassen %.3f ms, "
                      + "zweites %.3f ms, neu hashen %.3f ms, also %@", strokes.count, first, again, hash,
                      first < (again + hash) / 2 ? "getroffen" : "neu gehasht")
    }

    /// Deckung je Pixel (0…1): Alpha (durchsichtiger Grund) oder Dunkelheit (Papier)
    private static func coverage(_ cg: CGImage, alpha: Bool) -> (w: Int, h: Int, c: [Double])? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var c = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            if alpha {
                c[i] = Double(data[i * 4 + 3]) / 255
            } else {
                let m = min(data[i * 4], data[i * 4 + 1], data[i * 4 + 2])
                c[i] = Double(255 - m) / 255
            }
        }
        return (w: w, h: h, c: c)
    }

    /// Dicke einer waagrechten Linie in Pixeln: Median über die Spalten der Summe der Deckung
    private static func thickness(_ cov: (w: Int, h: Int, c: [Double])) -> Double {
        var sums: [Double] = []
        for x in 0..<cov.w {
            var s = 0.0
            for y in 0..<cov.h { s += cov.c[y * cov.w + x] }
            sums.append(s)
        }
        guard !sums.isEmpty else { return -1 }
        sums.sort()
        return sums[sums.count / 2]
    }

    /// Dicke einer waagrechten Linie (Strich in Seitenpunkten, Anfang bei `x0`, Höhe `y`) als Bild gerechnet,
    /// 8 Pixel je Seitenpunkt, gemessen 60 bis 260 Seitenpunkte nach dem Anfang
    static func imageThickness(_ stroke: PKStroke, y: Double, x0: Double) -> Double {
        let scale: CGFloat = 8
        let rect = CGRect(x: x0 + 60, y: y - 15, width: 200, height: 30)
        let image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale)
        guard let cg = image.cgImage, let cov = coverage(cg, alpha: true) else { return -1 }
        return thickness(cov) / Double(scale)
    }

    /// Bild der sichtbaren Leinwand, wie auf dem Schirm (mit Papier und PDF)
    static func snapshot(_ view: UIView) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    /// Dicke einer waagrechten Linie auf der Leinwand, in Seitenpunkten: Unterschied der Bilder vorher und nachher
    /// (Papier und PDF fallen so heraus). `factor`: Leinwandpunkte je Seitenpunkt mal Zoom, `offset`: Lage der Ansicht
    /// (bounds.origin); -1: Linie nicht im Bild
    static func canvasThickness(before: UIImage, after: UIImage, factor: CGFloat, offset: CGPoint,
                                y: Double, x0: Double) -> Double {
        let scale = Double(after.scale), f = Double(factor)
        let left = (x0 + 60) * f - Double(offset.x), right = (x0 + 260) * f - Double(offset.x)
        let top = (y - 15) * f - Double(offset.y), bottom = (y + 15) * f - Double(offset.y)
        let rect = CGRect(x: left * scale, y: top * scale, width: (right - left) * scale,
                          height: (bottom - top) * scale).integral
        guard let a = before.cgImage?.cropping(to: rect), let b = after.cgImage?.cropping(to: rect),
              let ca = coverage(a, alpha: false), let cb = coverage(b, alpha: false),
              ca.w == cb.w, ca.h == cb.h, CGFloat(cb.h) >= rect.height - 1 else { return -1 }
        var diff = cb
        for i in 0..<diff.c.count { diff.c[i] = max(0, cb.c[i] - ca.c[i]) }
        return thickness(diff) / (scale * f)
    }

    /// Was kosten die Aliase beim Erfassen der IDs? n Striche (alle schon im Speicher), ohne und mit 1000 Aliassen
    /// (keiner davon trifft), je Median aus 7 Läufen
    static func idTiming(n: Int) -> String {
        let strokes = (0..<n).map { i -> PKStroke in
            let x = CGFloat(i % 200) * 3.7, y = CGFloat(i / 200) * 9.1
            let points = [0, 1].map { j -> PKStrokePoint in
                PKStrokePoint(location: CGPoint(x: x + CGFloat(j) * 2, y: y), timeOffset: Double(j) * 0.01,
                              size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: 1.5)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: Date()),
                            transform: .identity, mask: nil)
        }
        let start = CACurrentMediaTime()
        _ = StrokeIDCache.shared.ids(for: strokes, toPage: .identity, aliases: [:])
        let first = (CACurrentMediaTime() - start) * 1000
        var fake: [String: String] = [:]
        for i in 0..<1000 { fake[String(repeating: "a", count: 20) + String(i)] = "b\(i)" }
        func time(_ aliases: [String: String]) -> Double {
            var ms: [Double] = []
            for _ in 0..<7 {
                let t0 = CACurrentMediaTime()
                _ = StrokeIDCache.shared.ids(for: strokes, toPage: .identity, aliases: aliases)
                ms.append((CACurrentMediaTime() - t0) * 1000)
            }
            return ms.sorted()[3]
        }
        let plain = time([:]), aliased = time(fake)
        // Was die Prüfung beim Ankommen kostet: 1000 Browser-Striche (61 Punkte) einlesen wie bisher, dazu neu die
        // eigene Prüfsumme (bisher fiel sie beim nächsten Erfassen an)
        let browser = (0..<100).flatMap { i in browserLike(origin: CGPoint(x: 0, y: Double(i) * 250), straight: false) }
        let jsons = changes(browser).map { $0.data }
        let t1 = CACurrentMediaTime()
        let decoded = jsons.compactMap { StrokeCodec.decodeWire($0)?.stroke }
        let decodeMs = (CACurrentMediaTime() - t1) * 1000
        let t2 = CACurrentMediaTime()
        for s in decoded { _ = StrokeCodec.digest(s) }
        let digestMs = (CACurrentMediaTime() - t2) * 1000
        // Zum Vergleich: dieselben Striche, wie eine App sie hochlädt (mit pk). So kamen Browser-Striche bisher meist
        // an, nachdem ein Gerät mit 122 sie umgeschrieben hatte (einlesen ohne Prüfung)
        let uploaded = decoded.map { StrokeCodec.data($0) }
        let t3 = CACurrentMediaTime()
        let decodedPK = uploaded.compactMap { StrokeCodec.decodeWire($0)?.stroke }
        let pkMs = (CACurrentMediaTime() - t3) * 1000
        // Ganzes Einfügen in eine Datei (wie deliver): 300 Browser-Striche mit Prüfung, dieselben 300 als pk-Striche
        func applyMs(_ added: [(id: String, data: String)]) -> Double {
            var c = RemoteChanges()
            c.added = added
            var a: [String: String] = [:]
            var r = false
            let t = CACurrentMediaTime()
            _ = StrokeCodec.apply(c, to: PKDrawing(), aliases: &a, rekeyed: &r)
            return (CACurrentMediaTime() - t) * 1000
        }
        let pkChanges = zip(decoded.prefix(300), uploaded.prefix(300))
            .map { (id: StrokeCodec.digest($0.0), data: $0.1) }
        let applyBrowser = applyMs(changes(Array(browser.prefix(300))))
        let applyPK = applyMs(Array(pkChanges))
        return String(format: "%ld Striche: erstes Hashen %.0f ms; aus dem Speicher ohne Aliase %.2f ms, "
                      + "mit 1000 Aliassen %.2f ms; %ld Browser-Striche: einlesen %.0f ms, "
                      + "eigene Prüfsumme dazu %.0f ms; als pk-Striche einlesen %.0f ms (%ld); "
                      + "einfügen 300 Browser-Striche %.1f ms, 300 pk-Striche %.1f ms",
                      n, first, plain, aliased, decoded.count, decodeMs, digestMs, pkMs, decodedPK.count,
                      applyBrowser, applyPK)
    }
}
#endif
