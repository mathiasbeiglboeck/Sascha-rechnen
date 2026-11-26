import PencilKit
import UIKit

/// Der zuletzt gezogene Weg des Lassos, in Seitenpunkten (alle Seiten untereinander, wie `PageLayout`)
struct LassoPath {
    let points: [CGPoint]
    let bounds: CGRect
    /// Kennzahl der Tinte unter dem Lasso, als er gezogen wurde: Ändert sie sich (Auswahl verschoben, kopiert,
    /// eingefügt, etwas dazugeschrieben), gehört der Weg nicht mehr zur Auswahl
    let inkPrint: Int
}

enum LassoGeometry {
    /// Nur Punkte, die mindestens `minStep` vom vorigen entfernt sind
    static func simplified(_ points: [CGPoint], minStep: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points where out.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= minStep }) ?? true { out.append(p) }
        return out
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var x0 = first.x, x1 = first.x, y0 = first.y, y1 = first.y
        for p in points {
            x0 = min(x0, p.x); x1 = max(x1, p.x)
            y0 = min(y0, p.y); y1 = max(y1, p.y)
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Fläche des (geschlossen gedachten) Wegs. Ein Antippen oder Verschieben der Auswahl hat fast keine
    static func area(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Liegt `p` im Weg (gerade-ungerade-Regel, der Weg gilt als geschlossen)?
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count > 2 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Liegt mindestens die Hälfte des Strichs im Weg? (`polygon` in denselben Koordinaten wie der Strich)
    static func mostlyInside(_ stroke: PKStroke, _ polygon: [CGPoint]) -> Bool {
        var n = 0, inside = 0
        for point in stroke.path.interpolatedPoints(by: .distance(4)) {
            n += 1
            if contains(polygon, point.location.applying(stroke.transform)) { inside += 1 }
        }
        return n > 0 && inside * 2 >= n
    }
}

extension PageExport {
    /// Nur die Frage: ihre Striche (Seitenpunkte) auf Weiß, mit Rand. 2 bis 4 Pixel je Seitenpunkt (die lange
    /// Kante etwa 1600 Pixel), höchstens 4096 Pixel lang
    static func questionPNG(_ ink: PKDrawing, region: CGRect, margin: CGFloat = 12) -> Data {
        let r = region.insetBy(dx: -margin, dy: -margin).integral
        let long = max(r.width, r.height, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(min(max(1600 / long, 2), 4), 4096 / long)
        format.opaque = true
        return UIGraphicsImageRenderer(size: r.size, format: format).pngData { c in
            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: r.size))
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink.image(from: r, scale: format.scale).draw(in: CGRect(origin: .zero, size: r.size))
            }
        }
    }

    /// Seite `i` mit der Frage darauf hervorgehoben (`lasso`: der Weg des Lassos, relativ zur Seite). Hochformat
    /// 1500 Pixel breit (A4: 1500 × 2121), Querformat 2000; höchstens 2400 Pixel lange Kante und 3,5 Megapixel
    func askPageJPEG(page i: Int, lasso: [CGPoint]) -> Data {
        let frame = frames[i]
        let s = min((frame.width > frame.height ? 2000 : 1500) / frame.width,
                    2400 / max(frame.width, frame.height),
                    (3_500_000 / max(frame.width * frame.height, 1)).squareRoot())
        let size = CGSize(width: (frame.width * s).rounded(), height: (frame.height * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { c in
            let ctx = c.cgContext
            ctx.scaleBy(x: s, y: s)
            drawPage(i, in: ctx, inkScale: s)
            guard lasso.count > 2 else { return }
            let path = CGMutablePath()
            path.addLines(between: lasso)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(UIColor(red: 1, green: 0.85, blue: 0, alpha: 0.15).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(UIColor(red: 1, green: 0.12, blue: 0.56, alpha: 1).cgColor)
            ctx.setLineWidth(3)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    /// Bild der Stelle unter einem ∞ (statt der Frage): oben die feste Frage `caption` gedruckt, darunter der
    /// Ausschnitt `r` der Seite `i` (Seitenpunkte relativ zur Seite) samt Hintergrund, die Stelle `spot` pink
    /// umrandet. 2 bis 4 Pixel je Seitenpunkt wie questionPNG, aber als JPEG wie das Bild der Seite: Mit einem Scan
    /// oder Foto als Hintergrund würde ein PNG zu groß für den Server
    func meaningJPEG(page i: Int, spot: CGRect, context r: CGRect, caption: String) -> Data {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                                                         .foregroundColor: UIColor.black, .paragraphStyle: style]
        let textWidth = max(r.width - 16, 40)
        let text = (caption as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                      options: .usesLineFragmentOrigin, attributes: attributes,
                                                      context: nil)
        let band = text.height.rounded(.up) + 12
        let size = CGSize(width: r.width, height: r.height + band)
        let long = max(size.width, size.height, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(min(max(1600 / long, 2), 4), 4096 / long)
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { c in
            let ctx = c.cgContext
            UIColor(white: 0.93, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: 0, width: size.width, height: band))
            (caption as NSString).draw(with: CGRect(x: 8, y: 6, width: textWidth, height: band - 8),
                                       options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
            ctx.translateBy(x: -r.minX, y: band - r.minY)
            drawRegion(i, region: r, in: ctx, inkScale: format.scale)
            ctx.setStrokeColor(UIColor(red: 1, green: 0.12, blue: 0.56, alpha: 1).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineJoin(.round)
            ctx.stroke(spot.insetBy(dx: -2, dy: -2))
        }
    }
}

// MARK: Die Seiten um die Frage

extension PageExport {
    /// Bereich der Seiten um eine Frage auf Seite `page`, die Claude mitbekommt (wie der Helfer beim PDF): „gründlich“
    /// bis zu sieben davor und zwei danach, sonst drei davor und eine danach
    static func contextSpan(around page: Int, count: Int, effort: String) -> ClosedRange<Int> {
        let (before, after) = effort == "thorough" ? (7, 2) : (3, 1)
        let last = max(count - 1, 0), q = min(max(page, 0), last)
        return max(q - before, 0)...min(q + after, last)
    }

    /// Schreibt die Seiten um die Frage auf Seite `q` neben ihre Bilder in `folder`, erst pages.pdf, dann pages.json
    /// (AskContext), im Hintergrund. Legt den Ordner nicht an: Ist die Frage inzwischen gelöscht oder schon oben,
    /// bleibt nichts liegen. Scheitert es, geht die Frage ohne die Seiten. „Schnell“ höchstens 1,5 MB, „gründlich“ 3:
    /// Die Frage soll auch bei schwachem Netz rasch oben sein, und während der Server sie schreibt, warten Antworten
    /// an die anderen Geräte, die gerade dann hinausgehen
    static func writeContext(_ export: PageExport, span: ClosedRange<Int>, question q: Int, pv: Int, effort: String,
                             to folder: URL) async {
        do {
            try await run { () throws -> Void in
                let started = Date()
                let maxBytes = effort == "thorough" ? 3_000_000 : 1_500_000
                guard let made = export.indexed().contextPDF(span: span, question: q, maxBytes: maxBytes) else {
                    #if DEBUG
                    NSLog("Asks-Debug: Nachbarseiten %@: PDF zu groß, ohne sie", folder.lastPathComponent)
                    #endif
                    return
                }
                if let pdf = made.pdf {
                    try pdf.write(to: folder.appendingPathComponent(AskContext.pdfName), options: .atomic)
                }
                let info = AskContext(pv: pv, page: q, span: [made.span.lowerBound, made.span.upperBound],
                                      pages: made.pages)
                try JSONEncoder().encode(info).write(to: folder.appendingPathComponent(AskContext.infoName),
                                                     options: .atomic)
                #if DEBUG
                NSLog("Asks-Debug: Nachbarseiten %@: Bereich %ld–%ld, Seiten [%@], PDF %ld Bytes, %.0f ms",
                      folder.lastPathComponent, made.span.lowerBound, made.span.upperBound,
                      made.pages.map(String.init).joined(separator: " "), made.pdf?.count ?? 0,
                      Date().timeIntervalSince(started) * 1000)
                #else
                _ = started
                #endif
            }
        } catch {
            #if DEBUG
            NSLog("Asks-Debug: Nachbarseiten %@ nicht geschrieben: %@", folder.lastPathComponent,
                  error.localizedDescription)
            #endif
        }
    }

    /// Die Seiten mit Tinte oder Notizen von Claude im Bereich `span` außer der Frage auf Seite `q` als ein PDF für
    /// Claude: je Seite ein JPEG (contextJPEG), darüber ein Streifen „Seite N“. Eine Seite nur mit Notizen zählt mit: Sonst
    /// hielte Claude sie für leer und schriebe womöglich über seine eigene frühere Lösung. Würde es größer als
    /// `maxBytes`, rückt der Bereich von außen nach innen (an beiden Enden gleich weit), bis es passt. Gibt den Bereich,
    /// die Seiten darin (ab 0) und das PDF zurück, ohne solche Seiten kein PDF; nil, wenn das PDF unerwartet groß wird
    /// oder nur die Seite der Frage bliebe
    func contextPDF(span: ClosedRange<Int>, question q: Int,
                    maxBytes: Int) -> (span: ClosedRange<Int>, pages: [Int], pdf: Data?)? {
        var range = span
        var shots: [(page: Int, jpeg: Data, size: CGSize)] = []
        var total = 0
        // Von der Frage nach außen
        let order = span.filter { $0 != q && frames.indices.contains($0) }
            .sorted { (abs($0 - q), $0) < (abs($1 - q), $1) }
        for i in order where hasInk(page: i) || notes[i]?.contains(where: { $0.text != nil || $0.box != nil }) == true {
            let shot = autoreleasepool { contextJPEG(page: i) }
            if total + shot.jpeg.count > maxBytes {
                let reach = abs(i - q) - 1
                range = max(span.lowerBound, q - reach)...min(span.upperBound, q + reach)
                shots.removeAll { !range.contains($0.page) }
                break
            }
            shots.append((page: i, jpeg: shot.jpeg, size: shot.size))
            total += shot.jpeg.count
        }
        // Bliebe nur die Seite der Frage, hieße das für Claude: Das Dokument hat nur sie
        guard range.count > 1 || span.count == 1 else { return nil }
        shots.sort { $0.page < $1.page }
        guard !shots.isEmpty else { return (range, [], nil) }
        let band: CGFloat = 44
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                                                         .foregroundColor: UIColor.black]
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 1200, height: 1700)).pdfData { c in
            for shot in shots {
                let size = shot.size
                c.beginPage(withBounds: CGRect(x: 0, y: 0, width: size.width, height: size.height + band),
                            pageInfo: [:])
                UIColor(white: 0.9, alpha: 1).setFill()
                c.fill(CGRect(x: 0, y: 0, width: size.width, height: band))
                ("Seite \(shot.page + 1)" as NSString).draw(at: CGPoint(x: 16, y: 9), withAttributes: attributes)
                // Das JPEG, wie es ist (Quartz übernimmt es so ins PDF, statt es neu zu kodieren)
                if let source = CGDataProvider(data: shot.jpeg as CFData),
                   let image = CGImage(jpegDataProviderSource: source, decode: nil, shouldInterpolate: true,
                                       intent: .defaultIntent) {
                    UIImage(cgImage: image).draw(in: CGRect(x: 0, y: band, width: size.width, height: size.height))
                }
            }
        }
        // Würde das JPEG doch neu kodiert, wäre das PDF viel größer: dann lieber ohne die Seiten
        guard pdf.count <= maxBytes + maxBytes / 2 else { return nil }
        return (range, shots.map(\.page), pdf)
    }

    /// Seite `i` für contextPDF: Hochformat 1200 Pixel breit (A4: 1200 × 1697), Querformat 1600, höchstens 2000 Pixel
    /// lang. Kleiner als das Bild der Seite mit der Frage (askPageJPEG), Handschrift bleibt gut lesbar
    private func contextJPEG(page i: Int) -> (jpeg: Data, size: CGSize) {
        let frame = frames[i]
        let s = min((frame.width > frame.height ? 1600 : 1200) / frame.width, 2000 / max(frame.width, frame.height))
        let size = CGSize(width: (frame.width * s).rounded(), height: (frame.height * s).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.6) { c in
            c.cgContext.scaleBy(x: s, y: s)
            drawPage(i, in: c.cgContext, inkScale: s)
        }
        return (jpeg, size)
    }
}

/// Hält die App wach, wenn sie während einer Arbeit in den Hintergrund geht (Bildschirm gesperrt, andere App), bis
/// `end()`, längstens so lange, wie iOS es erlaubt. Für das Vorbereiten einer Frage: Friert das Zeichnen der Seiten um
/// sie ein, ginge sie nach 30 s ohne sie hinauf (AskStore.add)
@MainActor
final class BackgroundWork {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Die Zeit ist um: jetzt beenden, sonst beendet iOS die App
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
