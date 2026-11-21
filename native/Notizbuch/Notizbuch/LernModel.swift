import AVFoundation
import PencilKit
import SwiftUI

// Lernwörter für Sascha: Die App spricht ein Wort vor, er schreibt es, der Helfer am Mac liest es („Claude fragen“ mit
// der Art "lernwort"), Sascha bestätigt das Gelesene oder schreibt nochmal, dann kommt „Richtig!“ oder ein Hinweis auf
// die Rechtschreibregel und ein zweiter Versuch.
//
// Wortliste und Protokoll liegen am Server (/api/lernen): Claude legt die Wörter ab, jedes Gerät hängt seine Versuche an.
// Wann ein Wort wieder dran ist, rechnet jedes Gerät selbst aus dem ganzen Protokoll (Lernkartei mit fünf Fächern).

struct LernWort: Codable, Hashable, Identifiable {
    var wort: String
    var satz: String?
    var added: Double
    var removed: Double?
    var id: String { wort }
}

/// Ein Versuch. ergebnis: "richtig" (gleich beim ersten Mal), "zweiter" (nach dem Hinweis, halb richtig), "falsch"
struct LernEvent: Codable, Hashable {
    var id: String
    var wort: String
    var t: Double
    var ergebnis: String
    var gelesen: [String]?
    /// Wiederholung in derselben Runde: zählt nicht fürs Fach (außer falsch)
    var wdh: Bool?
    /// Selbst geprüft (der Mac hat nicht geantwortet)
    var selbst: Bool?
    var from: String?
    var seq: Int?
}

/// Was der Mac gelesen hat
struct LernAntwort: Decodable, Equatable {
    var gelesen: String
    var richtig: Bool?
    var hinweis: String?
    var unleserlich: Bool?
}

/// Lernkartei: Fach 0 = neu, 1 bis 5. Wann ein Wort im Fach wieder dran ist (Tage nach dem letzten Mal)
enum Lernkartei {
    static let tage = [0, 0, 1, 3, 7, 14]

    struct Karte: Equatable {
        var fach = 0
        var zuletzt: Double?
        var versuche = 0
        var richtig = 0
    }

    /// Richtig beim ersten Mal: ein Fach höher (ein neues Wort gleich ins zweite). Nach dem Hinweis richtig: halb
    /// richtig, bleibt im Fach (ein neues ins erste). Falsch: zurück ins erste Fach. „Nochmal probieren“ am Ende einer
    /// Runde (wdh) zählt nur, wenn es falsch ist
    static func karten(_ log: [LernEvent]) -> [String: Karte] {
        var k: [String: Karte] = [:]
        for e in log.sorted(by: { $0.t < $1.t }) {
            var c = k[e.wort] ?? Karte()
            c.versuche += 1
            if e.ergebnis == "richtig" { c.richtig += 1 }
            if e.wdh == true {
                if e.ergebnis == "falsch" { c.fach = 1 }
            } else {
                switch e.ergebnis {
                case "richtig": c.fach = c.fach == 0 ? 2 : min(c.fach + 1, 5)
                case "zweiter": c.fach = max(c.fach, 1)
                default: c.fach = 1
                }
            }
            c.zuletzt = e.t
            k[e.wort] = c
        }
        return k
    }

    /// Tag, an dem das Wort wieder dran ist (neu: heute)
    static func faellig(_ c: Karte, calendar: Calendar = .current) -> Date {
        guard c.fach > 0, let t = c.zuletzt else { return .distantPast }
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: t))
        return calendar.date(byAdding: .day, value: tage[c.fach], to: day) ?? day
    }

    /// Wörter für eine Runde: zuerst die fälligen (niedrigstes Fach zuerst, das am längsten nicht geübte zuerst), dann
    /// neue in der Reihenfolge der Liste. `extra`: auch noch nicht fällige (wenn heute nichts dran ist)
    static func runde(_ words: [LernWort], _ log: [LernEvent], size: Int = 10, extra: Bool = false,
                      now: Date = Date(), calendar: Calendar = .current) -> [LernWort] {
        let k = karten(log)
        let aktiv = words.filter { $0.removed == nil }
        let today = calendar.startOfDay(for: now)
        let alt = aktiv.filter { (k[$0.wort]?.fach ?? 0) > 0 }
        let dran = alt.filter { faellig(k[$0.wort]!, calendar: calendar) <= today }
            .sorted { a, b in
                let x = k[a.wort]!, y = k[b.wort]!
                return x.fach != y.fach ? x.fach < y.fach : (x.zuletzt ?? 0) < (y.zuletzt ?? 0)
            }
        let neu = aktiv.filter { (k[$0.wort]?.fach ?? 0) == 0 }
        var out = Array((dran + neu).prefix(size))
        if extra && out.count < size {
            let rest = alt.filter { w in !out.contains(w) }
                .sorted { faellig(k[$0.wort]!, calendar: calendar) < faellig(k[$1.wort]!, calendar: calendar) }
            out += rest.prefix(size - out.count)
        }
        return out
    }

    static func anzahlDran(_ words: [LernWort], _ log: [LernEvent]) -> Int { runde(words, log, size: 10_000).count }
}

