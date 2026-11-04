import CoreGraphics

/// Alle Seiten liegen untereinander in einem gemeinsamen Koordinatensystem,
/// 768 Punkte breit. In diesem System speichert PencilKit auch die Striche,
/// unabhängig davon, wie weit gerade hineingezoomt ist oder welches Gerät es ist.
struct PageLayout {
    static let width: CGFloat = 768
    static let gap: CGFloat = 24
    static let a4Height: CGFloat = width * 297 / 210

    let frames: [CGRect]

    var totalHeight: CGFloat { (frames.last?.maxY ?? 0) + Self.gap }

    static func notebook(pages: Int) -> PageLayout {
        stack(Array(repeating: a4Height, count: max(pages, 1)))
    }

    static func pdf(_ doc: CGPDFDocument) -> PageLayout {
        stack((0..<doc.numberOfPages).compactMap { doc.page(at: $0 + 1).map(height(of:)) })
    }

    /// Höhe einer PDF-Seite, wenn sie auf volle Breite skaliert wird (Drehung berücksichtigt)
    static func height(of page: CGPDFPage) -> CGFloat {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let w = turned ? box.height : box.width
        let h = turned ? box.width : box.height
        return w > 0 ? width * h / w : a4Height
    }

    static func stack(_ heights: [CGFloat]) -> PageLayout {
        var y = gap
        var frames: [CGRect] = []
        for h in heights {
            frames.append(CGRect(x: 0, y: y, width: width, height: h))
            y += h + gap
        }
        return PageLayout(frames: frames)
    }
}
