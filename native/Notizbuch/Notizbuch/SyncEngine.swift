import Foundation
import PencilKit
import os

/// Protokoll für die Zeitmessung (am Mac in der Konsole zu sehen: Subsystem de.beiglboeck.notizbuch, Kategorie sync)
enum Log {
    static let sync = Logger(subsystem: "de.beiglboeck.notizbuch", category: "sync")
}

/// Metadaten, wie der Server sie liefert (Datum in Sekunden seit 1970)
struct RemoteMeta: Codable {
    var id: UUID
    var title: String
    var kind: DocKind
    var created: Date
    var modified: Date
    var pageCount: Int
    var deleted: Bool?
    var strokeSeq: Int?
    var hasPDF: Bool?
    var folder: String?
    var pdfVersion: Int?
    var pagesVersion: Int?
}

/// Was dieses Gerät über den Sync-Stand eines Dokuments weiß (liegt als sync.json im Dokumentordner)
struct DocSyncState: Codable {
    /// Höchste Änderungsnummer des Servers, die dieses Gerät kennt
    var seq = 0
    /// IDs der Striche, die beim letzten Abgleich auf beiden Seiten vorhanden waren
    var ids: [String] = []
    /// meta.modified (Sekunden seit 1970) beim letzten Abgleich
    var syncedModified: Double = 0
}

/// Stand einer Zeichnung für den Abgleich
struct StrokeSnapshot {
    /// Striche mit ihrer ID, in Zeichnungsreihenfolge
    var strokes: [(id: String, stroke: PKStroke)]
    /// Rechnet die Striche in Seitenpunkte um
    var toPage: CGAffineTransform
    /// Gelten als vorhanden, obwohl sie (noch) nicht in `strokes` sind: fremde Striche, die auf die Leinwand warten
    var alsoPresent: Set<String> = []
    /// Gelten als entfernt, obwohl sie noch in `strokes` sind: fremde Löschungen, die noch warten
    var alsoGone: Set<String> = []

    /// IDs über den Zwischenspeicher: Nur neue Striche werden gehasht
    /// - Parameter prune: nur für die offene Leinwand (siehe `StrokeIDCache.ids`)
    init(_ strokes: [PKStroke], toPage: CGAffineTransform, prune: Bool = false) {
        let ids = StrokeIDCache.shared.ids(for: strokes, toPage: toPage, prune: prune)
        self.strokes = zip(ids, strokes).map { (id: $0.0, stroke: $0.1) }
        self.toPage = toPage
    }
}

enum SyncError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Kein Server eingerichtet"
        case .http(let code, let message): return "Server antwortet \(code): \(message)"
        }
    }
}

