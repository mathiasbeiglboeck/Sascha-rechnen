import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// Die Schreibfläche: ein PKCanvasView (scrollt und zoomt selbst), darunter die Seiten.
/// Am iPad schreibt nur der Pencil, der Finger scrollt; am iPhone schreibt auch der Finger, gescrollt wird mit zwei.
///
/// Gespeichert wird in Seitenpunkten (Seite = 768 breit). Auf dem Bildschirm liegt die Zeichnung
/// dagegen in Bildschirmpunkten (Faktor `k`), damit PencilKit bei Zoom 1 nativ und scharf rendert
/// und nicht ein kleineres Bild hochskaliert.
final class CanvasController: UIViewController, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    var onToggleMenus: () -> Void = {}
    var onToggleEraser: () -> Void = {}
    var onFlash: (String) -> Void = { _ in }
    /// Hinweis mit eigener Anzeigedauer; leerer Text blendet ihn aus
    var onFlashTimed: (String, Double) -> Void = { _, _ in }
    var onGuests: (Int?) -> Void = { _ in }

    let doc: NoteDocument
    private let store: DocumentStore
    private let sync: SyncEngine
    let canvas = PKCanvasView()
    private let pagesView = UIView()
    private(set) var pdf: CGPDFDocument?
    private var pageCount: Int
    private(set) var layout = PageLayout.notebook(pages: 1)
    /// Bildschirmpunkte pro Seitenpunkt bei Zoom 1 (Seite füllt die Breite)
    private(set) var k: CGFloat = 0
    private var pendingSave: DispatchWorkItem?
    private var dirty = false
    private var settingDrawing = false

    private var inkColor = UIColor.black
    private var inkWidth: CGFloat = 2
    private var erasing = false
    private var lasso = false
    private var viewOnly = false
    private let eraserGesture = EraserGesture()
    private let eraserCursor = UIView()
    private var eraseStart: PKDrawing?
    private var lastErasePoint: CGPoint?
    /// Radius des Radierers in Bildschirmpunkten
    private static let eraserRadius: CGFloat = 8

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    init(doc: NoteDocument, store: DocumentStore, sync: SyncEngine) {
        self.doc = doc
        self.store = store
        self.sync = sync
        pageCount = max(doc.pageCount, 1)
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
        canvas.drawingPolicy = isPad ? .pencilOnly : .anyInput
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        // Feste Ränder statt Safe Area: sonst springt die Seite, wenn Statusleiste und Menü ein- oder ausblenden
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 4
        canvas.delegate = self
        if isPad {
            // Der Pencil soll nie scrollen, nur schreiben oder radieren
            canvas.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        } else {
            canvas.panGestureRecognizer.minimumNumberOfTouches = 2
        }
        view.addSubview(canvas)

        // Die Seiten liegen im Scrollbereich hinter der Tinte und werden beim Zoomen mitskaliert
        pagesView.isUserInteractionEnabled = false
        pagesView.layer.anchorPoint = .zero
        canvas.insertSubview(pagesView, at: 0)

        // Eigener Radierer: kleiner Kreis, löscht jeden Strich, den der Kreis berührt
        eraserGesture.addTarget(self, action: #selector(handleErase(_:)))
        eraserGesture.isEnabled = false
        if isPad { eraserGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)] }
        canvas.addGestureRecognizer(eraserGesture)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        canvas.addGestureRecognizer(hover)

        let d = Self.eraserRadius * 2
        eraserCursor.frame = CGRect(x: 0, y: 0, width: d, height: d)
        eraserCursor.layer.cornerRadius = Self.eraserRadius
        eraserCursor.layer.borderWidth = 1.5
        eraserCursor.layer.borderColor = UIColor(white: 0.35, alpha: 0.9).cgColor
        eraserCursor.backgroundColor = UIColor(white: 1, alpha: 0.35)
        eraserCursor.isUserInteractionEnabled = false
        eraserCursor.isHidden = true
        view.addSubview(eraserCursor)

        if doc.kind == .pdf {
            pdf = CGPDFDocument(store.pdfURL(doc.id) as CFURL)
        }

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        NotificationCenter.default.addObserver(self, selector: #selector(saveNow),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        // Ab jetzt landen entfernte Änderungen an diesem Dokument hier statt in der Datei
        sync.openController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCycle() }
        }
        syncCycle()
        connectLive()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = canvas.bounds.width
        guard w > 0 else { return }
        let newK = w / PageLayout.width
        guard abs(newK - k) > 0.0001 else { return }

        if k == 0 {
            // Erstes Layout: Ränder einmalig festlegen und Zeichnung laden
            let top = view.safeAreaInsets.top + 56
            canvas.contentInset = UIEdgeInsets(top: top, left: 0, bottom: view.safeAreaInsets.bottom + 24, right: 0)
            canvas.verticalScrollIndicatorInsets = canvas.contentInset
            setDrawing(store.loadDrawing(doc).transformed(using: CGAffineTransform(scaleX: newK, y: newK)))
            k = newK
            relayout()
            growIfNeeded()
            canvas.contentOffset = CGPoint(x: 0, y: -top)
        } else {
            // Drehen: Zeichnung auf die neue Breite umrechnen
            let f = newK / k
            setDrawing(canvas.drawing.transformed(using: CGAffineTransform(scaleX: f, y: f)))
            canvas.undoManager?.removeAllActions()
            k = newK
            updateContentSize()
            redrawInkSoon()
        }
        applyTool()
    }

    /// PencilKit behält beim Drehen die alten Kacheln der Tinte; nach der Animation neu aufbauen lassen
    private var redrawWork: DispatchWorkItem?
    private func redrawInkSoon() {
        redrawWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Nicht mitten in einem Strich, sonst ginge er verloren
            if self.usingTool { self.redrawInkSoon(); return }
            let drawing = self.canvas.drawing
            self.setDrawing(PKDrawing())
            self.setDrawing(drawing)
        }
        redrawWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        syncTimer?.invalidate()
        syncTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        applyPending()
        saveNow()
        if sync.openController === self { sync.openController = nil }
        let sync = self.sync, id = doc.id
        Task { await sync.syncClosed(id) }
    }

    // MARK: Sync: alle 3 Sekunden eigene Änderungen schicken und fremde holen

    private var syncTimer: Timer?
    private var localChanged = true
    private var usingTool = false
    private var pending = RemoteChanges()

    private func pageDrawing() -> PKDrawing {
        canvas.drawing.transformed(using: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
    }

    private func syncCycle() {
        guard sync.isConfigured, k > 0, !sync.isBusy(doc.id), UIApplication.shared.applicationState == .active else { return }
        // Fremde Änderungen müssen drin sein, bevor der eigene Stand verglichen wird
        if !pending.isEmpty {
            guard !usingTool else { return }
            applyPending()
        }
        let snapshot = localChanged ? pageDrawing() : nil
        localChanged = false
        let sync = self.sync, id = doc.id
        Task { [weak self] in
            let ok = await sync.syncStrokes(id, snapshot: snapshot)
            if !ok, snapshot != nil { self?.localChanged = true }
        }
    }

    /// Kurz nach einem Strich abgleichen, damit Zuschauer ihn gleich sehen
    private var syncSoonWork: DispatchWorkItem?
    private func syncSoon() {
        syncSoonWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncCycle() }
        syncSoonWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Live-Teilen

    private var socket: URLSessionWebSocketTask?
    private var shared = false
    private var guests = 0
    private var lastViewSent = Date.distantPast

    private func connectLive() {
        guard socket == nil, syncTimer != nil, let req = sync.webSocketRequest(doc.id) else { return }
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        task.resume()
        receive(task)
        sendView(force: true)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handleLive(text) }
                    self.receive(task)
                case .failure:
                    self.socket = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.connectLive() }
                }
            }
        }
    }

    private func handleLive(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "changes":
            syncSoon()
        case "presence":
            guests = obj["guests"] as? Int ?? 0
            onGuests(shared || guests > 0 ? guests : nil)
        default:
            break
        }
    }

    /// Teilt mit, welcher Bereich gerade zu sehen ist; Gäste mit „Folgen“ scrollen mit
    private func sendView(force: Bool = false) {
        guard let socket, k > 0, force || Date().timeIntervalSince(lastViewSent) > 0.3 else { return }
        lastViewSent = Date()
        let s = k * canvas.zoomScale
        let y0 = (canvas.contentOffset.y + canvas.contentInset.top) / s
        let y1 = (canvas.contentOffset.y + canvas.bounds.height) / s
        let text = "{\"type\":\"view\",\"y0\":\(Double(y0)),\"y1\":\(Double(y1))}"
        socket.send(.string(text)) { _ in }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        sendView()
    }

    func startLiveSharing() {
        guard sync.isConfigured else {
            onFlash("Erst den Server einrichten (Zahnrad in der Übersicht)")
            return
        }
        onFlash("Link wird erstellt …")
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.sync.shareLink(self.doc.id)
                self.shared = true
                self.onGuests(self.guests)
                self.connectLive()
                self.syncCycle()
                UIPasteboard.general.url = url
                self.onFlash("Link kopiert")
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = self.view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: 60, width: 1, height: 1)
                self.present(sheet, animated: true)
            } catch {
                self.onFlash("Teilen fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    func stopLiveSharing() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sync.stopSharing(self.doc.id)
                self.shared = false
                self.onGuests(nil)
                self.onFlash("Teilen beendet, der Link gilt nicht mehr")
            } catch {
                self.onFlash("Beenden fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Entfernte Änderungen; während der Pencil schreibt, warten sie, bis er absetzt
    func enqueue(_ changes: RemoteChanges) {
        pending.merge(changes)
        if !usingTool { applyPending() }
    }

    private func applyPending() {
        guard !pending.isEmpty, k > 0 else { return }
        let changes = pending
        pending = RemoteChanges()
        guard let merged = StrokeCodec.apply(changes, to: pageDrawing()) else { return }
        let wasEmpty = canvas.drawing.strokes.isEmpty
        setDrawing(merged.transformed(using: CGAffineTransform(scaleX: k, y: k)))
        // Auf einer leeren Leinwand zeigt PencilKit den ersten Strich von außen sonst nicht an
        if wasEmpty { redrawInkSoon() }
        // Alte Rückgängig-Schritte würden fremde Striche wieder entfernen
        canvas.undoManager?.removeAllActions()
        growIfNeeded()
        dirty = false
        pendingSave?.cancel()
        store.saveDrawing(merged, for: doc.id, pageCount: pageCount)
    }

    /// Stand der Zeichnung nach dem Laden bzw. letzten Speichern; gleicher Stand wird nicht erneut gespeichert
    private var savedData: Data?

    private func setDrawing(_ drawing: PKDrawing) {
        settingDrawing = true
        canvas.drawing = drawing
        settingDrawing = false
        savedData = canvas.drawing.dataRepresentation()
    }

    // MARK: Werkzeuge

    func apply(color: UIColor, width: CGFloat, mode: ToolMode, viewOnly: Bool = false) {
        self.viewOnly = viewOnly
        inkColor = color
        inkWidth = width
        erasing = mode == .eraser
        lasso = mode == .lasso
        applyTool()
    }

    private func applyTool() {
        // Lasso von PencilKit: auswählen, verschieben; Antippen der Auswahl zeigt Ausschneiden, Kopieren,
        // Duplizieren, Löschen; Antippen einer leeren Stelle zeigt Einsetzen
        if lasso {
            if !(canvas.tool is PKLassoTool) { canvas.tool = PKLassoTool() }
        } else {
            canvas.tool = PKInkingTool(.pen, color: inkColor, width: inkWidth * max(k, 0.5))
        }
        // Nur-Sehen-Modus (am iPhone Standard): nichts zeichnet, ein Finger scrollt
        canvas.drawingGestureRecognizer.isEnabled = !erasing && !viewOnly
        eraserGesture.isEnabled = erasing && !viewOnly
        if !isPad { canvas.panGestureRecognizer.minimumNumberOfTouches = viewOnly ? 1 : 2 }
        if !erasing { eraserCursor.isHidden = true }
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    // MARK: Radierer

    @objc private func handleErase(_ g: EraserGesture) {
        let p = g.location(in: canvas)
        moveCursor(to: g.location(in: view))
        switch g.state {
        case .began:
            usingTool = true
            lockScrolling()
            eraseStart = canvas.drawing
            lastErasePoint = nil
            erase(at: p)
        case .changed:
            erase(at: p)
        case .ended, .cancelled, .failed:
            usingTool = false
            unlockScrollingSoon()
            eraserCursor.isHidden = true
            if let start = eraseStart, start.strokes.count != canvas.drawing.strokes.count {
                canvas.undoManager?.registerUndo(withTarget: self) { $0.replaceDrawingUndoably(with: start) }
                // PencilKit lässt beim Entfernen manchmal einen feinen Rest des Strichs stehen
                redrawInkSoon()
            }
            eraseStart = nil
            lastErasePoint = nil
        default:
            break
        }
    }

    /// Setzt eine Zeichnung und merkt sich die aktuelle für Wiederholen bzw. Rückgängig
    private func replaceDrawingUndoably(with drawing: PKDrawing) {
        let current = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { $0.replaceDrawingUndoably(with: current) }
        canvas.drawing = drawing
    }

    /// `p` in Scroll-Koordinaten; die Zeichnung liegt in Koordinaten ohne Zoom
    private func erase(at p: CGPoint) {
        let z = canvas.zoomScale
        let center = CGPoint(x: p.x / z, y: p.y / z)
        let r = Self.eraserRadius / z
        // Bei schneller Bewegung die Strecke dazwischen mit abtasten
        var samples = [center]
        if let last = lastErasePoint {
            let dist = hypot(center.x - last.x, center.y - last.y)
            let n = Int(dist / r)
            if n > 0 {
                samples = (1...n).map { i in
                    let t = CGFloat(i) / CGFloat(n + 1)
                    return CGPoint(x: last.x + (center.x - last.x) * t, y: last.y + (center.y - last.y) * t)
                } + [center]
            }
        }
        lastErasePoint = center

        var strokes = canvas.drawing.strokes
        let before = strokes.count
        strokes.removeAll { stroke in samples.contains { Self.stroke(stroke, hits: $0, radius: r) } }
        if strokes.count != before {
            canvas.drawing = PKDrawing(strokes: strokes)
        }
    }

    private static func stroke(_ stroke: PKStroke, hits c: CGPoint, radius r: CGFloat) -> Bool {
        let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        guard stroke.renderBounds.intersects(box) else { return false }
        let t = stroke.transform
        let scale = hypot(t.a, t.b)
        for point in stroke.path.interpolatedPoints(by: .distance(max(r / 2, 0.5))) {
            let q = point.location.applying(t)
            if hypot(q.x - c.x, q.y - c.y) <= r + point.size.width * scale / 2 { return true }
        }
        return false
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            lockScrolling()
            if erasing && eraseStart == nil { moveCursor(to: g.location(in: view)) }
        default:
            unlockScrollingSoon()
            if eraseStart == nil { eraserCursor.isHidden = true }
        }
    }

    // MARK: Handballen: solange der Pencil schwebt oder schreibt, bewegt sich die Seite nicht

    private var unlockWork: DispatchWorkItem?

    private func lockScrolling() {
        unlockWork?.cancel()
        unlockWork = nil
        guard canvas.isScrollEnabled else { return }
        canvas.isScrollEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
    }

    /// Kurz warten: zwischen Schweben und Aufsetzen (und zwischen zwei Wörtern) soll nichts freigegeben werden
    private func unlockScrollingSoon() {
        unlockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.canvas.isScrollEnabled = true
            self?.canvas.pinchGestureRecognizer?.isEnabled = true
        }
        unlockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        usingTool = true
        lockScrolling()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        usingTool = false
        unlockScrollingSoon()
        applyPending()
    }

    private func moveCursor(to p: CGPoint) {
        eraserCursor.center = p
        eraserCursor.isHidden = false
    }

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
            pagesView.addSubview(PageView(frame: layout.frames[i], content: content))
        }
        updateContentSize()
    }

    private func updateContentSize() {
        let s = k * canvas.zoomScale
        pagesView.transform = .identity
        pagesView.bounds = CGRect(x: 0, y: 0, width: PageLayout.width, height: layout.totalHeight)
        pagesView.layer.position = .zero
        pagesView.transform = CGAffineTransform(scaleX: s, y: s)
        canvas.contentSize = CGSize(width: PageLayout.width * s, height: layout.totalHeight * s)
    }

    /// Im Notizbuch kommt eine neue leere Seite dazu, sobald auf der letzten geschrieben wird
    private func growIfNeeded() {
        guard pdf == nil, k > 0, !canvas.drawing.strokes.isEmpty else { return }
        let bottom = canvas.drawing.bounds.maxY / k
        var grew = false
        while let last = PageLayout.notebook(pages: pageCount).frames.last, bottom > last.minY {
            pageCount += 1
            grew = true
        }
        if grew { relayout() }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !settingDrawing else { return }
        dirty = true
        localChanged = true
        syncSoon()
        growIfNeeded()
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let s = k * scrollView.zoomScale
        pagesView.transform = CGAffineTransform(scaleX: s, y: s)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateContentSize()
    }

    @objc func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard dirty, k > 0 else { return }
        dirty = false
        // Bloßes Öffnen (PencilKit meldet manchmal verspätet eine „Änderung“) soll nichts speichern
        let current = canvas.drawing.dataRepresentation()
        guard current != savedData else { return }
        savedData = current
        let pageUnits = canvas.drawing.transformed(using: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
        store.saveDrawing(pageUnits, for: doc.id, pageCount: pageCount)
    }
}

