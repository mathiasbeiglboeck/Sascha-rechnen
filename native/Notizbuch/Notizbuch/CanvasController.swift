import UIKit
import PencilKit
import PDFKit

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
    /// Für die offene Seitenübersicht: fremde Striche oder Seitenänderungen sind angekommen
    var onPagesChanged: (() -> Void)?

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
    /// Eingefügte fremde Striche, die noch nicht in der Datei sind. Gespeichert wird dann höchstens einmal pro
    /// Sekunde statt nach jedem fremden Strich (die ganze Zeichnung zu schreiben kostet bei großen Dokumenten)
    private var remoteUnsaved = false
    private var remoteSave: DispatchWorkItem?
    private var settingDrawing = false
    /// Stand nach dem letzten Setzen oder Speichern; ein gleicher Stand wird nicht noch einmal gespeichert
    private var baseline: PKDrawing?
    /// Seit dem letzten Setzen oder Speichern mit einem Werkzeug gearbeitet (dann sicher eine echte Änderung)
    private var toolUsedSinceSave = false

    private var inkColor = UIColor.black
    private var inkWidth: CGFloat = 2
    private var erasing = false
    private var lasso = false
    private var pointing = false
    private let pointerGesture = PointerGesture()
    private let pointerOverlay = PointerOverlay()
    /// Kennung dieses Geräts für Zeigestift-Linien (gilt bis zum Schließen)
    private let pointerAuthor = String(UUID().uuidString.prefix(8))
    private var pointerCount = 0
    private var pointerLine: String?
    private var pointerUnsent: [CGPoint] = []
    private var lastPointerSend = Date.distantPast
    private var pointerFlush: DispatchWorkItem?
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

        // Zeigestift: leuchtende Linien über allem, verblassen nach etwa zehn Sekunden
        pointerOverlay.layer.anchorPoint = .zero
        canvas.addSubview(pointerOverlay)
        pointerGesture.space = pointerOverlay
        pointerGesture.addTarget(self, action: #selector(handlePointer(_:)))
        pointerGesture.isEnabled = false
        if isPad { pointerGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)] }
        canvas.addGestureRecognizer(pointerGesture)

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

        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)

        // Ab jetzt landen entfernte Änderungen an diesem Dokument hier statt in der Datei
        sync.openController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if detached { reattach() }
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTick() }
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
            // Erst Seiten und Größe der Leinwand, dann die Tinte: PencilKit legt seine Kacheln so gleich für die
            // endgültige Größe an. Kurz danach noch einmal neu aufbauen: Selten blieb eine Kachel sonst leer.
            k = newK
            relayout()
            setDrawing(store.loadDrawing(doc).transformed(using: CGAffineTransform(scaleX: newK, y: newK)))
            growIfNeeded()
            canvas.contentOffset = CGPoint(x: 0, y: -top)
            redrawInkSoon()
            warmUpIDs()
            syncCycle()
        } else {
            // Drehen: Zeichnung auf die neue Breite umrechnen
            let f = newK / k
            setDrawing(canvas.drawing.transformed(using: CGAffineTransform(scaleX: f, y: f)))
            canvas.undoManager?.removeAllActions()
            k = newK
            updatePixelScale()
            updateContentSize()
            redrawInkSoon()
            // Alle Striche liegen jetzt anders: IDs im Hintergrund neu, nicht beim nächsten Strich
            warmUpIDs()
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
            if self.toolBusy { self.redrawInkSoon(); return }
            let drawing = self.canvas.drawing
            self.setDrawing(PKDrawing())
            self.setDrawing(drawing)
        }
        redrawWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        detached = true
        syncTimer?.invalidate()
        syncTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pointerFlush?.cancel()
        applyPending()
        saveNow()
        persistSyncStateNow()
        if sync.openController === self { sync.openController = nil }
        let sync = self.sync, id = doc.id
        Task { await sync.syncClosed(id) }
    }

    /// Wieder sichtbar, nachdem die Ansicht verschwunden war: Inzwischen kamen fremde Änderungen in die Datei
    /// statt auf die Leinwand. Also wieder als offene Leinwand anmelden und die Zeichnung neu laden.
    private func reattach() {
        detached = false
        sync.openController = self
        guard k > 0 else { return }
        // Aktuelle Metadaten (die beim Öffnen übergebenen sind veraltet, etwa die Layout-Version)
        let current = store.documents.first { $0.id == doc.id } ?? doc
        if doc.kind == .pdf {
            pdf = CGPDFDocument(store.pdfURL(doc.id) as CFURL) ?? pdf
        } else {
            pageCount = max(current.pageCount, 1)
        }
        pending = RemoteChanges()
        setDrawing(store.loadDrawing(current).transformed(using: CGAffineTransform(scaleX: k, y: k)))
        canvas.undoManager?.removeAllActions()
        rebuildPages()
        growIfNeeded()
        localChanged = true
        warmUpIDs()
    }

    // MARK: Sync: eigene Striche gleich nach dem Absetzen schicken, fremde holen, sobald der Server sie meldet

    private var syncTimer: Timer?
    private var syncTask: Task<Void, Never>?
    /// Noch einmal holen, sobald der laufende Abgleich fertig ist
    private var fetchAgain = false
    /// Höchste Änderungsnummer, die der Server per Hinweis gemeldet hat
    private var remoteSeqHint = 0
    /// Beginn des letzten erfolgreichen Abgleichs: So aktuell ist hier der Stand des Servers
    private var lastFetch = Date.distantPast
    private var localChanged = true
    private var usingTool = false
    /// Wann der Stift zuletzt abgesetzt wurde. PencilKit übernimmt den fertigen Strich erst kurz
    /// nach `canvasViewDidEndUsingTool` in die Zeichnung; wer in diesem Moment die Zeichnung
    /// ersetzt (fremde Striche einfügen), verliert den gerade geschriebenen Strich.
    private var lastToolEnd = Date.distantPast
    private var toolBusy: Bool { usingTool || Date().timeIntervalSince(lastToolEnd) < 0.5 }
    private var pendingWork: DispatchWorkItem?
    private var pending = RemoteChanges()
    /// Seitenzahl, die ein anderes Gerät nach Löschen oder Einfügen gemeldet hat (nur Notizbücher)
    private var remotePageTarget: Int?
    private var remoteTargetSince: Date?
    /// Stand vor der letzten Seitenänderung in der Übersicht
    private var pageUndo: PageUndo?
    /// Seiten werden gerade gelöscht oder eingefügt: so lange kein Abgleich der Striche
    private var restructuring = false
    /// Die Ansicht ist verschwunden (Dokument geschlossen)
    private var detached = false
    /// Nach Seitenänderungen in einem PDF: Die verschobenen Striche warten, bis das neue PDF am Server ist
    private var pdfHoldUntil: Date?
    private var nextHoldRetry = Date.distantPast
    /// Ein anderes Gerät hat Seiten geändert: Seine verschobenen Striche warten auf den neuen Seitenstand
    private var structureSyncSince: Date?
    /// IDs aller Striche werden im Hintergrund vorberechnet
    private var idWarmup: Task<Void, Never>?
    private var warmups = 0
    private var persistWork: DispatchWorkItem?

    /// Für den Abgleich in Paketen: Es gibt Neues, das zuerst hinaus soll
    var hasUnsyncedLocalChanges: Bool { localChanged }
    var isRestructuring: Bool { restructuring }

    /// Leinwand- in Seitenpunkte
    private var toPage: CGAffineTransform { CGAffineTransform(scaleX: 1 / k, y: 1 / k) }

    private func pageDrawing() -> PKDrawing {
        canvas.drawing.transformed(using: toPage)
    }

    private var canSync: Bool {
        sync.isConfigured && k > 0 && !restructuring && !detached && UIApplication.shared.applicationState == .active
    }

    /// Takt alle 3 Sekunden: holt auch, falls ein Hinweis des Servers verloren ging, und versucht Fehlgeschlagenes
    /// noch einmal. Lief eben erst ein Abgleich (der holt immer mit), ist diese Runde überflüssig (spart Anfragen)
    private func syncTick() {
        if !localChanged, remoteSeqHint <= sync.knownSeq(doc.id), Date().timeIntervalSince(lastFetch) < 2.5 { return }
        syncCycle()
    }

    /// Gleicht ab: schickt eigene Änderungen und holt fremde. Läuft schon ein Abgleich, folgt gleich danach noch einer.
    private func syncCycle() {
        guard canSync else { return }
        if syncTask != nil {
            fetchAgain = true
            return
        }
        syncTask = Task { [weak self] in
            await self?.syncLoop()
            self?.syncTask = nil
        }
    }

    private func syncLoop() async {
        var again = true
        while again, canSync {
            // Große Dokumente: erst wenn alle IDs bekannt sind (nach dem Öffnen oder Drehen), sonst hielte
            // das Hashen die App an
            for _ in 0..<3 {
                guard let warmup = idWarmup else { break }
                await warmup.value
            }
            guard canSync else { return }
            fetchAgain = false
            let holding = holdingStrokes
            if holding, Date() > nextHoldRetry {
                // Das neue PDF muss zuerst hinauf, bis dahin warten die verschobenen Striche
                nextHoldRetry = Date().addingTimeInterval(6)
                let sync = self.sync
                Task { [weak self] in
                    await sync.syncLibrary()
                    self?.syncCycle()
                }
            }
            let snapshot = localChanged && !holding ? strokeSnapshot() : nil
            if snapshot != nil { localChanged = false }
            let hint = remoteSeqHint
            let started = Date()
            let ok = await sync.syncStrokes(doc.id, snapshot: snapshot)
            guard ok else {
                // Nächster Versuch mit dem Takt (alle 3 Sekunden), nicht sofort
                if snapshot != nil { localChanged = true }
                return
            }
            // Eine Seitenänderung hat begonnen und das Hochladen in Paketen unterbrochen: Der Rest geht danach
            // hinaus (auch wenn sie abgebrochen wird)
            if snapshot != nil, restructuring { localChanged = true }
            lastFetch = started
            let known = sync.knownSeq(doc.id)
            // Kam während der Anfrage kein neuer Hinweis, ist der alte erledigt (auch nach einem Neustart des Servers)
            if remoteSeqHint == hint { remoteSeqHint = min(remoteSeqHint, known) }
            schedulePersist()
            again = fetchAgain || (localChanged && !holdingStrokes) || remoteSeqHint > known
        }
    }

    private var holdingStrokes: Bool {
        guard let until = pdfHoldUntil else { return false }
        if Date() < until, sync.pdfUploadPending.contains(doc.id) { return true }
        pdfHoldUntil = nil
        return false
    }

    /// Stand der Leinwand für den Abgleich. Fremde Änderungen, die noch auf die Leinwand warten (der Stift
    /// schreibt gerade), zählen schon mit: Sonst hielte der Abgleich sie für hier gelöscht.
    private func strokeSnapshot() -> StrokeSnapshot {
        let start = CACurrentMediaTime()
        var snapshot = StrokeSnapshot(canvas.drawing.strokes, toPage: toPage, prune: true)
        if !pending.isEmpty {
            snapshot.alsoPresent = Set(pending.added.map { $0.id })
            snapshot.alsoGone = pending.removed
        }
        Log.sync.info("Stand der Leinwand: \(snapshot.strokes.count) Striche in \(CanvasController.ms(since: start)) ms")
        return snapshot
    }

    nonisolated static func ms(since start: CFTimeInterval) -> Int { Int((CACurrentMediaTime() - start) * 1000) }

    /// IDs aller Striche im Hintergrund vorberechnen (nach dem Laden oder Drehen), damit kein Abgleich die App
    /// anhält, weil er Zehntausende Striche hashen müsste
    private func warmUpIDs() {
        warmups += 1
        let number = warmups
        let strokes = canvas.drawing.strokes, toPage = self.toPage
        let start = CACurrentMediaTime()
        idWarmup = Task { [weak self] in
            await StrokeIDCache.shared.prewarm(strokes, toPage: toPage)
            Log.sync.info("IDs vorberechnet: \(strokes.count) Striche in \(CanvasController.ms(since: start)) ms")
            guard let self, self.warmups == number else { return }
            self.idWarmup = nil
            self.applyPendingWhenIdle()
            self.syncCycle()
        }
    }

    /// Gleich nach einem Strich abgleichen; die kurze Pause fasst Änderungen eines Augenblicks zusammen
    private var syncSoonWork: DispatchWorkItem?
    private func syncSoon() {
        syncSoonWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncCycle() }
        syncSoonWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    /// Sync-Stand bald sichern (fasst viele Abgleiche zu einem Schreiben zusammen)
    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSyncStateNow() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Sichert den Sync-Stand, wenn die gespeicherte Zeichnung alles enthält, was er als vorhanden kennt:
    /// Alle gelieferten fremden Änderungen sind eingefügt, und nichts ist ungespeichert. Sonst später
    /// (das nächste Speichern oder Einfügen plant es neu).
    private func persistSyncStateNow() {
        persistWork?.cancel()
        persistWork = nil
        guard pending.isEmpty, !dirty, !remoteUnsaved, k > 0 else { return }
        sync.persistState(doc.id)
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
            // Ein neuerer Server meldet die Änderungsnummer: das eigene Echo und schon Geholtes übergehen
            if let seq = (obj["seq"] as? NSNumber)?.intValue {
                remoteSeqHint = max(remoteSeqHint, seq)
                guard seq > sync.knownSeq(doc.id) else { return }
                // Der laufende Abgleich sieht den Hinweis und holt gleich danach
                if syncTask != nil { return }
            }
            syncCycle()
        case "pointer":
            guard let id = obj["id"] as? String, let author = obj["from"] as? String,
                  let pts = obj["pts"] as? [[Double]] else { return }
            let points = pts.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            let color = PointerOverlay.color(hex: obj["color"] as? String) ?? PointerOverlay.pink
            canvas.bringSubviewToFront(pointerOverlay)
            pointerOverlay.add(id: id, author: author, points: points, end: obj["end"] as? Bool ?? false, color: color)
        case "pages":
            // Ein anderes Gerät hat Seiten gelöscht oder eingefügt: neue Seitenzahl bzw. neues PDF holen. Gilt
            // dieser Seitenstand hier schon (etwa das Echo der eigenen Seitenänderung), ist nichts zu tun
            let local = store.documents.first { $0.id == doc.id }
            if let pages = (obj["pagesVersion"] as? NSNumber)?.intValue, pages <= local?.pagesVersion ?? 0,
               let pdfVersion = (obj["pdfVersion"] as? NSNumber)?.intValue, pdfVersion <= local?.pdfVersion ?? 0 {
                return
            }
            // Bei PDFs die verschobenen Striche erst einfügen, wenn auch das neue PDF da ist (sonst lägen sie kurz
            // auf den falschen Seiten). Im Notizbuch passen sie auch vorher.
            if doc.kind == .pdf { structureSyncSince = Date() }
            let sync = self.sync
            Task { [weak self] in
                await sync.syncLibrary()
                self?.structureSyncSince = nil
                self?.applyPendingWhenIdle()
            }
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
        applyPendingWhenIdle()
    }

    /// Fremde Striche erst einfügen, wenn der Stift eine halbe Sekunde ruht (und neue Seiten schon da sind)
    private func applyPendingWhenIdle() {
        pendingWork?.cancel()
        guard !pending.isEmpty else { return }
        let waitForPages = structureSyncSince.map { Date().timeIntervalSince($0) < 15 } ?? false
        guard toolBusy || waitForPages || idWarmup != nil else {
            applyPending()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.applyPendingWhenIdle() }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Fügt die fremden Änderungen ein. Nur die neuen Striche kommen dazu; die übrigen bleiben, wie sie sind,
    /// sodass PencilKit nicht alles neu zeichnen muss. Gespeichert wird im Hintergrund.
    private func applyPending() {
        guard !pending.isEmpty, k > 0 else { return }
        let start = CACurrentMediaTime()
        let changes = pending
        pending = RemoteChanges()
        guard let result = StrokeCodec.apply(changes, to: canvas.drawing, scale: k, prune: true) else { return }
        setDrawing(result.drawing)
        // Auf einer leeren Leinwand zeigt PencilKit den ersten Strich von außen sonst nicht an
        if result.wasEmpty { redrawInkSoon() }
        // Alte Rückgängig-Schritte würden fremde Striche wieder entfernen
        canvas.undoManager?.removeAllActions()
        fitToRemotePageCount()
        growIfNeeded()
        // Gespeichert wird gleich, mit allem, was dann auf der Leinwand ist (kommen viele fremde Striche
        // nacheinander, höchstens einmal pro Sekunde). So lange bleibt der Sync-Stand ungesichert.
        remoteUnsaved = true
        if remoteSave == nil {
            let work = DispatchWorkItem { [weak self] in self?.saveNow() }
            remoteSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        onPagesChanged?()
        Log.sync.info("Eingefügt: +\(changes.added.count) −\(changes.removed.count) in \(CanvasController.ms(since: start)) ms")
    }

    private func setDrawing(_ drawing: PKDrawing) {
        settingDrawing = true
        canvas.drawing = drawing
        settingDrawing = false
        // Ist noch etwas ungespeichert (etwa beim Neuzeichnen kurz nach dem Radieren), bleibt der Vergleichsstand
        // der zuletzt gespeicherte: Das nächste Speichern sieht dann den Unterschied und schreibt
        guard !dirty else { return }
        baseline = canvas.drawing
        toolUsedSinceSave = false
    }

    // MARK: Werkzeuge

    func apply(color: UIColor, width: CGFloat, mode: ToolMode, viewOnly: Bool = false) {
        self.viewOnly = viewOnly
        inkColor = color
        inkWidth = width
        erasing = mode == .eraser
        lasso = mode == .lasso
        pointing = mode == .pointer
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
        canvas.drawingGestureRecognizer.isEnabled = !erasing && !pointing && !viewOnly
        eraserGesture.isEnabled = erasing && !viewOnly
        pointerGesture.isEnabled = pointing && !viewOnly
        if !isPad { canvas.panGestureRecognizer.minimumNumberOfTouches = viewOnly ? 1 : 2 }
        if !erasing { eraserCursor.isHidden = true }
    }

    func undo() {
        toolUsedSinceSave = true
        canvas.undoManager?.undo()
    }

    func redo() {
        toolUsedSinceSave = true
        canvas.undoManager?.redo()
    }

    // MARK: Zeigestift

    @objc private func handlePointer(_ g: PointerGesture) {
        let points = g.takeSamples()
        switch g.state {
        case .began:
            // Am iPhone (Finger) nicht sperren: Ein zweiter Finger soll scrollen können
            if g.isPencil { lockScrolling() }
            startPointerLine()
            addPointer(points, end: false)
        case .changed:
            addPointer(points, end: false)
        case .ended, .cancelled, .failed:
            // Kurzes Antippen (die Geste begann gar nicht erst): ein leuchtender Punkt
            if pointerLine == nil, g.state == .ended, !points.isEmpty { startPointerLine() }
            addPointer(points, end: true)
            pointerLine = nil
            unlockScrollingSoon()
        default:
            break
        }
    }

    private func startPointerLine() {
        pointerCount += 1
        pointerLine = "\(pointerAuthor)-\(pointerCount)"
        pointerUnsent = []
        canvas.bringSubviewToFront(pointerOverlay)
    }

    /// Zeichnet die Punkte und schickt sie höchstens alle 30 ms an die anderen (am Ende sofort)
    private func addPointer(_ points: [CGPoint], end: Bool) {
        guard let id = pointerLine else { return }
        pointerOverlay.add(id: id, author: pointerAuthor, points: points, end: end, color: PointerOverlay.ownColor)
        pointerUnsent += points
        pointerFlush?.cancel()
        pointerFlush = nil
        if end || Date().timeIntervalSince(lastPointerSend) > 0.03 {
            sendPointer(id, end: end)
        } else {
            // Bleibt der Stift stehen, kommen keine neuen Punkte: den Rest trotzdem gleich schicken
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pointerLine == id else { return }
                self.sendPointer(id, end: false)
            }
            pointerFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
        }
    }

    private func sendPointer(_ id: String, end: Bool) {
        guard let socket else { return }
        lastPointerSend = Date()
        let coords = pointerUnsent.map { "[\(Double(($0.x * 10).rounded()) / 10),\(Double(($0.y * 10).rounded()) / 10)]" }
        pointerUnsent = []
        let text = "{\"type\":\"pointer\",\"from\":\"\(pointerAuthor)\",\"id\":\"\(id)\",\"end\":\(end),"
            + "\"color\":\"\(PointerOverlay.ownHex)\",\"pts\":[\(coords.joined(separator: ","))]}"
        socket.send(.string(text)) { _ in }
    }

    // MARK: Radierer

    @objc private func handleErase(_ g: EraserGesture) {
        let p = g.location(in: canvas)
        moveCursor(to: g.location(in: view))
        switch g.state {
        case .began:
            usingTool = true
            toolUsedSinceSave = true
            // Am iPhone (Finger) nicht sperren: Ein zweiter Finger soll scrollen können
            if g.isPencil { lockScrolling() }
            eraseStart = canvas.drawing
            lastErasePoint = nil
            erase(at: p)
        case .changed:
            erase(at: p)
        case .ended, .cancelled, .failed:
            if eraseStart == nil, g.state == .ended {
                // Kurzes Antippen mit dem Finger (die Geste begann gar nicht erst): einmal radieren
                toolUsedSinceSave = true
                eraseStart = canvas.drawing
                lastErasePoint = nil
                erase(at: p)
            }
            usingTool = false
            lastToolEnd = Date()
            defer { applyPendingWhenIdle() }
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
        strokes.removeAll { stroke in samples.contains { CanvasController.stroke(stroke, hits: $0, radius: r) } }
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
        toolUsedSinceSave = true
        // Handballen gibt es nur am iPad; am iPhone soll ein zweiter Finger weiter scrollen können
        if isPad { lockScrolling() }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        usingTool = false
        lastToolEnd = Date()
        unlockScrollingSoon()
        applyPendingWhenIdle()
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
        updatePixelScale()
        updateContentSize()
    }

    /// Alle Seiten neu anlegen, wenn sich Reihenfolge oder Inhalt der Seiten geändert hat
    private func rebuildPages() {
        for v in pagesView.subviews { v.removeFromSuperview() }
        relayout()
    }

    private func updatePixelScale() {
        for case let page as PageView in pagesView.subviews { page.pixelScale = k }
    }

    private func updateContentSize() {
        let s = k * canvas.zoomScale
        pagesView.transform = .identity
        pagesView.bounds = CGRect(x: 0, y: 0, width: PageLayout.width, height: layout.totalHeight)
        pagesView.layer.position = .zero
        pagesView.transform = CGAffineTransform(scaleX: s, y: s)
        pointerOverlay.transform = .identity
        pointerOverlay.bounds = pagesView.bounds
        pointerOverlay.layer.position = .zero
        pointerOverlay.transform = CGAffineTransform(scaleX: s, y: s)
        canvas.contentSize = CGSize(width: PageLayout.width * s, height: layout.totalHeight * s)
    }

    /// Unterkante der Tinte in Seitenpunkten (nil = keine Tinte)
    private var inkBottom: CGFloat? {
        let bounds = canvas.drawing.bounds
        guard k > 0, !bounds.isNull, !bounds.isEmpty, bounds.maxY.isFinite else { return nil }
        return bounds.maxY / k
    }

    /// Im Notizbuch kommt eine neue leere Seite dazu, sobald auf der letzten geschrieben wird
    private func growIfNeeded() {
        guard pdf == nil, let bottom = inkBottom else { return }
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
        pointerOverlay.transform = CGAffineTransform(scaleX: s, y: s)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateContentSize()
    }

    /// Speichert im Hintergrund (Umrechnen und Kodieren der ganzen Zeichnung soll den Stift nie bremsen)
    @objc func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        remoteSave?.cancel()
        remoteSave = nil
        guard dirty || remoteUnsaved, k > 0 else { return }
        // Nur eigene Änderungen zählen als Bearbeitung (modified), übernommene fremde nicht
        let touch = dirty
        let current = canvas.drawing
        // Bloßes Öffnen (PencilKit meldet manchmal verspätet eine „Änderung“) soll nichts speichern:
        // Ohne Werkzeug seither vergleicht der Hintergrund mit dem letzten Stand. Eingefügte fremde Striche
        // stehen dagegen sicher noch nicht in der Datei
        let base = toolUsedSinceSave || remoteUnsaved ? nil : baseline
        dirty = false
        remoteUnsaved = false
        store.saveDrawing(current, toPage: toPage, for: doc.id, pageCount: pageCount, touch: touch, unlessEqualTo: base)
        baseline = current
        toolUsedSinceSave = false
        schedulePersist()
    }

    @objc private func appWillResignActive() {
        if !toolBusy { applyPending() }
        saveNow()
        persistSyncStateNow()
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

// MARK: Seiten löschen und einfügen (Seitenübersicht)

/// Wie die letzte Seitenänderung rückgängig zu machen ist, für „Rückgängig“ in der Übersicht.
/// Rückgängig rechnet die Seiten zurück, statt den alten Stand einzusetzen: Striche, die inzwischen
/// von anderen Geräten kamen, bleiben so erhalten.
struct PageUndo {
    /// Striche der gelöschten Seiten (Seitenpunkte, Koordinaten vor der Änderung)
    let removed: [PKStroke]
    /// Für jede Seite jetzt: welche Seite sie vorher war (nil = eingefügte Seite)
    let inverse: (Int) -> Int?
    /// Seitenzahl des Notizbuchs vor der Änderung
    let pageCount: Int
    /// Kopie des PDFs vor der Änderung (nur bei PDF-Dokumenten)
    let pdfBackup: URL?
}

struct PageEditError: LocalizedError {
    let errorDescription: String?
}

/// Was die Übersicht für ihre Vorschaubilder braucht. Umrechnen und Sortieren der Striche läuft im Hintergrund.
struct OverviewSource: @unchecked Sendable {
    let frames: [CGRect]
    let pdf: CGPDFDocument?
    /// Zeichnung der Leinwand und wie sie in Seitenpunkte umzurechnen ist
    let ink: PKDrawing
    let toPage: CGAffineTransform

    func build() -> PageExport {
        PageExport(frames: frames, pdf: pdf, ink: ink.transformed(using: toPage)).indexed()
    }
}

extension CanvasController {
    /// Momentaufnahme aller Seiten für die Übersicht (fremde Striche zuerst einfügen)
    func overviewSource() -> OverviewSource {
        applyPending()
        saveNow()
        return OverviewSource(frames: layout.frames, pdf: pdf, ink: canvas.drawing,
                              toPage: CGAffineTransform(scaleX: 1 / max(k, 0.0001), y: 1 / max(k, 0.0001)))
    }

    var canUndoPageChange: Bool { pageUndo != nil }
    var pageTotal: Int { layout.frames.count }

    /// Springt so, dass Seite `i` oben unter der Leiste beginnt
    func scrollToPage(_ i: Int) {
        guard k > 0, layout.frames.indices.contains(i) else { return }
        let s = k * canvas.zoomScale
        let top = canvas.contentInset.top
        let maxY = max(canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height, -top)
        let y = min(max((layout.frames[i].minY - layout.gap) * s - top, -top), maxY)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: false)
        sendView(force: true)
        // Nach einem großen Sprung blieb selten eine Kachel der Tinte leer; neu aufbauen lassen
        redrawInkSoon()
    }

    /// Seiten, auf denen etwas steht
    private func inkedPages() -> Set<Int> {
        guard k > 0, !layout.frames.isEmpty else { return [] }
        var pages = Set<Int>()
        for stroke in canvas.drawing.strokes {
            pages.insert(layout.page(at: stroke.renderBounds.midY / k))
        }
        return pages
    }

    /// Löscht Seiten samt ihren Notizen; die Seiten darunter rücken nach
    func deletePages(_ pages: Set<Int>, done: @escaping (String?) -> Void) {
        guard !restructuring else { done("Einen Moment, die letzte Änderung läuft noch"); return }
        var gone = pages.filter { layout.frames.indices.contains($0) }
        guard !gone.isEmpty else { done(nil); return }
        let count = layout.frames.count
        if pdf != nil {
            if gone.count >= count {
                done("Mindestens eine Seite muss bleiben")
                return
            }
        } else {
            // Nach der letzten beschriebenen Seite bleibt immer eine leere (sie käme sofort wieder)
            let lastInk = inkedPages().max() ?? -1
            let tail = (lastInk + 1)..<count
            if !tail.isEmpty, tail.allSatisfy({ gone.contains($0) }), let keep = tail.last { gone.remove(keep) }
            guard !gone.isEmpty else {
                done("Die leere Seite am Ende bleibt immer da")
                return
            }
        }
        let sorted = gone.sorted()
        // Neue Nummer jeder alten Seite (nil = gelöscht)
        var newIndex: [Int?] = []
        var shift = 0
        for i in 0..<count {
            if gone.contains(i) {
                newIndex.append(nil)
                shift += 1
            } else {
                newIndex.append(i - shift)
            }
        }
        let table = newIndex
        let mapping: (Int) -> Int? = { i in i >= 0 && i < table.count ? table[i] : i - sorted.count }
        // Rückweg: Seite n jetzt war vorher die n-te verbliebene; danach Gewachsenes rückt um die gelöschten nach
        let survivors = (0..<count).filter { !gone.contains($0) }
        let inverse: (Int) -> Int? = { n in n < survivors.count ? survivors[n] : n + sorted.count }
        var edit: (@Sendable (PDFDocument) throws -> Void)?
        if pdf != nil {
            edit = { doc in
                for i in sorted.reversed() { doc.removePage(at: i) }
            }
        }
        restructure(pageDelta: -sorted.count, mapping: mapping, inverse: inverse, pdfEdit: edit, done: done)
    }

    /// Fügt eine leere karierte Seite ein, sodass sie Seite `index` wird
    func insertBlankPage(at index: Int, done: @escaping (String?) -> Void) {
        guard !restructuring else { done("Einen Moment, die letzte Änderung läuft noch"); return }
        let j = min(max(index, 0), layout.frames.count)
        let mapping: (Int) -> Int? = { i in i >= j ? i + 1 : i }
        let inverse: (Int) -> Int? = { n in n < j ? n : (n == j ? nil : n - 1) }
        var edit: (@Sendable (PDFDocument) throws -> Void)?
        if pdf != nil { edit = { doc in
            // So breit wie die Nachbarseite, im Format A4
            let neighbor = doc.page(at: max(j - 1, 0))
            var width: CGFloat = 595.28
            if let neighbor {
                let box = neighbor.bounds(for: .cropBox)
                width = abs(neighbor.rotation) % 180 == 90 ? box.height : box.width
            }
            guard let page = PDFDocument(data: CanvasController.gridPagePDF(width: width))?.page(at: 0) else {
                throw PageEditError(errorDescription: "Leere Seite konnte nicht erstellt werden")
            }
            doc.insert(page, at: j)
        } }
        restructure(pageDelta: 1, mapping: mapping, inverse: inverse, pdfEdit: edit, done: done)
    }

    /// Eine karierte Seite als einseitiges PDF (für das Einfügen in PDF-Dokumente)
    nonisolated static func gridPagePDF(width: CGFloat) -> Data {
        let height = width * 297 / 210
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height))
        return renderer.pdfData { c in
            c.beginPage()
            let s = width / PageLayout.width
            c.cgContext.scaleBy(x: s, y: s)
            PageView.drawGrid(in: c.cgContext, rect: CGRect(x: 0, y: 0, width: PageLayout.width, height: PageLayout.a4Height),
                              lineWidth: 0.5)
        }
    }

    /// Holt sofort, was am Server neu ist, und bringt es auf die Leinwand: Vor einer Seitenänderung soll alles,
    /// was andere schon geschrieben haben, mit seiner Seite mitrücken. Eigenes geht erst danach hinaus
    /// (es bekommt durch das Verschieben ohnehin neue IDs).
    private func fetchRemoteNow() async {
        if let running = syncTask { await running.value }
        for _ in 0..<3 {
            guard let warmup = idWarmup else { break }
            await warmup.value
        }
        if sync.isConfigured, k > 0 {
            await sync.syncStrokes(doc.id, snapshot: nil)
        }
        applyPending()
    }

    /// Macht die letzte Seitenänderung rückgängig
    func undoPageChange(done: @escaping (String?) -> Void) {
        guard let undo = pageUndo, !restructuring else { done(nil); return }
        pageUndo = nil
        restructuring = true
        Task { [weak self] in
            guard let self else { return }
            await self.fetchRemoteNow()
            // Eine eingefügte Seite fiele mit allem darauf weg. Steht inzwischen etwas darauf (auch von anderen
            // Geräten oder Gästen), lieber nicht rückgängig machen
            let before = self.layout
            if self.pageDrawing().strokes.contains(where: { undo.inverse(before.page(at: $0.renderBounds.midY)) == nil }) {
                self.pageUndo = undo
                self.restructuring = false
                done("Auf der eingefügten Seite steht inzwischen etwas. Zum Entfernen die Seite löschen.")
                return
            }
            if let backup = undo.pdfBackup {
                let url = self.store.pdfURL(self.doc.id)
                do {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: backup)
                } catch {
                    self.restructuring = false
                    done("Rückgängig fehlgeschlagen: \(error.localizedDescription)")
                    return
                }
                guard let restored = CGPDFDocument(url as CFURL) else {
                    self.restructuring = false
                    done("Rückgängig fehlgeschlagen: PDF lässt sich nicht öffnen")
                    return
                }
                self.pdf = restored
            }
            let current = self.layout
            let strokes = self.pageDrawing().strokes
            // Notizbuch: so viele Seiten, dass auch inzwischen gewachsene Seiten einen Platz haben
            let target = self.pdf.map { PageLayout.pdf($0) } ?? PageLayout.notebook(pages: undo.pageCount + current.frames.count)
            let moved = CanvasController.move(strokes, from: current, to: target, mapping: undo.inverse)
            self.commitPages(PKDrawing(strokes: moved.kept + undo.removed), pageCount: undo.pageCount,
                             pdfChanged: undo.pdfBackup != nil)
            done(nil)
        }
    }

    /// Verschiebt Striche mit ihrer Seite von `old` nach `new`; `mapping` sagt, welche Seite welche wird
    /// (nil = fällt weg). Was keiner Seite sicher zuzuordnen ist, bleibt, wo es ist: lieber an der falschen
    /// Stelle als verloren.
    private static func move(_ strokes: [PKStroke], from old: PageLayout, to new: PageLayout,
                             mapping: (Int) -> Int?) -> (kept: [PKStroke], removed: [PKStroke]) {
        var kept: [PKStroke] = [], removed: [PKStroke] = []
        guard !old.frames.isEmpty else { return (strokes, []) }
        for stroke in strokes {
            let i = old.page(at: stroke.renderBounds.midY)
            guard let j = mapping(i) else {
                removed.append(stroke)
                continue
            }
            guard j >= 0, j < new.frames.count else {
                kept.append(stroke)
                continue
            }
            var s = stroke
            s.transform = s.transform.concatenating(
                CGAffineTransform(translationX: 0, y: new.frames[j].minY - old.frames[i].minY))
            kept.append(s)
        }
        return (kept, removed)
    }

    /// Beim Schließen der Übersicht: Kopie für Rückgängig aufräumen
    func discardPageUndo() {
        if let backup = pageUndo?.pdfBackup { try? FileManager.default.removeItem(at: backup) }
        pageUndo = nil
    }

    /// Ordnet Seiten neu: `mapping` sagt für jede alte Seite, welche neue Seite sie wird (nil = fällt weg).
    /// Zuerst wird geholt, was andere Geräte schon geschrieben haben, damit es mitrückt. Bei PDFs wird dann
    /// das PDF selbst geändert (im Hintergrund), danach rücken die Notizen mit.
    private func restructure(pageDelta: Int, mapping: @escaping (Int) -> Int?, inverse: @escaping (Int) -> Int?,
                             pdfEdit: (@Sendable (PDFDocument) throws -> Void)?, done: @escaping (String?) -> Void) {
        restructuring = true
        discardPageUndo()
        Task { [weak self] in
            guard let self else { return }
            await self.fetchRemoteNow()
            var backup: URL?
            var newPDF: CGPDFDocument?
            if let pdfEdit {
                let url = self.store.pdfURL(self.doc.id)
                do {
                    backup = try await PageExport.run { () -> URL? in
                        let fm = FileManager.default
                        // Kopie für Rückgängig (fehlt sie, geht es eben ohne Rückgängig)
                        let copy = url.deletingLastPathComponent().appendingPathComponent("source-undo.pdf")
                        try? fm.removeItem(at: copy)
                        let saved = (try? fm.copyItem(at: url, to: copy)) != nil ? copy : nil
                        do {
                            guard let doc = PDFDocument(url: url) else {
                                throw PageEditError(errorDescription: "PDF lässt sich nicht öffnen")
                            }
                            try pdfEdit(doc)
                            let tmp = url.deletingLastPathComponent().appendingPathComponent("source-new.pdf")
                            try? fm.removeItem(at: tmp)
                            guard doc.write(to: tmp) else {
                                throw PageEditError(errorDescription: "PDF lässt sich nicht speichern")
                            }
                            _ = try fm.replaceItemAt(url, withItemAt: tmp)
                        } catch {
                            if let saved { try? fm.removeItem(at: saved) }
                            throw error
                        }
                        return saved
                    }
                    guard let p = CGPDFDocument(url as CFURL) else {
                        throw PageEditError(errorDescription: "Geändertes PDF lässt sich nicht öffnen")
                    }
                    newPDF = p
                } catch {
                    if let backup { try? FileManager.default.removeItem(at: backup) }
                    self.restructuring = false
                    done("Seiten ändern fehlgeschlagen: \(error.localizedDescription)")
                    return
                }
            }
            // Was eben noch kam, liegt im alten Layout: erst einfügen, dann verschieben
            self.applyPending()
            let old = self.layout
            let strokes = self.pageDrawing().strokes
            let new: PageLayout
            if let newPDF {
                self.pdf = newPDF
                new = .pdf(newPDF)
            } else {
                new = .notebook(pages: max(old.frames.count + pageDelta, 1))
            }
            let moved = CanvasController.move(strokes, from: old, to: new, mapping: mapping)
            self.pageUndo = PageUndo(removed: moved.removed, inverse: inverse, pageCount: old.frames.count, pdfBackup: backup)
            self.commitPages(PKDrawing(strokes: moved.kept), pageCount: new.frames.count, pdfChanged: newPDF != nil)
            done(nil)
        }
    }

    /// Übernimmt eine neue Seitenordnung: Zeichnung (Seitenpunkte), Seiten neu anlegen, speichern, abgleichen
    private func commitPages(_ drawing: PKDrawing, pageCount newCount: Int, pdfChanged: Bool) {
        remotePageTarget = nil
        if pdf == nil { pageCount = max(newCount, 1) }
        setDrawing(drawing.transformed(using: CGAffineTransform(scaleX: k, y: k)))
        canvas.undoManager?.removeAllActions()
        rebuildPages()
        growIfNeeded()
        redrawInkSoon()
        dirty = false
        pendingSave?.cancel()
        remoteUnsaved = false
        remoteSave?.cancel()
        remoteSave = nil
        store.saveDrawing(drawing, for: doc.id, pageCount: pageCount, touch: true)
        // Neue Seitenversion: Andere Geräte übernehmen Seitenzahl bzw. PDF, auch wenn sie inzwischen selbst
        // etwas gespeichert haben
        store.notePagesChanged(doc.id, pdf: pdfChanged, pageCount: pageCount)
        if pdfChanged {
            // Die verschobenen Striche erst schicken, wenn das neue PDF am Server ist (höchstens 30 s warten)
            sync.notePDFUploadPending(doc.id)
            pdfHoldUntil = Date().addingTimeInterval(30)
            nextHoldRetry = Date().addingTimeInterval(6)
        }
        localChanged = true
        restructuring = false
        schedulePersist()
        warmUpIDs()
        let sync = self.sync
        Task { [weak self] in
            await sync.syncLibrary()
            self?.syncCycle()
        }
        syncCycle()
    }

    /// Ein anderes Gerät hat Seiten gelöscht oder eingefügt: neue Seitenzahl bzw. neues PDF übernehmen
    func remoteStructureChanged(pageCount n: Int, pdfChanged: Bool) {
        // Das eigene Rückgängig passt nicht mehr zu den neuen Seiten
        discardPageUndo()
        if pdfChanged, doc.kind == .pdf {
            pdf = CGPDFDocument(store.pdfURL(doc.id) as CFURL) ?? pdf
            if k > 0 { rebuildPages() }
        }
        if doc.kind == .notebook {
            remotePageTarget = max(n, 1)
            remoteTargetSince = Date()
            fitToRemotePageCount()
        }
        onPagesChanged?()
    }

    /// Notizbuch auf die gemeldete Seitenzahl bringen, aber nie eine Seite mit Notizen abschneiden.
    /// Erledigt, sobald die verschobenen Striche da sind (oder nach einer halben Minute).
    private func fitToRemotePageCount() {
        guard let target = remotePageTarget, pdf == nil, k > 0 else { return }
        var want = max(target, 1)
        if let bottom = inkBottom {
            while bottom > PageLayout.gap + CGFloat(want - 1) * (PageLayout.a4Height + PageLayout.gap) { want += 1 }
        }
        if want == target || Date().timeIntervalSince(remoteTargetSince ?? .distantPast) > 30 {
            remotePageTarget = nil
        }
        guard want != pageCount else { return }
        pageCount = want
        rebuildPages()
    }
}
