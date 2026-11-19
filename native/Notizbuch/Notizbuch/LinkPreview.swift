import PDFKit
import PencilKit
import UIKit
import WebKit

/// Ziel eines Links im PDF: die Seite (ab 0) und die Höhe der Stelle auf ihr in Seitenpunkten (von oben; nil: oben)
struct LinkTarget: Equatable, Sendable {
    var page: Int
    var y: CGFloat?
}

/// Wohin ein Link führt: an eine Stelle im selben Dokument oder zu einer Seite im Internet (nur http und https)
enum LinkGoal: Equatable, Sendable {
    case place(LinkTarget)
    case web(URL)
}

/// Ein Link mit Vorschau: wo er liegt (Seitenpunkte seiner Seite, von ihrer oberen linken Ecke) und wohin
struct LinkSpot: Sendable {
    var rect: CGRect
    var goal: LinkGoal
}

/// Vorschau auf das Ziel eines Links: Hält man den Radierer `holdDuration` still auf einen Link, zeigt ein Fenster, wohin
/// er führt (siehe CanvasController, „Vorschau auf das Ziel eines Links“): eine Stelle im selben PDF samt Tinte, oder
/// die Seite im Internet.
enum LinkPreview {
    /// So lange bleibt der Radierer still auf dem Link, bis die Vorschau kommt (bis 120: 1,5 s, Mathias fand das zu lang)
    static let holdDuration: TimeInterval = 0.8
    /// Erst nach dieser Zeit erscheint der Kreis, der sich bis zur Vorschau füllt: Beim gewöhnlichen Radieren, das auf
    /// einem Link beginnt, blitzt so nichts auf
    static let ringDelay: TimeInterval = 0.25
    /// So weit darf sich der Radierer dabei bewegen (Bildschirmpunkte); weiter, und er radiert wie immer
    static let holdSlop: CGFloat = 10