/// Meldet Berührungen sofort (ohne Mindestbewegung wie beim Pan), damit auch ein kurzes Antippen radiert
final class EraserGesture: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = (state == .possible && touches.count == 1) ? .began : .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}

// MARK: Teilen: Seite oder ganzes Dokument als PDF oder Bild

enum ShareKind {
    case pagePDF, pageImage, documentPDF
    /// Seite in den Ausgang für einen Empfänger: "claude" oder "chatgpt"
    case sendTo(String)
    /// Ganzes Dokument als ein PDF in den Ausgang (höchstens `maxPagesToAI` Seiten)
    case sendDocumentTo(String)
}

extension CanvasController {
    /// Seite, deren Mitte gerade am nächsten zur Bildschirmmitte liegt
    var currentPageIndex: Int {
        guard k > 0 else { return 0 }
        let s = k * canvas.zoomScale
        let y = (canvas.contentOffset.y + canvas.bounds.height / 2) / s
        return layout.frames.indices.min { abs(layout.frames[$0].midY - y) < abs(layout.frames[$1].midY - y) } ?? 0
    }

    private var exporter: PageExport {
        PageExport(frames: layout.frames, pdf: pdf,
                   ink: canvas.drawing.transformed(using: CGAffineTransform(scaleX: 1 / k, y: 1 / k)))
    }

