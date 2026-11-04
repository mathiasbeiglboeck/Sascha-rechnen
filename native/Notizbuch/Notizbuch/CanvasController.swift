import UIKit
import PencilKit

/// Die Schreibfläche: ein PKCanvasView (scrollt und zoomt selbst), darunter die Seiten.
/// Der Finger scrollt, nur der Pencil schreibt (am iPhone schreibt auch der Finger, gescrollt wird dort mit zwei Fingern).
final class CanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    var onToggleMenus: () -> Void = {}
    var onToggleEraser: () -> Void = {}

    private let docID: UUID
    private let kind: DocKind
    private let store: DocumentStore
    private let canvas = PKCanvasView()
    private let pagesView = UIView()
    private var pdf: CGPDFDocument?
    private var pageCount: Int
    private var layout = PageLayout.notebook(pages: 1)
    private var fitScale: CGFloat = 1
    private var lastWidth: CGFloat = 0
    private var pendingSave: DispatchWorkItem?
    private var dirty = false

    init(doc: NoteDocument, store: DocumentStore) {
        docID = doc.id
        kind = doc.kind
        pageCount = max(doc.pageCount, 1)
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1)

        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.drawingPolicy = UIDevice.current.userInterfaceIdiom == .pad ? .pencilOnly : .anyInput
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.delegate = self
        canvas.drawing = store.loadDrawing(docID)
        view.addSubview(canvas)

        // Die Seiten liegen im Scrollbereich hinter der Tinte und werden beim Zoomen mitskaliert
        pagesView.isUserInteractionEnabled = false
        pagesView.layer.anchorPoint = .zero
        canvas.insertSubview(pagesView, at: 0)

        if kind == .pdf {
            pdf = CGPDFDocument(store.pdfURL(docID) as CFURL)
        }
        relayout()
        growIfNeeded()

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        NotificationCenter.default.addObserver(self, selector: #selector(saveNow),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = canvas.bounds.width
        guard w > 0, w != lastWidth else { return }
        // Seitenbreite = Bildschirmbreite; die relative Zoomstufe bleibt beim Drehen erhalten
        let relative = lastWidth == 0 ? 1 : canvas.zoomScale / fitScale
        lastWidth = w
        fitScale = w / PageLayout.width
        canvas.minimumZoomScale = fitScale
        canvas.maximumZoomScale = fitScale * 4
        canvas.zoomScale = fitScale * relative
        updateContentSize()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    // MARK: Werkzeuge

    func apply(color: UIColor, width: CGFloat, eraser: Bool) {
        if eraser {
            if !(canvas.tool is PKEraserTool) { canvas.tool = PKEraserTool(.vector) }
        } else {
            canvas.tool = PKInkingTool(.pen, color: color, width: width)
        }
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    // MARK: Pencil Pro: Drücken blendet die Menüs aus, Doppeltippen wechselt zum Radierer

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { onToggleMenus() }
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        onToggleEraser()
    }

    // Ältere iPadOS-Versionen kennen nur das Doppeltippen
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onToggleEraser()
    }

    // MARK: Seiten

    private func relayout() {
        if let pdf {
            layout = .pdf(pdf)
        } else {
            layout = .notebook(pages: pageCount)
        }
        // Nur fehlende Seiten anlegen, vorhandene bleiben (sonst würden sie neu gezeichnet)
        for i in pagesView.subviews.count..<layout.frames.count {
            let content: PageView.Content
            if let pdf, let page = pdf.page(at: i + 1) { content = .pdf(page) } else { content = .grid }
            let page = PageView(frame: layout.frames[i], content: content)
            page.layer.shadowColor = UIColor.black.cgColor
            page.layer.shadowOpacity = 0.12
            page.layer.shadowRadius = 3
            page.layer.shadowOffset = CGSize(width: 0, height: 1)
            page.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
            pagesView.addSubview(page)
        }
        updateContentSize()
    }

    private func updateContentSize() {
        let z = canvas.zoomScale
        pagesView.transform = .identity
        pagesView.bounds = CGRect(x: 0, y: 0, width: PageLayout.width, height: layout.totalHeight)
        pagesView.layer.position = .zero
        pagesView.transform = CGAffineTransform(scaleX: z, y: z)
        canvas.contentSize = CGSize(width: PageLayout.width * z, height: layout.totalHeight * z)
    }

    /// Im Notizbuch kommt eine neue leere Seite dazu, sobald auf der letzten geschrieben wird
    private func growIfNeeded() {
        guard pdf == nil, !canvas.drawing.strokes.isEmpty else { return }
        let bottom = canvas.drawing.bounds.maxY
        var grew = false
        while let last = PageLayout.notebook(pages: pageCount).frames.last, bottom > last.minY {
            pageCount += 1
            grew = true
        }
        if grew { relayout() }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        dirty = true
        growIfNeeded()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        pagesView.transform = CGAffineTransform(scaleX: scrollView.zoomScale, y: scrollView.zoomScale)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateContentSize()
    }

    @objc private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard dirty else { return }
        dirty = false
        store.saveDrawing(canvas.drawing, for: docID, pageCount: pageCount)
    }
}