/// Vergleich wie am Mac: Unicode zusammengesetzt, Leerraum zusammengefasst, Groß- und Kleinschreibung zählt
func lernNorm(_ s: String) -> String {
    s.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

// MARK: - Sprechen

/// Spricht Wörter und Rückmeldungen mit der iPad-Stimme (österreichisch, wenn installiert, sonst deutsch; die beste
/// vorhandene Qualität). Geht ohne Netz
@MainActor
final class Sprecher: NSObject, ObservableObject {
    private let synth = AVSpeechSynthesizer()
    @Published private(set) var voice: AVSpeechSynthesisVoice?
    private static let key = "lernStimme"

    override init() {
        super.init()
        voice = Self.gewaehlt() ?? Self.beste()
    }

    /// Alle deutschen Stimmen auf diesem Gerät, beste Qualität zuerst
    static var deutsche: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("de") }
            .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
    }

    private static func gewaehlt() -> AVSpeechSynthesisVoice? {
        UserDefaults.standard.string(forKey: key).flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    }

    /// Ohne eigene Wahl: die beste österreichische, wenn sie mindestens so gut ist wie die beste deutsche
    private static func beste() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        func best(_ lang: String) -> AVSpeechSynthesisVoice? {
            all.filter { $0.language == lang }.max { $0.quality.rawValue < $1.quality.rawValue }
        }
        let at = best("de-AT"), de = best("de-DE")
        if let at, at.quality.rawValue >= (de?.quality.rawValue ?? 0) { return at }
        return de ?? at
    }

    /// Stimme wählen (nil: automatisch) und kurz probehören
    func waehle(_ v: AVSpeechSynthesisVoice?) {
        UserDefaults.standard.set(v?.identifier, forKey: Self.key)
        voice = v ?? Self.beste()
        sprich(["Hallo Sascha! Schreib das Wort: Landstraße."], langsam: false)
    }

    var automatisch: Bool { Self.gewaehlt() == nil }

    static func titel(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = " · Premium"
        case .enhanced: q = " · Enhanced"
        default: q = ""
        }
        return "\(v.name) (\(v.language))\(q)"
    }

    var stimme: String { voice.map { "\($0.name) (\($0.language))" } ?? "Standardstimme" }

    func sprich(_ teile: [String], langsam: Bool = true) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.stopSpeaking(at: .immediate)
        for (i, t) in teile.enumerated() where !t.isEmpty {
            let u = AVSpeechUtterance(string: t)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * (langsam ? 0.8 : 0.95)
            u.postUtteranceDelay = i < teile.count - 1 ? 0.6 : 0
            synth.speak(u)
        }
    }

    /// Schalter am Start der Lernwörter: auch den Beispielsatz vorsprechen (Standard: nur das Wort)
    static let mitSatzKey = "lernMitSatz"

    /// „Schreib das Wort: Fahrrad.“ Mit dem Schalter dazu „Ich fahre mit dem Fahrrad. – Fahrrad.“ Der Satz hilft nur
    /// beim Verstehen (das/dass, Meer/mehr); geschrieben wird nur das Wort
    func diktiere(_ w: LernWort) {
        var teile = ["Schreib das Wort: \(w.wort)."]
        if UserDefaults.standard.bool(forKey: Self.mitSatzKey), let s = w.satz, !s.isEmpty {
            teile.append(s)
            teile.append(w.wort)
        }
        sprich(teile)
    }

    /// Hängt an, was gerade gesprochen wird, statt es abzubrechen
    func sprichDanach(_ t: String) {
        let u = AVSpeechUtterance(string: t)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        u.preUtteranceDelay = 0.4
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}