    func share(_ kind: ShareKind, from sourceRect: CGRect) {
        saveNow()
        let i = currentPageIndex
        if case .sendTo(let recipient) = kind {
            sendPage(i, to: recipient)
            return
        }
        if case .sendDocumentTo(let recipient) = kind {
            sendDocument(to: recipient)
            return
        }
        let export = exporter
        let title = doc.title.replacingOccurrences(of: "/", with: "-")
        let pages = layout.frames.count
        if case .documentPDF = kind, pages > 10 { onFlashTimed("PDF mit \(pages) Seiten wird erstellt …", 30) }
        Task { [weak self] in
            do {
                let url = try await PageExport.run { () -> URL in
                    let tmp = FileManager.default.temporaryDirectory
                    switch kind {
                    case .pagePDF:
                        let url = tmp.appendingPathComponent("\(title) – Seite \(i + 1).pdf")
                        try export.writePDF(pages: [i], to: url, inkScale: 4)
                        return url
                    case .documentPDF:
                        let url = tmp.appendingPathComponent("\(title).pdf")
                        try export.writePDF(pages: Array(export.frames.indices), to: url, inkScale: 3)
                        return url
                    default:
                        let url = tmp.appendingPathComponent("\(title) – Seite \(i + 1).png")
                        try export.pngData(page: i).write(to: url, options: .atomic)
                        return url
                    }
                }
                guard let self else { return }
                self.onFlashTimed("", 0)
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = self.view
                sheet.popoverPresentationController?.sourceRect = sourceRect
                self.present(sheet, animated: true)
            } catch {
                self?.onFlashTimed("Export fehlgeschlagen: \(error.localizedDescription)", 3)
            }
        }
    }

