import Foundation
import PencilKit
import os

/// Protokoll (am Mac in der Konsole zu sehen: Subsystem de.beiglboeck.notizbuch)
enum Log {
    /// Zeitmessung des Abgleichs
    static let sync = Logger(subsystem: "de.beiglboeck.notizbuch", category: "sync")
    /// Werkzeuge und PencilKit (etwa welche Schwebe-Gesten der Radierer pausiert)
    static let ink = Logger(subsystem: "de.beiglboeck.notizbuch", category: "ink")
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
    /// Wann Name bzw. Ordner zuletzt geändert wurden (siehe NoteDocument); fehlen bei Einträgen älterer Apps
    var titleSet: Date?
    var folderSet: Date?
    /// "md": Markdown aus dem Eingang. Solange es kein PDF hat, setzt es das erste Gerät, das es sieht (`typeset`)
    var source: String?
}

/// Was dieses Gerät über den Sync-Stand eines Dokuments weiß (liegt als sync.json im Dokumentordner)
struct DocSyncState: Codable {
    /// Höchste Änderungsnummer des Servers, die dieses Gerät kennt
    var seq = 0
    /// IDs der Striche, die beim letzten Abgleich auf beiden Seiten vorhanden waren
    var ids: [String] = []
    /// meta.modified (Sekunden seit 1970) beim letzten Abgleich
    var syncedModified: Double = 0
    /// Striche, die die App unter einer anderen eigenen Prüfsumme kennt als der Server (aus dem Browser): eigene
    /// Prüfsumme → ID des Servers (siehe StrokeCodec.apply). Fehlt in älteren Dateien und ohne solche Striche
    var aliases: [String: String]?
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

