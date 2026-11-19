import PDFKit
import PencilKit
import UIKit

/// Ziel eines Links im PDF: die Seite (ab 0) und die Höhe der Stelle auf ihr in Seitenpunkten (von oben; nil: oben)
struct LinkTarget: Equatable, Sendable {
    var page: Int
    var y: CGFloat?
}

/// Ein Link, der an eine Stelle im selben Dokument führt: wo er liegt (Seitenpunkte seiner Seite, von ihrer oberen
/// linken Ecke) und wohin
struct LinkSpot: Sendable {
    var rect: CGRect
    var target: LinkTarget
}

/// Vorschau auf das Ziel eines Links: Hält man den Radierer `holdDuration` still auf einen Link, der an eine andere
/// Stelle im selben PDF führt, zeigt ein Fenster diese Stelle (siehe CanvasController, „Vorschau auf das Ziel eines
/// Links“). Links ins Internet bleiben, wie sie sind.
enum LinkPreview {
    /// So lange bleibt der Radierer still auf dem Link, bis die Vorschau kommt
    static let holdDuration: TimeInterval = 1.5
    /// Erst nach dieser Zeit erscheint der Kreis, der sich bis zur Vorschau füllt: Beim gewöhnlichen Radieren, das auf
    /// einem Link beginnt, blitzt so nichts auf
    static let ringDelay: TimeInterval = 0.25
    /// So weit darf sich der Radierer dabei bewegen (Bildschirmpunkte); weiter, und er radiert wie immer
    static let holdSlop: CGFloat = 10

    /// Alle Links im PDF an `url`, die an eine Stelle im selben Dokument führen, je Seite. Läuft im Hintergrund: Die
    /// Leinwand zeichnet mit CoreGraphics, das Links nicht auflöst; dafür liest PDFKit das PDF hier einmal selbst.
    /// Abgebrochen (neues PDF, Leinwand zu): leer
    static func scan(_ url: URL) -> [[LinkSpot]] {
        guard let document = PDFDocument(url: url) else { return [] }
        let count = document.pageCount
        // Seiten wie im PageLayout: volle Breite, Höhe nach Seitenverhältnis
        var toView = [CGAffineTransform?](repeating: nil, count: count)
        var heights = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            if Task.isCancelled { return [] }
            guard let page = document.page(at: i)?.pageRef else { continue }
            heights[i] = PageLayout.height(of: page)
            toView[i] = viewTransform(page, size: CGSize(width: PageLayout.width, height: heights[i]))
        }
        var spots = [[LinkSpot]](repeating: [], count: count)
        for i in 0..<count {
            if Task.isCancelled { return [] }
            autoreleasepool {
                guard let page = document.page(at: i), let transform = toView[i] else { return }
                for annotation in page.annotations {
                    guard let destination = destination(of: annotation),
                          let target = resolve(destination, in: document, toView: toView, heights: heights)
                    else { continue }
                    let rect = annotation.bounds.applying(transform)
                    guard !rect.isNull, rect.width > 0 || rect.height > 0 else { continue }
                    spots[i].append(LinkSpot(rect: rect, target: target))
                }
            }
        }
        return spots
    }

    /// Ziel des Links an `point` (Seitenpunkte der Seite, von ihrer oberen linken Ecke). Liegt keiner genau dort, zählt
    /// der nächste, der höchstens `tolerance` entfernt ist
    static func target(at point: CGPoint, in spots: [LinkSpot], tolerance: CGFloat) -> LinkTarget? {
        var best: (distance: CGFloat, target: LinkTarget)?
        for spot in spots {
            let d = distance(from: point, to: spot.rect)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (d, spot.target) }
        }
        return best?.target
    }

    /// Wie PageView eine PDF-Seite zeichnet: PDF-Koordinaten (Ursprung unten links, PDFKits „page space“) →
    /// Seitenpunkte dieser Seite (Ursprung oben links, `size` wie ihr Rahmen im PageLayout)
    static func viewTransform(_ page: CGPDFPage, size: CGSize) -> CGAffineTransform {
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let natural = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard natural.width > 0 else { return .identity }
        let s = size.width / natural.width
        return page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true)
            .concatenating(CGAffineTransform(scaleX: s, y: -s))
            .concatenating(CGAffineTransform(translationX: 0, y: size.height))
    }

    /// Wohin der Link führt, wenn an eine Stelle in diesem Dokument: „Gehe zu“, auch über einen benannten Sprung (den
    /// PDFKit auflöst). Adressen im Internet, andere Dateien und Befehle wie „nächste Seite“ zählen nicht
    private static func destination(of annotation: PDFAnnotation) -> PDFDestination? {
        if let action = annotation.action {
            return (action as? PDFActionGoTo)?.destination
        }
        return annotation.destination
    }

    private static func resolve(_ destination: PDFDestination, in document: PDFDocument,
                                toView: [CGAffineTransform?], heights: [CGFloat]) -> LinkTarget? {
        guard let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard toView.indices.contains(index), let transform = toView[index] else { return nil }
        let p = destination.point
        // Ziel „ganze Seite“: oben
        guard isSpecified(p.y) else { return LinkTarget(page: index, y: nil) }
        let x = isSpecified(p.x) ? p.x : page.pageRef?.getBoxRect(.cropBox).minX ?? 0
        let y = CGPoint(x: x, y: p.y).applying(transform).y
        return LinkTarget(page: index, y: min(max(y, 0), heights[index]))
    }

    /// PDFKit setzt fehlende Angaben eines Ziels (etwa bei „ganze Seite“) auf kPDFDestinationUnspecifiedValue
    private static func isSpecified(_ v: CGFloat) -> Bool {
        v.isFinite && abs(v) < 1_000_000
    }

    private static func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Höchstens so hoch wird ein Stück der Vorschau (Seitenpunkte, zwei A4-Seiten): Auch eine sehr hohe Seite, etwa eine
    /// als PDF gesicherte Webseite, braucht so nur einige MB statt Hunderte
    static let maxSlice: CGFloat = 2 * PageLayout.a4Height
    /// Ein gekürztes Stück beginnt so weit über dem Ziel
    static let sliceLead: CGFloat = 200

    /// Was die Vorschau zeigt: die Zielseite und die nächste. Ist eine davon höher als `maxSlice`, nur ein Stück: auf der
    /// Zielseite ab knapp über dem Ziel, und die nächste Seite nur, wenn das Stück bis ans Ende der Zielseite reicht
    static func slices(for target: LinkTarget, frames: [CGRect]) -> [LinkPreviewSlice] {
        guard frames.indices.contains(target.page) else { return [] }
        let height = frames[target.page].height
        let top = height > maxSlice ? min(max((target.y ?? 0) - sliceLead, 0), height - maxSlice) : 0
        let first = LinkPreviewSlice(page: target.page, top: top, bottom: min(height, top + maxSlice))
        let next = target.page + 1
        guard first.bottom >= height, frames.indices.contains(next) else { return [first] }
        return [first, LinkPreviewSlice(page: next, top: 0, bottom: min(frames[next].height, maxSlice))]
    }
}