    /// Ganzes Dokument höchstens so viele Seiten an Claude oder ChatGPT
    static let maxPagesToAI = 80

    /// Ganzes Dokument (Hintergrund und Notizen) als ein PDF an Claude oder ChatGPT
    private func sendDocument(to recipient: String) {
        guard sync.isConfigured else {
            onFlashTimed("Erst den Server einrichten (Zahnrad in der Übersicht)", 2.5)
            return
        }
        let count = min(layout.frames.count, Self.maxPagesToAI)
        let cut = layout.frames.count > count
        let name = cut ? "\(doc.title) – Seiten 1-\(count).pdf" : "\(doc.title).pdf"
        let who = recipient == "claude" ? "Claude" : "ChatGPT"
        let export = exporter
        onFlashTimed("Wird gesendet …", 60)
        let sync = self.sync
        Task { [weak self] in
            do {
                let pdf = try await PageExport.run { () -> Data in
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try export.writePDF(pages: Array(0..<count), to: url, inkScale: 2)
                    return try Data(contentsOf: url)
                }
                try await sync.sendToOutbox(to: recipient, name: name, data: pdf, type: "application/pdf")
                self?.onFlashTimed(cut ? "Seiten 1–\(count) liegen bereit für \(who)" : "Ganzes Dokument liegt bereit für \(who)", 2.5)
            } catch {
                self?.onFlashTimed("Senden fehlgeschlagen: \(error.localizedDescription)", 3)
            }
        }
    }

    /// Legt die Seite als PDF und als Bild in den Ausgang des Briefkastens, wo Claude oder Codex sie abholen
    private func sendPage(_ i: Int, to recipient: String) {
        guard sync.isConfigured else {
            onFlashTimed("Erst den Server einrichten (Zahnrad in der Übersicht)", 2.5)
            return
        }
        let base = "\(doc.title) – Seite \(i + 1)"
        let export = exporter
        onFlashTimed("Wird gesendet …", 30)
        let sync = self.sync
        Task { [weak self] in
            do {
                let (pdf, png) = try await PageExport.run { () -> (Data, Data) in
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try export.writePDF(pages: [i], to: url, inkScale: 4)
                    return (try Data(contentsOf: url), export.pngData(page: i))
                }
                try await sync.sendToOutbox(to: recipient, name: base + ".pdf", data: pdf, type: "application/pdf")
                try await sync.sendToOutbox(to: recipient, name: base + ".png", data: png, type: "image/png")
                self?.onFlashTimed("Seite \(i + 1) liegt bereit für \(recipient == "claude" ? "Claude" : "ChatGPT")", 2.5)
            } catch {
                self?.onFlashTimed("Senden fehlgeschlagen: \(error.localizedDescription)", 3)
            }
        }
    }
}
