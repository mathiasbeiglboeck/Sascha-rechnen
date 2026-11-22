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
    /// Hier gestellt, nie am Server angekommen, und das bleibt so (abgelehnt, Bilder fehlen): Verschieben und Löschen
    /// gehen nur hier
    var failedHere: Bool { v == nil && status != "local" }
    /// Wird angezeigt: nicht gerade gelöscht, ihre Seite nicht gelöscht (hier: `hidden`; auf einem anderen Gerät:
    /// Seite −1 vom Server, bis dort Rückgängig sie zurückbringt oder sie mit der Seite verschwindet)
    var isVisible: Bool { deleting != true && hidden != true && anchor.page >= 0 }
}

/// Die Seiten um eine Frage, wie sie in der App aussehen (mit Handschrift): So versteht Claude auch „oben“ und „wie
/// vorhin“, und es weiß, welche Seiten leer sind. Liegen als pages.json und pages.pdf neben den Bildern der Frage, bis
/// sie oben ist (PageExport.writeContext)
struct AskContext: Codable, Equatable {
    /// Seitenstand und Seite der Frage, als die Seiten entstanden: Rücken die Seiten bis zum Hochladen, passen die
    /// Nummern nicht mehr, dann gehen sie nicht mit
    var pv: Int
    var page: Int
    /// Angesehener Bereich [erste, letzte] und die Seiten darin mit Tinte außer der Seite der Frage (ab 0), je eine
    /// Seite in pages.pdf. Ohne solche Seiten gibt es kein PDF, und Claude erfährt, dass die anderen leer sind
    var span: [Int]
    var pages: [Int]