    /// IDs über den Zwischenspeicher: Nur neue Striche werden gehasht. `aliases`: die des Dokuments (SyncEngine.aliases)
    init(_ strokes: [PKStroke], toPage: CGAffineTransform, pruning: StrokeIDCache.Pruning = .never,
         aliases: [String: String]) {
        let ids = StrokeIDCache.shared.ids(for: strokes, toPage: toPage, pruning: pruning, aliases: aliases)
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
    weak var openController: CanvasController? {
        didSet { if let id = openController?.doc.id { openings[id, default: 0] += 1 } }
    }
    /// Wie oft ein Dokument geöffnet wurde: Ein Abgleich seiner Datei merkt so, dass inzwischen eine Leinwand darin
    /// geschrieben haben kann (seine Datei ist dann neuer als der Stand, mit dem er begann)
    private var openings: [UUID: Int] = [:]
    /// Wie oft ein Abgleich der Datei vollständig war: Wer darauf gewartet hat, braucht keinen eigenen mehr
    private var closedPasses: [UUID: Int] = [:]

    private var busy = Set<UUID>()
    /// Sync-Stand je Dokument im Speicher (die Platte liest und schreibt nur selten)
    private var states: [UUID: DocState] = [:]

    private final class DocState {
        var seq: Int
        /// IDs der Striche, die beim letzten Abgleich auf beiden Seiten vorhanden waren
        var confirmed: Set<String>
        var syncedModified: Double
        /// Eigene Prüfsumme → ID des Servers (siehe DocSyncState.aliases)
        var aliases: [String: String]

        init(_ s: DocSyncState) {
            seq = s.seq
            confirmed = Set(s.ids)
            syncedModified = s.syncedModified
            aliases = s.aliases ?? [:]
        }

        var stored: DocSyncState {
            DocSyncState(seq: seq, ids: Array(confirmed), syncedModified: syncedModified,
                         aliases: aliases.isEmpty ? nil : aliases)
        }
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
    /// Nur für neue Fragen (uploadAsk, mit den Seiten um die Frage einige MB): eigene Verbindung, damit Striche nicht
    /// hinter dem großen Hochladen warten, und als Hintergrundverkehr, der der Leitung den Vortritt für sie lässt
    private let askSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.networkServiceType = .background
        return URLSession(configuration: config)
    }()

    private var pendingDeletes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "syncPendingDeletes") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "syncPendingDeletes") }
    }

    /// Zeitpunkt je vorgemerktem Grabstein (Sekunden seit 1970): beim Löschen der des Löschens, beim Aufräumen von
    /// temp der Stand des Dokuments damals. Geht der Grabstein erst später hinauf, löscht er so nichts, was andere
    /// Geräte inzwischen geändert haben: Der Server nimmt ihn dann nicht an (sein Eintrag ist neuer)
    private var pendingDeleteStamps: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: "syncPendingDeleteStamps") as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "syncPendingDeleteStamps") }
    }

    /// Aufgeräumtes aus temp, mit der höchsten Änderungsnummer seiner Striche, die dieses Gerät damals kannte. Sein
    /// Grabstein geht erst nach der nächsten Abfrage der Bibliothek hinauf, und nur, wenn der Server seitdem nichts
    /// Neues hat (siehe Schritt 2)
    private var pendingPurgeSeqs: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: "syncPendingPurgeSeqs") as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "syncPendingPurgeSeqs") }
    }

    /// Dokumente, die nach einem Grabstein zurückkamen (siehe Schritt 3). Mit dem Grabstein hat der Server alle ihre
    /// Striche gelöscht, also gehen alle noch einmal hinauf. Auch auf der Platte vermerkt, falls die App vorher endet
    private var resend: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(resend.map(\.uuidString), forKey: "syncResend") }
    }
    /// Bei neu heruntergeladenen Dokumenten, und nach dem Zurücksetzen für `resend` ohne Stand der Zeichnung: Die erste
    /// Antwort bringt alles, was am Server liegt, auch eigene frühere Striche. Sie zählen nicht als fremd (siehe
    /// `foreignSince`). Auf der Platte vermerkt, damit das auch nach einem Neustart vor dieser Antwort gilt
    private var refetching: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(refetching.map(\.uuidString), forKey: "syncRefetching") }
    }

    /// Dokumente, deren Striche der Server womöglich mit einem Grabstein gelöscht hat: solange ihr Zurückholen
    /// unterwegs ist (Schritt 3), oder weil eine Antwort des Servers weniger kannte als dieses Gerät (die höchste
    /// Änderungsnummer eines Dokuments sinkt nur durch einen Grabstein). Zeigt der nächste Abgleich den Eintrag
    /// gültig, gehen alle Striche noch einmal hinauf, auch wenn die Antwort auf das Zurückholen verloren ging oder ein
    /// anderes Gerät den Grabstein ersetzt hat. Ist es ein Grabstein, entscheidet Schritt 2 wie sonst
    private var lostAtServer: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(lostAtServer.map(\.uuidString), forKey: "syncLostAtServer") }
    }

    /// Dokumente, in die fremde Striche kamen (von anderen Geräten oder Gästen im Browser), seit der Abgleich der
    /// Bibliothek sie zuletzt gültig sah. Fremd ist, was dieses Gerät noch nicht hatte: ein neuer Strich, oder das
    /// Löschen eines vorhandenen. Nur dann gelten Striche am Server nach einem Grabstein als danach geschrieben: Eigene,
    /// etwa der Rest eines noch laufenden Hochladens aller Striche, holen ein Dokument nicht zurück, das inzwischen noch
    /// einmal gelöscht wurde
    private var foreignSince: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(foreignSince.map(\.uuidString), forKey: "syncForeignSince") }
    }

    /// Ebenso, aber angekommen, während das Dokument hier offen war. Nach einem Grabstein kommt es dann zurück, auch
    /// wenn es inzwischen zu ist und danach mehr geschrieben wurde, als dieses Gerät schon geholt hat (etwa von einem
    /// Gast, der weiterschreibt)
    private var foreignWhileOpen: Set<UUID> = [] {
        didSet { UserDefaults.standard.set(foreignWhileOpen.map(\.uuidString), forKey: "syncForeignWhileOpen") }
    }
    /// Wie oft fremde Striche ankamen, je Dokument (nur im Speicher): Schritt 2 erkennt daran, was erst während seiner
    /// Abfrage ankam
    private var foreignArrivals: [UUID: Int] = [:]
    /// Geschlossene Dokumente, in denen ein geholter Strich schon da war und nun unter der ID des Servers gilt (siehe
    /// StrokeCodec.apply): Ein zweiter Durchgang von `syncClosed` löscht die Fassung unter der alten ID am Server
    private var rekeyedClosed = Set<UUID>()

    /// Höchste Änderungsnummer der Striche je Dokument laut letzter Abfrage der Bibliothek
    private var remoteSeqs: [UUID: Int] = [:]

    /// Markdown aus dem Eingang, das dieses Gerät gerade setzt, und wann es nach einem Fehler wieder dran ist (nur im
    /// Speicher: Nach einem Neustart versucht es das gleich wieder)
    private var typesetting = Set<UUID>()
    private var typesetRetry: [UUID: (after: Date, failures: Int)] = [:]
    /// Hier gesetzt und als erstes am Server abgelegt: Das neue Dokument nimmt dieses PDF, statt es gleich wieder zu laden
    private var typesetPDFs: [UUID: Data] = [:]

    /// Dokumente mit Strichen am Server, die dieses Gerät noch nicht geholt hat (etwa weil ihr Abgleich eben
    /// fehlschlug), und solche, deren Abgleich gerade läuft (seine Antwort kann Neues bringen). Das Aufräumen von temp
    /// lässt sie stehen: Sein Grabstein löschte diese Striche sonst auch am Server
    var unfetched: Set<UUID> {
        Set(remoteSeqs.compactMap { id, seq in seq > (states[id]?.seq ?? 0) ? id : nil }).union(busy)
    }

    init(store: DocumentStore) {
        self.store = store
        serverURL = UserDefaults.standard.string(forKey: "syncURL") ?? ""
        key = UserDefaults.standard.string(forKey: "syncKey") ?? ""
        func ids(_ key: String) -> Set<UUID> {
            Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { UUID(uuidString: $0) })
        }
        resend = ids("syncResend")
        lostAtServer = ids("syncLostAtServer")
        foreignSince = ids("syncForeignSince")
        foreignWhileOpen = ids("syncForeignWhileOpen")
        refetching = ids("syncRefetching")
    }

    var isConfigured: Bool {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces))?.host != nil
            && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isBusy(_ id: UUID) -> Bool { busy.contains(id) }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         contentType: String = "application/json", background: Bool = false) async throws -> Data {
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
        let (data, response) = try await (background ? askSession : session).data(for: req)
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

    /// Aliase des Dokuments (eigene Prüfsumme → ID des Servers, siehe StrokeCodec.apply). Jede Berechnung seiner IDs
    /// nimmt sie mit; geladen werden sie mit dem Sync-Stand, also auch nach einem Neustart vor dem ersten Hashen
    func aliases(_ id: UUID) -> [String: String] { state(id).aliases }

    /// Für StrokeCodec.apply auf der Leinwand: ändert die Aliase an Ort und Stelle (über eine Kopie kostete jedes
    /// Einfügen mit neuem Alias alle Einträge). Auf die Platte kommen sie mit dem Sync-Stand, also mit der Zeichnung
    func withAliases<T>(_ id: UUID, _ body: (inout [String: String]) -> T) -> T {
        let s = state(id)
        return body(&s.aliases)
    }

    /// Auf der offenen Leinwand gilt ein geholter Strich nun unter der ID des Servers (siehe StrokeCodec.apply): Wie bei
    /// geschlossenen Dokumenten (deliver) gilt die Datei bis zu einem gelungenen Durchgang von `syncClosed` als nicht
    /// abgeglichen. Schließt die Leinwand, bevor ihr nächster Abgleich die Fassung unter der alten ID am Server löscht,
    /// und scheitert auch der Durchgang beim Schließen, holt Schritt 4 ihn nach, auch nach einem Neustart
    func noteRekeyed(_ id: UUID) { state(id).syncedModified = 0 }

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

    /// Ein großes Hochladen in Paketen, etwa nach einer Seitenänderung (alle Striche darunter haben neue IDs).
    /// Was nicht dazugehört (inzwischen neu Geschriebenes, Lasso-Kopien, Radiertes), geht vor, damit es nicht
    /// hinter dem Rest wartet. Die abgelösten alten Fassungen verschwinden erst mit dem letzten Paket: So fehlen
    /// die Striche nirgends, auch am Server nicht, solange das Hochladen dauert oder unterbrochen ist.
    private struct Bulk {
        /// Erkennt ein überholtes Hochladen (das nach einer neuen Seitenänderung nichts mehr ändern darf)
        var generation: Int
        /// Beginn: Später geschriebene Striche gehören nicht dazu
        var since: Date
        /// Striche, die zum großen Hochladen gehören (nil = noch unbekannt); alle anderen gehen vor
        var waiting: Set<String>?
        /// Abgelöste alte Fassungen: Ihre Löschung geht erst mit dem letzten Paket (nil = beim ersten Abgleich alles,
        /// was dann fehlt)
        var retired: Set<String>?
    }
    private var bulks: [UUID: Bulk] = [:]
    private var bulkGenerations = 0

    /// Seitenzahl nach der Seitenänderung eines anderen Geräts, solange dessen verschobene Striche noch kommen:
    /// Bis dahin reichen die alten Fassungen weiter hinunter. Ein geschlossenes Dokument (und eine Leinwand, die es
    /// jetzt öffnet) schrumpft wieder darauf, sobald sie weg sind.
    private var pageTargets: [UUID: Int] = [:]
    func pageTarget(_ id: UUID) -> Int? { pageTargets[id] }
    func notePageTargetReached(_ id: UUID) { pageTargets[id] = nil }

    /// Die offene Leinwand hat Seiten geändert: Der nächste Abgleich lädt viel hoch (siehe `Bulk`)
    @discardableResult
    func noteBulkChange(_ id: UUID) -> Int {
        bulkGenerations += 1
        bulks[id] = Bulk(generation: bulkGenerations, since: Date())
        // Die eigene Seitenänderung ist die neueste
        pageTargets[id] = nil
        return bulkGenerations
    }

    /// Die IDs der Zeichnung nach der Seitenänderung sind bekannt: Was sonst noch neu ist, geht vor; was am Server
    /// steht, aber nicht mehr darin vorkommt, sind die abgelösten alten Fassungen. Läuft gerade noch ein Abgleich
    /// von davor, kommt von ihm vielleicht noch eine alte Fassung an den Server: Dann legt das erst der nächste
    /// Abgleich fest (alles, was dann fehlt)
    func noteBulkContents(_ id: UUID, generation: Int, ids: Set<String>) {
        guard var bulk = bulks[id], bulk.generation == generation else { return }
        bulk.waiting = ids
        if bulk.retired == nil, !busy.contains(id) { bulk.retired = state(id).confirmed.subtracting(ids) }
        bulks[id] = bulk
    }

    /// Schickt die lokalen Änderungen (Unterschied von `snapshot` zum letzten Abgleich) und holt die entfernten.
    /// Die entfernten Änderungen gehen an die offene Leinwand oder direkt in die Datei, nie verloren.
    /// Viele neue Striche gehen in Paketen, in Zeichnungsreihenfolge (so liegen sie überall gleich übereinander);
    /// nach jedem Paket ist der Stand gesichert. Was nicht zu einem großen Hochladen gehört, geht vor (siehe `Bulk`).
    /// Gelöscht wird, sobald das zuerst Geschickte oben ist; Löschungen unbekannter Herkunft während eines großen
    /// Hochladens (etwa nach einem Neustart mittendrin) erst mit dem letzten Paket.
    /// - Parameter snapshot: aktueller Stand der Zeichnung, oder nil, wenn sich lokal nichts geändert hat
    @discardableResult
    func syncStrokes(_ id: UUID, snapshot: StrokeSnapshot?) async -> Bool {
        guard isConfigured, !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }

        if resend.contains(id) {
            // Nach einem Grabstein zurück (siehe Schritt 3): Nichts gilt mehr als am Server vorhanden, also geht alles
            // noch einmal hinauf. Erst hier, wo sicher kein anderer Abgleich des Dokuments läuft. Ein leerer Stand passt
            // immer zur Zeichnung, darf also gleich auf die Platte. Die Aliase bleiben: Sie gehören zur Zeichnung, ihre
            // Striche gehen unter der ID des Servers wieder hinauf
            let s = self.state(id)
            s.seq = 0
            s.confirmed = []
            s.syncedModified = 0
            bulks[id] = nil
            persistState(id)
            // Erledigt ist das Vorhaben erst, wenn der leere Stand auf der Platte ist. Endet die App vorher, beginnt es
            // nach dem Neustart eben noch einmal. Das Warten (auf das Speichern davor) kommt nur nach einem Grabstein vor
            store.waitForWrites()
            // Ohne Stand der Zeichnung ist eigenes Früheres in der ersten Antwort nicht zu erkennen (siehe `refetching`)
            if snapshot == nil, !refetching.contains(id) { refetching.insert(id) }
            resend.remove(id)
        }
        let state = self.state(id)
        // Abgleich der offenen Leinwand: Er hört auf, sobald sie Neues hat, Seiten ändert oder geschlossen wird.
        // Abgleich der Datei: Er hört auf, sobald das Dokument inzwischen offen war
        let startedOpen = openController?.doc.id == id
        let openedBefore = openings[id, default: 0]
        var adds: [(id: String, stroke: PKStroke)] = []
        var earlyRemoves: [String] = []
        var lateRemoves: [String] = []
        // So viele Striche am Anfang von `adds` gehören nicht zum großen Hochladen
        var freshCount = 0
        var toPage = CGAffineTransform.identity
        // Was die Zeichnung enthält: Daran erkennt die Antwort, was fremd ist (siehe `foreignSince`)
        var present: Set<String>?
        if let snapshot {
            toPage = snapshot.toPage
            var current = Set<String>(minimumCapacity: snapshot.strokes.count + snapshot.alsoPresent.count)
            for s in snapshot.strokes where !snapshot.alsoGone.contains(s.id) { current.insert(s.id) }
            current.formUnion(snapshot.alsoPresent)
            present = current
            adds = snapshot.strokes.filter { !state.confirmed.contains($0.id) && !snapshot.alsoGone.contains($0.id) }
            let removes = state.confirmed.subtracting(current)
            if var bulk = bulks[id] {
                let retired = bulk.retired ?? removes
                bulk.retired = retired
                bulks[id] = bulk
                earlyRemoves = Array(removes.subtracting(retired))
                lateRemoves = Array(removes.intersection(retired))
                let b = bulk
                func isFresh(_ a: (id: String, stroke: PKStroke)) -> Bool {
                    a.stroke.path.creationDate > b.since || b.waiting.map { !$0.contains(a.id) } == true
                }
                let fresh = adds.filter { isFresh($0) }
                if !fresh.isEmpty, fresh.count < adds.count {
                    adds = fresh + adds.filter { !isFresh($0) }
                }
                freshCount = fresh.count
            } else if adds.count > Self.chunkSize {
                // Großes Hochladen ohne bekannte Seitenänderung: Die Löschungen könnten die alten Fassungen sein
                bulkGenerations += 1
                bulks[id] = Bulk(generation: bulkGenerations, since: Date(), retired: removes)
                lateRemoves = Array(removes)
            } else {
                earlyRemoves = Array(removes)
            }
        }
        let generation = bulks[id]?.generation
        // IDs aus einem Alias: Solche Striche gehen mit Vermerk hinauf, damit andere Geräte sie prüfen (ihre eigene
        // Prüfsumme weicht ab, siehe StrokeCodec.apply). Stand von jetzt, also wie beim Erfassen der Zeichnung; nur
        // wenn etwas hinaufgeht (ein bloßes Holen, etwa nach jedem Hinweis des Servers, braucht sie nicht)
        let aliasIDs = adds.isEmpty || state.aliases.isEmpty ? Set<String>() : Set(state.aliases.values)
        /// Was vom großen Hochladen ab `next` noch fehlt (für den nächsten Abgleich, falls dieser nicht fertig wird)
        func noteWaiting(from next: Int) {
            guard adds.count > Self.chunkSize, let generation, bulks[id]?.generation == generation else { return }
            bulks[id]?.waiting = Set(adds[max(next, freshCount)...].map { $0.id })
        }

        struct Response: Decodable {
            struct Change: Decodable { var id: String; var data: String? }
            var seq: Int
            var changes: [Change]
        }
        let started = Date()
        // Radiertes geht mit dem Paket, in dem das zuerst Geschickte endet (Lasso: erst die Kopien, dann weg mit
        // dem Original), die abgelösten alten Fassungen mit dem letzten
        let earlyChunk = freshCount == 0 ? 0 : (freshCount - 1) / Self.chunkSize
        var next = 0
        var chunk = 0
        repeat {
            let part = adds[next..<min(next + Self.chunkSize, adds.count)]
            var gone = chunk == earlyChunk ? earlyRemoves : []
            if next + part.count >= adds.count { gone += lateRemoves }
            noteWaiting(from: next)
            do {
                let add = part.map { a -> [String: String] in
                    var stroke = a.stroke
                    stroke.transform = StrokeCodec.pageTransform(a.stroke, toPage)
                    let alias = !aliasIDs.isEmpty && aliasIDs.contains(String(a.id.prefix(while: { $0 != "#" })))
                    return ["id": a.id, "data": StrokeCodec.data(stroke, alias: alias)]
                }
                let since = state.seq
                let body = try JSONSerialization.data(withJSONObject: ["since": since, "add": add, "remove": gone])
                let data = try await request("POST", "/api/doc/\(Self.path(id))/sync", body: body)
                let response = try JSONDecoder().decode(Response.self, from: data)
                // Der Server kennt weniger als dieses Gerät: Ein Grabstein hat die Striche gelöscht (siehe `lostAtServer`).
                // Gehen ohnehin gleich alle noch einmal hinauf, ist nichts zu vermerken
                if response.seq < since, !resend.contains(id), !lostAtServer.contains(id) { lostAtServer.insert(id) }
                state.confirmed.subtract(gone)
                // Hier Gelöschtes braucht seinen Alias nicht mehr (kommt der Strich zurück, etwa mit Rückgängig, geht er
                // unter seiner eigenen Prüfsumme hinauf)
                if !state.aliases.isEmpty, !gone.isEmpty {
                    let removed = Set(gone)
                    state.aliases = state.aliases.filter { !removed.contains($0.value) }
                }
                for a in part { state.confirmed.insert(a.id) }
                // Das eigene Echo (was diese Anfrage gerade hochgeladen oder gelöscht hat) nicht zurück an die
                // Leinwand geben: Hat sich die Zeichnung inzwischen geändert (z. B. Seiten eingefügt, Striche
                // verschoben), würde ein alter Strich sonst wieder auftauchen. Der Server lässt es inzwischen
                // selbst weg; das hier schützt auch gegen einen älteren Server.
                var own = Set(gone)
                for a in part { own.insert(a.id) }
                var changes = RemoteChanges()
                // Fremd ist nur, was dieses Gerät noch nicht hatte: ein neuer Strich, oder das Löschen eines vorhandenen.
                // Eigene frühere Striche, die eine Antwort noch einmal bringt (etwa nach dem Zurücksetzen), zählen nicht
                var fresh = false
                for c in response.changes where !own.contains(c.id) {
                    let known = state.confirmed.contains(c.id) || present?.contains(c.id) == true
                    if let d = c.data {
                        if !known { fresh = true }
                        changes.added.append((c.id, d))
                        state.confirmed.insert(c.id)
                    } else {
                        if known { fresh = true }
                        changes.removed.insert(c.id)
                        state.confirmed.remove(c.id)
                    }
                }
                state.seq = response.seq
                if fresh, !refetching.contains(id) {
                    if !foreignSince.contains(id) { foreignSince.insert(id) }
                    foreignArrivals[id, default: 0] += 1
                    // Auch wenn die Antwort erst nach dem Schließen ankommt: Gefragt hat die offene Leinwand
                    if startedOpen || openController?.doc.id == id, !foreignWhileOpen.contains(id) {
                        foreignWhileOpen.insert(id)
                    }
                }
                if refetching.contains(id) { refetching.remove(id) }
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
            chunk += 1
            // Die offene Leinwand hat Neues (zuerst das schicken, der Rest folgt im nächsten Abgleich) oder will
            // Seiten ändern. Oder dieser Stand ist überholt, weil die Leinwand inzwischen zu ist bzw. das Dokument
            // offen war: Dann macht gleich ein Abgleich seiner Datei weiter
            if next < adds.count {
                let canvasNow = openController?.doc.id == id ? openController : nil
                let stop = canvasNow.map { $0.hasUnsyncedLocalChanges || $0.isRestructuring }
                    ?? (startedOpen || openings[id, default: 0] != openedBefore)
                if stop {
                    noteWaiting(from: next)
                    if canvasNow == nil { Task { [weak self] in await self?.syncClosed(id) } }
                    return true
                }
            }
        } while next < adds.count
        // Alles oben: Das große Hochladen ist fertig (ein bloßes Holen ändert daran nichts, und ein inzwischen neu
        // begonnenes, etwa nach einer weiteren Seitenänderung, bleibt)
        if snapshot != nil, bulks[id]?.generation == generation { bulks[id] = nil }
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
        let state = self.state(id)
        var rekeyed = false
        let applied = StrokeCodec.apply(changes, to: drawing, pruning: openController == nil ? .closed : .never,
                                        aliases: &state.aliases, rekeyed: &rekeyed)
        if rekeyed {
            rekeyedClosed.insert(id)
            // Bis ein Durchgang mit den neuen IDs gelingt, gilt die Datei als nicht abgeglichen: Schritt 4 holt ihn
            // nach, auch nach einem Fehler oder Neustart (der Stand geht gleich mit auf die Platte)
            state.syncedModified = 0
        }
        if let merged = applied?.drawing {
            let target = pageTargets[id]
            let pages = PageLayout.pagesNeeded(for: merged, kind: doc.kind, current: target ?? doc.pageCount)
            if let target, pages <= target { pageTargets[id] = nil }
            store.saveDrawing(merged, for: id, pageCount: pages, touch: false)
        }
    }

    /// Abgleich eines Dokuments, das gerade nicht offen ist: Zeichnung von der Platte
    func syncClosed(_ id: UUID) async {
        let passes = closedPasses[id, default: 0]
        // Eben geschlossen: Läuft noch ein Abgleich der Leinwand, dessen Ende abwarten. Läuft danach immer noch einer
        // (etwa der Rest eines großen Hochladens, der schon mit der Datei weitermacht), bleibt es bei ihm; ebenso,
        // wenn inzwischen einer fertig wurde (er begann nach diesem Aufruf, hat also schon alles)
        for _ in 0..<100 where busy.contains(id) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Inzwischen wieder geöffnet: Dann gleicht die Leinwand ab, nicht die (ältere) Datei
        guard !busy.contains(id), closedPasses[id, default: 0] == passes, openController?.doc.id != id,
              let doc = store.documents.first(where: { $0.id == id }) else { return }
        let opened = openings[id, default: 0]
        // Was vorher neu zugeordnet wurde (siehe `rekeyedClosed`), erfasst dieser Durchgang schon unter der neuen ID
        rekeyedClosed.remove(id)
        let snapshot = StrokeSnapshot(store.loadDrawing(doc).strokes, toPage: .identity,
                                      pruning: openController == nil ? .closed : .never, aliases: state(id).aliases)
        guard await syncStrokes(id, snapshot: snapshot) else { return }
        // Währenddessen wieder geöffnet: Das Geholte wartet auf der Leinwand, nicht in der Datei. Den Stand sichert
        // dann die Leinwand, sobald ihre Zeichnung gespeichert ist (sonst wäre er der Datei voraus). War es offen und
        // ist schon wieder zu, fehlt hier, was dort dazukam: Dann gilt der Abgleich nicht als vollständig, und der
        // nächste holt es nach
        guard openController?.doc.id != id, openings[id, default: 0] == opened else { return }
        // Ein geholter Strich war schon da (siehe `rekeyedClosed`): gleich noch ein Durchgang mit den neuen IDs. Bis
        // einer gelingt, gilt der Abgleich nicht als vollständig (siehe `deliver`)
        let rekeyed = rekeyedClosed.remove(id) != nil
        if !rekeyed {
            state(id).syncedModified = store.documents.first(where: { $0.id == id })?.modified
                .timeIntervalSince1970 ?? 0
        }
        closedPasses[id, default: 0] += 1
        persistState(id)
        if rekeyed { await syncClosed(id) }
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
            // 1. Lokal gelöschte Dokumente als Grabstein hochladen, mit dem Zeitpunkt des Löschens (siehe
            //    `pendingDeleteStamps`). Ist der Eintrag am Server neuer, nimmt er ihn nicht an; dann holt Schritt 2 das
            //    Dokument wieder. Über Aufgeräumtes aus temp entscheidet Schritt 2 (siehe `pendingPurgeSeqs`)
            for idString in pendingDeletes where pendingPurgeSeqs[idString] == nil {
                _ = try await tombstone(idString, stamp: pendingDeleteStamps[idString] ?? Date().timeIntervalSince1970)
                pendingDeletes.remove(idString)
                pendingDeleteStamps[idString] = nil
            }

            // 2. Vom Server übernehmen. Was dieses Gerät vor der Abfrage wusste: Was erst währenddessen ankommt, kann
            //    neuer sein als ihr Ergebnis
            var seqBefore: [UUID: Int] = [:]
            for doc in store.documents { seqBefore[doc.id] = state(doc.id).seq }
            let lostBefore = lostAtServer
            let arrivalsBefore = foreignArrivals
            struct Library: Decodable { var docs: [RemoteMeta] }
            let remote = try Self.decoder.decode(Library.self, from: try await request("GET", "/api/library")).docs
            var remoteByID: [UUID: RemoteMeta] = [:]
            for r in remote { remoteByID[r.id] = r }
            remoteSeqs = remoteByID.mapValues { $0.strokeSeq ?? 0 }

            // Aufgeräumtes aus temp: Der Grabstein geht nur hinauf, wenn der Server seitdem nichts Neues hat, weder am
            // Eintrag noch an Strichen (etwa von einem Gast im Browser, was den Eintrag nicht neuer macht). Sonst kommt
            // das Dokument unten wieder, und das Aufräumen entscheidet später neu. Erst nach dieser Abfrage, egal wie
            // lange der Grabstein wartete: Bis zu ihr kann jemand hineingeschrieben haben
            var purgedNow = Set<UUID>()
            for (idString, known) in pendingPurgeSeqs {
                if let id = UUID(uuidString: idString), let r = remoteByID[id], r.deleted != true,
                   let stamp = pendingDeleteStamps[idString],
                   (r.strokeSeq ?? 0) <= known, r.modified.timeIntervalSince1970 <= stamp {
                    let saved = try await tombstone(idString, stamp: stamp)
                    if (try? Self.decoder.decode(RemoteMeta.self, from: saved))?.deleted == true { purgedNow.insert(id) }
                }
                pendingDeletes.remove(idString)
                pendingDeleteStamps[idString] = nil
                pendingPurgeSeqs[idString] = nil
            }

            var markdownWaiting: [RemoteMeta] = []
            for r in remote {
                let local = store.documents.first { $0.id == r.id }
                if r.deleted == true {
                    typesetPDFs[r.id] = nil
                    // Gelöscht: Was Schritt 3 beim Zurückholen vorhatte, entscheidet er neu. Erst während der Abfrage
                    // Vermerktes bleibt: Die Antwort dazu kann einen neueren Eintrag kennen als diese Abfrage
                    if lostAtServer.contains(r.id), lostBefore.contains(r.id) { lostAtServer.remove(r.id) }
                    guard let local else { continue }
                    // Anderswo gelöscht. Hier offen, oder hier seitdem geändert: behalten. Geändert bringt Schritt 3 es
                    // zurück (samt allen Strichen), sonst wird es nach dem Schließen gelöscht
                    let isOpen = openController?.doc.id == r.id
                    let unchanged = local.modified.timeIntervalSince1970 <= r.modified.timeIntervalSince1970 + 0.001
                    // Am Server liegen Striche von nach dem Löschen (alle davor hat der Grabstein gelöscht): Jemand hat
                    // danach noch hineingeschrieben, etwa ein Gast im Browser (das macht den Eintrag nicht neuer). Es gilt
                    // als hier geändert und kommt zurück, wenn es hier offen ist und diese Striche noch nicht geholt hat
                    // (läuft gerade ein Abgleich der Leinwand, entscheidet seine Antwort mit). Ebenso, wenn hier seit
                    // dem letzten Abgleich, der es gültig sah, fremde Striche ankamen und es hier offen ist, dabei offen
                    // war, oder dieses Gerät alle Striche danach schon hat. Sonst nicht: Es können späte Striche des
                    // löschenden Geräts sein, oder eigene, etwa der Rest eines Hochladens aller Striche, das ein
                    // erneutes Löschen überholt hat
                    let after = r.strokeSeq ?? 0
                    var back = false
                    if unchanged, after > 0 {
                        let seen = state(r.id).seq
                        back = (isOpen && !busy.contains(r.id) && seen < after)
                            || (foreignSince.contains(r.id) && (isOpen || foreignWhileOpen.contains(r.id) || seen >= after))
                    }
                    if back {
                        var touched = local
                        touched.modified = max(Date(), r.modified.addingTimeInterval(0.01))
                        store.save(touched)
                    } else if unchanged, !isOpen, !busy.contains(r.id), !store.isWriting(r.id),
                              foreignArrivals[r.id] == arrivalsBefore[r.id] {
                        // (Läuft gerade ein Abgleich seiner Striche, etwa der eben geschlossenen Leinwand, oder kamen
                        // während der Abfrage fremde Striche an, entscheidet der nächste Abgleich, mit frischer Abfrage.
                        // Ebenso, solange die Zeichnung noch geschrieben wird: Wurde kurz vor dem Schließen noch
                        // geschrieben, zeigt `modified` das erst danach)
                        states[r.id] = nil
                        bulks[r.id] = nil
                        pageTargets[r.id] = nil
                        if resend.contains(r.id) { resend.remove(r.id) }
                        if lostAtServer.contains(r.id) { lostAtServer.remove(r.id) }
                        if foreignSince.contains(r.id) { foreignSince.remove(r.id) }
                        if foreignWhileOpen.contains(r.id) { foreignWhileOpen.remove(r.id) }
                        if refetching.contains(r.id) { refetching.remove(r.id) }
                        store.delete(local)
                    }
                    continue
                }
                // Gültig: Fremdes von davor zählt nicht mehr. Kam erst während der Abfrage etwas an, bleibt es vermerkt,
                // denn es kann nach einem Grabstein geschrieben sein, den sie noch nicht zeigt
                if foreignArrivals[r.id] == arrivalsBefore[r.id] {
                    if foreignSince.contains(r.id) { foreignSince.remove(r.id) }
                    if foreignWhileOpen.contains(r.id) { foreignWhileOpen.remove(r.id) }
                }
                if lostAtServer.contains(r.id), lostBefore.contains(r.id) {
                    // Gilt wieder, nachdem der Server die Striche gelöscht hat: zurückgeholt (nur die Antwort ging
                    // verloren), oder ein Eintrag hat den Grabstein ersetzt. Nur was schon vor der Abfrage vermerkt war:
                    // Die Antwort zu später Vermerktem kann einen Grabstein kennen, den diese Abfrage noch nicht zeigt
                    lostAtServer.remove(r.id)
                    if local != nil { resendAll(r.id) }
                } else if local != nil, openController?.doc.id != r.id, let known = seqBefore[r.id],
                          (r.strokeSeq ?? 0) < known, states[r.id]?.seq == known, !resend.contains(r.id) {
                    // Der Server kennt weniger Striche, als dieses Gerät schon vor der Abfrage geholt hatte: Ein
                    // Grabstein hat sie gelöscht, und ein Eintrag hat ihn ersetzt, ohne dass sie wieder hinaufgingen
                    // (etwa einer, der genau zwischen Abfrage und Hochladen kam). Alle noch einmal hinauf. Hat sich der
                    // Stand hier inzwischen geändert, entscheidet das der nächste Abgleich (sonst ginge alles doppelt)
                    resendAll(r.id)
                }
                if var local {
                    // Ändert die offene Leinwand gerade selbst Seiten, ihr nicht dazwischen das PDF austauschen;
                    // danach ist ihre Seitenänderung die neuere
                    let restructuring = { self.openController?.doc.id == r.id && self.openController?.isRestructuring == true }
                    // Ein neueres PDF zuerst holen. Währenddessen kann sich das Dokument hier ändern (umbenannt,
                    // verschoben, Seiten geändert, gelöscht): Danach zählt sein dann aktueller Stand, sonst ginge
                    // diese Änderung beim Speichern verloren
                    var newPDF: Data?
                    if r.kind == .pdf, r.hasPDF == true, (r.pdfVersion ?? 0) > (local.pdfVersion ?? 0), !restructuring() {
                        newPDF = try await request("GET", "/api/pdf/\(Self.path(r.id))")
                        guard let current = store.documents.first(where: { $0.id == r.id }) else { continue }
                        local = current
                    }
                    var merged = local
                    var changed = false
                    let remotePages = r.pagesVersion ?? 0, localPages = local.pagesVersion ?? 0
                    let busyHere = restructuring()
                    let remoteNewer = r.modified.timeIntervalSince1970 > local.modified.timeIntervalSince1970 + 0.001
                    if remoteNewer {
                        merged.modified = r.modified
                        // Gleicher Seitenstand: Die Seitenzahl wächst nur (Schreiben auf der letzten Seite)
                        if remotePages == localPages { merged.pageCount = max(local.pageCount, r.pageCount) }
                        changed = true
                    }
                    // Name und Ordner: Es gilt, was zuletzt umbenannt bzw. verschoben wurde, auch wenn danach auf einem
                    // anderen Gerät noch ins Dokument geschrieben wurde (das allein macht den Eintrag nur neuer)
                    let title = Self.newer(local: local.title, set: local.titleSet, remote: r.title, remoteSet: r.titleSet,
                                           created: local.created, remoteNewer: remoteNewer)
                    let folder = Self.newer(local: local.folder, set: local.folderSet, remote: r.folder, remoteSet: r.folderSet,
                                            created: local.created, remoteNewer: remoteNewer)
                    if merged.title != title.value { merged.title = title.value; changed = true }
                    if merged.titleSet != title.set { merged.titleSet = title.set; changed = true }
                    if merged.folder != folder.value { merged.folder = folder.value; changed = true }
                    if merged.folderSet != folder.set { merged.folderSet = folder.set; changed = true }
                    if title.ahead || folder.ahead,
                       merged.modified.timeIntervalSince1970 <= r.modified.timeIntervalSince1970 + 0.001 {
                        // Hier liegt der neuere Name oder Ordner, der Server hat (etwa nach dem Schreiben auf einem
                        // anderen Gerät) einen neueren Eintrag mit dem alten: knapp neuer machen, dann lädt Schritt 3
                        // ihn hoch und der Server nimmt ihn an
                        merged.modified = max(merged.modified, r.modified).addingTimeInterval(0.01)
                        changed = true
                    }
                    // Seitenzahl und PDF folgen der neuesten Seitenänderung, unabhängig vom übrigen Stand:
                    // Ein Gerät, das nur fremde Striche übernommen hat, ist dadurch nicht „neuer“
                    var structure = false
                    if remotePages > localPages, !busyHere {
                        merged.pagesVersion = remotePages
                        merged.pageCount = max(r.pageCount, 1)
                        if r.kind == .notebook { pageTargets[r.id] = merged.pageCount }
                        changed = true
                        structure = true
                    }
                    var pdfChanged = false
                    if let newPDF, (r.pdfVersion ?? 0) > (local.pdfVersion ?? 0), !busyHere {
                        try newPDF.write(to: store.pdfURL(r.id), options: .atomic)
                        merged.pdfVersion = r.pdfVersion
                        changed = true
                        pdfChanged = true
                    }
                    if changed { store.save(merged) }
                    if structure || pdfChanged, let c = openController, c.doc.id == r.id {
                        c.remoteStructureChanged(pageCount: merged.pageCount, pdfChanged: pdfChanged)
                    }
                } else {
                    // Hier eben gelöscht (währenddessen; der Grabstein geht beim nächsten Abgleich hinauf) oder eben
                    // aufgeräumt: nicht wieder anlegen und herunterladen
                    if pendingDeletes.contains(r.id.uuidString) || purgedNow.contains(r.id) { continue }
                    // Neu auf diesem Gerät (oder nach dem Löschen wieder da): ohne alten Sync-Stand beginnen, sonst
                    // hielte der Abgleich alle früher bekannten Striche für hier gelöscht. Was das erste Holen bringt,
                    // ist der ganze Stand, nichts Neues von anderen
                    states[r.id] = nil
                    bulks[r.id] = nil
                    pageTargets[r.id] = nil
                    if !refetching.contains(r.id) { refetching.insert(r.id) }
                    try? FileManager.default.removeItem(at: stateURL(r.id))
                    if r.kind == .pdf {
                        guard r.hasPDF == true else {
                            // Markdown aus dem Eingang, das noch kein Gerät gesetzt hat: setzt dieses, neben dem Abgleich
                            if r.source == "md" { markdownWaiting.append(r) }
                            continue
                        }
                        typesetRetry[r.id] = nil
                        let pdf: Data
                        if let mine = typesetPDFs.removeValue(forKey: r.id), (r.pdfVersion ?? 0) == 0 {
                            // Eben hier gesetzt, und am Server liegt genau dieses
                            pdf = mine
                        } else {
                            pdf = try await request("GET", "/api/pdf/\(Self.path(r.id))")
                        }
                        try FileManager.default.createDirectory(at: store.folder(r.id), withIntermediateDirectories: true)
                        try pdf.write(to: store.pdfURL(r.id), options: .atomic)
                    } else {
                        try FileManager.default.createDirectory(at: store.folder(r.id), withIntermediateDirectories: true)
                    }
                    // Striche auf dem Server liegen immer im aktuellen Seitenlayout
                    store.save(NoteDocument(id: r.id, title: r.title, kind: r.kind, created: r.created,
                                            modified: r.modified, pageCount: max(r.pageCount, 1),
                                            layoutVersion: PageLayout.currentVersion, folder: r.folder,
                                            pdfVersion: r.pdfVersion, pagesVersion: r.pagesVersion,
                                            titleSet: r.titleSet, folderSet: r.folderSet))
                }
            }
            for r in markdownWaiting { typeset(r) }

            // 3. Eigene Dokumente hochladen, wenn neu oder neuer, oder wenn hier eine neuere Seitenänderung liegt
            //    (der Server übernimmt die dann auch in einen sonst neueren Stand)
            for id in store.documents.map(\.id) {
                // Der aktuelle Stand: Während der Uploads davor kann sich das Dokument geändert haben (oder ist gelöscht)
                guard let local = store.documents.first(where: { $0.id == id }) else { continue }
                let r = remoteByID[local.id]
                let metaNewer = r == nil || local.modified.timeIntervalSince1970 > r!.modified.timeIntervalSince1970 + 0.001
                // Anderswo gelöscht und hier seitdem nicht geändert (hier noch offen, wird nach dem Schließen gelöscht):
                // nicht hochladen, sonst ginge sein PDF bei jedem Abgleich neu hinauf. Seitdem geändert: zurückbringen
                let revive = r?.deleted == true
                if revive, !metaNewer { continue }
                let pagesNewer = (local.pagesVersion ?? 0) > (r?.pagesVersion ?? 0)
                let pdfNewer = local.kind == .pdf && (r?.hasPDF != true || (local.pdfVersion ?? 0) > (r?.pdfVersion ?? 0))
                if !pdfNewer { pdfUploadPending.remove(local.id) }
                guard metaNewer || pagesNewer || pdfNewer else { continue }
                if pdfNewer {
                    let pdf = try Data(contentsOf: store.pdfURL(local.id))
                    _ = try await request("PUT", "/api/pdf/\(Self.path(local.id))", body: pdf, contentType: "application/pdf")
                }
                // Immer mit den Zeitpunkten für Name und Ordner (nie geändert: der des Anlegens). Daran erkennen die
                // anderen Geräte einen Eintrag dieser App-Version; ohne sie gilt wie bei älteren Apps der neuere Eintrag
                var upload = local
                if upload.titleSet == nil { upload.titleSet = upload.created }
                if upload.folderSet == nil { upload.folderSet = upload.created }
                if revive, !lostAtServer.contains(id) { lostAtServer.insert(id) }
                let saved = try await request("PUT", "/api/library/\(Self.path(local.id))", body: try Self.encoder.encode(upload))
                pdfUploadPending.remove(local.id)
                // Zurück (der Server antwortet mit dem Eintrag, der jetzt gilt). Mit dem Grabstein hat er alle Striche
                // gelöscht: alle noch einmal hinauf. Fremdes von davor geht dabei mit, zählt also nicht mehr als neu
                if revive {
                    lostAtServer.remove(id)
                    if (try? Self.decoder.decode(RemoteMeta.self, from: saved))?.deleted != true {
                        if foreignSince.contains(id) { foreignSince.remove(id) }
                        if foreignWhileOpen.contains(id) { foreignWhileOpen.remove(id) }
                        resendAll(id)
                    }
                }
            }

            // 4. Striche der nicht geöffneten Dokumente
            for local in store.documents where local.id != openController?.doc.id {
                let state = self.state(local.id)
                let remoteSeq = remoteByID[local.id]?.strokeSeq ?? 0
                if remoteSeq > state.seq || local.modified.timeIntervalSince1970 > state.syncedModified + 0.001
                    || resend.contains(local.id) {
                    await syncClosed(local.id)
                }
            }
            lastSync = Date()
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    /// Markdown aus dem Eingang: holen, auf A4-Seiten setzen (MarkdownTypesetter) und das PDF ablegen. Setzen es mehrere
    /// Geräte zugleich, gilt das erste PDF am Server (PUT …?ifMissing=1). Danach holt jedes Gerät das Dokument wie ein
    /// neues PDF, so liegen die Striche überall auf demselben PDF. Ältere Apps übergehen PDF-Dokumente ohne PDF, sehen
    /// es also erst dann
    private func typeset(_ r: RemoteMeta) {
        guard !typesetting.contains(r.id), (typesetRetry[r.id]?.after ?? .distantPast) <= Date() else { return }
        typesetting.insert(r.id)
        Task {
            do {
                let data = try await request("GET", "/api/md/\(Self.path(r.id))")
                let pdf = try await MarkdownTypesetter.pdf(from: try MarkdownTypesetter.text(of: data), title: r.title)
                let answer = try await request("PUT", "/api/pdf/\(Self.path(r.id))?ifMissing=1", body: pdf,
                                               contentType: "application/pdf")
                struct First: Decodable { var ok: Bool? }
                if (try? Self.decoder.decode(First.self, from: answer))?.ok == true { typesetPDFs[r.id] = pdf }
                typesetRetry[r.id] = nil
            } catch {
                // Später noch einmal (etwa ohne Netz), nach 1 Minute, dann immer seltener (höchstens stündlich)
                let failures = (typesetRetry[r.id]?.failures ?? 0) + 1
                typesetRetry[r.id] = (Date().addingTimeInterval(min(60 * pow(2, Double(failures - 1)), 3600)), failures)
                Log.sync.error("Markdown \(r.id.uuidString, privacy: .public) nicht gesetzt: \(error.localizedDescription, privacy: .public)")
                typesetting.remove(r.id)
                return
            }
            typesetting.remove(r.id)
            await syncLibrary()
        }
    }

    /// Lädt einen Grabstein hoch (`stamp`: sein Zeitpunkt, Sekunden seit 1970). Antwort: der Eintrag, der jetzt gilt
    private func tombstone(_ idString: String, stamp: Double) async throws -> Data {
        let tomb: [String: Any] = ["id": idString, "title": "", "kind": "notebook", "deleted": true,
                                   "created": Date().timeIntervalSince1970, "modified": stamp, "pageCount": 0]
        return try await request("PUT", "/api/library/\(idString)", body: try JSONSerialization.data(withJSONObject: tomb))
    }

    /// Das Dokument gilt am Server wieder, nachdem ein Grabstein alle seine Striche gelöscht hat: alle noch einmal
    /// hinauf, von der offenen Leinwand gleich, sonst mit Schritt 4
    private func resendAll(_ id: UUID) {
        resend.insert(id)
        if let canvas = openController, canvas.doc.id == id { canvas.resendAll() }
    }

    /// Name oder Ordner beim Abgleich der Bibliothek. Es gilt der zuletzt vergebene (`set`, fehlt = seit dem Anlegen
    /// nicht geändert), egal wo danach noch geschrieben wurde. Fehlt der Zeitpunkt am Server (Eintrag einer älteren
    /// App), oder sind beide gleich alt, gilt wie bisher der neuere Eintrag (`remoteNewer`).
    /// Ergebnis: der Wert, der hier zu speichernde Zeitpunkt, und ob hier der neuere Stand liegt, den der Server noch nicht hat
    static func newer<T: Equatable>(local: T, set: Date?, remote: T, remoteSet: Date?,
                                    created: Date, remoteNewer: Bool) -> (value: T, set: Date?, ahead: Bool) {
        // Eintrag einer älteren App: wie bisher der neuere Eintrag, der eigene Zeitpunkt bleibt. Wann sie den Wert
        // gesetzt hat, ist nicht bekannt; ihr Eintrag kann auch nur einen alten Wert tragen, weil sie danach (ohne die
        // Umbenennung zu kennen) geschrieben hat. Mit dem Zeitpunkt ihres Eintrags schlüge der die Umbenennung dauerhaft
        guard let remoteSet else { return (remoteNewer ? remote : local, set, false) }
        let mine = (set ?? created).timeIntervalSince1970, theirs = remoteSet.timeIntervalSince1970
        if theirs > mine + 0.001 { return (remote, remoteSet, false) }
        if mine > theirs + 0.001 { return (local, set, local != remote) }
        return (remoteNewer ? remote : local, set, false)
    }

    /// Merkt ein lokal gelöschtes Dokument vor, damit es auch auf den anderen Geräten verschwindet.
    /// - Parameter unchangedSince: beim Aufräumen von temp der Stand des Dokuments (`modified`). Dann geht der
    ///   Grabstein erst nach der nächsten Abfrage hinauf, und nur, wenn seitdem niemand das Dokument geändert oder
    ///   hineingeschrieben hat (siehe Schritt 2)
    func noteDeleted(_ id: UUID, unchangedSince: Date? = nil) {
        // Welche Striche dieses Gerät kannte (nach einem gelungenen Abgleich ist der Stand jedes Dokuments geladen)
        let known = states[id]?.seq ?? 0
        states[id] = nil
        bulks[id] = nil
        pageTargets[id] = nil
        if resend.contains(id) { resend.remove(id) }
        if lostAtServer.contains(id) { lostAtServer.remove(id) }
        if foreignSince.contains(id) { foreignSince.remove(id) }
        if foreignWhileOpen.contains(id) { foreignWhileOpen.remove(id) }
        if refetching.contains(id) { refetching.remove(id) }
        guard isConfigured else { return }
        pendingDeletes.insert(id.uuidString)
        // Knapp danach: Den gleich alten Eintrag am Server ersetzt er, jeden neueren nicht
        pendingDeleteStamps[id.uuidString] = unchangedSince.map { $0.timeIntervalSince1970 + 0.001 }
            ?? Date().timeIntervalSince1970
        pendingPurgeSeqs[id.uuidString] = unchangedSince == nil ? nil : known
    }

    // MARK: Claude fragen

    /// Fragen an Claude und ihre Antworten. Eigene Anfragen, nie Teil des Abgleichs der Striche
    lazy var asks = AskStore(store: store, sync: self)

    /// Alle Fragen eines Dokuments, vollständig bis zur Version `v` des Servers
    struct AskList: Decodable {
        var v: Int
        var asks: [Ask]
    }

    private static func askPath(_ doc: UUID) -> String { "/api/doc/\(path(doc))/asks" }

    func fetchAsks(_ doc: UUID) async throws -> AskList {
        try JSONDecoder().decode(AskList.self, from: try await request("GET", Self.askPath(doc)))
    }

    /// Die Seiten um eine Frage zum Hochladen: Bereich und Seiten (AskContext), das PDF nur bei Tinte auf ihnen
    struct AskPages {
        var info: AskContext
        var pdf: Data?
    }

    /// Neue Frage mit ihren beiden Bildern in einem Aufruf (multipart), dazu die Seiten um sie, wenn es sie gibt (ein
    /// älterer Server übergeht sie); noch einmal hochladen ändert nichts
    func uploadAsk(_ doc: UUID, _ ask: Ask, question: Data, page: Data,
                   context: AskPages? = nil) async throws -> AskList {
        let boundary = "BetterNotes-" + UUID().uuidString
        var body = Data()
        // Bilder mit Dateinamen: Ohne kämen sie am Server als Text an
        func part(_ name: String, filename: String? = nil, type: String? = nil, _ data: Data) {
            var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
            if let filename { head += "; filename=\"\(filename)\"" }
            head += "\r\n"
            if let type { head += "Content-Type: \(type)\r\n" }
            body.append(Data((head + "\r\n").utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        struct Meta: Encodable {
            var anchor: AskAnchor
            var pv: Int
            var effort: String
            var created: Double
            var from: String
            /// Die Seiten um die Frage (AskContext); ohne sie fehlen beide
            var span: [Int]?
            var pages: [Int]?
            /// "write": „Claude schreiben lassen“
            var mode: String?
        }
        let meta = Meta(anchor: ask.anchor, pv: ask.pv, effort: ask.effort, created: ask.created, from: ask.from ?? "",
                        span: context?.info.span, pages: context?.info.pages, mode: ask.mode)
        part("meta", try JSONEncoder().encode(meta))
        // Die Frage als PNG (Lasso) oder JPEG (∞); der Server erkennt die Art ohnehin an den ersten Bytes
        let jpeg = question.starts(with: [0xFF, 0xD8, 0xFF])
        part("question", filename: jpeg ? "question.jpg" : "question.png", type: jpeg ? "image/jpeg" : "image/png",
             question)
        part("page", filename: "page.jpg", type: "image/jpeg", page)
        if let pdf = context?.pdf { part("pages", filename: AskContext.pdfName, type: "application/pdf", pdf) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        let data = try await request("PUT", Self.askPath(doc) + "/" + ask.id, body: body,
                                     contentType: "multipart/form-data; boundary=\(boundary)", background: true)
        return try JSONDecoder().decode(AskList.self, from: data)
    }

    /// Markierung löschen (auf allen Geräten); gibt es sie am Server nicht mehr, ist das auch recht
    func deleteAsk(_ doc: UUID, _ id: String) async throws -> AskList {
        try JSONDecoder().decode(AskList.self, from: try await request("DELETE", Self.askPath(doc) + "/" + id))
    }

    /// Neue Stellen nach Seitenänderungen, für den Seitenstand `pv`. Der Server nimmt sie nur, wenn seine Stelle
    /// nicht schon zu einem neueren Seitenstand gehört
    /// Dazu die Notizen der Fragen von „Claude schreiben lassen“ (ersetzen die bisherigen; ein älterer Server übergeht sie)
    func moveAsks(_ doc: UUID, pv: Int, anchors: [String: AskAnchor],
                  notes: [String: [AskNote]] = [:]) async throws -> AskList {
        struct Body: Encodable {
            var pv: Int
            var anchors: [String: AskAnchor]
            var notes: [String: [AskNote]]?
        }
        let body = try JSONEncoder().encode(Body(pv: pv, anchors: anchors, notes: notes.isEmpty ? nil : notes))
        return try JSONDecoder().decode(AskList.self, from: try await request("PATCH", Self.askPath(doc), body: body))
    }

    // MARK: Briefkasten

    func sendToOutbox(to recipient: String, name: String, data: Data, type: String) async throws {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "seite"
        _ = try await request("PUT", "/api/outbox/\(recipient)/\(safe)", body: data, contentType: type)
    }

    // MARK: Lernwörter

    /// Für den Lernwörter-Modus (LernModel): ein Aufruf an den Server mit Adresse und Schlüssel dieses Geräts
    func lernRequest(_ method: String, _ path: String, body: Data? = nil,
                     contentType: String = "application/json") async throws -> Data {
        try await request(method, path, body: body, contentType: contentType)
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
