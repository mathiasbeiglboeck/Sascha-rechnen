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

    /// Bildschirmpunkte je Seitenpunkt bei Zoom 1. Die Kacheln werden dann genau in Bildschirmpixeln
    /// gezeichnet (statt in einer Zweierpotenz, die die GPU danach krumm skaliert); nur so landen die
    /// auf ganze Pixel gelegten Karolinien auch am Bildschirm auf ganzen Pixeln.
    /// Wird auf dem Hauptthread gesetzt und in den Kachel-Zeichnungen nur gelesen
    nonisolated(unsafe) private var screenGrid: ScreenGrid?

    var pixelScale: CGFloat = 0 {
        didSet { if pixelScale != oldValue { applyPixelScale() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPixelScale() // UIKit setzt contentsScale beim Einhängen auf den Bildschirmwert zurück
    }

    private func applyPixelScale() {
        guard pixelScale > 0, let screen = window?.windowScene?.screen else { return }
        let scale = screen.scale * pixelScale
        let grid = ScreenGrid(pxPerPoint: scale,
                              originX: (frame.minX * scale).truncatingRemainder(dividingBy: 1),
                              originY: (frame.minY * scale).truncatingRemainder(dividingBy: 1))
        screenGrid = grid
        guard abs(layer.contentsScale - scale) > 0.0001 else { return }
        layer.contentsScale = scale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        switch content {
        case .grid:
            Self.drawGrid(in: ctx, rect: rect, lineWidth: 0.5, screen: screenGrid)
        case .pdf(let page):
            Self.drawPDF(page, in: ctx, size: bounds.size)
        }
    }

    /// 7-mm-Karos: A4 ist 210 mm breit, also 30 Kästchen über die Seitenbreite
    nonisolated static let gridStep = PageLayout.width / 30
    nonisolated(unsafe) static let gridColor = UIColor(white: 0.82, alpha: 1)

    /// Wie die Seite am Bildschirm liegt: Bildschirmpixel je Seitenpunkt (bei Zoom 1) und die Lage
    /// der Seitenecke in Bildschirmpixeln. Damit legt `drawGrid` jede Linie auf ganze Bildschirmpixel.
    struct ScreenGrid: Sendable {
        var pxPerPoint: CGFloat
        var originX: CGFloat
        var originY: CGFloat
    }

    /// `screen`: am Bildschirm jede Linie auf ganze Bildschirmpixel legen. Sonst fällt eine dünne
    /// Linie je nach Lage zwischen zwei Pixel und wird so blass, dass man sie kaum sieht.
    /// Die Kacheln werden oft in doppelter Auflösung gezeichnet und danach verkleinert, deshalb
    /// zählt hier der Bildschirm, nicht der Zeichenkontext. Ohne `screen` (Export) einfach zeichnen.
    nonisolated static func drawGrid(in ctx: CGContext, rect: CGRect, lineWidth: CGFloat, screen: ScreenGrid? = nil) {
        ctx.setStrokeColor(gridColor.cgColor)
        guard let screen, screen.pxPerPoint > 0 else {
            ctx.setLineWidth(lineWidth)
            var x = (rect.minX / gridStep).rounded(.up) * gridStep
            while x <= rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)); x += gridStep
            }
            var y = (rect.minY / gridStep).rounded(.up) * gridStep
            while y <= rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); y += gridStep
            }
            ctx.strokePath()
            return
        }
        let px = screen.pxPerPoint
        let widthPx = max(1, (lineWidth * px).rounded())
        ctx.setLineWidth(widthPx / px)
        // Linienmitte so, dass die Linie am Bildschirm genau ganze Pixel füllt
        func snap(_ v: CGFloat, origin: CGFloat) -> CGFloat {
            let s = v * px + origin
            return ((s - widthPx / 2).rounded() + widthPx / 2 - origin) / px
        }
        // Ganze Seite ablaufen und nur Linien im Kachelbereich zeichnen, damit eine Linie an der
        // Kachelgrenze in beiden Kacheln an derselben Stelle liegt
        let pad = widthPx / px
        var x = ((rect.minX - pad) / gridStep).rounded(.up) * gridStep
        while x <= rect.maxX + pad {
            let sx = snap(x, origin: screen.originX)
            ctx.move(to: CGPoint(x: sx, y: rect.minY)); ctx.addLine(to: CGPoint(x: sx, y: rect.maxY))
            x += gridStep
        }
        var y = ((rect.minY - pad) / gridStep).rounded(.up) * gridStep
        while y <= rect.maxY + pad {
            let sy = snap(y, origin: screen.originY)
            ctx.move(to: CGPoint(x: rect.minX, y: sy)); ctx.addLine(to: CGPoint(x: rect.maxX, y: sy))
            y += gridStep
        }
        ctx.strokePath()
    }

    /// Zeichnet eine PDF-Seite füllend in ein Rechteck der Größe `size` (UIKit-Koordinaten, y nach unten)
    nonisolated static func drawPDF(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
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