/// Ein Stück einer Seite in der Vorschau: die Seite (ab 0) und der Bereich auf ihr (Seitenpunkte von ihrer Oberkante)
struct LinkPreviewSlice: Equatable, Sendable {
    var page: Int
    var top: CGFloat
    var bottom: CGFloat
}

/// Was die Bilder der Vorschau brauchen, für den Hintergrund
struct LinkPreviewJob: @unchecked Sendable {
    let slices: [LinkPreviewSlice]
    let frames: [CGRect]
    let pdf: CGPDFDocument?
    /// Die Striche dieser Stücke, in Seitenpunkten des ganzen Dokuments
    let ink: [PKStroke]
    let pixelWidth: CGFloat

    /// Die Bilder der Stücke; nil, wenn die Vorschau inzwischen nicht mehr gebraucht wird
    func render() -> LinkPreviewImages? {
        var images: [UIImage] = []
        for slice in slices {
            if Task.isCancelled { return nil }
            images.append(image(of: slice))
        }
        return LinkPreviewImages(slices: slices, images: images)
    }

    /// Ein Stück einer Seite (Hintergrund und Tinte), `pixelWidth` Pixel breit. Gerastert wird nur die Tinte darin
    private func image(of slice: LinkPreviewSlice) -> UIImage {
        let frame = frames[slice.page]
        let s = pixelWidth / frame.width
        let visible = CGRect(x: 0, y: slice.top, width: frame.width, height: slice.bottom - slice.top)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Vier Bytes je Pixel genügen für PDF und Tinte (der erweiterte Farbraum bräuchte doppelt so viel)
        format.preferredRange = .standard
        let size = CGSize(width: pixelWidth.rounded(), height: max((visible.height * s).rounded(), 1))
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let ctx = c.cgContext
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: 0, y: -slice.top)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(visible)
            if let page = pdf?.page(at: slice.page + 1) {
                PageView.drawPDF(page, in: ctx, size: frame.size)
            } else {
                PageView.drawGrid(in: ctx, rect: visible, lineWidth: 0.5)
            }
            let area = visible.offsetBy(dx: frame.minX, dy: frame.minY)
            let own = ink.filter { $0.renderBounds.intersects(area) }
            let inked = own.reduce(CGRect.null) { $0.union($1.renderBounds) }.intersection(area).integral
            guard !inked.isEmpty else { return }
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                PKDrawing(strokes: own).image(from: inked, scale: s)
                    .draw(in: inked.offsetBy(dx: -frame.minX, dy: -frame.minY))
            }
        }
    }
}