    /// Alle Links im PDF an `url`, die an eine Stelle im selben Dokument oder ins Internet führen, je Seite. Läuft im
    /// Hintergrund: Die Leinwand zeichnet mit CoreGraphics, das Links nicht auflöst; dafür liest PDFKit das PDF hier
    /// einmal selbst. Abgebrochen (neues PDF, Leinwand zu): leer
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
                    guard let found = goal(of: annotation, onPage: i, in: document, toView: toView, heights: heights)
                    else { continue }
                    let rect = annotation.bounds.applying(transform)
                    guard !rect.isNull, rect.width > 0 || rect.height > 0 else { continue }
                    spots[i].append(LinkSpot(rect: rect, goal: found))
                }
            }
        }
        return spots
    }

    /// Ziel des Links an `point` (Seitenpunkte der Seite, von ihrer oberen linken Ecke). Liegt keiner genau dort, zählt
    /// der nächste, der höchstens `tolerance` entfernt ist
    static func goal(at point: CGPoint, in spots: [LinkSpot], tolerance: CGFloat) -> LinkGoal? {
        var best: (distance: CGFloat, goal: LinkGoal)?
        for spot in spots {
            let d = distance(from: point, to: spot.rect)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (d, spot.goal) }
        }
        return best?.goal
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

    /// Wohin der Link auf Seite `index` führt: „Gehe zu“ (auch über einen benannten Sprung, den PDFKit auflöst), die
    /// Befehle „nächste“, „vorige“, „erste“ und „letzte Seite“, oder eine Adresse im Internet. Andere Dateien, E-Mail
    /// und sonstige Befehle zählen nicht
    private static func goal(of annotation: PDFAnnotation, onPage index: Int, in document: PDFDocument,
                             toView: [CGAffineTransform?], heights: [CGFloat]) -> LinkGoal? {
        guard let action = annotation.action else {
            guard let destination = annotation.destination else { return nil }
            return resolve(destination, in: document, toView: toView, heights: heights).map(LinkGoal.place)
        }
        switch action {
        case let action as PDFActionGoTo:
            return resolve(action.destination, in: document, toView: toView, heights: heights).map(LinkGoal.place)
        case let action as PDFActionNamed:
            let page: Int
            switch action.name {
            case .nextPage: page = index + 1
            case .previousPage: page = index - 1
            case .firstPage: page = 0
            case .lastPage: page = document.pageCount - 1
            default: return nil
            }
            guard toView.indices.contains(page), toView[page] != nil else { return nil }
            return .place(LinkTarget(page: page, y: nil))
        case let action as PDFActionURL:
            return webURL(action.url).map(LinkGoal.web)
        default:
            return nil
        }
    }

    /// Eine Adresse im Internet (http, https, oder ohne Schema mit „www.“ am Anfang), sonst nil
    static func webURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host?.isEmpty == false ? url : nil
        case nil:
            let text = url.absoluteString
            guard text.lowercased().hasPrefix("www.") else { return nil }
            return URL(string: "https://" + text)
        default:
            return nil
        }
    }

    /// Die Vorschau lädt immer über https (WebKit lädt in der App nichts unverschlüsselt); Safari bekommt die Adresse,
    /// wie sie im PDF steht
    static func secure(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url ?? url
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
    private let fade = CAGradientLayer()
    private var laidOutWidth: CGFloat = 0

    /// Hintergrund zwischen den Seiten, wie die Leinwand
    static let background = UIColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1)
    /// Grauer Rand um die Seiten (Punkte): So hebt sich das Fenster vom weißen PDF darunter ab
    static let edge: CGFloat = 6
    /// Oben blendet die Seite auf dieser Höhe aus: Eine angeschnittene Zeile über dem Ziel stört so nicht
    private static let fadeHeight: CGFloat = 18
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

    /// Breite der Seiten im Fenster (Punkte): `width` ohne den grauen Rand
    static func pageWidth(in controller: UIViewController) -> CGFloat {
        max(width(in: controller) - 2 * edge, 1)
    }

    /// Größe des Popovers am iPad: so breit wie `width`, höchstens 440 hoch, bei wenig Inhalt (eine kurze letzte Seite)
    /// nur so hoch wie er
    static func preferredSize(for content: LinkPreviewImages, in controller: UIViewController) -> CGSize {
        let s = pageWidth(in: controller) / PageLayout.width
        let gaps = CGFloat(max(content.slices.count - 1, 0)) * PageLayout.gap * s
        let total = content.slices.reduce(gaps + 2 * edge) { $0 + ($1.bottom - $1.top) * s }
        return CGSize(width: width(in: controller),
                      height: min(440, controller.view.bounds.height * 0.45, total.rounded(.up)))
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
        fade.colors = [Self.background.cgColor, Self.background.withAlphaComponent(0).cgColor]
        view.layer.addSublayer(fade)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: Self.fadeHeight)
        CATransaction.commit()
        let label = badge.intrinsicContentSize
        badge.frame = CGRect(x: area.maxX - label.width - 22, y: area.minY + 8, width: label.width + 14, height: label.height + 6)
        let w = area.width - 2 * Self.edge
        guard w > 0, abs(w - laidOutWidth) > 0.5 else { return }
        let first = laidOutWidth == 0
        laidOutWidth = w
        // Punkte der Vorschau je Seitenpunkt: Jede Seite füllt die Breite innerhalb des Rands
        let s = w / PageLayout.width
        var y = Self.edge
        for imageView in imageViews {
            let size = imageView.image?.size ?? .zero
            let h = size.width > 0 ? w * size.height / size.width : 0
            imageView.frame = CGRect(x: Self.edge, y: y, width: w, height: h)
            y += h + PageLayout.gap * s
        }
        scroll.contentSize = CGSize(width: area.width, height: max(y - PageLayout.gap * s, Self.edge) + Self.edge)
        guard first else { return }
        let maxY = max(scroll.contentSize.height - scroll.bounds.height, 0)
        scroll.contentOffset = CGPoint(x: 0, y: min(max(Self.edge + targetY * s - Self.marginAbove, 0), maxY))
    }
}

