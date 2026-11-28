import CryptoKit
import UIKit
import WebKit

/// Setzt die Notizen von „Claude schreiben lassen“: Markdown mit Formeln, gedruckt und ohne Hintergrund, in derselben
/// eingebauten Seite wie die Antworten (Antwort.html: markdown-it und KaTeX, ohne Netz). Jede Notiz wird ein kleines
/// PDF in ihrer Breite (Seitenpunkte, Seite = 768 breit) und so hoch, wie ihr Text braucht. Die Leinwand zeichnet es
/// scharf in jeder Zoomstufe, der Export legt es auf die Seite.
///
/// Gesetzte Notizen liegen im Speicher und als Datei in Caches/notizen/ (Name: Prüfsumme über die Fassung des Setzens,
/// Text, Breite, Farbe und Größe). Ändert sich nichts davon, wird nie neu gesetzt. Endet WebKit oder hängt es (etwa im
/// Hintergrund), wird die Notiz später noch einmal gesetzt (höchstens dreimal, solange die App vorn ist).
@MainActor
enum NoteTypesetter {
    /// Gesetzte Notiz: die Seite des PDFs und ihre Größe in Seitenpunkten (Breite = Breite der Notiz)
    struct Typeset: @unchecked Sendable {
        let page: CGPDFPage
        let size: CGSize
        private let document: CGPDFDocument

        nonisolated init?(_ data: Data) {
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
                  let page = doc.page(at: 1) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return nil }
            document = doc
            self.page = page
            size = box.size
        }

