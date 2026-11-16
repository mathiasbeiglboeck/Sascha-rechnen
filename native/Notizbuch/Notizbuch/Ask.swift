import Foundation

/// Stelle einer Frage: Seite (ab 0) und Rechteck der Frage auf dieser Seite, in Seitenpunkten (Seite 768 breit,
/// Ursprung oben links). So speichert sie auch der Server
struct AskAnchor: Codable, Equatable {
    var page: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Eine Frage an Claude, wie der Server sie liefert, dazu, was nur dieses Gerät über sie weiß.
///
/// Ablauf: local (nur hier, noch nicht am Server) → open (wartet auf den Mac) → claimed (der Mac arbeitet daran) →
/// answered oder failed. Am Nutzungslimit gibt der Mac sie zurück (wieder open, mit `note`).
struct Ask: Codable, Identifiable, Equatable {
    var id: String
    var status: String
    var anchor: AskAnchor
    /// Seitenstand des Dokuments (pagesVersion), auf den sich `anchor` bezieht
    var pv: Int
    /// "quick" oder "thorough"
    var effort: String
    /// Sekunden seit 1970
    var created: Double
    var updated: Double?
    /// Die Antwort in Markdown, Formeln in LaTeX
    var answer: String?
    /// Fehler (failed) oder warum sie noch wartet (etwa am Nutzungslimit)
    var note: String?
    /// Gerät, auf dem gefragt wurde
    var from: String?
    var v: Int?

    // Nur auf diesem Gerät
    /// Die Antwort wurde hier schon angesehen
    var seen: Bool?
    /// Wird gelöscht, der Server weiß es noch nicht
    var deleting: Bool?
    /// Stelle hier verschoben (Seiten gelöscht oder eingefügt), der Server weiß es noch nicht
    var moved: Bool?
    /// Ihre Seite wurde gelöscht: unsichtbar, bis die Seitenübersicht zu ist (Rückgängig bringt sie zurück)
    var hidden: Bool?
    /// Warum sie noch nicht hochging (etwa „Server-Update nötig“)
    var localNote: String?

    var isAnswered: Bool { status == "answered" }
    var isFailed: Bool { status == "failed" }
    var isWaiting: Bool { !isAnswered && !isFailed }
    var isThorough: Bool { effort == "thorough" }
    /// Wird angezeigt (nicht gerade gelöscht, ihre Seite nicht gelöscht)
    var isVisible: Bool { deleting != true && hidden != true }
}

/// Fragen an Claude je Dokument: Zwischenspeicher in <Dokument>/asks.json, Abgleich mit dem Server.
///
/// Läuft ganz neben dem Abgleich der Striche: eigene Anfragen, nie in dessen Takt. Der Server bestimmt, welche
/// Fragen es gibt und was mit ihnen ist; was hier noch nicht oben ist (neue Fragen, Löschen, verschobene Stellen),
/// geht bei jedem Abgleich zuerst hinauf. Die Bilder einer neuen Frage liegen bis zum Hochladen in
/// <Dokument>/asks/<id>/.
@MainActor
final class AskStore: ObservableObject {
    /// Steigt je Dokument mit jeder Änderung seiner Fragen; die offene Leinwand zeichnet dann ihre Markierungen neu
    @Published private(set) var revisions: [UUID: Int] = [:]

    private let store: DocumentStore
    private unowned let sync: SyncEngine
    private var lists: [UUID: [Ask]] = [:]
    /// Version des Servers (über alle Dokumente), bis zu der die Liste vollständig ist
    private var versions: [UUID: Int] = [:]
    private var running = Set<UUID>()
    private var again = Set<UUID>()
    private var retries: [UUID: Task<Void, Never>] = [:]
    /// Fehlversuche in Folge je Dokument (für die Wartezeit bis zum nächsten)
    private var failures: [UUID: Int] = [:]

    init(store: DocumentStore, sync: SyncEngine) {
        self.store = store
        self.sync = sync
    }

    private struct File: Codable {
        var v: Int
        var asks: [Ask]
    }

    private func fileURL(_ doc: UUID) -> URL { store.folder(doc).appendingPathComponent("asks.json") }

