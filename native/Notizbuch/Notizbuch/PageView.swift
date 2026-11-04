import UIKit

/// Eine Seite unter der Tinte: dünn grau kariertes A4 oder eine PDF-Seite.
/// CATiledLayer zeichnet beim Hineinzoomen in höherer Auflösung nach, so bleibt alles scharf.
final class PageView: UIView {
    enum Content {
        case grid
        case pdf(CGPDFPage)
    }

    override class var layerClass: AnyClass { CATiledLayer.self }

    private let content: Content

    init(frame: CGRect, content: Content) {
        self.content = content
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        isUserInteractionEnabled = false
        let tiled = layer as! CATiledLayer
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 3
        tiled.tileSize = CGSize(width: 512, height: 512)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        switch content {
        case .grid:
            Self.drawGrid(in: ctx, rect: rect, lineWidth: 0.5)
        case .pdf(let page):
            Self.drawPDF(page, in: ctx, size: bounds.size)
        }
    }

    /// 5-mm-Karos: A4 ist 210 mm breit, also 42 Kästchen über die Seitenbreite
    static let gridStep = PageLayout.width / 42
    static let gridColor = UIColor(white: 0.82, alpha: 1)

    static func drawGrid(in ctx: CGContext, rect: CGRect, lineWidth: CGFloat) {
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(lineWidth)
        var x = (rect.minX / gridStep).rounded(.up) * gridStep
        while x <= rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += gridStep
        }
        var y = (rect.minY / gridStep).rounded(.up) * gridStep
        while y <= rect.maxY {
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += gridStep
        }
        ctx.strokePath()
    }

    /// Zeichnet eine PDF-Seite füllend in ein Rechteck der Größe `size` (UIKit-Koordinaten, y nach unten)
    static func drawPDF(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let natural = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard natural.width > 0 else { return }
        let s = size.width / natural.width
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: s, y: -s)
        // Bringt die Seite samt Drehung in das Rechteck (0, 0, natural); skaliert selbst nur nach unten, daher oben s
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}