    static let infoName = "pages.json"
    static let pdfName = "pages.pdf"
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
    /// Dokumente, in denen noch etwas hinauf muss, auch über einen Neustart hinweg: So geht eine Frage auch dann
    /// hinaus, wenn ihr Dokument zu ist (`flushAll`)
    private var pendingDocs = Set((UserDefaults.standard.stringArray(forKey: AskStore.pendingKey) ?? [])
        .compactMap(UUID.init(uuidString:)))
    private static let pendingKey = "askPendingDocs"
    /// Der Server kannte „Claude fragen“ beim letzten Versuch nicht: erst billig nachsehen, bevor wieder Bilder
    /// hinaufgehen
    private var serverTooOld = false
    /// Dokumente, deren letzter Versuch am Netz scheiterte (offline): Klappt der Abgleich der Bibliothek wieder, geht
    /// es gleich weiter statt erst nach der Wartezeit
    private var offline = Set<UUID>()
    /// Neue Fragen, deren Seiten ringsum noch entstehen (`add(_:_:preparing:)`): Bis dahin wartet ihr Hochladen
    private var preparing = Set<String>()

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
        updatePending(doc)
        revisions[doc, default: 0] += 1
    }

    private func updatePending(_ doc: UUID) {
        // Auch mit Fragen, deren Seite eben gelöscht wurde: Endet die App, bevor die Übersicht zu ist, löscht sie der
        // nächste Start (das Laden der Liste macht aus ihnen zu löschende)
        let pending = hasLocalWork(doc) || asks(doc).contains { $0.hidden == true }
        guard pending != pendingDocs.contains(doc) else { return }
        if pending { pendingDocs.insert(doc) } else { pendingDocs.remove(doc) }
        UserDefaults.standard.set(pendingDocs.map(\.uuidString), forKey: Self.pendingKey)
    }

    /// Neue Frage; ihre Bilder liegen schon in `imageFolder(doc, ask.id)`. Mit `preparing` entstehen die Seiten um die
    /// Frage noch: Die Markierung erscheint gleich, hinauf geht die Frage erst nach `prepared` (spätestens nach 30 s,
    /// dann ohne die Seiten)
    func add(_ doc: UUID, _ ask: Ask, preparing: Bool = false) {
        guard preparing else {
            edit(doc) { $0.append(ask) }
            return refresh(doc)
        }
        self.preparing.insert(ask.id)
        edit(doc) { $0.append(ask) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.prepared(doc, ask.id)
        }
    }

    /// Die Seiten um die Frage sind fertig (oder ließen sich nicht machen): Jetzt geht sie hinauf
    func prepared(_ doc: UUID, _ id: String) {
        guard preparing.remove(id) != nil else { return }
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
    /// neue, nil = gelöscht), und gilt für den neuen Seitenstand `pv`. Fällt ihre Seite weg, wird sie unsichtbar
    /// (die anderen Geräte bekommen Seite −1), bis Rückgängig sie zurückbringt oder `dropHidden` sie löscht. Gibt
    /// die IDs der unsichtbar gewordenen zurück. Fragen, die ein anderes Gerät eben so versteckt hat, bleiben, wie sie sind
    func remap(_ doc: UUID, pv: Int, mapping: (Int) -> Int?) -> [String] {
        var hidden: [String] = []
        edit(doc) { list in
            for i in list.indices where list[i].deleting != true && list[i].hidden != true && list[i].anchor.page >= 0 {
                list[i].pv = pv
                guard let j = mapping(list[i].anchor.page) else {
                    list[i].hidden = true
                    // Noch nicht am Server: Sie geht erst hinauf, wenn Rückgängig sie zurückbringt
                    list[i].moved = list[i].v == nil ? nil : true
                    hidden.append(list[i].id)
                    continue
                }
                list[i].anchor.page = max(j, 0)
                list[i].moved = list[i].failedHere ? nil : true
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
                list[i].moved = list[i].failedHere ? nil : true
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

    /// Wartet, bis der laufende Abgleich dieses Dokuments fertig ist, höchstens `seconds` Sekunden (vor einer
    /// Seitenänderung, damit eben anderswo gestellte Fragen mitrücken)
    func waitIdle(_ doc: UUID, upTo seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        // In kleinen Schritten: Meist ist der Abgleich fast gleichzeitig mit dem der Striche fertig, und die
        // Seitenänderung soll danach nicht noch auf einen ganzen Schritt warten
        while running.contains(doc), Date() < end {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Schickt hinauf, was in anderen (auch geschlossenen) Dokumenten noch wartet: aus der Schleife der Bibliothek
    /// und beim Zurückkommen in die App. Ohne Wartendes keine Anfrage. Nach einem Fehler gilt dessen Wartezeit, außer
    /// das Gerät war offline und der Abgleich der Bibliothek klappte eben wieder (`online`)
    func flushAll(online: Bool = false) {
        for doc in pendingDocs where !running.contains(doc) {
            if retries[doc] != nil, !(online && offline.contains(doc)) { continue }
            if hasLocalWork(doc) { refresh(doc) } else { updatePending(doc) }
        }
    }

    private func pass(_ doc: UUID) async {
        // Dokument hier gelöscht: Seine Fragen sind am Server mit ihm weg
        guard store.documents.contains(where: { $0.id == doc }) else { return drop(doc) }
        do {
            if serverTooOld {
                apply(doc, try await sync.fetchAsks(doc))
                serverTooOld = false
            }
            // Scheitert eine neue Frage (etwa ein großes Bild bei schlechtem Netz), kommen Antworten trotzdem herein
            let uploadError = try await flush(doc)
            apply(doc, try await sync.fetchAsks(doc))
            if let uploadError { throw uploadError }
            failures[doc] = nil
            offline.remove(doc)
        } catch {
            let problem = Self.classify(error)
            if case .notConfigured = problem { return }
            if error is URLError { offline.insert(doc) } else { offline.remove(doc) }
            if case .oldServer = problem {
                serverTooOld = true
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
            // Am Mac stauen sich Fragen (aus oder am Nutzungslimit): seltener, jedes Mal gehen die Bilder mit
            case .tooMany: wait = min(120 * pow(2, Double(min(n - 1, 4))), 1800)
            default: wait = min(20 * pow(2, Double(min(n - 1, 4))), 300)
            }
            scheduleRetry(doc, after: wait)
        }
    }

    /// Muss etwas hinauf? (Eine neue Frage, deren Seite eben gelöscht wurde, wartet auf Rückgängig, nicht auf den Server)
    private func hasLocalWork(_ doc: UUID) -> Bool {
        asks(doc).contains {
            ($0.status == "local" && $0.hidden != true) || $0.deleting == true || ($0.moved == true && $0.v != nil)
        }
    }

    private func drop(_ doc: UUID) {
        lists[doc] = nil
        versions[doc] = nil
        failures[doc] = nil
        offline.remove(doc)
        retries[doc]?.cancel()
        retries[doc] = nil
        if pendingDocs.remove(doc) != nil {
            UserDefaults.standard.set(pendingDocs.map(\.uuidString), forKey: Self.pendingKey)
        }
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

    /// Erst Löschen, dann neue Fragen, dann verschobene Stellen. Netzfehler beim Löschen und Verschieben brechen ab
    /// (später noch einmal); scheitert eine neue Frage, geht der Rest trotzdem und ihr Fehler kommt zurück. Was nie
    /// gelingen kann, wird hier als gescheitert vermerkt
    private func flush(_ doc: UUID) async throws -> Error? {
        for ask in asks(doc) where ask.deleting == true {
            // Nie am Server angekommen und gescheitert: Löschen geht nur hier
            if ask.failedHere {
                forget(doc, ask.id)
                continue
            }
            do {
                let list = try await sync.deleteAsk(doc, ask.id)
                forget(doc, ask.id)
                apply(doc, list)
            } catch {
                switch Self.classify(error) {
                // Dokument am Server weg: seine Fragen mit
                case .noDoc: forget(doc, ask.id)
                // Älterer Server: Eine nie hochgeladene Frage ist damit erledigt, eine von ihm bekannte nicht
                case .oldServer where ask.v == nil: forget(doc, ask.id)
                default: throw error
                }
            }
        }

        var uploadError: Error?
        for id in asks(doc).filter({ $0.status == "local" }).map(\.id) {
            // Jedes Mal frisch gelesen: Während eine andere hochging, kann sich diese geändert haben (Seite gelöscht,
            // gelöscht, vom Server schon bekannt). Entstehen ihre Seiten ringsum noch, kommt sie mit `prepared`
            guard uploadError == nil, let ask = self.ask(doc, id), ask.status == "local", ask.deleting != true,
                  ask.hidden != true, !preparing.contains(id) else { continue }
            let folder = imageFolder(doc, ask.id)
            guard let question = questionImage(in: folder),
                  let page = try? Data(contentsOf: folder.appendingPathComponent("page.jpg")) else {
                fail(doc, ask.id, "Die Bilder der Frage fehlen. Bitte noch einmal fragen.")
                continue
            }
            let list: SyncEngine.AskList
            do {
                list = try await upload(doc, ask, question: question, page: page,
                                        context: Self.context(in: folder, for: ask))
            } catch {
                switch Self.classify(error) {
                case .tooMany:
                    note(doc, "Zu viele offene Fragen, diese wartet")
                    uploadError = error
                case .rejected(let message):
                    fail(doc, ask.id, message)
                case .stalePages:
                    // Hier inzwischen mitgerückt (die Seiten änderten sich, während sie hochging): gleich noch einmal
                    // mit der neuen Stelle. Sonst ist die Stelle veraltet
                    if let now = self.ask(doc, ask.id), now.pv > ask.pv {
                        again.insert(doc)
                    } else {
                        fail(doc, ask.id, "Die Seiten haben sich inzwischen geändert. Bitte noch einmal fragen.")
                    }
                default:
                    uploadError = error
                }
                continue
            }
            try? FileManager.default.removeItem(at: folder)
            // Inzwischen auf einem anderen Gerät gelöscht (die Antwort aufs erste Hochladen ging verloren; der Server
            // merkt sich gelöschte Fragen): hier auch weg
            guard let server = list.asks.first(where: { $0.id == ask.id }) else {
                forget(doc, ask.id)
                apply(doc, list)
                continue
            }
            // Steht sie am Server anders als hier (inzwischen verschoben oder ihre Seite gelöscht, oder der Server hatte
            // sie schon von einem früheren Versuch), folgt das Verschieben gleich
            edit(doc) { l in
                guard let i = l.firstIndex(where: { $0.id == ask.id }) else { return }
                let same = server.anchor == l[i].anchor && server.pv == l[i].pv && l[i].hidden != true
                l[i].moved = same ? nil : true
                l[i].localNote = nil
            }
            apply(doc, list)
        }

        // Verschobene Stellen; eine Frage auf einer eben gelöschten Seite bekommt Seite −1 (unsichtbar, bis
        // Rückgängig sie zurückbringt). Ein älterer Server übergeht die −1, dann bleibt es wie bisher
        let moved = asks(doc).filter { $0.moved == true && $0.v != nil && $0.deleting != true }
        for (pv, group) in Dictionary(grouping: moved, by: \.pv) {
            let anchors = Dictionary(group.map { a -> (String, AskAnchor) in
                var anchor = a.anchor
                if a.hidden == true { anchor.page = -1 }
                return (a.id, anchor)
            }, uniquingKeysWith: { a, _ in a })
            let list = try await sync.moveAsks(doc, pv: pv, anchors: anchors)
            edit(doc) { l in
                for a in group {
                    guard let i = l.firstIndex(where: { $0.id == a.id }), l[i].anchor == a.anchor, l[i].pv == a.pv,
                          l[i].hidden == a.hidden
                    else { continue }
                    l[i].moved = nil
                }
            }
            apply(doc, list)
        }
        return uploadError
    }

    /// Das Bild der Frage: question.png (mit dem Lasso markiert: nur die Striche) oder question.jpg (∞: die Stelle samt
    /// Hintergrund der Seite)
    private func questionImage(in folder: URL) -> Data? {
        for name in ["question.png", "question.jpg"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { return data }
        }
        return nil
    }

    /// Die Seiten um die Frage (pages.json, bei Tinte daneben auch pages.pdf), wenn sie noch zu ihrer Stelle passen:
    /// Rückten die Seiten seither, stimmen ihre Nummern nicht mehr, dann geht die Frage ohne sie
    private static func context(in folder: URL, for ask: Ask) -> SyncEngine.AskPages? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(AskContext.infoName)),
              let info = try? JSONDecoder().decode(AskContext.self, from: data),
              info.pv == ask.pv, info.page == ask.anchor.page, info.span.count == 2 else { return nil }
        guard !info.pages.isEmpty else { return SyncEngine.AskPages(info: info, pdf: nil) }
        guard let pdf = try? Data(contentsOf: folder.appendingPathComponent(AskContext.pdfName)) else { return nil }
        return SyncEngine.AskPages(info: info, pdf: pdf)
    }

    /// Eine neue Frage hinauf; ist ihr Dokument noch nicht am Server, erst die Bibliothek abgleichen
    private func upload(_ doc: UUID, _ ask: Ask, question: Data, page: Data,
                        context: SyncEngine.AskPages?) async throws -> SyncEngine.AskList {
        do {
            return try await sync.uploadAsk(doc, ask, question: question, page: page, context: context)
        } catch {
            guard case .noDoc = Self.classify(error) else { throw error }
            await sync.syncLibrary()
            return try await sync.uploadAsk(doc, ask, question: question, page: page, context: context)
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
                // Hier noch nicht hochgeladen, am Server aber schon (die Antwort aufs Hochladen ging verloren): Die
                // Bilder braucht es nicht mehr
                if l.status == "local" { forgetImages(doc, l.id) }
                if l.moved == true || l.hidden == true {
                    r.anchor = l.anchor
                    r.pv = l.pv
                    r.hidden = l.hidden
                    // Wurde sie hier verschoben oder ihre Seite gelöscht, bevor sie oben war, geht die Stelle gleich
                    // hinauf (gelöschte Seite: −1)
                    r.moved = l.status == "local" ? true : l.moved
                }
            }
            merged.append(r)
        }
        for l in local where !remoteIDs.contains(l.id) {
            // Hier gestellt und nie am Server angekommen (wartet oder scheiterte): bleibt, bis sie oben ist oder
            // gelöscht wird. Was der Server kannte und nicht mehr liefert, ist anderswo gelöscht
            if l.v == nil, l.deleting != true {
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
        /// Kann so nie gelingen (Bild zu groß, ungültig); mit dem Text für die Karte
        case rejected(String)
        /// Gefragt auf einem älteren Seitenstand, als der Server kennt: Die Stelle stimmt nicht mehr
        case stalePages
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
            case (429, .some("too-many")): return .tooMany
            case (409, .some("stale-pages")): return .stalePages
            // Nur begründete Ablehnungen sind endgültig; ein 400 ohne Kennung ist ein Fehler am Server (etwa sein
            // Tageslimit) und geht später noch einmal
            case (400, .some), (413, _):
                return .rejected("Der Server nimmt die Frage nicht an: \(parsed?.error ?? "Fehler \(status)")")
            default: return .transient
            }
        }
    }
}