    /// Bilder einer neuen Frage, bis sie am Server ist
    func imageFolder(_ doc: UUID, _ id: String) -> URL {
        store.folder(doc).appendingPathComponent("asks", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    // MARK: Lesen

    func asks(_ doc: UUID) -> [Ask] {
        if let list = lists[doc] { return list }
        var list: [Ask] = []
        var v = 0
        if let data = try? Data(contentsOf: fileURL(doc)), let file = try? JSONDecoder().decode(File.self, from: data) {
            list = file.asks
            v = file.v
        }
        // Seite gelöscht in einer früheren Sitzung: Rückgängig gibt es nicht mehr, die Frage geht mit ihrer Seite
        for i in list.indices where list[i].hidden == true {
            list[i].hidden = nil
            list[i].deleting = true
        }
        lists[doc] = list
        versions[doc] = v
        return list
    }

    func ask(_ doc: UUID, _ id: String) -> Ask? { asks(doc).first { $0.id == id } }

    // MARK: Ändern

    private func edit(_ doc: UUID, _ change: (inout [Ask]) -> Void) {
        var list = asks(doc)
        let before = list
        change(&list)
        guard list != before else { return }
        save(doc, list)
    }

    private func save(_ doc: UUID, _ list: [Ask]) {
        // Erst der Speicher, dann die Revision: Wer auf sie hört, liest gleich die neue Liste
        lists[doc] = list
        let data = try? JSONEncoder().encode(File(v: versions[doc] ?? 0, asks: list))
        store.enqueueWrite(to: fileURL(doc)) { data }
        revisions[doc, default: 0] += 1
    }

    /// Neue Frage; ihre Bilder liegen schon in `imageFolder(doc, ask.id)`
    func add(_ doc: UUID, _ ask: Ask) {
        edit(doc) { $0.append(ask) }
        refresh(doc)
    }

    /// Markierung löschen, auf allen Geräten (eine noch wartende Frage wird damit zurückgezogen)
    func delete(_ doc: UUID, _ id: String) {
        edit(doc) { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].deleting = true
        }
        refresh(doc)
    }

    func markSeen(_ doc: UUID, _ id: String) {
        edit(doc) { list in
            guard let i = list.firstIndex(where: { $0.id == id }), list[i].isAnswered, list[i].seen != true else { return }
            list[i].seen = true
        }
    }

    /// Seiten gelöscht oder eingefügt: Jede Frage rückt mit ihrer Seite, wie die Striche (`mapping`: alte Seite →
    /// neue, nil = gelöscht), und gilt für den neuen Seitenstand `pv`. Fällt ihre Seite weg, wird sie unsichtbar,
    /// bis Rückgängig sie zurückbringt oder `dropHidden` sie löscht. Gibt die IDs der unsichtbar gewordenen zurück
    func remap(_ doc: UUID, pv: Int, mapping: (Int) -> Int?) -> [String] {
        var hidden: [String] = []
        edit(doc) { list in
            for i in list.indices where list[i].deleting != true && list[i].hidden != true {
                guard let j = mapping(list[i].anchor.page) else {
                    list[i].hidden = true
                    hidden.append(list[i].id)
                    continue
                }
                list[i].anchor.page = max(j, 0)
                list[i].pv = pv
                list[i].moved = true
            }
        }
        refresh(doc)
        return hidden
    }

    /// Rückgängig einer Seitenänderung: Die unsichtbaren Fragen kommen an ihre alte Stelle zurück (ihre Seite ist
    /// wieder da, mit der alten Nummer)
    func unhide(_ doc: UUID, _ ids: [String], pv: Int) {
        guard !ids.isEmpty else { return }
        edit(doc) { list in
            for i in list.indices where ids.contains(list[i].id) && list[i].hidden == true {
                list[i].hidden = nil
                list[i].pv = pv
                list[i].moved = true
            }
        }
        refresh(doc)
    }

    /// Kein Rückgängig mehr (Übersicht zu, nächste Seitenänderung): Fragen auf gelöschten Seiten endgültig löschen
    func dropHidden(_ doc: UUID, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        edit(doc) { list in
            for i in list.indices where ids.contains(list[i].id) && list[i].hidden == true {
                list[i].hidden = nil
                list[i].deleting = true
            }
        }
        refresh(doc)
    }

    // MARK: Abgleich

    /// Hinweis des Servers: Fragen dieses Dokuments haben sich geändert (Version `v`)
    func hint(_ doc: UUID, v: Int?) {
        _ = asks(doc)
        if let v, v <= versions[doc] ?? 0 { return }
        refresh(doc)
    }

    /// Schickt hinauf, was hier neu ist, und holt die Liste vom Server. Läuft schon ein Abgleich dieses Dokuments,
    /// folgt gleich danach noch einer
    func refresh(_ doc: UUID) {
        guard sync.isConfigured else { return }
        _ = asks(doc)
        if running.contains(doc) {
            again.insert(doc)
            return
        }
        running.insert(doc)
        retries[doc]?.cancel()
        retries[doc] = nil
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.again.remove(doc)
                await self.pass(doc)
            } while self.again.contains(doc)
            self.running.remove(doc)
        }
    }

