import Foundation
import PencilKit

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
    private var librarySyncing = false
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

    func loadState(_ id: UUID) -> DocSyncState {
        guard let data = try? Data(contentsOf: stateURL(id)) else { return DocSyncState() }
        return (try? JSONDecoder().decode(DocSyncState.self, from: data)) ?? DocSyncState()
    }

    private func saveState(_ state: DocSyncState, _ id: UUID) {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL(id), options: .atomic) }
    }

    // MARK: Striche

    /// Schickt die lokalen Änderungen (Unterschied von `snapshot` zum letzten Abgleich) und holt die entfernten.
    /// Die entfernten Änderungen gehen an die offene Leinwand oder direkt in die Datei, nie verloren.
    /// - Parameter snapshot: aktuelle Zeichnung in Seitenpunkten, oder nil, wenn sich lokal nichts geändert hat
    @discardableResult
    func syncStrokes(_ id: UUID, snapshot: PKDrawing?) async -> Bool {
        guard isConfigured, !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }

        var state = loadState(id)
        var add: [[String: String]] = []
        var remove: [String] = []
        var ids = Set(state.ids)
        if let snapshot {
            let encoded = StrokeCodec.encodeAll(snapshot.strokes)
            let current = Set(encoded.map(\.id))
            add = encoded.filter { !ids.contains($0.id) }.map { ["id": $0.id, "data": $0.data] }
            remove = Array(ids.subtracting(current))
            ids = current
        }

        struct Response: Decodable {
            struct Change: Decodable { var id: String; var data: String? }
            var seq: Int
            var changes: [Change]
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["since": state.seq, "add": add, "remove": remove])
            let data = try await request("POST", "/api/doc/\(Self.path(id))/sync", body: body)
            let response = try JSONDecoder().decode(Response.self, from: data)
            var changes = RemoteChanges()
            for c in response.changes {
                if let d = c.data {
                    changes.added.append((c.id, d))
                    ids.insert(c.id)
                } else {
                    changes.removed.insert(c.id)
                    ids.remove(c.id)
                }
            }
            state.seq = response.seq
            state.ids = Array(ids)
            saveState(state, id)
            deliver(changes, to: id)
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func deliver(_ changes: RemoteChanges, to id: UUID) {
        guard !changes.isEmpty else { return }
        if let controller = openController, controller.doc.id == id {
            controller.enqueue(changes)
            return
        }
        guard let doc = store.documents.first(where: { $0.id == id }) else { return }
        let drawing = store.loadDrawing(doc)
        if let merged = StrokeCodec.apply(changes, to: drawing) {
            store.saveDrawing(merged, for: id, pageCount: PageLayout.pagesNeeded(for: merged, kind: doc.kind, current: doc.pageCount))
        }
    }

    /// Abgleich eines Dokuments, das gerade nicht offen ist: Zeichnung von der Platte
    func syncClosed(_ id: UUID) async {
        guard let doc = store.documents.first(where: { $0.id == id }) else { return }
        guard await syncStrokes(id, snapshot: store.loadDrawing(doc)) else { return }
        var state = loadState(id)
        state.syncedModified = store.documents.first(where: { $0.id == id })?.modified.timeIntervalSince1970 ?? 0
        saveState(state, id)
    }

    // MARK: Bibliothek

    func syncLibrary() async {
        guard isConfigured, !librarySyncing else { return }
        librarySyncing = true
        defer { librarySyncing = false }
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
                    if local != nil, openController?.doc.id != r.id { store.delete(local!) }
                    continue
                }
                if let local {
                    if r.modified.timeIntervalSince1970 > local.modified.timeIntervalSince1970 + 0.001 {
                        var merged = local
                        merged.title = r.title
                        merged.folder = r.folder
                        merged.pageCount = max(local.pageCount, r.pageCount)
                        merged.modified = r.modified
                        store.save(merged)
                    }
                } else {
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
                                            layoutVersion: PageLayout.currentVersion, folder: r.folder))
                }
            }

            // 3. Eigene Dokumente hochladen, wenn neu oder neuer
            for local in store.documents {
                let r = remoteByID[local.id]
                guard r == nil || local.modified.timeIntervalSince1970 > r!.modified.timeIntervalSince1970 + 0.001 else { continue }
                if local.kind == .pdf, r?.hasPDF != true {
                    let pdf = try Data(contentsOf: store.pdfURL(local.id))
                    _ = try await request("PUT", "/api/pdf/\(Self.path(local.id))", body: pdf, contentType: "application/pdf")
                }
                _ = try await request("PUT", "/api/library/\(Self.path(local.id))", body: try Self.encoder.encode(local))
            }

            // 4. Striche der nicht geöffneten Dokumente
            for local in store.documents where local.id != openController?.doc.id {
                let state = loadState(local.id)
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