/// Die Bilder einer Vorschau (Zielseite und die nächste, mit Tinte), im Hintergrund gezeichnet
struct LinkPreviewImages: @unchecked Sendable {
    let slices: [LinkPreviewSlice]
    let images: [UIImage]
}

/// Das Fenster der Vorschau: die Zielseite und die nächste mit Tinte (bei sehr hohen Seiten ein Stück davon), oben die
/// Stelle des Ziels, darin scrollbar.
/// Am iPad ein Popover am Radierer, am iPhone ein halbhohes Blatt; Antippen daneben schließt es
final class LinkPreviewController: UIViewController {
    private let content: LinkPreviewImages
    /// Stelle des Ziels im ersten Stück (Seitenpunkte von dessen Oberkante)
    private let targetY: CGFloat
    private let scroll = UIScrollView()
    private var imageViews: [UIImageView] = []
    private let badge = UILabel()
    private var laidOutWidth: CGFloat = 0

    /// Hintergrund zwischen den Seiten, wie die Leinwand
    static let background = UIColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1)
    /// Über dem Ziel bleibt so viel von der Seite sichtbar (Punkte der Vorschau): Ein Ziel liegt oft auf der Grundlinie
    /// der ersten Zeile oder knapp darüber
    private static let marginAbove: CGFloat = 28

    init(content: LinkPreviewImages, targetY: CGFloat) {
        self.content = content
        self.targetY = targetY
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Breite des Fensters in Punkten: am iPad ein Popover, am iPhone (schmal) die ganze Breite
    static func width(in controller: UIViewController) -> CGFloat {
        let bounds = controller.view.bounds
        return controller.traitCollection.horizontalSizeClass == .compact ? bounds.width : min(620, bounds.width - 40)
    }

    /// Größe des Popovers am iPad: so breit wie `width`, höchstens 440 hoch, bei wenig Inhalt (eine kurze letzte Seite)
    /// nur so hoch wie er
    static func preferredSize(for content: LinkPreviewImages, in controller: UIViewController) -> CGSize {
        let w = width(in: controller)
        let s = w / PageLayout.width
        let gaps = CGFloat(max(content.slices.count - 1, 0)) * PageLayout.gap * s
        let total = content.slices.reduce(gaps) { $0 + ($1.bottom - $1.top) * s }
        return CGSize(width: w, height: min(440, controller.view.bounds.height * 0.45, total.rounded(.up)))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        view.backgroundColor = Self.background
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        view.addSubview(scroll)
        for image in content.images {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.backgroundColor = .white
            scroll.addSubview(imageView)
            imageViews.append(imageView)
        }
        if let first = content.slices.first {
            badge.text = "Seite \(first.page + 1)"
        }
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.textColor = UIColor(white: 0.3, alpha: 1)
        badge.backgroundColor = UIColor(white: 1, alpha: 0.85)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        badge.isUserInteractionEnabled = false
        view.addSubview(badge)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ohne den Pfeil des Popovers und die Ränder des Blatts
        let area = view.bounds.inset(by: view.safeAreaInsets)
        scroll.frame = area
        let label = badge.intrinsicContentSize
        badge.frame = CGRect(x: area.maxX - label.width - 22, y: area.minY + 8, width: label.width + 14, height: label.height + 6)
        let w = area.width
        guard w > 0, abs(w - laidOutWidth) > 0.5 else { return }
        let first = laidOutWidth == 0
        laidOutWidth = w
        // Punkte der Vorschau je Seitenpunkt: Jede Seite füllt die Breite
        let s = w / PageLayout.width
        var y: CGFloat = 0
        for imageView in imageViews {
            let size = imageView.image?.size ?? .zero
            let h = size.width > 0 ? w * size.height / size.width : 0
            imageView.frame = CGRect(x: 0, y: y, width: w, height: h)
            y += h + PageLayout.gap * s
        }
        scroll.contentSize = CGSize(width: w, height: max(y - PageLayout.gap * s, 0))
        guard first else { return }
        let maxY = max(scroll.contentSize.height - scroll.bounds.height, 0)
        scroll.contentOffset = CGPoint(x: 0, y: min(max(targetY * s - Self.marginAbove, 0), maxY))
    }
}