// MARK: - Modell

@MainActor
final class LernModel: ObservableObject {
    enum Phase: Equatable {
        case start
        case schreiben
        case lesen
        /// Der Mac hat gelesen: Sascha bestätigt oder schreibt nochmal
        case bestaetigen(LernAntwort)
        /// Richtig (beim ersten oder zweiten Versuch)
        case richtig(zweiter: Bool)
        /// Erster Versuch falsch: Hinweis, gleich nochmal
        /// nil: der Tipp ist noch unterwegs
        case tipp(String?)
        /// Zweiter Versuch falsch: das richtige Wort zeigen
        case aufloesung(String?)
        /// Der Mac antwortet nicht: selbst vergleichen
        case selbst(String)
        case fertig
    }

    @Published var phase: Phase = .start
    @Published private(set) var words: [LernWort] = []
    @Published private(set) var log: [LernEvent] = []
    @Published private(set) var status: String?
    @Published private(set) var queue: [LernWort] = []
    @Published private(set) var index = 0
    @Published private(set) var versuch = 1
    /// Sterne dieser Runde (halbe für „nach dem Tipp“)
    @Published private(set) var sterne: Double = 0
    @Published private(set) var ersteVersuche: [String: String] = [:]
    @Published var drawing = PKDrawing()
    /// Was bei „richtig“ dasteht (und gesprochen wird)
    @Published private(set) var lobText = ""
    /// Was der Mac zuletzt gelesen hat (für die Auflösung)
    var zuletztGelesen: String? { gelesen.last }

    let sprecher = Sprecher()
    private let sync: SyncEngine
    private var since = 0
    private var pending: [LernEvent] = []
    private var gelesen: [String] = []
    /// Diese Runde wiederholt nur die Wörter der letzten, die noch nicht ganz gepasst haben (zählt nicht fürs Fach,
    /// außer falsch)
    @Published private(set) var nochmalRunde = false
    private var leseTask: Task<Void, Never>?
    /// Der Tipp, im Hintergrund geholt, sobald das Gelesene vom Wort abweicht (Sascha prüft derweil das Gelesene)
    private var tippTask: Task<String?, Never>?
    private var letztesBild: Data?

    init(sync: SyncEngine) {
        self.sync = sync
        load()
    }

    var aktuell: LernWort? { index < queue.count ? queue[index] : nil }
    var aktiveWoerter: [LernWort] { words.filter { $0.removed == nil } }
    var karten: [String: Lernkartei.Karte] { Lernkartei.karten(log) }
    var anzahlDran: Int { Lernkartei.anzahlDran(words, log) }
    /// Wörter dieser Runde, die beim ersten Versuch nicht richtig waren: Am Ende kann Sascha sie nochmal probieren
    var nochmalWoerter: [LernWort] { queue.filter { ersteVersuche[$0.wort] != "richtig" } }

    // MARK: Speicher (Zwischenstand auf dem Gerät, falls offline)

    private struct File: Codable {
        var words: [LernWort]
        var log: [LernEvent]
        var since: Int
        var pending: [LernEvent]
    }

    private var fileURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("lernen.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(File.self, from: data) else { return }
        words = f.words
        log = f.log
        since = f.since
        pending = f.pending
    }

