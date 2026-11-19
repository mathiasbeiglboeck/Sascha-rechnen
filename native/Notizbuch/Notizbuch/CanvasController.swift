import UIKit
import PencilKit
import PDFKit
import Combine

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
    let canvas = InkCanvasView()
    private let pagesView = UIView()
    private(set) var pdf: CGPDFDocument? {
        didSet { if pdf !== oldValue { linksChanged() } }
    }
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
    /// Claude fragen: merkt sich den Weg des Lassos (PencilKit verrät seine Auswahl nicht)
    private let lassoTracker = LassoTracker()
    /// Der zuletzt gezogene Weg des Lassos (Seitenpunkte)
    private var lassoPath: LassoPath?
    /// Die Markierungen der Fragen an Claude, über der Tinte
    private let askOverlay = AskOverlay()
    private let askTap = MarkTapGesture()
    private var askWatch: AnyCancellable?
    private weak var answerCard: AnswerCardController?
    /// Beantwortete Fragen beim letzten Zeichnen der Markierungen (nil: noch nie gezeichnet)
    private var knownAnswered: Set<String>?
    private var viewOnly = false
    private let eraserGesture = EraserGesture()
    private let eraserCursor = UIView()
    private var eraseStart: PKDrawing?
    private var lastErasePoint: CGPoint?
    /// Radius des Radierers in Bildschirmpunkten
    private static let eraserRadius: CGFloat = 8
    /// Links im PDF, die an eine Stelle im Dokument führen, je Seite (nil: noch nicht gelesen)
    private var linkSpots: [[LinkSpot]]?
    private var linkScan: Task<Void, Never>?
    /// Zählt die PDFs dieser Leinwand: Was das Lesen eines älteren findet, gilt nicht mehr
    private var linkGeneration = 0
    /// Der Radierer setzte auf einem Link auf und wartet, ob er still bleibt
    private var linkHold: LinkHold?
    /// In dieser Berührung kam die Vorschau: Bis zum Abheben radiert der Radierer nichts mehr
    private var linkPreviewTouch = false
    /// Die Vorschau erscheint, sobald ihre Bilder fertig sind. Eine neue Berührung des Radierers, ein anderes Werkzeug,
    /// ein neues PDF oder ein inzwischen geöffnetes Fenster (etwa eine Antwort) bricht das ab: Sie soll nie mitten in
    /// etwas anderem auftauchen
    private var linkPresentation: Task<Void, Never>?
    private weak var linkPreview: LinkPreviewController?
    /// Kreis um den Radierer, der sich bis zur Vorschau füllt
    private let holdRing = CAShapeLayer()
    /// Kurzes Tippen im Pencil Pro (am iPhone im Gerät), wenn die Vorschau kommt (UICanvasFeedbackGenerator, ab iOS 17.5)
    private var holdFeedback: AnyObject?

    /// Der Radierer wartet auf einem Link, ob er still bleibt
    private struct LinkHold {
        let target: LinkTarget
        /// Wo er aufsetzte: in der Ansicht (für den Spielraum) und in der Zeichnung (ohne Zoom, zum Radieren: Der Zoom
        /// kann sich während des Wartens noch ändern, etwa wenn er nach dem Aufziehen zurückfedert)
        let viewPoint: CGPoint
        let drawingPoint: CGPoint
        let timers: [DispatchWorkItem]
        /// Bilder der Vorschau: Sie werden ab dem Erscheinen des Kreises im Hintergrund gezeichnet
        var images: Task<LinkPreviewImages?, Never>?
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Wo die Leinwand öffnet: zurück in einem Tab dort, wo er zuletzt stand (nil = oben)
    private let start: Viewport?
    /// Zusätzlicher Rand oben für die Tab-Zeile über der Leiste
    private let topExtra: CGFloat

    init(doc: NoteDocument, store: DocumentStore, sync: SyncEngine, start: Viewport? = nil, topExtra: CGFloat = 0) {
        self.doc = doc
        self.store = store
        self.sync = sync
        self.start = start
        self.topExtra = topExtra
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
        // Eine Vorschau eines Links, die noch auf ihre Bilder wartet, käme sonst mitten in diese neue Berührung
        eraserGesture.onTouchDown = { [weak self] in self?.cancelLinkPresentation() }
        canvas.addGestureRecognizer(eraserGesture)

        // Zeigestift: leuchtende Linien über allem, verblassen nach etwa zehn Sekunden
        pointerOverlay.layer.anchorPoint = .zero
        canvas.addSubview(pointerOverlay)
        pointerGesture.space = pointerOverlay
        pointerGesture.addTarget(self, action: #selector(handlePointer(_:)))
        pointerGesture.isEnabled = false
        if isPad { pointerGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)] }
        canvas.addGestureRecognizer(pointerGesture)

        // Claude fragen: Weg des Lassos mitschreiben, ohne PencilKit aufzuhalten (Pencil am iPad, Finger am iPhone)
        lassoTracker.cancelsTouchesInView = false
        lassoTracker.delaysTouchesBegan = false
        lassoTracker.delaysTouchesEnded = false
        lassoTracker.space = pagesView
        lassoTracker.onEnded = { [weak self] in self?.lassoEnded($0) }
        lassoTracker.isEnabled = false
        if isPad { lassoTracker.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)] }
        canvas.addGestureRecognizer(lassoTracker)
        canvas.selectionMenuItems = { [weak self] context in self?.askMenuItems(context) ?? [] }
        // Markierungen der Fragen über der Tinte; Antippen öffnet die Antwort
        canvas.addSubview(askOverlay)
        askTap.drawing = canvas.drawingGestureRecognizer
        askTap.delegate = self
        askTap.addTarget(self, action: #selector(handleAskTap(_:)))
        canvas.addGestureRecognizer(askTap)
        // Erst nach der Änderung zeichnen (nicht mitten darin): Was dabei passiert, darf die Fragen wieder ändern
        askWatch = sync.asks.$revisions
            .map { [id = doc.id] in $0[id] ?? 0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadAskMarks() }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        canvas.addGestureRecognizer(hover)
        appHover = hover

        let d = Self.eraserRadius * 2
        eraserCursor.frame = CGRect(x: 0, y: 0, width: d, height: d)
        eraserCursor.layer.cornerRadius = Self.eraserRadius
        eraserCursor.layer.borderWidth = 1.5
        eraserCursor.layer.borderColor = UIColor(white: 0.35, alpha: 0.9).cgColor
        eraserCursor.backgroundColor = UIColor(white: 1, alpha: 0.35)
        eraserCursor.isUserInteractionEnabled = false
        eraserCursor.isHidden = true
        view.addSubview(eraserCursor)
        setUpHoldRing()
        if #available(iOS 17.5, *) { holdFeedback = UICanvasFeedbackGenerator(view: view) }

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
        // Verlassener Tab: meldet sich nicht wieder an, die nächste Leinwand ist schon offen
        guard !left else { return }
        if !appeared {
            appeared = true
            // Rückgängig gilt nur für diese Leinwand. Das Fenster teilt einen Stapel für alle: Schritte einer früheren
            // Leinwand (anderer Tab, geschlossenes Dokument) würden sonst auf deren nicht mehr sichtbare Zeichnung wirken
            canvas.undoManager?.removeAllActions()
        }
        if detached { reattach() }
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTick() }
        }
        syncCycle()
        connectLive()
        sync.asks.refresh(doc.id)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = canvas.bounds.width
        guard w > 0 else { return }
        let newK = w / PageLayout.width
        guard abs(newK - k) > 0.0001 else { return }

        if k == 0 {
            // Erstes Layout: Ränder einmalig festlegen und Zeichnung laden (stehen Tabs über der Leiste, oben mehr Platz)
            let top = view.safeAreaInsets.top + 56 + topExtra
            canvas.contentInset = UIEdgeInsets(top: top, left: 0, bottom: view.safeAreaInsets.bottom + 24, right: 0)
            canvas.verticalScrollIndicatorInsets = canvas.contentInset
            // Erst Seiten und Größe der Leinwand, dann die Tinte: PencilKit legt seine Kacheln so gleich für die
            // endgültige Größe an. Kurz danach noch einmal neu aufbauen: Selten blieb eine Kachel sonst leer.
            k = newK
            relayout()
            // Zurück in einem Tab: Zoom wie zuletzt, auch das vor der Tinte
            if let zoom = start?.zoom, abs(zoom - 1) > 0.001 {
                canvas.zoomScale = min(max(zoom, canvas.minimumZoomScale), canvas.maximumZoomScale)
                updateContentSize()
            }
            setDrawing(store.loadDrawing(doc).transformed(using: CGAffineTransform(scaleX: newK, y: newK)))
            growIfNeeded()
            adoptRemotePageTarget()
            canvas.contentOffset = startOffset(top: top)
            redrawInkSoon()
            warmUpIDs()
            syncCycle()
        } else {
            // Drehen: Zeichnung auf die neue Breite umrechnen
            let f = newK / k
            let scale = CGAffineTransform(scaleX: f, y: f)
            // Der Vergleichsstand fürs Speichern gilt in Leinwandpunkten: mit umrechnen (bleibt er, weil etwas
            // ungespeichert ist, sähe das Speichern sonst einen Unterschied, wo keiner ist)
            if dirty { baseline = baseline?.transformed(using: scale) }
            setDrawing(canvas.drawing.transformed(using: scale))
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
    /// Wartet das ausstehende Neuzeichnen, bis der Pencil nicht mehr schwebt? Nur nach dem Radieren (handleErase):
    /// Setzen der Zeichnung unter dem schwebenden Pencil versteckt PencilKits Live-Leinwand, und der nächste Strich
    /// erschiene erst beim Absetzen. Alle anderen Anlässe (Drehen, Seitensprung, fremde Striche) warten nicht
    private var redrawWaitsForPencil = false
    private func redrawInkSoon(waitForPencil: Bool = false) {
        // Kommen mehrere Anlässe zusammen, wartet das Neuzeichnen nur, wenn alle warten dürfen
        redrawWaitsForPencil = waitForPencil && (redrawWork == nil || redrawWaitsForPencil)
        redrawWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Nicht mitten in einem Strich, sonst ginge er verloren
            if self.toolBusy || (self.redrawWaitsForPencil && self.pencilNear) {
                self.redrawInkSoon(waitForPencil: self.redrawWaitsForPencil)
                return
            }
            self.redrawInkNow()
        }
        redrawWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Baut die Tinte sofort neu auf; ein noch ausstehendes Neuzeichnen entfällt damit
    private func redrawInkNow() {
        redrawWork?.cancel()
        redrawWork = nil
        redrawWaitsForPencil = false
        let drawing = canvas.drawing
        setDrawing(PKDrawing())
        setDrawing(drawing)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        detach()
    }

    /// Endgültig verlassen (Tab-Wechsel oder Editor zu): Erscheint die Ansicht doch noch einmal, bleibt sie abgemeldet
    private var left = false
    /// Schon einmal erschienen (danach nur noch nach dem Verschwinden, etwa unter einem Vollbild)
    private var appeared = false

    /// Der Tab wechselt oder schließt: wie das Verschwinden der Ansicht (speichern, abgleichen, abmelden), aber sofort,
    /// bevor die nächste Leinwand öffnet. Ihr späteres Verschwinden ändert dann nichts mehr
    func leave() {
        left = true
        detach()
        // Die Seitenübersicht gehört jetzt zum nächsten Tab (ihr Rückruf hielte sonst diese Leinwand fest)
        onPagesChanged = nil
    }

    /// Ist ein Strich unterwegs oder eben abgesetzt (PencilKit übernimmt ihn erst kurz danach in die Zeichnung)?
    /// Dann wartet ein Tab-Wechsel, sonst ginge der Strich verloren
    var isSettling: Bool { toolBusy }

    /// Sichtbare Stelle in Seitenpunkten (linker oberer Rand unter der Leiste) und Zoom; dort öffnet der Tab wieder
    var viewport: Viewport? {
        guard k > 0 else { return nil }
        let s = k * canvas.zoomScale
        return Viewport(x: canvas.contentOffset.x / s, y: (canvas.contentOffset.y + canvas.contentInset.top) / s,
                        zoom: canvas.zoomScale)
    }

    /// Wo die Leinwand beim Öffnen steht: oben, oder zurück in einem Tab an seiner letzten Stelle
    private func startOffset(top: CGFloat) -> CGPoint {
        guard let start else { return CGPoint(x: 0, y: -top) }
        let s = k * canvas.zoomScale
        let maxX = max(canvas.contentSize.width - canvas.bounds.width, 0)
        let maxY = max(canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height, -top)
        return CGPoint(x: min(max(start.x * s, 0), maxX), y: min(max(start.y * s - top, -top), maxY))
    }

    private func detach() {
        guard !detached else { return }
        detached = true
        syncTimer?.invalidate()
        syncTimer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        pointerFlush?.cancel()
        // Verschwindet die Fläche, während der Pencil schwebt, kommt das Ende des Schwebens vielleicht nie an
        pencilHovering = false
        busyRetry?.cancel()
        busyRetry = nil
        applyPending()
        saveNow()
        // Solange die Leinwand noch im Fenster ist: Ihre Schritte aus dem gemeinsamen Rückgängig-Stapel nehmen, sonst
        // träfe Rückgängig in der nächsten Leinwand diese hier (und die App-eigenen Radier-Schritte eine schon
        // freigegebene)
        canvas.undoManager?.removeAllActions()
        persistSyncStateNow()
        if sync.openController === self { sync.openController = nil }
        cancelLinkHold()
        cancelLinkPresentation()
        // Das Lesen der Links fängt beim Wiederkommen neu an (dann mit dem dann aktuellen PDF)
        linkScan?.cancel()
        linkScan = nil
        // Karte mit der Antwort und Vorschau eines Links (am iPhone vielleicht über der Karte): von unten her schließen,
        // das nimmt alles darüber mit
        let base: UIViewController? = answerCard ?? linkPreview
        if let base { Self.dismissStack(from: base, animated: false) }
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
        adoptRemotePageTarget()
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
    /// Wie `lastToolEnd`, aber nur für PencilKits eigene Striche (nicht den Radierer der App)
    private var lastInkEnd = Date.distantPast
    /// Ist ein eben geschriebener Strich womöglich noch nicht in der Zeichnung?
    private var inkSettling: Bool { Date().timeIntervalSince(lastInkEnd) < 0.5 }
    /// Schwebt der Pencil gerade über der Fläche (eigene Schwebe-Geste der App)?
    private var pencilHovering = false
    /// Wann er zuletzt aufgehört hat zu schweben: aufgesetzt, weggehoben oder zur Leiste gewandert
    private var lastHoverEnd = Date.distantPast
    /// Schwebt der Pencil, oder schwebte er eben noch? Die kurze Nachfrist deckt den Moment zwischen dem Ende des
    /// Schwebens und dem Aufsetzen ab, in dem der neue Strich noch nicht gemeldet ist, und PencilKits Aufräumen danach
    private var pencilNear: Bool { pencilHovering || Date().timeIntervalSince(lastHoverEnd) < 0.25 }
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

    /// Das Dokument kam zurück, nachdem es anderswo gelöscht war: alle Striche noch einmal hinauf (welche das sind,
    /// weiß der Abgleich)
    func resendAll() {
        localChanged = true
        syncCycle()
    }

    /// Leinwand- in Seitenpunkte
    private var toPage: CGAffineTransform { CGAffineTransform(scaleX: 1 / k, y: 1 / k) }

    private func pageDrawing() -> PKDrawing {
        canvas.drawing.transformed(using: toPage)
    }

    private var canSync: Bool {
        sync.isConfigured && k > 0 && !restructuring && !detached && UIApplication.shared.applicationState == .active
    }

    /// Takt alle 3 Sekunden: holt auch, falls ein Hinweis des Servers verloren ging, und versucht Fehlgeschlagenes
    /// noch einmal. Lief eben erst ein Abgleich (der holt immer mit) und steht die Live-Verbindung (sie meldet
    /// Neues sofort), ist diese Runde überflüssig (spart Anfragen)
    private func syncTick() {
        if socket != nil, !localChanged, remoteSeqHint <= sync.knownSeq(doc.id),
           Date().timeIntervalSince(lastFetch) < 2.5 { return }
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
            // Gleicht gerade die eben geschlossene Fassung dieses Dokuments ab (schnell zu seinem Tab
            // zurückgewechselt): gleich danach, ohne vorher umsonst den Stand der Leinwand zu erfassen
            if sync.isBusy(doc.id) {
                retryWhenFree()
                return
            }
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
                // Nächster Versuch mit dem Takt (alle 3 Sekunden), nicht sofort; nur wenn ein anderer Abgleich
                // dieses Dokuments im Weg war, gleich nach ihm
                if snapshot != nil { localChanged = true }
                if sync.isBusy(doc.id) { retryWhenFree() }
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

    /// Wartender Versuch, sobald der andere Abgleich dieses Dokuments fertig ist; höchstens einer, egal wie oft
    /// Takt, Striche oder Hinweise des Servers inzwischen abgleichen wollen
    private var busyRetry: DispatchWorkItem?
    private func retryWhenFree() {
        guard busyRetry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.busyRetry = nil
            self?.syncCycle()
        }
        busyRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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
        var snapshot = StrokeSnapshot(canvas.drawing.strokes, toPage: toPage, pruning: .canvas)
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
    /// - Parameter done: bekommt danach die IDs der Striche von jetzt (aus dem Speicher, ohne neu zu hashen)
    private func warmUpIDs(then done: (([String]) -> Void)? = nil) {
        warmups += 1
        let number = warmups
        let strokes = canvas.drawing.strokes, toPage = self.toPage
        let start = CACurrentMediaTime()
        idWarmup = Task { [weak self] in
            await StrokeIDCache.shared.prewarm(strokes, toPage: toPage)
            Log.sync.info("IDs vorberechnet: \(strokes.count) Striche in \(CanvasController.ms(since: start)) ms")
            guard let self, self.warmups == number else { return }
            self.idWarmup = nil
            // Ohne Aufräumen: Ist die Leinwand inzwischen zu, gehört der Speicher vielleicht schon einer anderen
            done?(StrokeIDCache.shared.ids(for: strokes, toPage: toPage, pruning: .never))
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
        // Eine geschlossene Leinwand, deren Abgleich noch lief, sichert nichts mehr, sobald das Dokument wieder
        // (in einer neuen Leinwand) offen ist: Deren Fremdes ist dann vielleicht noch nicht gespeichert
        guard pending.isEmpty, !dirty, !remoteUnsaved, k > 0,
              sync.openController == nil || sync.openController === self else { return }
        sync.persistState(doc.id)
    }

    // MARK: Live-Teilen

    private var socket: URLSessionWebSocketTask?
    /// Auf der neuen Verbindung kam noch nichts an
    private var socketFresh = false
    private var shared = false
    private var guests = 0
    private var lastViewSent = Date.distantPast

    private func connectLive() {
        guard socket == nil, syncTimer != nil, let req = sync.webSocketRequest(doc.id) else { return }
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        socketFresh = true
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
                    // Verbindung steht: Was geschrieben wurde, solange sie fehlte, gleich holen (Hinweise ab jetzt)
                    if self.socketFresh {
                        self.socketFresh = false
                        self.syncCycle()
                        // Ebenso die Fragen an Claude (Antworten, die ohne Verbindung kamen)
                        self.sync.asks.refresh(self.doc.id)
                    }
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
        case "asks":
            // Fragen an Claude haben sich geändert (neue Antwort, gelöscht, verschoben): Liste holen
            sync.asks.hint(doc.id, v: (obj["v"] as? NSNumber)?.intValue)
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
                self.presentOnTop(sheet)
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
        guard let result = StrokeCodec.apply(changes, to: canvas.drawing, scale: k, pruning: .canvas) else { return }
        setDrawing(result.drawing)
        // Auf einer leeren Leinwand zeigt PencilKit den ersten Strich von außen sonst nicht an
        if result.wasEmpty { redrawInkSoon() }
        // Alte Rückgängig-Schritte würden fremde Striche wieder entfernen
        canvas.undoManager?.removeAllActions()
        // Solange noch Striche kommen (nach einer Seitenänderung anderswo in vielen Paketen), gilt die gemeldete
        // Seitenzahl weiter: Die alten Fassungen verschwinden erst mit dem letzten Paket
        if remotePageTarget != nil { remoteTargetSince = Date() }
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
        // Radierer wird abgewählt, während der Pencil weg ist (etwa mit dem Finger über die Leiste): das Neuzeichnen
        // nach dem Radieren gleich erledigen. Nach dem Doppeltippen schwebt er meist noch; dann wartet es, bis er weg
        // ist (siehe redrawInkSoon)
        if erasing, mode != .eraser, !usingTool, !inkSettling, !pencilNear, redrawWork != nil { redrawInkNow() }
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
        // Duplizieren, Löschen; Antippen einer leeren Stelle zeigt Einsetzen. Nicht im Nur-Sehen-Modus: Dort blieben
        // PencilKits Lasso-Gesten aktiv, und eine Auswahl ließe sich verschieben. Der Stift löscht die Auswahl; mit
        // „Bearbeiten“ ist das Lasso wieder da
        if lasso && !viewOnly {
            if !(canvas.tool is PKLassoTool) { canvas.tool = PKLassoTool() }
        } else {
            canvas.tool = PKInkingTool(.pen, color: inkColor, width: inkWidth * max(k, 0.5))
        }
        // Nur-Sehen-Modus (am iPhone Standard): nichts zeichnet, ein Finger scrollt
        canvas.drawingGestureRecognizer.isEnabled = !erasing && !pointing && !viewOnly
        // PencilKits Lasso-Menü (Ausschneiden, Kopieren, Einsetzen …) nur, wenn man bearbeiten darf; siehe InkCanvasView
        canvas.editingAllowed = !viewOnly
        eraserGesture.isEnabled = erasing && !viewOnly
        pointerGesture.isEnabled = pointing && !viewOnly
        lassoTracker.isEnabled = lasso && !viewOnly
        if !lassoTracker.isEnabled { lassoPath = nil }
        if !isPad { canvas.panGestureRecognizer.minimumNumberOfTouches = viewOnly ? 1 : 2 }
        if !erasing { eraserCursor.isHidden = true }
        setPencilKitHover(enabled: !(erasing && !viewOnly))
        if erasing && !viewOnly {
            // Links des PDFs schon lesen, bevor der Radierer auf einem aufsetzt
            loadLinksIfNeeded()
        } else {
            cancelLinkHold()
            cancelLinkPresentation()
        }
    }

    /// PencilKits eigene Schwebe-Gesten, solange der Radierer sie abgeschaltet hat
    private var pausedPencilKitHover: [UIGestureRecognizer] = []
    /// Die eigene Schwebe-Geste der App (Handballen, Radierer-Kreis); sie bleibt immer an
    private weak var appHover: UIHoverGestureRecognizer?
    /// Läuft die Pause gerade? Nur für das Protokoll
    private var hoverPauseActive = false

    /// Schaltet PencilKits Schweben (die Vorschau unter dem schwebenden Pencil) beim eigenen Radierer ab und beim
    /// Wechsel zurück wieder an. Lief es über das Radieren hinweg weiter, erschien der erste Strich nach dem
    /// Doppeltippen zum Stift erst beim Absetzen; erst Wegheben des Pencils räumte das auf. Beim Radierer bekommt
    /// PencilKit so vom Pencil gar nichts mit, wie wenn er weg wäre, und das Wiedereinschalten beginnt ein frisches
    /// Schweben. Fehlen die Gesten (andere PencilKit-Version), passiert nichts; das Protokoll (Kategorie ink) nennt,
    /// was pausiert wurde
    private func setPencilKitHover(enabled: Bool) {
        if enabled {
            for g in pausedPencilKitHover { g.isEnabled = true }
            pausedPencilKitHover = []
            hoverPauseActive = false
            return
        }
        let before = pausedPencilKitHover.count
        // Bei jedem Aufruf nachsehen: PencilKit könnte eine Geste neu anlegen oder wieder einschalten
        let onCanvas = (canvas.gestureRecognizers ?? []).filter { $0 !== appHover && Self.watchesPencil($0) }
        let pencilKitViews = canvas.subviews.filter { $0 !== pagesView && $0 !== pointerOverlay && $0 !== askOverlay }
        for g in onCanvas + pencilKitViews.flatMap({ Self.pencilWatchers(in: $0) })
        where g.isEnabled && !pausedPencilKitHover.contains(where: { $0 === g }) {
            g.isEnabled = false
            pausedPencilKitHover.append(g)
        }
        guard !hoverPauseActive || pausedPencilKitHover.count != before else { return }
        hoverPauseActive = true
        let names = pausedPencilKitHover.map { g in
            "\(type(of: g))@\(g.view.map { String(describing: type(of: $0)) } ?? "-")"
        }
        let list = names.isEmpty ? "keine" : names.joined(separator: ", ")
        Log.ink.info("Radierer: PencilKit-Gesten pausiert: \(list, privacy: .public)")
    }

    /// PencilKits Schwebe-Gesten und sein Beobachter, der dem Schweben jede Pencil-Berührung meldet (er nimmt selbst
    /// nie eine an, Abschalten bricht also nichts ab)
    private static func watchesPencil(_ g: UIGestureRecognizer) -> Bool {
        g is UIHoverGestureRecognizer || NSStringFromClass(type(of: g)).contains("PencilObserver")
    }

    private static func pencilWatchers(in view: UIView) -> [UIGestureRecognizer] {
        let own = (view.gestureRecognizers ?? []).filter { watchesPencil($0) }
        return own + view.subviews.flatMap { pencilWatchers(in: $0) }
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
            linkPreviewTouch = false
            // Auf einem Link im PDF: erst abwarten, ob der Radierer still bleibt (dann Vorschau statt radieren)
            if !beginLinkHold(at: p, viewPoint: g.location(in: view)) { erase(at: p) }
        case .changed:
            eraseMoved(to: p, viewPoint: g.location(in: view))
        case .ended, .cancelled, .failed:
            // Vor der Vorschau abgehoben: wie ein Antippen radieren. Abgebrochen (zweiter Finger, anderes Werkzeug):
            // nichts
            if linkHold != nil { endLinkHold(erasingTo: g.state == .ended ? p : nil) }
            linkPreviewTouch = false
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
                // PencilKit lässt beim Entfernen manchmal einen feinen Rest des Strichs stehen: neu zeichnen, sobald
                // der Pencil nicht mehr schwebt (siehe redrawInkSoon). Brach der Wechsel zum Stift die Geste ab
                // (Pencil noch auf dem Glas), gleich
                if erasing || inkSettling || pencilNear { redrawInkSoon(waitForPencil: true) } else { redrawInkNow() }
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
            pencilHovering = true
            lockScrolling()
            if erasing && eraseStart == nil { moveCursor(to: g.location(in: view)) }
        default:
            if pencilHovering { lastHoverEnd = Date() }
            pencilHovering = false
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
        lastInkEnd = lastToolEnd
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
        reloadAskMarks()
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
        askOverlay.layout(scale: s)
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
        askOverlay.layout(scale: s)
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
        // Bloßes Öffnen (PencilKit meldet manchmal verspätet eine „Änderung“) soll nichts speichern und nichts als
        // bearbeitet markieren: Ohne Werkzeug seither vergleicht der Hintergrund mit dem letzten Stand. Eingefügte
        // fremde Striche stehen dagegen sicher noch nicht in der Datei, dann wird jedenfalls geschrieben.
        let base = dirty && !toolUsedSinceSave ? baseline : nil
        let force = remoteUnsaved
        dirty = false
        remoteUnsaved = false
        store.saveDrawing(current, toPage: toPage, for: doc.id, pageCount: pageCount, touch: touch,
                          unlessEqualTo: base, force: force)
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

    /// Aktueller Name (inzwischen vielleicht umbenannt, auch auf einem anderen Gerät)
    private var currentTitle: String { store.documents.first { $0.id == doc.id }?.title ?? doc.title }

    /// Name als Dateiname (Export, Briefkasten). Was Mac, Windows oder OneDrive in Dateinamen nicht nehmen, wird
    /// ersetzt oder fällt weg: „/“ trennt Ordner, „:“ (in der Uhrzeit neuer Notizbücher) zeigt der Mac als „/“,
    /// \ | * ? " < > lehnen Windows und OneDrive ab, ebenso Punkte und Leerzeichen am Ende; ein Punkt am Anfang
    /// versteckt die Datei. Sehr lange Namen werden gekürzt (Dateinamen haben höchstens 255 Bytes)
    static func fileName(_ title: String) -> String {
        var name = ""
        for ch in title {
            switch ch {
            case "/", "\\", "|": name.append("-")
            case ":": name.append(".")
            case "*", "?", "\"", "<", ">": continue
            default:
                // Steuerzeichen (Zeilenumbruch, Tabulator …) als Leerzeichen
                let control = ch.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
                name.append(control ? " " : ch)
            }
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        // Platz für Zusätze wie „ – Seiten 1-50.pdf“
        var short = ""
        for ch in name.trimmingCharacters(in: edges) {
            if short.utf8.count + String(ch).utf8.count > 200 { break }
            short.append(ch)
        }
        short = short.trimmingCharacters(in: edges)
        return short.isEmpty ? "Notizen" : short
    }

    /// Über dem zeigen, was gerade offen ist (etwa der Karte mit der Antwort am iPhone): Sonst zeigt UIKit nichts
    func presentOnTop(_ controller: UIViewController) {
        topPresenter.present(controller, animated: true)
    }

    /// Das Oberste, was gerade gezeigt wird (ohne das, was sich schon schließt), sonst die Leinwand
    private var topPresenter: UIViewController {
        var host: UIViewController = self
        while let next = host.presentedViewController, !next.isBeingDismissed { host = next }
        return host
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
        let title = Self.fileName(currentTitle)
        let pages = layout.frames.count
        // Großes PDF: Hinweis, bis es fertig ist (nur diesen räumt das Ende wieder weg, keinen fremden)
        let showsProgress: Bool
        if case .documentPDF = kind, pages > 10 { showsProgress = true } else { showsProgress = false }
        if showsProgress { onFlashTimed("PDF mit \(pages) Seiten wird erstellt …", 30) }
        // Hinweise auch, wenn diese Leinwand inzwischen zu ist (Tab gewechselt): Sie erscheinen dann im sichtbaren Tab
        let flash = onFlashTimed
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
                if showsProgress { flash("", 0) }
                guard let self else { return }
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = self.view
                sheet.popoverPresentationController?.sourceRect = sourceRect
                self.presentOnTop(sheet)
            } catch {
                flash("Export fehlgeschlagen: \(error.localizedDescription)", 3)
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
        let title = Self.fileName(currentTitle)
        let name = cut ? "\(title) – Seiten 1-\(count).pdf" : "\(title).pdf"
        let who = recipient == "claude" ? "Claude" : "ChatGPT"
        let export = exporter
        onFlashTimed("Wird gesendet …", 60)
        let sync = self.sync
        // Das Ergebnis auch melden, wenn diese Leinwand inzwischen zu ist (Tab gewechselt)
        let flash = onFlashTimed
        Task {
            do {
                let pdf = try await PageExport.run { () -> Data in
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try export.writePDF(pages: Array(0..<count), to: url, inkScale: 2)
                    return try Data(contentsOf: url)
                }
                try await sync.sendToOutbox(to: recipient, name: name, data: pdf, type: "application/pdf")
                flash(cut ? "Seiten 1–\(count) liegen bereit für \(who)" : "Ganzes Dokument liegt bereit für \(who)", 2.5)
            } catch {
                flash("Senden fehlgeschlagen: \(error.localizedDescription)", 3)
            }
        }
    }

    /// Legt die Seite als PDF und als Bild in den Ausgang des Briefkastens, wo Claude oder Codex sie abholen
    private func sendPage(_ i: Int, to recipient: String) {
        guard sync.isConfigured else {
            onFlashTimed("Erst den Server einrichten (Zahnrad in der Übersicht)", 2.5)
            return
        }
        let base = "\(Self.fileName(currentTitle)) – Seite \(i + 1)"
        let export = exporter
        onFlashTimed("Wird gesendet …", 30)
        let sync = self.sync
        // Das Ergebnis auch melden, wenn diese Leinwand inzwischen zu ist (Tab gewechselt)
        let flash = onFlashTimed
        Task {
            do {
                let (pdf, png) = try await PageExport.run { () -> (Data, Data) in
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: url) }
                    try export.writePDF(pages: [i], to: url, inkScale: 4)
                    return (try Data(contentsOf: url), export.pngData(page: i))
                }
                try await sync.sendToOutbox(to: recipient, name: base + ".pdf", data: pdf, type: "application/pdf")
                try await sync.sendToOutbox(to: recipient, name: base + ".png", data: png, type: "image/png")
                flash("Seite \(i + 1) liegt bereit für \(recipient == "claude" ? "Claude" : "ChatGPT")", 2.5)
            } catch {
                flash("Senden fehlgeschlagen: \(error.localizedDescription)", 3)
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
    /// Fragen an Claude auf gelöschten Seiten: unsichtbar, bis Rückgängig sie zurückbringt oder das Ende des
    /// Rückgängig sie löscht
    var hiddenAsks: [String] = []
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
            // Wie beim Ändern der Seiten: eben anderswo gestellte Fragen rücken mit
            self.sync.asks.refresh(self.doc.id)
            await self.fetchRemoteNow()
            await self.sync.asks.waitIdle(self.doc.id, upTo: 4)
            // Eine eingefügte Seite fiele mit allem darauf weg. Steht inzwischen etwas darauf (auch von anderen
            // Geräten oder Gästen), lieber nicht rückgängig machen
            let before = self.layout
            if self.pageDrawing().strokes.contains(where: { undo.inverse(before.page(at: $0.renderBounds.midY)) == nil }) {
                self.pageUndo = undo
                self.restructuring = false
                self.syncCycle()
                done("Auf der eingefügten Seite steht inzwischen etwas. Zum Entfernen die Seite löschen.")
                return
            }
            if let backup = undo.pdfBackup {
                let url = self.store.pdfURL(self.doc.id)
                do {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: backup)
                } catch {
                    // Nichts geändert: Rückgängig bleibt möglich (und räumt sonst beim Schließen der Übersicht auf)
                    self.pageUndo = undo
                    self.restructuring = false
                    self.syncCycle()
                    done("Rückgängig fehlgeschlagen: \(error.localizedDescription)")
                    return
                }
                guard let restored = CGPDFDocument(url as CFURL) else {
                    // Die Seiten bleiben gelöscht, die Fragen darauf mit
                    self.sync.asks.dropHidden(self.doc.id, undo.hiddenAsks)
                    self.restructuring = false
                    self.syncCycle()
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
            // Fragen an Claude rücken mit zurück; die auf den gelöschten Seiten kommen wieder
            let pv = self.currentPagesVersion
            let gone = self.sync.asks.remap(self.doc.id, pv: pv, mapping: undo.inverse)
            self.sync.asks.unhide(self.doc.id, undo.hiddenAsks, pv: pv)
            self.sync.asks.dropHidden(self.doc.id, gone)
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
        if let hidden = pageUndo?.hiddenAsks, !hidden.isEmpty { sync.asks.dropHidden(doc.id, hidden) }
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
            // Fragen an Claude, die andere Geräte eben gestellt haben, sollen auch mitrücken: zugleich mit den
            // Strichen holen, danach höchstens noch 4 Sekunden darauf warten
            self.sync.asks.refresh(self.doc.id)
            await self.fetchRemoteNow()
            await self.sync.asks.waitIdle(self.doc.id, upTo: 4)
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
                    self.syncCycle()
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
            // Fragen an Claude rücken mit ihrer Seite; die auf gelöschten Seiten bleiben bis zum Ende des Rückgängig
            self.pageUndo?.hiddenAsks = self.sync.asks.remap(self.doc.id, pv: self.currentPagesVersion, mapping: mapping)
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
        // Alle Striche darunter haben neue IDs: viel hochzuladen, was danach geschrieben wird, geht vor
        let bulk = sync.noteBulkChange(doc.id)
        if pdfChanged {
            // Die verschobenen Striche erst schicken, wenn das neue PDF am Server ist (höchstens 30 s warten)
            sync.notePDFUploadPending(doc.id)
            pdfHoldUntil = Date().addingTimeInterval(30)
            nextHoldRetry = Date().addingTimeInterval(6)
        }
        localChanged = true
        restructuring = false
        schedulePersist()
        let id = doc.id, engine = sync
        warmUpIDs { ids in engine.noteBulkContents(id, generation: bulk, ids: Set(ids)) }
        Task { [weak self] in
            await engine.syncLibrary()
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
        // Der neue Seitenstand gilt jetzt auch für die Markierungen. Kamen die Fragen schon vorher (mit dem neuen
        // Stand), blieben sie bis hier verborgen; ohne neu angelegte Seiten (gleiche Seitenzahl, etwa nach
        // Löschen und Rückgängig) zeigte sie sonst nichts mehr an
        reloadAskMarks()
        onPagesChanged?()
    }

    /// Ein anderes Gerät hat Seiten gelöscht und lädt die verschobenen Striche noch hoch (siehe
    /// `SyncEngine.pageTarget`): Seine Seitenzahl gilt, sobald die alten Fassungen weg sind
    private func adoptRemotePageTarget() {
        guard pdf == nil, remotePageTarget == nil, let target = sync.pageTarget(doc.id) else { return }
        remotePageTarget = target
        remoteTargetSince = Date()
        fitToRemotePageCount()
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
            if want == target { sync.notePageTargetReached(doc.id) }
        }
        guard want != pageCount else { return }
        pageCount = want
        rebuildPages()
    }
}

// MARK: Vorschau auf das Ziel eines Links: Radierer 1,5 s still auf einem Link, der an eine Stelle im PDF führt

extension CanvasController {
    /// Neues PDF (Seiten geändert, Rückgängig, anderes Gerät): Die gelesenen Links gehören zum alten
    private func linksChanged() {
        // Wartete der Radierer gerade auf einem Link: Der Rest dieser Berührung radiert nichts (der Pencil steht still,
        // und sein Link gehört zum alten PDF)
        if linkHold != nil { linkPreviewTouch = true }
        cancelLinkHold()
        cancelLinkPresentation()
        linkSpots = nil
        linkScan?.cancel()
        linkScan = nil
        linkGeneration += 1
        // Erst nach dem, was gerade läuft: Wer das PDF tauscht, rechnet gleich danach die IDs der Striche neu, und auf
        // die soll das Lesen warten
        guard erasing && !viewOnly else { return }
        DispatchQueue.main.async { [weak self] in self?.loadLinksIfNeeded() }
    }

    /// Liest die Links des PDFs einmal im Hintergrund. Abgleich und Schreiben gehen vor: Das Lesen wartet, bis die IDs
    /// der Striche vorberechnet sind (darauf wartet der erste Abgleich), und läuft mit niedriger Priorität
    private func loadLinksIfNeeded() {
        // Nicht nach dem Verlassen: SwiftUI aktualisiert die Leinwand beim Schließen vielleicht noch einmal
        guard !detached, doc.kind == .pdf, pdf != nil, k > 0, linkSpots == nil, linkScan == nil else { return }
        let generation = linkGeneration
        let url = store.pdfURL(doc.id)
        let warmup = idWarmup
        // Auch die äußere Aufgabe mit niedriger Priorität: Wer auf eine Aufgabe wartet, hebt sonst deren Priorität an
        linkScan = Task(priority: .utility) { [weak self] in
            if let warmup { await warmup.value }
            guard !Task.isCancelled else { return }
            #if DEBUG
            let start = CACurrentMediaTime()
            #endif
            let scan = Task.detached(priority: .utility) { LinkPreview.scan(url) }
            let spots = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled, let self, self.linkGeneration == generation else { return }
            self.linkSpots = spots
            self.linkScan = nil
            #if DEBUG
            let links = spots.reduce(0) { $0 + $1.count }, ms = Int((CACurrentMediaTime() - start) * 1000)
            NSLog("Link-Debug: %@", "\(links) Links auf \(spots.count) Seiten gelesen in \(ms) ms")
            #endif
        }
    }

    /// Setzt der Radierer auf einem Link auf, der an eine Stelle im Dokument führt, wartet er, ob er still bleibt: nach
    /// `ringDelay` erscheint der Kreis, nach `holdDuration` die Vorschau. Ist dort kein solcher Link: false, dann
    /// radiert er gleich wie immer. `p` in Scroll-Koordinaten der Leinwand, `viewPoint` in der Ansicht
    private func beginLinkHold(at p: CGPoint, viewPoint: CGPoint) -> Bool {
        cancelLinkHold()
        guard let target = linkTarget(at: p) else { return false }
        let ring = DispatchWorkItem { [weak self] in self?.linkHoldRing() }
        let done = DispatchWorkItem { [weak self] in self?.linkHoldElapsed() }
        let z = canvas.zoomScale
        linkHold = LinkHold(target: target, viewPoint: viewPoint, drawingPoint: CGPoint(x: p.x / z, y: p.y / z),
                            timers: [ring, done])
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkPreview.ringDelay, execute: ring)
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkPreview.holdDuration, execute: done)
        return true
    }

    /// Der Radierer bewegt sich (`p` in Scroll-Koordinaten der Leinwand, `v` in der Ansicht): radieren. Wartet er noch
    /// auf einem Link, erst wenn er den Spielraum verlässt, dann ab der Stelle, wo er aufsetzte. Nach der Vorschau
    /// radiert diese Berührung nichts mehr
    private func eraseMoved(to p: CGPoint, viewPoint v: CGPoint) {
        guard !linkPreviewTouch else { return }
        if let hold = linkHold {
            guard hypot(v.x - hold.viewPoint.x, v.y - hold.viewPoint.y) > LinkPreview.holdSlop else { return }
            endLinkHold(erasingTo: p)
        } else {
            erase(at: p)
        }
    }

    /// Ziel des Links unter dem Radierer (`p` in Scroll-Koordinaten der Leinwand). Er zählt, sobald der Kreis des
    /// Radierers ihn berührt
    private func linkTarget(at p: CGPoint) -> LinkTarget? {
        guard doc.kind == .pdf, k > 0, linkPreview == nil else { return nil }
        guard let spots = linkSpots else {
            loadLinksIfNeeded()
            return nil
        }
        let s = k * canvas.zoomScale
        let point = CGPoint(x: p.x / s, y: p.y / s)
        let i = layout.page(at: point.y)
        guard spots.indices.contains(i), !spots[i].isEmpty, layout.frames.indices.contains(i) else { return nil }
        let frame = layout.frames[i]
        return LinkPreview.target(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), in: spots[i],
                                  tolerance: Self.eraserRadius / s)
    }

    /// Der Kreis erscheint; zugleich werden die Bilder der Vorschau im Hintergrund gezeichnet
    private func linkHoldRing() {
        guard var hold = linkHold else { return }
        showHoldRing(duration: LinkPreview.holdDuration - LinkPreview.ringDelay)
        hold.images = renderLinkPreview(hold.target)
        linkHold = hold
    }

    /// Lange genug still: kurz tippen und die Vorschau zeigen, sobald ihre Bilder fertig sind. Bis zum Abheben radiert
    /// der Radierer dann nichts mehr
    private func linkHoldElapsed() {
        guard let hold = linkHold else { return }
        linkHold = nil
        linkPreviewTouch = true
        hideHoldRing()
        if #available(iOS 17.5, *), let feedback = holdFeedback as? UICanvasFeedbackGenerator {
            feedback.pathCompleted(at: hold.viewPoint)
        }
        let images = hold.images ?? renderLinkPreview(hold.target)
        let anchor = eraserCursor.isHidden ? hold.viewPoint : eraserCursor.center
        // Öffnet sich inzwischen etwas anderes (eine Antwort, Teilen …) oder schließt sich, was offen war: keine Vorschau
        let host = topPresenter
        linkPresentation?.cancel()
        linkPresentation = Task { [weak self, weak host] in
            let content = await withTaskCancellationHandler { await images.value } onCancel: { images.cancel() }
            guard let content, !Task.isCancelled, let self, !self.detached, let host, self.topPresenter === host
            else { return }
            self.linkPresentation = nil
            self.presentLinkPreview(content, target: hold.target, at: anchor)
        }
    }

    /// Eine Vorschau, deren Bilder noch nicht fertig sind, erscheint nicht mehr
    private func cancelLinkPresentation() {
        linkPresentation?.cancel()
        linkPresentation = nil
    }

    /// Der Radierer wartet nicht mehr: Kreis weg, Bilder der Vorschau verwerfen
    private func cancelLinkHold() {
        guard let hold = linkHold else { return }
        linkHold = nil
        for timer in hold.timers { timer.cancel() }
        hold.images?.cancel()
        hideHoldRing()
    }

    /// Die Berührung radiert doch (bewegt, oder vor der Vorschau abgehoben): von der Stelle, wo der Radierer aufsetzte,
    /// bis `end` (Scroll-Koordinaten). Ohne `end` (abgebrochen) radiert sie nichts
    private func endLinkHold(erasingTo end: CGPoint?) {
        guard let hold = linkHold else { return }
        cancelLinkHold()
        guard let end else { return }
        let z = canvas.zoomScale
        erase(at: CGPoint(x: hold.drawingPoint.x * z, y: hold.drawingPoint.y * z))
        erase(at: end)
    }

    /// Bilder der Zielseite und der nächsten samt Tinte (siehe LinkPreview.slices), im Hintergrund gezeichnet.
    /// Umgerechnet werden nur die Striche darauf; Abbrechen der Aufgabe lässt die restlichen Bilder weg
    private func renderLinkPreview(_ target: LinkTarget) -> Task<LinkPreviewImages?, Never> {
        let frames = layout.frames
        let slices = LinkPreview.slices(for: target, frames: frames)
        let area = slices.reduce(CGRect.null) { area, slice in
            let f = frames[slice.page]
            return area.union(CGRect(x: f.minX, y: f.minY + slice.top, width: f.width, height: slice.bottom - slice.top))
        }.applying(CGAffineTransform(scaleX: k, y: k))
        let ink = canvas.drawing.strokes.filter { $0.renderBounds.intersects(area) }
        let job = LinkPreviewJob(slices: slices, frames: frames, pdf: pdf,
                                 ink: PKDrawing(strokes: ink).transformed(using: toPage).strokes,
                                 pixelWidth: (LinkPreviewController.width(in: self) * traitCollection.displayScale).rounded())
        return Task.detached(priority: .userInitiated) { job.render() }
    }

    /// Zeigt die Vorschau: am iPad als Popover am Radierer (darüber oder darunter), am iPhone als halbhohes Blatt.
    /// Antippen daneben schließt sie
    private func presentLinkPreview(_ content: LinkPreviewImages, target: LinkTarget, at point: CGPoint) {
        guard !content.images.isEmpty, linkPreview == nil, view.window != nil else { return }
        let preview = LinkPreviewController(content: content, targetY: (target.y ?? 0) - (content.slices.first?.top ?? 0))
        preview.modalPresentationStyle = .popover
        preview.preferredContentSize = LinkPreviewController.preferredSize(for: content, in: self)
        if let pop = preview.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28)
            pop.permittedArrowDirections = [.up, .down]
            pop.backgroundColor = LinkPreviewController.background
            let sheet = pop.adaptiveSheetPresentationController
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        linkPreview = preview
        presentOnTop(preview)
    }

    /// Schließt `base` samt allem, was darüber gezeigt wird (`base.dismiss` schlösse nur das Oberste darüber). Ist
    /// `base` nicht mehr gezeigt, passiert nichts
    static func dismissStack(from base: UIViewController, animated: Bool) {
        guard let host = base.presentingViewController, host.presentedViewController === base else { return }
        host.dismiss(animated: animated)
    }

    private func setUpHoldRing() {
        let r = Self.eraserRadius
        holdRing.path = UIBezierPath(arcCenter: CGPoint(x: r, y: r), radius: r + 5, startAngle: -.pi / 2,
                                     endAngle: 1.5 * .pi, clockwise: true).cgPath
        holdRing.fillColor = nil
        holdRing.strokeColor = UIColor.systemBlue.cgColor
        holdRing.lineWidth = 2.5
        holdRing.lineCap = .round
        holdRing.strokeEnd = 0
        holdRing.isHidden = true
        eraserCursor.layer.addSublayer(holdRing)
    }

    private func showHoldRing(duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdRing.isHidden = false
        holdRing.strokeEnd = 1
        CATransaction.commit()
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = duration
        holdRing.add(fill, forKey: "fill")
    }

    private func hideHoldRing() {
        holdRing.removeAnimation(forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdRing.isHidden = true
        holdRing.strokeEnd = 0
        CATransaction.commit()
    }
}

// MARK: Claude fragen: Frage mit dem Lasso markieren, Antwort an ihrer Markierung lesen

extension CanvasController: UIGestureRecognizerDelegate {
    /// Seitenstand dieses Dokuments jetzt (ms; 0 = nie Seiten geändert)
    private var currentPagesVersion: Int { store.documents.first { $0.id == doc.id }?.pagesVersion ?? 0 }

    /// „Claude fragen“ und „Claude gründlich fragen“ vorn im Menü einer Lasso-Auswahl
    private func askMenuItems(_ context: SelectionMenuContext) -> [UIMenuElement] {
        [("quick", "Claude fragen", "questionmark.bubble"),
         ("thorough", "Claude gründlich fragen", "text.bubble")].map { effort, title, symbol in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.askClaude(effort: effort, from: context)
            }
        }
    }

    /// Weg des Lassos, sobald er fertig ist. Antippen (Menü öffnen, Auswahl aufheben) zählt nicht, dann bleibt der
    /// vorige Weg. Verschieben der Auswahl (eine Linie ohne Fläche) und Winziges löschen ihn: Er passte nicht mehr.
    /// Gemessen auf dem Bildschirm, also gleich in jeder Zoomstufe
    private func lassoEnded(_ raw: [CGPoint]) {
        guard k > 0 else { return }
        let s = k * canvas.zoomScale
        let points = LassoGeometry.simplified(raw, minStep: 2 / s)
        guard points.count >= 8 else { return }
        guard LassoGeometry.area(points) * s * s >= 400 else {
            lassoPath = nil
            return
        }
        let box = LassoGeometry.bounds(points)
        lassoPath = LassoPath(points: points, bounds: box, inkPrint: inkPrint(near: box))
    }

    /// Kennzahl der Tinte, die `box` (Seitenpunkte) berührt, in Seitenpunkten gerechnet (übersteht Drehen)
    private func inkPrint(near box: CGRect) -> Int {
        guard k > 0 else { return 0 }
        let area = box.applying(CGAffineTransform(scaleX: k, y: k))
        var h = Hasher()
        for stroke in canvas.drawing.strokes where stroke.renderBounds.intersects(area) {
            let b = stroke.renderBounds
            for v in [b.minX, b.minY, b.maxX, b.maxY] { h.combine(Int((v / k * 4).rounded())) }
            h.combine(stroke.path.count)
        }
        return h.finalize()
    }

    /// Die markierte Frage an Claude: Striche im Lasso, ihre Stelle, zwei Bilder (nur die Frage; die ganze Seite mit
    /// der Frage hervorgehoben). Die Markierung erscheint, sobald die Bilder fertig sind; hochgeladen wird gleich
    /// danach (ohne Netz später)
    private func askClaude(effort: String, from menu: SelectionMenuContext) {
        guard k > 0, !viewOnly else { return }
        guard sync.isConfigured else {
            onFlashTimed("Erst den Server einrichten (Zahnrad in der Übersicht)", 2.5)
            return
        }
        // Der zuletzt gezogene Weg gehört zu dieser Auswahl: Die Tinte darunter ist unverändert (nichts verschoben,
        // dupliziert oder eingefügt), und PencilKit zeigt sein Menü in seiner Nähe
        let source = menu.space.map { pagesView.convert(menu.sourcePoint, from: $0) }
        #if DEBUG
        NSLog("Claude fragen: Menü bei %@, Lasso %@", source.map { "\($0)" } ?? "nil",
              lassoPath.map { "\($0.bounds)" } ?? "nil")
        #endif
        guard let lasso = lassoPath, inkPrint(near: lasso.bounds) == lasso.inkPrint,
              source.map({ lasso.bounds.insetBy(dx: -120, dy: -120).contains($0) }) ?? true
        else {
            onFlashTimed("Bitte die Frage noch einmal mit dem Lasso umkreisen", 2.5)
            return
        }
        // Striche, die mindestens zur Hälfte im Lasso liegen (sonst die, deren Mitte darin liegt)
        let toCanvas = CGAffineTransform(scaleX: k, y: k)
        let polygon = lasso.points.map { $0.applying(toCanvas) }
        let area = lasso.bounds.applying(toCanvas)
        let strokes = canvas.drawing.strokes
        let near = strokes.filter { $0.renderBounds.intersects(area) }
        var picked = near.filter { LassoGeometry.mostlyInside($0, polygon) }
        if picked.isEmpty {
            picked = near.filter { LassoGeometry.contains(polygon, CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) }
        }
        guard !picked.isEmpty else {
            onFlashTimed("Im Lasso ist keine Schrift", 2)
            return
        }
        let ink = PKDrawing(strokes: picked).transformed(using: toPage)
        let rect = ink.bounds
        guard !layout.frames.isEmpty, !rect.isNull, !rect.isEmpty else { return }
        // Seite der Frage, Stelle relativ zu ihr
        let page = layout.page(at: rect.midY)
        let frame = layout.frames[page]
        let pageRect = CGRect(origin: .zero, size: frame.size)
        var local = rect.offsetBy(dx: -frame.minX, dy: -frame.minY).intersection(pageRect)
        if local.isNull || local.isEmpty {
            let x = min(max(rect.minX - frame.minX, 0), frame.width), y = min(max(rect.minY - frame.minY, 0), frame.height)
            local = CGRect(x: x, y: y, width: 1, height: 1)
        }
        let lassoOnPage = lasso.points.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
        // Für das Bild der Seite nur ihre Striche (nicht die ganze Zeichnung umrechnen)
        let pageArea = frame.applying(toCanvas)
        let export = PageExport(frames: layout.frames, pdf: pdf,
                                ink: PKDrawing(strokes: strokes.filter { $0.renderBounds.intersects(pageArea) })
                                    .transformed(using: toPage))
        let ask = Ask(id: UUID().uuidString, status: "local",
                      anchor: AskAnchor(page: page, x: Double(local.minX), y: Double(local.minY),
                                        w: Double(local.width), h: Double(local.height)),
                      pv: currentPagesVersion, effort: effort, created: Date().timeIntervalSince1970,
                      from: isPad ? "iPad" : "iPhone")
        lassoPath = nil
        // Auswahl aufheben, sobald das Menü weg ist
        DispatchQueue.main.async { [weak self] in self?.endLassoSelection() }

        let folder = sync.asks.imageFolder(doc.id, ask.id)
        let box = UncheckedBox(ink)
        let asks = sync.asks, id = doc.id
        // Hinweise auch, wenn diese Leinwand inzwischen zu ist (Tab gewechselt)
        let flash = onFlashTimed
        Task {
            do {
                try await PageExport.run {
                    let question = PageExport.questionPNG(box.value, region: rect)
                    let pageImage = export.askPageJPEG(page: page, lasso: lassoOnPage)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try question.write(to: folder.appendingPathComponent("question.png"), options: .atomic)
                    try pageImage.write(to: folder.appendingPathComponent("page.jpg"), options: .atomic)
                }
                asks.add(id, ask)
                flash(effort == "thorough" ? "Frage an Claude geschickt (gründlich)" : "Frage an Claude geschickt", 2)
            } catch {
                flash("Frage konnte nicht vorbereitet werden: \(error.localizedDescription)", 3)
            }
        }
    }

    /// Hebt PencilKits Auswahl auf wie ein Werkzeugwechsel (das Lasso bleibt das Werkzeug) und nimmt ihr den Fokus.
    /// Ersetzt die Zeichnung nicht: Kein Rückgängig geht verloren, kein Strich unterwegs
    private func endLassoSelection() {
        guard canvas.tool is PKLassoTool else { return }
        canvas.tool = PKInkingTool(.pen, color: inkColor, width: inkWidth * max(k, 0.5))
        applyTool()
        canvas.endEditing(true)
    }

    /// Die Seite für Antworten wird einmal je App-Start vorgeladen
    private static var answerPageWarm = false

    /// Markierungen neu: nach Änderungen der Fragen, neuen Seiten, Drehen
    private func reloadAskMarks() {
        guard k > 0 else { return }
        let list = sync.asks.asks(doc.id)
        askOverlay.set(list, frames: layout.frames, pagesVersion: currentPagesVersion)
        askOverlay.layout(scale: k * canvas.zoomScale)
        if canvas.subviews.last !== askOverlay { canvas.bringSubviewToFront(askOverlay) }
        // Neue Antwort, während das Dokument offen ist. Gesammelt, nicht ersetzt: Eine Markierung, die mit ihrer Seite
        // kurz verschwand (Seite gelöscht, dann Rückgängig), meldet sich danach nicht als neue Antwort
        let answered = Set(list.filter { $0.isAnswered && $0.isVisible }.map(\.id))
        if let known = knownAnswered, !answered.subtracting(known).isEmpty { onFlash("Claude hat geantwortet") }
        knownAnswered = (knownAnswered ?? []).union(answered)
        // Die Seite für die Antworten schon laden, damit die erste Karte gleich etwas zeigt
        if !list.isEmpty, !Self.answerPageWarm {
            Self.answerPageWarm = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AnswerPage.prewarm() }
        }
        // Die Frage der offenen Karte ist weg (gelöscht, auch auf einem anderen Gerät)
        if let card = answerCard, sync.asks.ask(doc.id, card.model.askID)?.isVisible != true {
            // Samt einer Vorschau eines Links, die am iPhone darüber liegen kann
            Self.dismissStack(from: card, animated: true)
        }
    }

    // MARK: Markierung antippen

    /// Nur Berührungen, die auf einer Markierung beginnen. Radierer und Zeigestift behalten ihre (Pencil am iPad,
    /// Finger am iPhone)
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === askTap else { return true }
        let toolOwns = (erasing || pointing) && !viewOnly && (!isPad || touch.type == .pencil)
        guard !toolOwns else { return false }
        // Kann diese Berührung zeichnen, wartet PencilKit kurz, ob es ein Antippen wird; der Rand um die Markierung
        // bleibt dann schmal, damit ein Punkt gleich daneben Tinte wird. Sonst (Finger am iPad, nur Lesen) ist er
        // breiter, zum leichteren Treffen
        let canDraw = !viewOnly && (touch.type == .pencil || !isPad)
        guard askOverlay.mark(at: touch.location(in: canvas), padding: canDraw ? 2 : 10) != nil else { return false }
        if askTap.state == .possible { askTap.touchCanDraw = canDraw }
        return true
    }

    @objc private func handleAskTap(_ g: MarkTapGesture) {
        guard g.state == .ended, let id = askOverlay.mark(at: g.location(in: canvas), padding: 10) else { return }
        showAnswer(id)
    }

    /// Karte mit der Antwort: am iPad neben der Markierung, am iPhone von unten (halb hoch, die Seite bleibt
    /// bedienbar; eine andere Markierung tauscht nur den Inhalt)
    private func showAnswer(_ id: String) {
        guard let mark = askOverlay.view(for: id) else { return }
        if let card = answerCard {
            card.model.askID = id
            askOverlay.highlight(id)
            // Am iPad wandert die Karte zur neuen Markierung
            if let pop = card.popoverPresentationController {
                pop.sourceView = mark
                pop.sourceRect = mark.bounds
                pop.containerView?.setNeedsLayout()
            }
            return
        }
        guard presentedViewController == nil else { return }
        let model = AnswerCardModel(doc: doc.id, askID: id, asks: sync.asks)
        let card = AnswerCardController(model: model)
        model.onDelete = { [weak self, weak card] askID in
            guard let self else { return }
            self.sync.asks.delete(self.doc.id, askID)
            card?.dismiss(animated: true)
        }
        card.onClose = { [weak self] in self?.askOverlay.highlight(nil) }
        card.modalPresentationStyle = .popover
        card.preferredContentSize = CGSize(width: min(480, view.bounds.width - 40),
                                           height: min(520, view.bounds.height * 0.7))
        if let pop = card.popoverPresentationController {
            pop.sourceView = mark
            pop.sourceRect = mark.bounds
            pop.permittedArrowDirections = .any
            let sheet = pop.adaptiveSheetPresentationController
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.largestUndimmedDetentIdentifier = .medium
        }
        answerCard = card
        askOverlay.highlight(id)
        present(card, animated: true)
    }
}

