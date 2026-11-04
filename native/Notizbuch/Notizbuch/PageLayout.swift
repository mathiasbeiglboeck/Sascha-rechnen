import CoreGraphics
import PencilKit

/// Alle Seiten liegen untereinander in einem gemeinsamen Koordinatensystem,
/// 768 Punkte breit. In diesem System werden die Striche gespeichert,
/// unabhängig davon, wie weit gerade hineingezoomt ist oder welches Gerät es ist.
struct PageLayout {
    static let width: CGFloat = 768
    /// Abstand zwischen den Seiten. Version 1 hatte 24, seit Version 2 ist er schmal.
    static let gap: CGFloat = 6
    static let currentVersion = 2
    static let a4Height: CGFloat = width * 297 / 210

    let frames: [CGRect]
    let gap: CGFloat

    var totalHeight: CGFloat { (frames.last?.maxY ?? 0) + gap }

    static func notebook(pages: Int, gap: CGFloat = PageLayout.gap) -> PageLayout {
        stack(Array(repeating: a4Height, count: max(pages, 1)), gap: gap)
    }

    static func pdf(_ doc: CGPDFDocument, gap: CGFloat = PageLayout.gap) -> PageLayout {
        stack((0..<doc.numberOfPages).compactMap { doc.page(at: $0 + 1).map(height(of:)) }, gap: gap)
    }

    /// Höhe einer PDF-Seite, wenn sie auf volle Breite skaliert wird (Drehung berücksichtigt)
    static func height(of page: CGPDFPage) -> CGFloat {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let w = turned ? box.height : box.width
        let h = turned ? box.width : box.height
        return w > 0 ? width * h / w : a4Height
    }

    static func stack(_ heights: [CGFloat], gap: CGFloat = PageLayout.gap) -> PageLayout {
        var y = gap
        var frames: [CGRect] = []
        for h in heights {
            frames.append(CGRect(x: 0, y: y, width: width, height: h))
            y += h + gap
        }
        return PageLayout(frames: frames, gap: gap)
    }

    /// Verschiebt jeden Strich mit der Seite, auf der er liegt, von einem alten Layout in dieses
    func migrate(_ drawing: PKDrawing, from old: PageLayout) -> PKDrawing {
        let strokes = drawing.strokes.map { stroke -> PKStroke in
            let midY = stroke.renderBounds.midY
            let i = old.frames.lastIndex { $0.minY - old.gap <= midY } ?? 0
            guard i < frames.count else { return stroke }
            var s = stroke
            s.transform = s.transform.concatenating(
                CGAffineTransform(translationX: 0, y: frames[i].minY - old.frames[i].minY))
            return s
        }
        return PKDrawing(strokes: strokes)
    }
}
