import PencilKit
import UIKit

/// Erstellt PDFs und Bilder von Seiten abseits des Hauptthreads.
/// Jede Seite wird einzeln gezeichnet und gleich wieder freigegeben, die Tinte nur dort gerastert,
/// wo auf der Seite wirklich etwas steht. So bleibt auch ein 100-seitiges Skriptum im Speicher klein.
struct PageExport: @unchecked Sendable {
    let frames: [CGRect]
    let pdf: CGPDFDocument?
    let ink: PKDrawing
    /// Striche je Seite, einmal vorsortiert (siehe `indexed()`); sonst wird je Seite die ganze Zeichnung durchsucht
    private var byPage: [[PKStroke]]?

    init(frames: [CGRect], pdf: CGPDFDocument?, ink: PKDrawing) {
        self.frames = frames
        self.pdf = pdf
        self.ink = ink
    }

    /// Dieselbe Momentaufnahme mit den Strichen nach Seiten sortiert: Die Übersicht fragt jede Seite einzeln
    /// ab, und ein Skriptum mit 100 Seiten und 10 000 Strichen soll dafür nicht 100-mal alles durchsuchen.
    func indexed() -> PageExport {
        var copy = self
        var pages = Array(repeating: [PKStroke](), count: frames.count)
        if !frames.isEmpty {
            let layout = PageLayout(frames: frames, gap: PageLayout.gap)
            for stroke in ink.strokes {
                let b = stroke.renderBounds
                guard !b.isNull, !b.isEmpty else { continue }
                // Erste Seite, die der Strich berühren kann, dann so weit, wie er reicht
                var i = max(layout.page(at: b.minY) - 1, 0)
                while i < frames.count, frames[i].minY <= b.maxY {
                    if frames[i].intersects(b) { pages[i].append(stroke) }
                    i += 1
                }
            }
        }
        copy.byPage = pages
        return copy
    }

    /// Striche einer Seite (ein Strich über eine Seitengrenze hinweg gehört zu beiden)
    private func strokes(on i: Int) -> [PKStroke] {
        if let byPage, byPage.indices.contains(i) { return byPage[i] }
        let frame = frames[i]
        return ink.strokes.filter { $0.renderBounds.intersects(frame) }
    }

    /// Zeichnet Seite `i` (Hintergrund und Tinte) in Seitenpunkten ab (0, 0)
    func drawPage(_ i: Int, in ctx: CGContext, inkScale: CGFloat) {
        let frame = frames[i]
        let rect = CGRect(origin: .zero, size: frame.size)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        if let page = pdf?.page(at: i + 1) {
            PageView.drawPDF(page, in: ctx, size: frame.size)
        } else {
            PageView.drawGrid(in: ctx, rect: rect, lineWidth: 0.5)
        }
        let own = strokes(on: i)
        guard !own.isEmpty else { return }
        // Nur den Bereich mit Tinte rastern, nicht die ganze Seite
        let area = own.reduce(CGRect.null) { $0.union($1.renderBounds) }.intersection(frame).integral
        guard !area.isEmpty else { return }
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let image = PKDrawing(strokes: own).image(from: area, scale: inkScale)
            image.draw(in: area.offsetBy(dx: -frame.minX, dy: -frame.minY))
        }
    }

    /// Breite der Seite im PDF: Notizbuchseiten als A4, PDF-Seiten in Originalgröße
    private func outputWidth(_ i: Int) -> CGFloat {
        guard let page = pdf?.page(at: i + 1) else { return 595.28 }
        let box = page.getBoxRect(.cropBox)
        return abs(page.rotationAngle) % 180 == 90 ? box.height : box.width
    }

    /// Schreibt die Seiten als PDF direkt in eine Datei, Seite für Seite
    func writePDF(pages: [Int], to url: URL, inkScale: CGFloat) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595.28, height: 841.89))
        try renderer.writePDF(to: url) { c in
            for i in pages {
                autoreleasepool {
                    let frame = frames[i]
                    let s = outputWidth(i) / frame.width
                    c.beginPage(withBounds: CGRect(x: 0, y: 0, width: frame.width * s, height: frame.height * s), pageInfo: [:])
                    c.cgContext.scaleBy(x: s, y: s)
                    drawPage(i, in: c.cgContext, inkScale: inkScale)
                }
            }
        }
    }

    func pngData(page i: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: frames[i].size, format: format).pngData { c in
            drawPage(i, in: c.cgContext, inkScale: 2)
        }
    }

    /// Kennzahl der Tinte auf einer Seite: ändert sich, wenn dort ein Strich dazukommt, wegfällt oder sich bewegt
    func inkFingerprint(page i: Int) -> Int {
        var h = Hasher()
        for s in strokes(on: i) {
            let b = s.renderBounds
            for v in [b.minX, b.minY, b.maxX, b.maxY] { h.combine(Int((v * 4).rounded())) }
            h.combine(s.path.count)
        }
        return h.finalize()
    }

    /// Kleines Vorschaubild einer Seite, `pixelWidth` Pixel breit
    func thumbnail(page i: Int, pixelWidth: CGFloat) -> UIImage {
        let frame = frames[i]
        let s = pixelWidth / frame.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: pixelWidth.rounded(), height: (frame.height * s).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            c.cgContext.scaleBy(x: s, y: s)
            drawPage(i, in: c.cgContext, inkScale: s)
        }
    }

    /// Im Hintergrund ausführen, damit die App nicht einfriert
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}