/// Das Fenster für einen Link ins Internet: die Seite selbst, darin scrollbar und antippbar, oben ihre Adresse und
/// „In Safari öffnen“. Sie lädt erst, wenn das Fenster kommt (nicht schon beim kurzen Innehalten auf dem Link), immer
/// über https, und nichts bleibt liegen (keine Cookies, kein Cache).
/// Am iPad ein Popover am Radierer, am iPhone ein halbhohes Blatt; Antippen daneben schließt es
final class WebPreviewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    /// Die Adresse, wie sie im PDF steht
    let url: URL
    private let web: WKWebView
    private let address = UILabel()
    private let safari = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let note = UILabel()
    /// Die erste Adresse, die WebKit für das Fenster meldet: die aus dem PDF, über https und in WebKits Schreibweise
    /// (etwa mit „/“ am Ende). Steht diese Seite noch da, bekommt Safari die Adresse so, wie sie im PDF steht
    private var first: URL?
    /// Angetippte http-Links lädt das Fenster über https wie den Link aus dem PDF; Safari bekommt sie wie den Link aus
    /// dem PDF so, wie sie angetippt wurden (https-Form → wie angetippt)
    private var upgraded: [URL: URL] = [:]
    /// Was im Fenster gerade geladen wird (nach Weiterleitungen deren Ziel), womit dieses Laden begann (vor jeder
    /// Weiterleitung), und was zuletzt nicht kam (bis wieder eine Seite erscheint)
    private var pending: URL?
    private var started: URL?
    private var failedTarget: URL?
    /// Folgt der gezeigten Adresse, auch wenn eine Seite per Skript weiterschaltet (für die Zeile oben)
    private var urlObservation: NSKeyValueObservation?

    /// Höhe der Leiste über der Seite
    private static let barHeight: CGFloat = 40

    init(url: URL) {
        self.url = url
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.dataDetectorTypes = []
        // Die Fassung für schmale Bildschirme: Das Fenster ist kaum breiter als ein Telefon
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        web = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    /// Größe des Popovers am iPad: so breit wie die Vorschau einer Stelle im PDF, etwas höher
    static func preferredSize(in controller: UIViewController) -> CGSize {
        CGSize(width: LinkPreviewController.width(in: controller), height: min(560, controller.view.bounds.height * 0.6))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Wie die Vorschau einer Stelle im PDF: hell, die Seite mit grauem Rand
        overrideUserInterfaceStyle = .light
        view.backgroundColor = LinkPreviewController.background
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        view.addSubview(web)

        showAddress(nil)
        urlObservation = web.observe(\.url, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.showAddress(web.url) }
        }
        address.font = .systemFont(ofSize: 13, weight: .medium)
        address.textColor = .secondaryLabel
        address.lineBreakMode = .byTruncatingMiddle
        view.addSubview(address)

        var button = UIButton.Configuration.plain()
        button.title = "In Safari öffnen"
        button.image = UIImage(systemName: "safari")
        button.imagePadding = 5
        button.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        safari.configuration = button
        safari.addTarget(self, action: #selector(openInSafari), for: .primaryActionTriggered)
        view.addSubview(safari)

        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        note.font = .systemFont(ofSize: 15)
        note.textColor = .secondaryLabel
        note.textAlignment = .center
        note.numberOfLines = 0
        note.backgroundColor = LinkPreviewController.background
        note.layer.cornerRadius = 10
        note.layer.masksToBounds = true
        note.isHidden = true
        view.addSubview(note)

        web.load(URLRequest(url: LinkPreview.secure(url)))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ohne den Pfeil des Popovers und die Ränder des Blatts
        let area = view.bounds.inset(by: view.safeAreaInsets)
        let bar = Self.barHeight
        let button = safari.intrinsicContentSize
        safari.frame = CGRect(x: area.maxX - button.width - 6, y: area.minY + (bar - button.height) / 2,
                              width: button.width, height: button.height)
        spinner.frame = CGRect(x: safari.frame.minX - 26, y: area.minY + (bar - 20) / 2, width: 20, height: 20)
        address.frame = CGRect(x: area.minX + 14, y: area.minY, width: max(spinner.frame.minX - area.minX - 20, 0),
                               height: bar)
        let edge = LinkPreviewController.edge
        web.frame = CGRect(x: area.minX + edge, y: area.minY + bar, width: max(area.width - 2 * edge, 0),
                           height: max(area.height - bar - edge, 0))
        let text = note.sizeThatFits(CGSize(width: max(web.frame.width - 80, 0), height: .greatestFiniteMagnitude))
        let box = CGSize(width: min(text.width + 32, web.frame.width - 32), height: text.height + 24)
        note.frame = CGRect(x: web.frame.midX - box.width / 2, y: web.frame.minY + 40, width: box.width,
                            height: box.height)
    }

    /// Oben die Adresse der gezeigten Seite, ohne „www.“ (bevor eine da ist: die aus dem PDF)
    private func showAddress(_ shown: URL?) {
        let page = shown.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } ?? url
        let host = page.host ?? page.absoluteString
        address.text = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Was „In Safari öffnen“ öffnet: die gezeigte Seite (auch nach einem Weiterschalten per Skript), angetippte
    /// http-Links so, wie sie angetippt wurden; kam das zuletzt Angetippte nicht, dieses, wie es angetippt wurde (auch
    /// wenn erst eine Weiterleitung scheiterte). Steht noch die Seite aus dem PDF da oder kam sie nicht, die Adresse so,
    /// wie sie im PDF steht: Eine Seite nur mit http lädt Safari dann über http
    var safariTarget: URL {
        if let failedTarget {
            return failedTarget == first ? url : (upgraded[failedTarget] ?? failedTarget)
        }
        // Auch während ein angetippter http-Link noch über https lädt: Safari bekommt ihn, wie er angetippt wurde
        if let shown = web.url, shown != first, ["http", "https"].contains(shown.scheme?.lowercased() ?? "") {
            return upgraded[shown] ?? shown
        }
        return url
    }

    @objc private func openInSafari() {
        UIApplication.shared.open(safariTarget)
        dismiss(animated: true)
    }

    private func show(_ text: String) {
        note.text = text
        note.isHidden = false
        view.setNeedsLayout()
        #if DEBUG
        NSLog("Link-Debug: Webseite: %@", text)
        #endif
    }

    private func failed(_ error: Error) {
        spinner.stopAnimating()
        let e = error as NSError
        // Abgebrochen (etwas anderes angetippt) oder von hier angehalten (eine Datei, die WebKit nicht zeigt)
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain", e.code == 102 { return }
        failedTarget = started ?? pending
        let offline = e.domain == NSURLErrorDomain
            && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed].contains(e.code)
        show(offline ? "Keine Verbindung" : "Die Seite lässt sich hier nicht laden.")
    }

    // MARK: WebKit

    /// Seiten und was sie einbetten; E-Mail, Telefon und Links in andere Apps nicht aus der Vorschau heraus
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { return decisionHandler(.cancel) }
        let scheme = target.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame ?? true, scheme == "http" || scheme == "https" else {
            return decisionHandler(.allow)
        }
        // Ein angetippter http-Link: über https wie der Link aus dem PDF (über http sperrt iOS ihn hier). Nicht bei
        // Weiterleitungen: Eine Seite, die von https auf http umleitet, drehte sich sonst im Kreis
        if scheme == "http", navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            loadOverHTTPS(navigationAction.request, from: target)
            return
        }
        if first == nil { first = target }
        pending = target
        decisionHandler(.allow)
    }

    /// Lädt ein http-Ziel über https und merkt sich die http-Adresse für Safari
    private func loadOverHTTPS(_ request: URLRequest, from target: URL) {
        let secure = LinkPreview.secure(target)
        upgraded[secure] = target
        var request = request
        request.url = secure
        web.load(request)
    }

    /// Was WebKit nicht zeigen kann (etwa ein Archiv), lädt es hier auch nicht herunter
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType else { return decisionHandler(.allow) }
        // „In Safari öffnen“ öffnet dann die Datei, nicht die Seite davor (das Abbrechen meldet WebKit als Fehler 102,
        // den failed() übergeht)
        failedTarget = started ?? pending
        decisionHandler(.cancel)
        show("Diese Datei lässt sich hier nicht zeigen.")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        spinner.startAnimating()
        // Eine neue Seite lädt: Was davor nicht kam, gilt für „In Safari öffnen“ nicht mehr. Die Entscheidung über das
        // erste Ziel fiel schon, Weiterleitungen kommen erst danach: pending ist hier der Anfang dieses Ladens
        failedTarget = nil
        started = pending
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        note.isHidden = true
        failedTarget = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        spinner.stopAnimating()
        #if DEBUG
        NSLog("Link-Debug: Webseite geladen: %@ (%@)", webView.title ?? "", webView.url?.absoluteString ?? "")
        #endif
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    /// Die Seite steht schon da, nur ein Rest fehlt: nichts melden
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        spinner.stopAnimating()
    }

    /// WebKits Prozess wurde beendet (etwa wegen Speicher): neu laden
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// Links, die ein neues Fenster öffnen wollen, öffnen hier (http über https wie oben)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let target = navigationAction.request.url else { return nil }
        if target.scheme?.lowercased() == "http" {
            loadOverHTTPS(navigationAction.request, from: target)
        } else {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