    /// Wie `refresh`, wartet aber auf das Ende, höchstens `seconds` Sekunden (etwa vor einer Seitenänderung, damit
    /// eben anderswo gestellte Fragen mitrücken)
    func refreshAndWait(_ doc: UUID, upTo seconds: Double) async {
        guard sync.isConfigured else { return }
        refresh(doc)
        let end = Date().addingTimeInterval(seconds)
        while running.contains(doc), Date() < end {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func pass(_ doc: UUID) async {
        do {
            try await flush(doc)
            apply(doc, try await sync.fetchAsks(doc))
            failures[doc] = nil
        } catch {
            let problem = Self.classify(error)
            if case .notConfigured = problem { return }
            if case .oldServer = problem {
                note(doc, "Server-Update nötig")
            }
            // Später noch einmal, solange etwas hinauf muss oder das Dokument offen ist (bei der offenen Leinwand
            // holt sonst erst der nächste Hinweis des Servers): 20 s, dann länger, höchstens alle 5 Minuten
            let n = (failures[doc] ?? 0) + 1
            failures[doc] = n
            let open = sync.openController?.doc.id == doc
            guard hasLocalWork(doc) || open else { return }
            let wait: Double
            switch problem {
            case .oldServer: wait = 300
            case .tooMany: wait = 120
            default: wait = min(20 * pow(2, Double(min(n - 1, 4))), 300)
            }
            scheduleRetry(doc, after: wait)
        }
    }

    private func hasLocalWork(_ doc: UUID) -> Bool {
        asks(doc).contains { $0.status == "local" || $0.deleting == true || $0.moved == true }
    }

    private func scheduleRetry(_ doc: UUID, after seconds: Double) {
        retries[doc]?.cancel()
        retries[doc] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.retries[doc] = nil
            self.refresh(doc)
        }
    }

    /// Hinweis an allen noch nicht hochgeladenen Fragen (die Karte zeigt ihn)
    private func note(_ doc: UUID, _ text: String?) {
        edit(doc) { list in
            for i in list.indices where list[i].status == "local" { list[i].localNote = text }
        }
    }

    /// Erst Löschen, dann neue Fragen, dann verschobene Stellen. Netzfehler brechen ab (später noch einmal),
    /// was nie gelingen kann, wird hier als gescheitert vermerkt
    private func flush(_ doc: UUID) async throws {
        for ask in asks(doc) where ask.deleting == true {
            do {
                let list = try await sync.deleteAsk(doc, ask.id)
                forget(doc, ask.id)
                apply(doc, list)
            } catch {
                // Älterer Server oder Dokument dort weg: Eine nie hochgeladene Frage ist damit erledigt
                switch Self.classify(error) {
                case .oldServer, .noDoc: forget(doc, ask.id)
                default: throw error
                }
            }
        }

        for ask in asks(doc) where ask.status == "local" && ask.deleting != true && ask.hidden != true {
            let folder = imageFolder(doc, ask.id)
            guard let question = try? Data(contentsOf: folder.appendingPathComponent("question.png")),
                  let page = try? Data(contentsOf: folder.appendingPathComponent("page.jpg")) else {
                fail(doc, ask.id, "Die Bilder der Frage fehlen. Bitte noch einmal fragen.")
                continue
            }
            let list: SyncEngine.AskList
            do {
                list = try await sync.uploadAsk(doc, ask, question: question, page: page)
            } catch {
                switch Self.classify(error) {
                case .noDoc:
                    // Neues Dokument, noch nicht am Server: erst die Bibliothek abgleichen, dann noch einmal
                    await sync.syncLibrary()
                    list = try await sync.uploadAsk(doc, ask, question: question, page: page)
                case .tooMany:
                    note(doc, "Zu viele offene Fragen, diese wartet")
                    throw error
                case .rejected(let message):
                    fail(doc, ask.id, "Der Server nimmt die Frage nicht an: \(message)")
                    continue
                default:
                    throw error
                }
            }
            try? FileManager.default.removeItem(at: folder)
            // Inzwischen verschoben (Seiten geändert, während sie hochging): Das Verschieben folgt gleich
            edit(doc) { l in
                guard let i = l.firstIndex(where: { $0.id == ask.id }) else { return }
                if l[i].anchor == ask.anchor, l[i].pv == ask.pv { l[i].moved = nil }
                l[i].localNote = nil
            }
            apply(doc, list)
        }

        let moved = asks(doc).filter {
            $0.moved == true && $0.status != "local" && $0.deleting != true && $0.hidden != true
        }
        for (pv, group) in Dictionary(grouping: moved, by: \.pv) {
            let anchors = Dictionary(group.map { ($0.id, $0.anchor) }, uniquingKeysWith: { a, _ in a })
            let list = try await sync.moveAsks(doc, pv: pv, anchors: anchors)
            edit(doc) { l in
                for a in group {
                    guard let i = l.firstIndex(where: { $0.id == a.id }), l[i].anchor == a.anchor, l[i].pv == a.pv
                    else { continue }
                    l[i].moved = nil
                }
            }
            apply(doc, list)
        }
    }

    /// Übernimmt die Liste des Servers. Er bestimmt, welche Fragen es gibt und was mit ihnen ist; von hier bleiben
    /// noch nicht hochgeladene Fragen, ausstehendes Löschen, verschobene Stellen und was schon gelesen ist
    private func apply(_ doc: UUID, _ remote: SyncEngine.AskList) {
        let local = asks(doc)
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteIDs = Set(remote.asks.map(\.id))
        var merged: [Ask] = []
        for var r in remote.asks {
            if let l = mine[r.id] {
                if l.deleting == true {
                    merged.append(l)
                    continue
                }
                // Gelesen bleibt gelesen, solange die Antwort dieselbe ist
                if r.isAnswered, l.isAnswered, l.answer == r.answer { r.seen = l.seen }
                if l.moved == true || l.hidden == true {
                    r.anchor = l.anchor
                    r.pv = l.pv
                    r.moved = l.moved
                    r.hidden = l.hidden
                }
            }
            merged.append(r)
        }
        for l in local where !remoteIDs.contains(l.id) {
            if l.status == "local", l.deleting != true {
                merged.append(l)
            } else {
                forgetImages(doc, l.id)
            }
        }
        merged.sort { $0.created < $1.created }
        versions[doc] = remote.v
        if merged == local {
            // Nur die Version ist neu: trotzdem sichern, damit ein späterer Hinweis mit ihr nichts mehr holt
            let data = try? JSONEncoder().encode(File(v: remote.v, asks: merged))
            store.enqueueWrite(to: fileURL(doc)) { data }
            return
        }
        save(doc, merged)
    }

    /// Eine Frage ist am Server erledigt (gelöscht): hier auch weg
    private func forget(_ doc: UUID, _ id: String) {
        edit(doc) { $0.removeAll { $0.id == id } }
        forgetImages(doc, id)
    }

    private func forgetImages(_ doc: UUID, _ id: String) {
        let folder = imageFolder(doc, id)
        if FileManager.default.fileExists(atPath: folder.path) { try? FileManager.default.removeItem(at: folder) }
    }

    /// Eine noch nicht hochgeladene Frage kann nie hinauf: als gescheitert zeigen (löschen geht wie sonst)
    private func fail(_ doc: UUID, _ id: String, _ message: String) {
        edit(doc) { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].status = "failed"
            list[i].note = message
            list[i].localNote = nil
        }
        forgetImages(doc, id)
    }

    // MARK: Fehler

    private enum Problem {
        case notConfigured
        /// Server ohne „Claude fragen“ (404 ohne Kennung)
        case oldServer
        /// Dokument (noch) nicht am Server
        case noDoc
        case tooMany
        /// Kann so nie gelingen (Bild zu groß, ungültig)
        case rejected(String)
        /// Netz, Server gerade nicht erreichbar, falscher Schlüssel …: später noch einmal
        case transient
    }

    private static func classify(_ error: Error) -> Problem {
        guard let sync = error as? SyncError else { return .transient }
        switch sync {
        case .notConfigured:
            return .notConfigured
        case .http(let status, let body):
            struct Body: Decodable { var error: String?; var code: String? }
            let parsed = try? JSONDecoder().decode(Body.self, from: Data(body.utf8))
            switch (status, parsed?.code) {
            case (404, .some("no-doc")): return .noDoc
            case (404, .none): return .oldServer
            case (429, _): return .tooMany
            case (400, _), (413, _): return .rejected(parsed?.error ?? "Fehler \(status)")
            default: return .transient
            }
        }
    }
}