    private func save() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(File(words: words, log: log, since: since, pending: pending)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: Server

    private struct Remote: Decodable {
        var v: Int
        var words: [LernWort]
        var log: [LernEvent]
    }

    /// Eigene Versuche hinauf, Liste und neue Versuche herunter
    func refresh() async {
        guard sync.isConfigured else {
            status = "Kein Server eingerichtet (Zahnrad in der Übersicht)."
            return
        }
        do {
            try await flush()
            let data = try await sync.lernRequest("GET", "/api/lernen?since=\(since)")
            let r = try JSONDecoder().decode(Remote.self, from: data)
            words = r.words
            let known = Set(log.map(\.id))
            log += r.log.filter { !known.contains($0.id) }
            since = max(since, r.log.compactMap(\.seq).max() ?? since)
            status = nil
            save()
        } catch let SyncError.http(code, body) where code == 404 && !body.contains("\"code\"") {
            status = "Der Server kennt die Lernwörter noch nicht (Server-Update nötig)."
        } catch {
            status = words.isEmpty ? "Keine Verbindung zum Server." : nil
        }
    }

    private func flush() async throws {
        guard !pending.isEmpty else { return }
        let batch = pending
        let body = try JSONEncoder().encode(["events": batch])
        _ = try await sync.lernRequest("POST", "/api/lernen/log", body: body)
        let sent = Set(batch.map(\.id))
        pending.removeAll { sent.contains($0.id) }
        save()
    }

    /// Wörter hinzufügen („Wort“ oder „Wort | Satz“ je Zeile) oder entfernen
    func aendern(add: [LernWort] = [], remove: [String] = []) async {
        struct Add: Encodable { var wort: String; var satz: String? }
        struct Body: Encodable { var add: [Add]; var remove: [String] }
        do {
            let body = try JSONEncoder().encode(Body(add: add.map { Add(wort: $0.wort, satz: $0.satz) }, remove: remove))
            _ = try await sync.lernRequest("POST", "/api/lernen/woerter", body: body)
            await refresh()
        } catch {
            status = "Ändern ging nicht: \(error.localizedDescription)"
        }
    }

    static func parse(_ text: String) -> [LernWort] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let w = parts.first, !w.isEmpty else { return nil }
            return LernWort(wort: lernNorm(w), satz: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil, added: 0)
        }
    }

    // MARK: Ablauf

    /// Eine Runde mit `size` Wörtern (5 oder 10): zuerst die fälligen, dann neue, dann solche, die erst später dran
    /// wären
    func starte(size: Int) {
        beginne(Lernkartei.runde(words, log, size: size, extra: true), nochmal: false)
    }

    /// Die Wörter der letzten Runde, die noch nicht ganz gepasst haben, nochmal
    func nochmalProbieren() {
        beginne(nochmalWoerter, nochmal: true)
    }

    private func beginne(_ q: [LernWort], nochmal: Bool) {
        guard !q.isEmpty else { return }
        queue = q
        nochmalRunde = nochmal
        index = 0
        sterne = 0
        ersteVersuche = [:]
        neuesWort()
    }

    private func neuesWort() {
        tippTask?.cancel()
        tippTask = nil
        versuch = 1
        gelesen = []
        drawing = PKDrawing()
        phase = .schreiben
        if let w = aktuell { sprecher.diktiere(w) }
    }

    func nochmalHoeren() {
        if let w = aktuell { sprecher.diktiere(w) }
    }

    /// „Fertig“: das Geschriebene an den Mac
    func fertig(image: Data) {
        guard let w = aktuell else { return }
        phase = .lesen
        leseTask?.cancel()
        leseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let antwort = try await self.lies(image: image, wort: w, versuch: self.versuch)
                guard !Task.isCancelled, self.phase == .lesen else { return }
                self.phase = .bestaetigen(antwort)
                self.holeTipp(antwort, bild: image, wort: w)
                if antwort.unleserlich == true {
                    self.sprecher.sprich(["Das konnte ich nicht lesen. Schreib es bitte noch einmal, etwas größer."], langsam: false)
                }
            } catch is CancellationError {
            } catch {
                guard self.phase == .lesen else { return }
                self.phase = .selbst(error.localizedDescription)
                self.sprecher.sprich(["So schreibt man es. Vergleiche selbst."], langsam: false)
            }
        }
    }

    /// Weicht das Gelesene ab, gleich den Tipp holen (ein älterer Helfer schickt ihn schon mit)
    private func holeTipp(_ a: LernAntwort, bild: Data, wort: LernWort) {
        tippTask?.cancel()
        tippTask = nil
        guard a.unleserlich != true, !a.gelesen.isEmpty, lernNorm(a.gelesen) != lernNorm(wort.wort) else { return }
        if let h = a.hinweis {
            tippTask = Task { h }
            return
        }
        let versuch = versuch
        tippTask = Task { [weak self] in
            guard let self else { return nil }
            return try? await self.lies(image: bild, wort: wort, versuch: versuch, gelesen: a.gelesen, bis: 30).hinweis
        }
    }

    func abbrechenLesen() {
        leseTask?.cancel()
        phase = .schreiben
    }

    /// Sascha: „Ja, so habe ich es geschrieben“
    func bestaetigt(_ a: LernAntwort) {
        guard let w = aktuell else { return }
        gelesen.append(a.gelesen)
        let ok = lernNorm(a.gelesen) == lernNorm(w.wort)
        if ok {
            ergebnis(versuch == 1 ? "richtig" : "zweiter")
            lobText = versuch == 1 ? Self.lob.randomElement()! : "Super, mit dem Tipp hast du es geschafft!"
            phase = .richtig(zweiter: versuch > 1)
            sprecher.sprich([lobText], langsam: false)
        } else if versuch == 1 {
            phase = .tipp(nil)
            sprecher.sprich(["Fast!"], langsam: false)
            zeigeTipp(index: index) { model, tipp in
                let t = tipp ?? "Schau dir das Wort noch einmal genau an und hör gut hin."
                model.phase = .tipp(t)
                model.sprecher.sprich([t], langsam: false)
            }
        } else {
            ergebnis("falsch")
            phase = .aufloesung(nil)
            sprecher.sprich(["Das war knifflig. So schreibt man es:", w.wort], langsam: false)
            zeigeTipp(index: index) { model, tipp in
                guard let tipp else { return }
                model.phase = .aufloesung(tipp)
                model.sprecher.sprichDanach(tipp)
            }
        }
    }

    /// Wartet auf den Tipp und zeigt ihn, solange noch dasselbe Wort mit derselben Karte dran ist
    private func zeigeTipp(index: Int, _ show: @escaping (LernModel, String?) -> Void) {
        let task = tippTask
        let before = phase
        Task { [weak self] in
            let tipp = await task?.value
            guard let self, self.index == index, self.phase == before else { return }
            show(self, tipp)
        }
    }

    /// Sascha: „Nein, so habe ich es nicht geschrieben“: seine Schrift bleibt, er bessert aus
    func nichtBestaetigt() {
        tippTask?.cancel()
        tippTask = nil
        phase = .schreiben
    }

    func nochmalVersuchen() {
        versuch = 2
        drawing = PKDrawing()
        phase = .schreiben
        if let w = aktuell { sprecher.diktiere(w) }
    }

    /// Selbst verglichen (der Mac hat nicht geantwortet)
    func selbstGeprueft(richtig: Bool) {
        ergebnis(richtig ? (versuch == 1 ? "richtig" : "zweiter") : "falsch", selbst: true)
        if richtig {
            lobText = versuch == 1 ? Self.lob.randomElement()! : "Super, mit dem Tipp hast du es geschafft!"
            phase = .richtig(zweiter: versuch > 1)
            sprecher.sprich([lobText], langsam: false)
        } else {
            weiter()
        }
    }

    func weiter() {
        sprecher.stop()
        index += 1
        if index >= queue.count {
            phase = .fertig
            sprecher.sprich([nochmalWoerter.isEmpty ? "Alle richtig! Großartig, Sascha!" : "Geschafft! Gut gemacht, Sascha!"], langsam: false)
            Task { await refresh() }
        } else {
            neuesWort()
        }
    }

    func beenden() {
        leseTask?.cancel()
        sprecher.stop()
        phase = .start
        Task { await refresh() }
    }

    private func ergebnis(_ e: String, selbst: Bool = false) {
        guard let w = aktuell else { return }
        let wdh = nochmalRunde
        ersteVersuche[w.wort] = e
        sterne += e == "richtig" ? 1 : e == "zweiter" ? 0.5 : 0
        let ev = LernEvent(id: UUID().uuidString, wort: w.wort, t: Date().timeIntervalSince1970, ergebnis: e,
                           gelesen: gelesen.isEmpty ? nil : gelesen, wdh: wdh ? true : nil, selbst: selbst ? true : nil,
                           from: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
        log.append(ev)
        pending.append(ev)
        save()
        Task { try? await flush() }
    }

    static let lob = ["Super, richtig!", "Toll gemacht!", "Genau so!", "Bravo, Sascha!", "Richtig, sehr gut!", "Perfekt!"]

    // MARK: Lesen lassen (über „Claude fragen“)

    private struct Meta: Encodable {
        struct Anchor: Encodable { var page = 0; var x = 0.0; var y = 0.0; var w = 768.0; var h = 200.0 }
        var anchor = Anchor()
        var pv = 0
        var effort = "lernwort"
        var created: Double
        var from: String
        var wort: String
        var satz: String?
        var versuch: Int
        /// Nur den Tipp holen: was Sascha geschrieben hat
        var gelesen: String?
    }

    private struct NurTipp: Decodable { var hinweis: String? }

    private struct AskList: Decodable {
        struct Item: Decodable { var id: String; var status: String; var answer: String?; var note: String? }
        var asks: [Item]
    }

    private enum LeseFehler: LocalizedError {
        case mac(String), zeit, alt
        var errorDescription: String? {
            switch self {
            case .mac(let s): return s
            case .zeit: return "Der Mac hat nicht geantwortet."
            case .alt: return "Der Server kennt die Lernwörter noch nicht (Server-Update nötig)."
            }
        }
    }

    private func lies(image: Data, wort: LernWort, versuch: Int, gelesen: String? = nil,
                      bis: Double = 120) async throws -> LernAntwort {
        let id = UUID().uuidString
        let boundary = "BetterNotes-" + UUID().uuidString
        var body = Data()
        func part(_ name: String, filename: String? = nil, type: String? = nil, _ data: Data) {
            var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\""
            if let filename { head += "; filename=\"\(filename)\"" }
            head += "\r\n"
            if let type { head += "Content-Type: \(type)\r\n" }
            body.append(Data((head + "\r\n").utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        let meta = Meta(created: Date().timeIntervalSince1970, from: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                        wort: wort.wort, satz: wort.satz, versuch: versuch, gelesen: gelesen)
        part("meta", try JSONEncoder().encode(meta))
        part("question", filename: "question.png", type: "image/png", image)
        part("page", filename: "page.png", type: "image/png", image)
        body.append(Data("--\(boundary)--\r\n".utf8))
        let path = "/api/doc/lernwoerter/asks"
        do {
            _ = try await sync.lernRequest("PUT", path + "/" + id, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        } catch let SyncError.http(code, text) where code == 404 && !text.contains("\"code\"") {
            throw LeseFehler.alt
        } catch let SyncError.http(_, text) where text.contains("Lernwort fehlt") {
            throw LeseFehler.alt
        }
        defer { Task { [sync] in _ = try? await sync.lernRequest("DELETE", path + "/" + id) } }
        // Warten, bis der Mac geantwortet hat (meist wenige Sekunden), höchstens `bis` Sekunden
        let t0 = Date()
        while Date().timeIntervalSince(t0) < bis {
            try await Task.sleep(for: .milliseconds(700))
            guard let data = try? await sync.lernRequest("GET", path),
                  let list = try? JSONDecoder().decode(AskList.self, from: data),
                  let item = list.asks.first(where: { $0.id == id }) else { continue }
            if item.status == "answered", let a = item.answer, let d = a.data(using: .utf8),
               let antwort = try? JSONDecoder().decode(LernAntwort.self, from: d) {
                return antwort
            }
            // Antwort nur mit dem Tipp
            if gelesen != nil, item.status == "answered", let a = item.answer, let d = a.data(using: .utf8),
               let t = try? JSONDecoder().decode(NurTipp.self, from: d) {
                return LernAntwort(gelesen: gelesen ?? "", richtig: false, hinweis: t.hinweis)
            }
            // Beantwortet, aber nicht als Lernwort (ein Helfer von vor den Lernwörtern antwortet mit Text)
            if item.status == "answered" { throw LeseFehler.mac("Der Helfer am Mac ist noch nicht neu eingerichtet.") }
            if item.status == "failed" { throw LeseFehler.mac(item.note ?? "Der Mac konnte es nicht lesen.") }
            if let note = item.note, note.contains("Limit") || note.contains("abgemeldet") { throw LeseFehler.mac(note) }
        }
        throw LeseFehler.zeit
    }
}