        /// Zeichnet die Notiz in `rect` (UIKit-Koordinaten, y nach unten), Breite füllend
        nonisolated func draw(in ctx: CGContext, rect: CGRect) {
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0 else { return }
            let s = rect.width / box.width
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY + box.height * s)
            ctx.scaleBy(x: s, y: -s)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            ctx.restoreGState()
        }
    }

    /// Schriftgröße in Seitenpunkten (die Seite ist 768 breit, A4 also 1,29 Seitenpunkte je Druckpunkt): normal etwa
    /// 10 pt. Der Auftrag an Claude im Helfer rechnet mit denselben Zeilenhöhen
    nonisolated static func fontSize(_ size: String?) -> Double {
        switch size {
        case "small": return 10
        case "large": return 16
        default: return 13
        }
    }

    nonisolated static func cssColor(_ color: String?) -> String {
        switch color {
        case "red": return "#c8102e"
        case "green": return "#1a7f37"
        case "black": return "#111111"
        case "orange": return "#c25700"
        case "purple": return "#7a3fc4"
        default: return "#1d4ed8"
        }
    }

    nonisolated static func uiColor(_ color: String?) -> UIColor {
        let hex = cssColor(color).dropFirst()
        let v = UInt32(hex, radix: 16) ?? 0
        return UIColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// Breite einer Notiz in Seitenpunkten (Seite 768 breit), mindestens 20
    nonisolated static func width(_ note: AskNote) -> Double { max(20, (note.w * Double(PageLayout.width)).rounded()) }

    /// Vorn die Fassung des Setzens: Wächst sie, wird schon Gesetztes neu gesetzt (2: davor fehlten manchmal Zeichen
    /// aus den Zusatzschriften von KaTeX, etwa ℝ oder das große Σ)
    private static func key(_ note: AskNote) -> String {
        let raw = "2|\(width(note))|\(fontSize(note.size))|\(cssColor(note.color))|\(note.text)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static var memory: [String: Typeset] = [:]
    /// Notizen, die gerade gesetzt werden oder nicht zu setzen waren (nicht immer wieder versuchen)
    private static var busy = Set<String>()
    private static var failed = Set<String>()
    /// Wie oft eine Notiz in dieser Sitzung an einem beendeten oder hängenden WebKit scheiterte, während die App vorn
    /// war (im Hintergrund beendet iOS WebKit ohnehin; das zählt nicht)
    private static var attempts: [String: Int] = [:]
    private static let maxAttempts = 3
    private static var queue: Task<Void, Never>?

    private static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("notizen", isDirectory: true)
    }

    /// Schon gesetzt? Nur der Speicher: Dateien liest `prepare` abseits des Hauptthreads
    static func cached(_ note: AskNote) -> Typeset? { memory[key(note)] }

    /// Setzt, was noch fehlt; `done` danach (auf dem Hauptthread), wenn etwas dazukam. Schon als Datei Gesetztes kommt
    /// gleich (abseits des Hauptthreads gelesen, ohne auf andere Reihen zu warten), der Rest eine Notiz nach der anderen
    static func prepare(_ notes: [AskNote], done: @escaping () -> Void) {
        var seen = Set<String>()
        let todo = notes.filter { n in
            let k = key(n)
            return memory[k] == nil && !busy.contains(k) && !failed.contains(k) && seen.insert(k).inserted
        }
        guard !todo.isEmpty else { return }
        let keys = todo.map { key($0) }, dir = folder
        for k in keys { busy.insert(k) }
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> [String: Typeset] in
                var out: [String: Typeset] = [:]
                for k in keys {
                    if let data = try? Data(contentsOf: dir.appendingPathComponent(k + ".pdf")), let t = Typeset(data) {
                        out[k] = t
                    }
                }
                return out
            }.value
            for (k, t) in loaded {
                memory[k] = t
                busy.remove(k)
            }
            if !loaded.isEmpty { done() }
            let rest = todo.filter { loaded[key($0)] == nil }
            if !rest.isEmpty { enqueue(rest, done: done) }
        }
    }

    /// Setzt `notes` mit WebKit, eine nach der anderen, nach den Reihen davor. Endet WebKit oder hängt es, kommen die
    /// übrigen 2 s später wieder dran, aber erst, wenn die App vorn ist (so lange bleiben sie `busy`)
    private static func enqueue(_ notes: [AskNote], done: @escaping () -> Void) {
        let before = queue, dir = folder
        queue = Task {
            await before?.value
            var added = false
            var again: [AskNote] = []
            let job = Job()
            for (i, note) in notes.enumerated() {
                let k = key(note)
                do {
                    let data = try await job.typeset(note)
                    guard let t = Typeset(data) else { throw MarkdownTypesetter.Failure.noPDF }
                    memory[k] = t
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? data.write(to: dir.appendingPathComponent(k + ".pdf"), options: .atomic)
                    busy.remove(k)
                    added = true
                } catch let error where isTransient(error, job: job) {
                    // WebKit beendet oder hängt (etwa die App eben im Hintergrund): Nur vorn zählt das als Versuch
                    if UIApplication.shared.applicationState == .active { attempts[k, default: 0] += 1 }
                    Log.sync.error("Notiz nicht gesetzt (noch einmal): \(error.localizedDescription, privacy: .public)")
                    if attempts[k, default: 0] >= maxAttempts {
                        failed.insert(k)
                        busy.remove(k)
                        again = Array(notes[(i + 1)...])
                    } else {
                        again = Array(notes[i...])
                    }
                    break
                } catch {
                    failed.insert(k)
                    busy.remove(k)
                    Log.sync.error("Notiz nicht gesetzt: \(error.localizedDescription, privacy: .public)")
                }
            }
            job.close()
            if added { done() }
            guard !again.isEmpty else { return }
            // Nicht in der Reihe warten: Andere Notizen kommen inzwischen dran
            Task { [again] in
                try? await Task.sleep(for: .seconds(2))
                while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .seconds(1)) }
                enqueue(again, done: done)
            }
        }
    }

    /// WebKit beendet oder hängt: später noch einmal. Fehler im Skript, kein PDF, Seite fehlt: nicht
    private static func isTransient(_ error: Error, job: Job) -> Bool {
        if job.isCrashed { return true }
        if let f = error as? MarkdownTypesetter.Failure {
            switch f {
            case .timeout, .crashed: return true
            default: return false
            }
        }
        if let e = error as? WKError {
            return e.code != .javaScriptExceptionOccurred && e.code != .javaScriptResultTypeIsUnsupported
        }
        return false
    }

    /// Setzt alle fehlenden Notizen und wartet darauf (für den Export), höchstens `seconds`
    static func ready(_ notes: [AskNote], seconds: Double = 20) async -> [AskNote: Typeset] {
        prepare(notes) {}
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, notes.contains(where: { busy.contains(key($0)) }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        var out: [AskNote: Typeset] = [:]
        for n in notes { if let t = cached(n) { out[n] = t } }
        return out
    }

    /// Alte Dateien aufräumen: was 60 Tage nicht gebraucht wurde
    static func cleanUp() {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-60 * 86400)
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < limit { try? fm.removeItem(at: file) }
        }
    }

    /// Eine Web-Ansicht, die niemand sieht, für eine Reihe von Notizen
    private final class Job: NSObject, WKNavigationDelegate {
        private let web: WKWebView
        private let page = Bundle.main.url(forResource: "Antwort", withExtension: "html")
        private var loading: CheckedContinuation<Void, Error>?
        private var loaded = false
        private var crashed = false
        /// Der WebContent-Prozess dieser Ansicht endete
        var isCrashed: Bool { crashed }

        override init() {
            let config = WKWebViewConfiguration()
            config.dataDetectorTypes = []
            config.websiteDataStore = .nonPersistent()
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 400), configuration: config)
            super.init()
            // Durchsichtig: Im PDF steht nur die Schrift, kein weißer Grund
            web.isOpaque = false
            web.backgroundColor = .clear
            web.underPageBackgroundColor = .clear
            web.scrollView.backgroundColor = .clear
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.navigationDelegate = self
        }

        func close() {
            web.navigationDelegate = nil
            web.stopLoading()
        }

        func typeset(_ note: AskNote) async throws -> Data {
            if crashed { throw MarkdownTypesetter.Failure.crashed }
            if !loaded {
                guard let page else { throw MarkdownTypesetter.Failure.noPage }
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    loading = c
                    web.loadFileURL(page, allowingReadAccessTo: page)
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        self?.finishLoading(MarkdownTypesetter.Failure.timeout)
                    }
                }
                loaded = true
            }
            let width = NoteTypesetter.width(note)
            web.frame.size.width = CGFloat(width) + 40
            let result = try await web.callAsyncJavaScript(NoteTypesetter.script, arguments: [
                "md": note.text, "width": width, "size": NoteTypesetter.fontSize(note.size),
                "color": NoteTypesetter.cssColor(note.color),
            ], in: nil, contentWorld: .page)
            struct Box: Decodable { var left: Double; var top: Double; var width: Double; var height: Double }
            guard let json = result as? String, let box = try? JSONDecoder().decode(Box.self, from: Data(json.utf8)),
                  box.width > 0 else { throw MarkdownTypesetter.Failure.script("unerwartete Antwort der Seite") }
            let height = max(1, ceil(box.height))
            web.frame.size.height = max(height + ceil(box.top) + 4, 50)
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: floor(box.left), y: floor(box.top), width: ceil(box.width), height: height)
            return try await web.pdf(configuration: config)
        }

        private func finishLoading(_ error: Error?) {
            guard let c = loading else { return }
            loading = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finishLoading(error)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finishLoading(error)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            crashed = true
            finishLoading(MarkdownTypesetter.Failure.crashed)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true && url?.path == page?.path ? .allow : .cancel)
        }
    }

    /// Läuft in Antwort.html (render ist dort definiert). Ergebnis: JSON mit der Lage des gesetzten Texts
    private static let script = #"""
    if (!document.getElementById("note-style")) {
      const style = document.createElement("style");
      style.id = "note-style";
      style.textContent = `
        html.note, html.note body { background: transparent !important; overflow: hidden; }
        html.note body { margin: 0; padding: 0; }
        html.note #out { font-family: ui-serif, "New York", Georgia, serif; line-height: 1.35; }
        html.note #out > :first-child { margin-top: 0; }
        html.note #out > :last-child { margin-bottom: 0; }
        html.note p, html.note ul, html.note ol, html.note pre, html.note blockquote, html.note table { margin: 0 0 .45em; }
        html.note ul, html.note ol { padding-left: 1.3em; }
        html.note h1, html.note h2, html.note h3, html.note h4 { font-size: 1.1em; margin: .5em 0 .3em; }
        html.note code, html.note pre { background: transparent; color: inherit; }
        html.note blockquote { color: inherit; border-left-color: currentColor; }
        html.note a { color: inherit; text-decoration: underline; }
        html.note td, html.note th { border-color: currentColor; }
        html.note th { background: transparent; }
        html.note eq, html.note eqn { overflow: visible; max-width: none; }
      `;
      document.head.appendChild(style);
    }
    document.documentElement.classList.add("note");
    const out = document.getElementById("out");
    out.style.width = width + "px";
    out.style.fontSize = size + "px";
    out.style.color = color;
    render(md);
    // Farbe auch für Formeln und Tabellen (KaTeX erbt sie, ein paar Stile der Seite setzen eigene)
    for (const el of out.querySelectorAll("*")) if (!el.closest(".katex")) el.style.color = color;
    // Erst alle Schriften von KaTeX laden und darauf warten (höchstens 5 s je Aufruf), dann neu umbrechen. Von sich aus
    // lädt WebKit eine Schrift erst, wenn Text sie braucht, und document.fonts.ready wartet nicht immer darauf (älteres
    // WebKit wie in iPadOS 18 ab der zweiten Notiz einer Ansicht nie): Dann fehlten im PDF Zeichen aus den
    // Zusatzschriften (ℝ, das große Σ), ihr Platz blieb aber frei
    const fonts = async () => {
      let loads = Array.from(document.fonts, (f) => (f.status === "loaded" ? null : f.load()));
      // Zählt document.fonts die Schriften aus dem CSS nicht auf: dieselben über Name, Gewicht und Stil
      if (!loads.length) {
        const names = ["AMS", "Caligraphic", "Fraktur", "Main", "Math", "SansSerif", "Script", "Size1", "Size2", "Size3",
          "Size4", "Typewriter"];
        loads = names.flatMap((name) => ["", "bold ", "italic ", "italic bold "]
          .map((style) => document.fonts.load(style + "1em KaTeX_" + name)));
      }
      const loaded = Promise.all(loads.map((p) => p && p.catch(() => null))).then(() => document.fonts.ready);
      await Promise.race([loaded, new Promise((done) => setTimeout(done, 5000))]);
      out.getBoundingClientRect();
    };
    await fonts();
    // Zu breite Formeln kleiner setzen (höchstens auf 40 %), statt sie abzuschneiden
    for (const el of out.querySelectorAll("eq, eqn, .katex-display")) {
      for (let i = 0; i < 5; i++) {
        const need = el.scrollWidth, avail = width;
        if (need <= avail + 2) break;
        const now = parseFloat(el.style.fontSize) || 100;
        const next = Math.max(40, Math.floor(now * avail / need));
        if (next >= now) break;
        el.style.fontSize = next + "%";
      }
    }
    await fonts();
    const r = out.getBoundingClientRect();
    // Unten etwas Luft für Unterlängen
    return JSON.stringify({ left: r.left + window.scrollX, top: r.top + window.scrollY, width: r.width,
                            height: Math.max(r.height + 2, 4) });
    """#
}