/// Gleicht Dokumente und Striche mit dem Notizbuch-Server ab und bedient den Ausgang des Briefkastens.
@MainActor
final class SyncEngine: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var lastSync: Date?
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "syncURL") }
    }
    @Published var key: String {
        didSet { UserDefaults.standard.set(key, forKey: "syncKey") }
    }

    let store: DocumentStore
    /// Das gerade geöffnete Dokument bekommt entfernte Änderungen direkt auf die Leinwand
    weak var openController: CanvasController?

    private var busy = Set<UUID>()
    /// Sync-Stand je Dokument im Speicher (die Platte liest und schreibt nur selten)
    private var states: [UUID: DocState] = [:]

    private final class DocState {
        var seq: Int
        /// IDs der Striche, die beim letzten Abgleich auf beiden Seiten vorhanden waren
        var confirmed: Set<String>
        var syncedModified: Double

        init(_ s: DocSyncState) {
            seq = s.seq
            confirmed = Set(s.ids)
            syncedModified = s.syncedModified
        }

        var stored: DocSyncState { DocSyncState(seq: seq, ids: Array(confirmed), syncedModified: syncedModified) }
    }
    /// Der laufende Abgleich der Bibliothek (nil = keiner)
    private var libraryTask: Task<Void, Never>?
    /// Während eines Abgleichs angefragt: danach gleich noch einmal
    private var libraryAgain = false
    /// PDFs, deren neue Fassung (nach Löschen oder Einfügen von Seiten) noch nicht am Server ist
    private(set) var pdfUploadPending = Set<UUID>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var pendingDeletes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "syncPendingDeletes") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "syncPendingDeletes") }
    }

    init(store: DocumentStore) {
        self.store = store
        serverURL = UserDefaults.standard.string(forKey: "syncURL") ?? ""
        key = UserDefaults.standard.string(forKey: "syncKey") ?? ""
    }

    var isConfigured: Bool {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces))?.host != nil
            && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         contentType: String = "application/json") async throws -> Data {
        guard isConfigured else { throw SyncError.notConfigured }
        var base = serverURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw SyncError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer " + key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SyncError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static func path(_ id: UUID) -> String { id.uuidString }

    // MARK: Sync-Stand je Dokument

    private func stateURL(_ id: UUID) -> URL { store.folder(id).appendingPathComponent("sync.json") }

    private func state(_ id: UUID) -> DocState {
        if let s = states[id] { return s }
        var stored = DocSyncState()
        if let data = try? Data(contentsOf: stateURL(id)),
           let decoded = try? JSONDecoder().decode(DocSyncState.self, from: data) {
            stored = decoded
        }
        let s = DocState(stored)
        states[id] = s
        return s
    }

    /// Höchste Änderungsnummer des Servers, die dieses Gerät für das Dokument schon geholt hat
    func knownSeq(_ id: UUID) -> Int { state(id).seq }

    /// Schreibt den Sync-Stand auf die Platte, nach allen schon angestoßenen Zeichnungen.
    /// Nur aufrufen, wenn die Zeichnung (auf der Platte oder unterwegs dorthin) alles enthält, was der Stand als
    /// vorhanden kennt. Sonst hielte der nächste Abgleich nach einem Absturz fremde Striche für gelöscht und
    /// löschte sie auch am Server. Ein älterer Stand auf der Platte schadet dagegen nie (dann wird eben doppelt geschickt).
    func persistState(_ id: UUID) {
        guard let s = states[id] else { return }
        let stored = s.stored
        store.enqueueWrite(to: stateURL(id)) { try? JSONEncoder().encode(stored) }
    }

    // MARK: Striche

    /// Höchstens so viele neue Striche je Anfrage. Nach einer Seitenänderung bekommen alle Striche darunter
    /// neue IDs; in einem Stück wären das viele MB, die bei schlechter Verbindung immer wieder von vorn begännen.
    private static let chunkSize = 300

    /// Ein großes Hochladen in Paketen, etwa nach einer Seitenänderung (alle Striche darunter haben neue IDs), oder
    /// ein unterbrochenes. Was nicht dazugehört (inzwischen neu Geschriebenes, Radiertes), geht vor, damit es nicht
    /// hinter dem Rest wartet. Die alten Fassungen verschobener Striche verschwinden erst mit dem letzten Paket:
    /// So fehlen sie nirgends, auch am Server nicht, solange das Hochladen dauert oder unterbrochen ist.
    private struct Bulk {
        /// Zeitpunkt der Seitenänderung: Später geschriebene Striche gehören nicht dazu
        var since: Date?
        /// Noch nicht hochgeladene Striche (nil = das Hochladen hat noch nicht begonnen)
        var waiting: Set<String>?
        /// Löschungen, die erst mit dem letzten Paket gehen (nil = beim ersten Abgleich festlegen: alles, was dann
        /// fehlt, sind die alten Fassungen)
        var lastRemoves: Set<String>?
    }
    private var bulks: [UUID: Bulk] = [:]

    /// Die offene Leinwand hat Seiten geändert: Der nächste Abgleich lädt viel hoch (siehe `Bulk`)
    func noteBulkChange(_ id: UUID) {
        bulks[id] = Bulk(since: Date())
    }

    /// Schickt die lokalen Änderungen (Unterschied von `snapshot` zum letzten Abgleich) und holt die entfernten.
    /// Die entfernten Änderungen gehen an die offene Leinwand oder direkt in die Datei, nie verloren.
    /// Viele neue Striche gehen in Paketen, in Zeichnungsreihenfolge (so liegen sie überall gleich übereinander);
    /// nach jedem Paket ist der Stand gesichert. Nur was während eines langen Hochladens neu geschrieben wird,
    /// geht vor dem Rest hinaus, damit es nicht hinter einer großen Verschiebung wartet.
    /// - Parameter snapshot: aktueller Stand der Zeichnung, oder nil, wenn sich lokal nichts geändert hat
    @discardableResult
    func syncStrokes(_ id: UUID, snapshot: StrokeSnapshot?) async -> Bool {
        guard isConfigured, !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }

        let state = self.state(id)
        var adds: [(id: String, stroke: PKStroke)] = []
        // Mit dem ersten bzw. erst mit dem letzten Paket
        var firstRemoves: [String] = []
        var lastRemoves: [String] = []
        var toPage = CGAffineTransform.identity
        if let snapshot {
            toPage = snapshot.toPage
            var current = Set<String>(minimumCapacity: snapshot.strokes.count + snapshot.alsoPresent.count)
            for s in snapshot.strokes where !snapshot.alsoGone.contains(s.id) { current.insert(s.id) }
            current.formUnion(snapshot.alsoPresent)
            adds = snapshot.strokes.filter { !state.confirmed.contains($0.id) && !snapshot.alsoGone.contains($0.id) }
            let removes = state.confirmed.subtracting(current)
            if var bulk = bulks[id] {
                let held = bulk.lastRemoves ?? removes
                bulk.lastRemoves = held
                firstRemoves = Array(removes.subtracting(held))
                lastRemoves = Array(removes.intersection(held))
                if adds.count > Self.chunkSize {
                    let b = bulk
                    func isFresh(_ a: (id: String, stroke: PKStroke)) -> Bool {
                        if let waiting = b.waiting { return !waiting.contains(a.id) }
                        if let since = b.since { return a.stroke.path.creationDate > since }
                        return false
                    }
                    let fresh = adds.filter { isFresh($0) }
                    if !fresh.isEmpty, fresh.count < adds.count {
                        adds = fresh + adds.filter { !isFresh($0) }
                    }
                }
                bulks[id] = bulk
            } else {
                firstRemoves = Array(removes)
            }
        }

        struct Response: Decodable {
            struct Change: Decodable { var id: String; var data: String? }
            var seq: Int
            var changes: [Change]
        }
        let started = Date()
        if adds.count > Self.chunkSize, bulks[id] == nil { bulks[id] = Bulk(lastRemoves: Set(lastRemoves)) }
        var next = 0
        repeat {
            let part = adds[next..<min(next + Self.chunkSize, adds.count)]
            // Radiertes gleich mit dem ersten Paket. Die alten Fassungen verschobener Striche erst mit dem letzten:
            // Dann sind die verschobenen schon alle am Server, bevor ihre alte Fassung verschwindet
            var gone = next == 0 ? firstRemoves : []
            if next + part.count >= adds.count { gone += lastRemoves }
            if adds.count > Self.chunkSize { bulks[id]?.waiting = Set(adds[next...].map { $0.id }) }
            do {
                let add = part.map { a -> [String: String] in
                    var stroke = a.stroke
                    stroke.transform = StrokeCodec.pageTransform(a.stroke, toPage)
                    return ["id": a.id, "data": StrokeCodec.data(stroke)]
                }
                let body = try JSONSerialization.data(withJSONObject: ["since": state.seq, "add": add, "remove": gone])
                let data = try await request("POST", "/api/doc/\(Self.path(id))/sync", body: body)
                let response = try JSONDecoder().decode(Response.self, from: data)
                state.confirmed.subtract(gone)
                for a in part { state.confirmed.insert(a.id) }
                // Das eigene Echo (was diese Anfrage gerade hochgeladen oder gelöscht hat) nicht zurück an die
                // Leinwand geben: Hat sich die Zeichnung inzwischen geändert (z. B. Seiten eingefügt, Striche
                // verschoben), würde ein alter Strich sonst wieder auftauchen. Der Server lässt es inzwischen
                // selbst weg; das hier schützt auch gegen einen älteren Server.
                var own = Set(gone)
                for a in part { own.insert(a.id) }
                var changes = RemoteChanges()
                for c in response.changes where !own.contains(c.id) {
                    if let d = c.data {
                        changes.added.append((c.id, d))
                        state.confirmed.insert(c.id)
                    } else {
                        changes.removed.insert(c.id)
                        state.confirmed.remove(c.id)
                    }
                }
                state.seq = response.seq
                deliver(changes, to: id)
                // Ein geschlossenes Dokument hat die Änderungen jetzt in seiner Datei (oder unterwegs dorthin);
                // die offene Leinwand sichert ihren Stand selbst, sobald ihre Zeichnung gespeichert ist
                if openController?.doc.id != id { persistState(id) }
                if !add.isEmpty || !gone.isEmpty || !changes.isEmpty {
                    Log.sync.info("sync \(add.count) hoch, \(gone.count) weg, \(changes.added.count)+\(changes.removed.count) geholt, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                }
            } catch {
                status = error.localizedDescription
                return false
            }
            next += part.count
            // Hat die offene Leinwand inzwischen Neues, zuerst das schicken (der Rest folgt im nächsten Abgleich).
            // Ebenso, wenn sie Seiten ändern will: Sie wartet sonst auf alle übrigen Pakete
            if next < adds.count, let c = openController, c.doc.id == id, c.hasUnsyncedLocalChanges || c.isRestructuring {
                bulks[id]?.waiting = Set(adds[next...].map { $0.id })
                return true
            }
        } while next < adds.count
        // Alles oben: Das große Hochladen ist fertig (ein bloßes Holen ändert daran nichts)
        if snapshot != nil { bulks[id] = nil }
        return true
    }

    private func deliver(_ changes: RemoteChanges, to id: UUID) {
        guard !changes.isEmpty else { return }
        if let controller = openController, controller.doc.id == id {
            controller.enqueue(changes)
            return
        }
        guard let doc = store.documents.first(where: { $0.id == id }) else { return }
        let drawing = store.loadDrawing(doc)
        if let merged = StrokeCodec.apply(changes, to: drawing, prune: openController == nil)?.drawing {
            store.saveDrawing(merged, for: id, pageCount: PageLayout.pagesNeeded(for: merged, kind: doc.kind, current: doc.pageCount),
                              touch: false)
        }
    }

    /// Abgleich eines Dokuments, das gerade nicht offen ist: Zeichnung von der Platte
    func syncClosed(_ id: UUID) async {
        // Eben geschlossen: Läuft noch ein Abgleich der Leinwand, dessen Ende abwarten
        for _ in 0..<100 where busy.contains(id) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Inzwischen wieder geöffnet: Dann gleicht die Leinwand ab, nicht die (ältere) Datei
        guard openController?.doc.id != id, let doc = store.documents.first(where: { $0.id == id }) else { return }
        let snapshot = StrokeSnapshot(store.loadDrawing(doc).strokes, toPage: .identity, prune: openController == nil)
        guard await syncStrokes(id, snapshot: snapshot) else { return }
        // Währenddessen wieder geöffnet: Das Geholte wartet auf der Leinwand, nicht in der Datei. Den Stand sichert
        // dann die Leinwand, sobald ihre Zeichnung gespeichert ist (sonst wäre er der Datei voraus)
        guard openController?.doc.id != id else { return }
        state(id).syncedModified = store.documents.first(where: { $0.id == id })?.modified.timeIntervalSince1970 ?? 0
        persistState(id)
    }

    // MARK: Bibliothek

    /// Gleicht die Bibliothek ab. Läuft schon ein Abgleich, kommt danach noch einer, und der Aufruf wartet auf dessen Ende.
    func syncLibrary() async {
        guard isConfigured else { return }
        if let running = libraryTask {
            libraryAgain = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.libraryAgain = false
                await self.syncLibraryOnce()
            } while self.libraryAgain
            self.libraryTask = nil
        }
        libraryTask = task
        await task.value
    }

    /// Nach dem Löschen oder Einfügen von Seiten in einem PDF: Diese Fassung muss vor den verschobenen Strichen
    /// auf den Server
    func notePDFUploadPending(_ id: UUID) {
        pdfUploadPending.insert(id)
    }

    private func syncLibraryOnce() async {
        do {
            // 1. Lokal gelöschte Dokumente als Grabstein hochladen
            for idString in pendingDeletes {
                let tomb: [String: Any] = ["id": idString, "title": "", "kind": "notebook", "deleted": true,
                                           "created": Date().timeIntervalSince1970,
                                           "modified": Date().timeIntervalSince1970, "pageCount": 0]
                _ = try await request("PUT", "/api/library/\(idString)", body: try JSONSerialization.data(withJSONObject: tomb))
                pendingDeletes.remove(idString)
            }

            // 2. Vom Server übernehmen
            struct Library: Decodable { var docs: [RemoteMeta] }
            let remote = try Self.decoder.decode(Library.self, from: try await request("GET", "/api/library")).docs
            var remoteByID: [UUID: RemoteMeta] = [:]
            for r in remote { remoteByID[r.id] = r }

            for r in remote {
                let local = store.documents.first { $0.id == r.id }
                if r.deleted == true {
                    if local != nil, openController?.doc.id != r.id {
                        states[r.id] = nil
                        bulks[r.id] = nil
                        store.delete(local!)
                    }
                    continue
                }
                if let local {
                    var merged = local
                    var changed = false
                    let remotePages = r.pagesVersion ?? 0, localPages = local.pagesVersion ?? 0
                    // Ändert die offene Leinwand gerade selbst Seiten, ihr nicht dazwischen das PDF austauschen;
                    // danach ist ihre Seitenänderung die neuere
                    let busyHere = openController?.doc.id == r.id && openController?.isRestructuring == true
                    // Titel, Ordner usw.: letzte Änderung gewinnt
                    if r.modified.timeIntervalSince1970 > local.modified.timeIntervalSince1970 + 0.001 {
                        merged.title = r.title
                        merged.folder = r.folder
                        merged.modified = r.modified
                        // Gleicher Seitenstand: Die Seitenzahl wächst nur (Schreiben auf der letzten Seite)
                        if remotePages == localPages { merged.pageCount = max(local.pageCount, r.pageCount) }
                        changed = true
                    }
                    // Seitenzahl und PDF folgen der neuesten Seitenänderung, unabhängig vom übrigen Stand:
                    // Ein Gerät, das nur fremde Striche übernommen hat, ist dadurch nicht „neuer“
                    var structure = false
                    if remotePages > localPages, !busyHere {
                        merged.pagesVersion = remotePages
                        merged.pageCount = max(r.pageCount, 1)
                        changed = true
                        structure = true
                    }
                    var pdfChanged = false
                    if r.kind == .pdf, r.hasPDF == true, (r.pdfVersion ?? 0) > (local.pdfVersion ?? 0), !busyHere {
                        let pdf = try await request("GET", "/api/pdf/\(Self.path(r.id))")
                        try pdf.write(to: store.pdfURL(r.id), options: .atomic)
                        merged.pdfVersion = r.pdfVersion
                        changed = true
                        pdfChanged = true
                    }
                    if changed { store.save(merged) }
                    if structure || pdfChanged, let c = openController, c.doc.id == r.id {
                        c.remoteStructureChanged(pageCount: merged.pageCount, pdfChanged: pdfChanged)
                    }
                } else {
                    // Neu auf diesem Gerät (oder nach dem Löschen wieder da): ohne alten Sync-Stand beginnen, sonst
                    // hielte der Abgleich alle früher bekannten Striche für hier gelöscht
                    states[r.id] = nil
                    bulks[r.id] = nil
                    try? FileManager.default.removeItem(at: stateURL(r.id))
                    if r.kind == .pdf {
                        guard r.hasPDF == true else { continue }
                        let pdf = try await request("GET", "/api/pdf/\(Self.path(r.id))")
                        try FileManager.default.createDirectory(at: store.folder(r.id), withIntermediateDirectories: true)
                        try pdf.write(to: store.pdfURL(r.id), options: .atomic)
                    } else {
                        try FileManager.default.createDirectory(at: store.folder(r.id), withIntermediateDirectories: true)
                    }
                    // Striche auf dem Server liegen immer im aktuellen Seitenlayout
                    store.save(NoteDocument(id: r.id, title: r.title, kind: r.kind, created: r.created,
                                            modified: r.modified, pageCount: max(r.pageCount, 1),
                                            layoutVersion: PageLayout.currentVersion, folder: r.folder,
                                            pdfVersion: r.pdfVersion, pagesVersion: r.pagesVersion))
                }
            }

            // 3. Eigene Dokumente hochladen, wenn neu oder neuer, oder wenn hier eine neuere Seitenänderung liegt
            //    (der Server übernimmt die dann auch in einen sonst neueren Stand)
            for local in store.documents {
                let r = remoteByID[local.id]
                let metaNewer = r == nil || local.modified.timeIntervalSince1970 > r!.modified.timeIntervalSince1970 + 0.001
                let pagesNewer = (local.pagesVersion ?? 0) > (r?.pagesVersion ?? 0)
                let pdfNewer = local.kind == .pdf && (r?.hasPDF != true || (local.pdfVersion ?? 0) > (r?.pdfVersion ?? 0))
                if !pdfNewer { pdfUploadPending.remove(local.id) }
                guard metaNewer || pagesNewer || pdfNewer else { continue }
                if pdfNewer {
                    let pdf = try Data(contentsOf: store.pdfURL(local.id))
                    _ = try await request("PUT", "/api/pdf/\(Self.path(local.id))", body: pdf, contentType: "application/pdf")
                }
                _ = try await request("PUT", "/api/library/\(Self.path(local.id))", body: try Self.encoder.encode(local))
                pdfUploadPending.remove(local.id)
            }

            // 4. Striche der nicht geöffneten Dokumente
            for local in store.documents where local.id != openController?.doc.id {
                let state = self.state(local.id)
                let remoteSeq = remoteByID[local.id]?.strokeSeq ?? 0
                if remoteSeq > state.seq || local.modified.timeIntervalSince1970 > state.syncedModified + 0.001 {
                    await syncClosed(local.id)
                }
            }
            lastSync = Date()
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    /// Merkt ein lokal gelöschtes Dokument vor, damit es auch auf den anderen Geräten verschwindet
    func noteDeleted(_ id: UUID) {
        states[id] = nil
        bulks[id] = nil
        guard isConfigured else { return }
        pendingDeletes.insert(id.uuidString)
    }

    // MARK: Briefkasten

    func sendToOutbox(to recipient: String, name: String, data: Data, type: String) async throws {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "seite"
        _ = try await request("PUT", "/api/outbox/\(recipient)/\(safe)", body: data, contentType: type)
    }

    // MARK: Live-Teilen

    /// Link für Gäste (bleibt gleich, bis das Teilen beendet wird)
    func shareLink(_ id: UUID) async throws -> URL {
        await syncLibrary() // Dokument und PDF müssen am Server sein
        struct Token: Decodable { var token: String }
        let data = try await request("POST", "/api/share/\(Self.path(id))")
        let token = try JSONDecoder().decode(Token.self, from: data).token
        guard let url = URL(string: baseURL + "/s/" + token) else { throw SyncError.notConfigured }
        return url
    }

    func stopSharing(_ id: UUID) async throws {
        _ = try await request("DELETE", "/api/share/\(Self.path(id))")
    }

    /// WebSocket zum Server: meldet sofort fremde Striche und die Zahl der Gäste
    func webSocketRequest(_ id: UUID) -> URLRequest? {
        guard isConfigured else { return nil }
        let wsBase = baseURL.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: wsBase + "/api/doc/\(Self.path(id))/ws") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer " + key.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Authorization")
        return req
    }

    private var baseURL: String {
        var base = serverURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// Prüft Adresse und Schlüssel; liefert die Zahl der Dokumente am Server
    func test() async throws -> Int {
        struct Library: Decodable { var docs: [RemoteMeta] }
        let lib = try Self.decoder.decode(Library.self, from: try await request("GET", "/api/library"))
        return lib.docs.filter { $0.deleted != true }.count
    }
}