#if DEBUG
// MARK: Nur für Tests im Simulator (Debug-Build)

extension CanvasController {
    /// Befehle über Links, etwa `xcrun simctl openurl booted "notizbuch://debug/ask?page=1"`:
    /// - `debug/ask?page=N&effort=quick|thorough`: Frage zu Seite N wie mit dem Lasso (steht dort nichts, erst Probeschrift)
    /// - `debug/card?ask=<id>|first|last`: Karte der Frage zeigen
    /// - `debug/delete?ask=<id>|first|last`: Markierung löschen
    /// - `debug/pages?delete=N`, `?insert=N`, `?undo`, `?done`: Seiten ändern, Rückgängig, Rückgängig verwerfen
    /// - `debug/state`: nur den Stand
    /// Danach steht der Stand der Fragen im Protokoll („Asks-Debug: …“)
    /// - `debug/link…`: Vorschau auf das Ziel eines Links (siehe `debugLink`, Protokoll „Link-Debug: …“)
    func debugCommand(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func has(_ name: String) -> Bool { items.contains { $0.name == name } }
        let log: (String) -> Void = { NSLog("Asks-Debug: %@", $0) }
        let list = sync.asks.asks(doc.id)
        func pick() -> String? {
            switch value("ask") {
            case nil, "first"?: return list.first?.id
            case "last"?: return list.last?.id
            case let id?: return id
            }
        }
        switch url.path {
        case "/link":
            return debugLink(items)
        case "/ask":
            guard k > 0, let n = value("page").flatMap({ Int($0) }), layout.frames.indices.contains(n) else {
                return log("ask: keine solche Seite")
            }
            let frame = layout.frames[n]
            let toCanvas = CGAffineTransform(scaleX: k, y: k)
            let pageArea = frame.applying(toCanvas)
            var onPage = canvas.drawing.strokes.filter {
                pageArea.contains(CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY))
            }
            if onPage.isEmpty {
                // Probeschrift: drei Wellenlinien oben links auf der Seite
                let strokes = (0..<3).map { line -> PKStroke in
                    let y0 = frame.minY + 120 + CGFloat(line) * 40
                    let points = (0...65).map { i -> PKStrokePoint in
                        let x = CGFloat(i) * 4
                        let p = CGPoint(x: frame.minX + 80 + x, y: y0 + 10 * sin(x / 12)).applying(toCanvas)
                        return PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 3 * k, height: 3 * k),
                                             opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    }
                    return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                }
                canvas.drawing.strokes.append(contentsOf: strokes)
                onPage = strokes
            }
            // Ein Lasso als Rechteck um die Schrift der Seite, in Seitenpunkten
            let box = onPage.reduce(CGRect.null) { $0.union($1.renderBounds) }.applying(toPage).insetBy(dx: -16, dy: -16)
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            lassoPath = LassoPath(points: corners, bounds: box, inkPrint: inkPrint(near: box))
            askClaude(effort: value("effort") ?? "quick", from: SelectionMenuContext(space: nil, sourcePoint: .zero))
            log("ask: Seite \(n), \(onPage.count) Striche")
        case "/card":
            guard let id = pick() else { return log("card: keine Frage") }
            showAnswer(id)
            log("card: \(id)")
        case "/delete":
            guard let id = pick() else { return log("delete: keine Frage") }
            sync.asks.delete(doc.id, id)
            log("delete: \(id)")
        case "/pages":
            let done: (String?) -> Void = { log("pages: \($0 ?? "ok")") }
            if let n = value("delete").flatMap({ Int($0) }) {
                deletePages([n], done: done)
            } else if let n = value("insert").flatMap({ Int($0) }) {
                insertBlankPage(at: n, done: done)
            } else if has("undo") {
                undoPageChange(done: done)
            } else if has("done") {
                discardPageUndo()
                log("pages: Rückgängig verworfen")
            }
        case "/state":
            break
        default:
            log("unbekannter Befehl \(url.path)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let state = self.sync.asks.asks(self.doc.id).map { a in
                "\(a.id.prefix(8)) \(a.status) Seite \(a.anchor.page) pv \(a.pv)"
                    + (a.hidden == true ? " versteckt" : "") + (a.deleting == true ? " löscht" : "")
                    + (a.moved == true ? " verschoben" : "") + (a.localNote.map { " (\($0))" } ?? "")
            }
            log("Stand: pv \(self.currentPagesVersion), \(self.layout.frames.count) Seiten, "
                + "\(self.askOverlay.subviews.count) Markierungen: " + state.joined(separator: "; "))
        }
    }

    /// - `debug/link`: alle Links des PDFs ins Protokoll; `&show` zeichnet sie rot auf die Seiten und ihre Ziele grün
    ///   (noch einmal `&show` nimmt das weg); `&scroll=N` springt vorher zu Seite N (ab 0)
    /// - `debug/link?page=N&index=K`: Vorschau des K-ten Links auf Seite N (beide ab 0), wie nach dem Halten
    /// - `…&hold=S`: wie der Radierer: aufsetzen, S Sekunden still halten, abheben; `&ink` legt vorher einen Probestrich
    ///   über den Link (wird er radiert oder nicht?); `&move=D` bewegt ihn nach 0,3 s um D Bildschirmpunkte nach rechts
    /// - `debug/link?close`: Vorschau schließen (wie Antippen daneben)
    private func debugLink(_ items: [URLQueryItem]) {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func has(_ name: String) -> Bool { items.contains { $0.name == name } }
        let log: (String) -> Void = { NSLog("Link-Debug: %@", $0) }
        if has("close") {
            if let preview = linkPreview { Self.dismissStack(from: preview, animated: false) }
            return log("geschlossen")
        }
        if let n = value("scroll").flatMap({ Int($0) }) { scrollToPage(n) }
        guard let spots = linkSpots else {
            loadLinksIfNeeded()
            guard linkScan != nil else { return log("kein PDF") }
            // Sobald die Links gelesen sind, noch einmal (ohne noch einmal zu springen)
            let rest = items.filter { $0.name != "scroll" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.debugLink(rest) }
            return log("Links werden gelesen …")
        }
        let summary = spots.enumerated().filter { !$0.element.isEmpty }.prefix(12).map { i, links -> String in
            let list = links.map { l -> String in
                let y = l.target.y.map { "@\(Int($0))" } ?? "@oben"
                return "(\(Int(l.rect.minX)),\(Int(l.rect.minY)) \(Int(l.rect.width))x\(Int(l.rect.height)))→S\(l.target.page)\(y)"
            }
            return "S\(i): " + list.joined(separator: " ")
        }
        log("\(spots.reduce(0) { $0 + $1.count }) Links auf \(spots.count) Seiten: " + summary.joined(separator: "; "))
        if has("show") { toggleLinkOverlay(spots) }
        guard let page = value("page").flatMap({ Int($0) }) else { return }
        let index = value("index").flatMap { Int($0) } ?? 0
        guard k > 0, spots.indices.contains(page), spots[page].indices.contains(index),
              layout.frames.indices.contains(page) else { return log("kein solcher Link") }
        let spot = spots[page][index]
        let frame = layout.frames[page]
        let s = k * canvas.zoomScale
        // Mitte des Links: in der Leinwand (Scroll-Koordinaten) und in der Ansicht
        let p = CGPoint(x: (frame.minX + spot.rect.midX) * s, y: (frame.minY + spot.rect.midY) * s)
        let v = canvas.convert(p, to: view)
        guard let hold = value("hold").flatMap({ Double($0) }) else {
            let images = renderLinkPreview(spot.target)
            Task { [weak self] in
                guard let content = await images.value, let self else { return }
                self.presentLinkPreview(content, target: spot.target, at: v)
                let y = spot.target.y.map { "\(Int($0))" } ?? "oben"
                let parts = content.slices.map { "S\($0.page) \(Int($0.top))–\(Int($0.bottom))" }.joined(separator: ", ")
                let sizes = content.images.map { "\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: ", ")
                log("Vorschau: Seite \(spot.target.page), y \(y), Stücke \(parts), Bilder \(sizes), "
                    + "Fenster \(self.linkPreview != nil)")
            }
            return
        }
        if has("ink") {
            // Probestrich quer über den Link
            let toCanvas = CGAffineTransform(scaleX: k, y: k)
            let y = frame.minY + spot.rect.midY
            let points = (0...20).map { i -> PKStrokePoint in
                let x = frame.minX + spot.rect.minX - 6 + (spot.rect.width + 12) * CGFloat(i) / 20
                return PKStrokePoint(location: CGPoint(x: x, y: y).applying(toCanvas), timeOffset: Double(i) * 0.01,
                                     size: CGSize(width: 3 * k, height: 3 * k), opacity: 1, force: 1, azimuth: 0,
                                     altitude: .pi / 2)
            }
            canvas.drawing.strokes.append(PKStroke(ink: PKInk(.pen, color: .red),
                                                   path: PKStrokePath(controlPoints: points, creationDate: Date())))
        }
        // Wie der Radierer in handleErase: aufsetzen …
        let before = canvas.drawing.strokes.count
        usingTool = true
        eraseStart = canvas.drawing
        lastErasePoint = nil
        linkPreviewTouch = false
        cancelLinkPresentation()
        moveCursor(to: v)
        let waits = beginLinkHold(at: p, viewPoint: v)
        if !waits { erase(at: p) }
        log("aufgesetzt auf Seite \(page) Link \(index), wartet: \(waits)")
        // … vielleicht bewegen …
        let move = value("move").flatMap { Double($0) }.map { CGFloat($0) }
        let v2 = CGPoint(x: v.x + (move ?? 0), y: v.y)
        let end = move == nil ? p : canvas.convert(v2, from: view)
        if let move {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.moveCursor(to: v2)
                self.eraseMoved(to: end, viewPoint: v2)
                log("bewegt um \(move) Punkte, wartet noch: \(self.linkHold != nil)")
            }
        }
        // … abheben
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self else { return }
            if self.linkHold != nil { self.endLinkHold(erasingTo: end) }
            let previewed = self.linkPreviewTouch
            self.linkPreviewTouch = false
            self.usingTool = false
            self.lastToolEnd = Date()
            self.eraseStart = nil
            self.lastErasePoint = nil
            self.eraserCursor.isHidden = true
            self.applyPendingWhenIdle()
            log("abgehoben nach \(hold) s: Vorschau \(previewed), Striche \(before) → \(self.canvas.drawing.strokes.count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                log("Fenster offen: \(self?.linkPreview != nil)")
            }
        }
    }

    /// Rote Rahmen um die Links, grüne Striche an ihren Zielen (in den Seiten, unter der Tinte)
    private func toggleLinkOverlay(_ spots: [[LinkSpot]]) {
        if let old = pagesView.layer.sublayers?.first(where: { $0.name == "link-debug" }) {
            old.removeFromSuperlayer()
            return
        }
        let links = UIBezierPath(), targets = UIBezierPath()
        for (i, list) in spots.enumerated() where layout.frames.indices.contains(i) {
            let frame = layout.frames[i]
            for spot in list {
                links.append(UIBezierPath(rect: spot.rect.offsetBy(dx: frame.minX, dy: frame.minY)))
                guard layout.frames.indices.contains(spot.target.page) else { continue }
                let f = layout.frames[spot.target.page]
                let y = f.minY + (spot.target.y ?? 0)
                targets.move(to: CGPoint(x: f.minX, y: y))
                targets.addLine(to: CGPoint(x: f.minX + 80, y: y))
            }
        }
        let overlay = CALayer()
        overlay.name = "link-debug"
        overlay.frame = pagesView.bounds
        let red = CAShapeLayer()
        red.path = links.cgPath
        red.fillColor = nil
        red.strokeColor = UIColor.red.cgColor
        red.lineWidth = 1
        let green = CAShapeLayer()
        green.path = targets.cgPath
        green.fillColor = nil
        green.strokeColor = UIColor.systemGreen.cgColor
        green.lineWidth = 3
        overlay.addSublayer(red)
        overlay.addSublayer(green)
        pagesView.layer.addSublayer(overlay)
    }
}
#endif
