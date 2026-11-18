import UIKit
import UniformTypeIdentifiers
import WebKit

/// Setzt Markdown einmal auf A4-Seiten, mit derselben eingebauten Seite wie die Antworten von Claude (Antwort.html:
/// markdown-it und KaTeX, ohne Netz, ohne HTML und Bilder), in einer Web-Ansicht, die niemand sieht. Danach ist es ein
/// gewöhnliches PDF: Die App schreibt darauf wie auf jedes andere, der Text selbst lässt sich nicht mehr bearbeiten.
///
/// Die Seiten bricht die App selbst um, nicht WebKits Druck: Die Seite misst, wo Zeilen, Formeln und Tabellenzeilen
/// liegen, und jede A4-Seite bekommt einen Ausschnitt, der keine davon durchschneidet (eine Überschrift bleibt bei der
/// Zeile danach). WebKit zeichnet jeden Ausschnitt als eigenes kleines PDF, die App setzt es mit Rändern auf die Seite.
enum MarkdownTypesetter {
    /// Höchstens so groß (wie im Eingang des Servers)
    static let maxBytes = 512 * 1024
    /// A4 in Punkten
    static let paper = CGSize(width: 595.28, height: 841.89)
    /// Die Fläche für den Text, von oben links gemessen (Ränder etwa 2 cm, unten mehr für die Seitenzahl)
    static let area = CGRect(x: 56, y: 56, width: 483, height: 722)

    /// Dateiendungen von Markdown (Öffnen aus der Dateien-App, Import)
    static let fileExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    /// Markdown für den Import-Dialog (in Info.plist deklariert, falls iOS den Typ nicht selbst kennt)
    static let contentTypes: [UTType] = [UTType("net.daringfireball.markdown")].compactMap { $0 }

    static func isMarkdown(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    enum Failure: LocalizedError {
        case tooLarge, notText, noPage, timeout, crashed, script(String), noPDF

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Markdown zu groß (höchstens \(MarkdownTypesetter.maxBytes / 1024) KB)"
            case .notText: return "Die Datei ist kein Text in UTF-8"
            case .noPage: return "Antwort.html fehlt in der App"
            case .timeout: return "Setzen des Markdown dauert zu lange"
            case .crashed: return "WebKit wurde beim Setzen beendet"
            case .script(let message): return "Markdown nicht gesetzt: \(message)"
            case .noPDF: return "Aus dem Markdown entstand kein PDF"
            }
        }
    }

    /// Der Text einer Markdown-Datei: UTF-8, ein BOM fällt weg
    static func text(of data: Data) throws -> String {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw Failure.notText }
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        return text
    }

    /// Vorspann (YAML zwischen --- am Anfang, er beginnt mit „schlüssel:“) kommt nicht auf die Seite. Gleiche Regel
    /// wie beim Namen im Eingang des Servers (markdownTitle)
    static func withoutFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let trimmed = { (line: String) in line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) }
        guard lines.count > 1, trimmed(lines[0]) == "---",
              let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(trimmed(lines[$0])) }),
              end < 200,
              let first = lines[1..<end].first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              first.range(of: "^[A-Za-z0-9_-]+:", options: .regularExpression) != nil
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// Immer nur ein Dokument zugleich (je eine Web-Ansicht)
    @MainActor private static var queue: Task<Void, Never>?

    /// Setzt Markdown auf A4-Seiten; `title` steht nur in den Eigenschaften des PDFs
    @MainActor
    static func pdf(from markdown: String, title: String? = nil) async throws -> Data {
        let before = queue
        let job = Task { () async throws -> Data in
            await before?.value
            return try await Job().run(MarkdownTypesetter.withoutFrontMatter(markdown), title: title)
        }
        queue = Task { _ = try? await job.value }
        return try await job.value
    }

    /// Lage des gesetzten Texts in der Web-Ansicht (Punkte der Ansicht, von oben) und die Ausschnitte der Seiten
    private struct Layout: Decodable {
        var left: Double
        var width: Double
        var height: Double
        var pages: [[Double]]
    }

    @MainActor
    private final class Job: NSObject, WKNavigationDelegate {
        private let web: WKWebView
        private let page = Bundle.main.url(forResource: "Antwort", withExtension: "html")
        private var loading: CheckedContinuation<Void, Error>?
        private var crashed = false

        override init() {
            let config = WKWebViewConfiguration()
            config.dataDetectorTypes = []
            // Nichts bleibt liegen (keine Cookies, kein Cache)
            config.websiteDataStore = .nonPersistent()
            web = WKWebView(frame: CGRect(origin: .zero, size: MarkdownTypesetter.area.size), configuration: config)
            super.init()
            web.isOpaque = true
            web.backgroundColor = .white
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.navigationDelegate = self
        }

        func run(_ markdown: String, title: String?) async throws -> Data {
            defer {
                web.navigationDelegate = nil
                web.stopLoading()
            }
            guard let page else { throw Failure.noPage }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                loading = c
                web.loadFileURL(page, allowingReadAccessTo: page)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    self?.loaded(Failure.timeout)
                }
            }
            let area = MarkdownTypesetter.area
            let result = try await call(MarkdownTypesetter.script, [
                "md": markdown, "css": MarkdownTypesetter.css, "width": Double(area.width), "height": Double(area.height),
            ])
            guard let json = result as? String,
                  let layout = try? JSONDecoder().decode(Layout.self, from: Data(json.utf8)),
                  layout.width > 0, layout.height > 0, !layout.pages.isEmpty
            else { throw Failure.script("unerwartete Antwort der Seite") }
            // So hoch wie das ganze Dokument: Jeder Ausschnitt liegt dann in der Ansicht. Sie hängt in keinem Fenster,
            // zeichnet also nichts auf den Bildschirm (und belegt dafür keinen Speicher)
            web.frame.size.height = max(CGFloat(layout.height), area.height)
            return try await compose(layout, title: title)
        }

        /// Jede Seite: den Ausschnitt als eigenes PDF von WebKit, mit Rändern auf A4, dazu die Seitenzahl
        private func compose(_ layout: Layout, title: String?) async throws -> Data {
            let paper = MarkdownTypesetter.paper, area = MarkdownTypesetter.area
            let out = NSMutableData()
            var media = CGRect(origin: .zero, size: paper)
            var info: [String: Any] = [kCGPDFContextCreator as String: "BetterNotes"]
            if let title, !title.isEmpty { info[kCGPDFContextTitle as String] = title }
            guard let consumer = CGDataConsumer(data: out as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &media, info as CFDictionary)
            else { throw Failure.noPDF }
            for (number, range) in layout.pages.enumerated() {
                guard range.count == 2, range[1] > range[0] else { continue }
                if crashed { throw Failure.crashed }
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: layout.left, y: range[0], width: layout.width, height: range[1] - range[0])
                let data = try await web.pdf(configuration: config)
                guard let provider = CGDataProvider(data: data as CFData),
                      let slice = CGPDFDocument(provider)?.page(at: 1)
                else { throw Failure.noPDF }
                // PDF-Koordinaten: Ursprung unten links. Oben bündig mit der Textfläche, ihre Breite füllend
                let box = slice.getBoxRect(.mediaBox)
                guard box.width > 0, box.height > 0 else { throw Failure.noPDF }
                let scale = area.width / box.width
                let top = paper.height - area.minY, height = box.height * scale
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: top - height, width: paper.width, height: height))
                ctx.translateBy(x: area.minX, y: top - height)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(slice)
                ctx.restoreGState()
                if layout.pages.count > 1 { MarkdownTypesetter.drawNumber(number + 1, in: ctx) }
                ctx.endPDFPage()
            }
            ctx.closePDF()
            guard out.length > 0 else { throw Failure.noPDF }
            return out as Data
        }

        private func call(_ body: String, _ arguments: [String: Any]) async throws -> Any {
            do {
                return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
                    web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { c.resume(with: $0) }
                }
            } catch {
                throw crashed ? Failure.crashed : Failure.script(error.localizedDescription)
            }
        }

        private func loaded(_ error: Error?) {
            guard let c = loading else { return }
            loading = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded(nil) }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded(error) }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loaded(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            crashed = true
            loaded(Failure.crashed)
        }

        /// Nur die eingebaute Seite
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true && url?.path == page?.path ? .allow : .cancel)
        }
    }

    /// Seitenzahl klein unten in der Mitte
    @MainActor
    private static func drawNumber(_ number: Int, in ctx: CGContext) {
        ctx.saveGState()
        // UIKit zeichnet von oben nach unten
        ctx.translateBy(x: 0, y: paper.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        let base = UIFont.systemFont(ofSize: 9)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 9) } ?? base
        let label = NSAttributedString(string: "\(number)",
                                       attributes: [.font: font, .foregroundColor: UIColor(white: 0.45, alpha: 1)])
        let size = label.size()
        label.draw(at: CGPoint(x: (paper.width - size.width) / 2, y: paper.height - 34 - size.height))
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    /// Aussehen auf Papier, über dem der Antwortkarten: Serifenschrift in Punktgröße (1 Punkt der Ansicht = 1 Punkt im
    /// PDF), echte Überschriften, nichts scrollt (lange Zeilen in Code und Tabellen brechen um, zu breite Formeln und
    /// Tabellen setzt die Seite kleiner)
    private static let css = """
    html.doc, html.doc body { background: #fff; overflow-x: hidden; }
    html.doc body { margin: 0; padding: 0; color: #111; font: 11.5px/1.45 ui-serif, "New York", Georgia, serif; }
    html.doc #out > :first-child { margin-top: 0; }
    html.doc p, html.doc ul, html.doc ol, html.doc pre, html.doc blockquote, html.doc table { margin: 0 0 .75em; }
    html.doc h1 { font-size: 1.6em; line-height: 1.2; margin: 1.2em 0 .55em; }
    html.doc h2 { font-size: 1.3em; line-height: 1.25; margin: 1.1em 0 .45em; }
    html.doc h3 { font-size: 1.12em; line-height: 1.3; margin: 1em 0 .4em; }
    html.doc h4, html.doc h5, html.doc h6 { font-size: 1em; margin: .9em 0 .3em; }
    html.doc code { font-size: .86em; background: #f3f3f3; }
    html.doc pre { white-space: pre-wrap; overflow-wrap: anywhere; overflow: visible; background: #f5f5f5;
      border-radius: 4px; }
    html.doc pre code { font-size: .86em; background: none; }
    html.doc blockquote { color: #333; border-left-color: #bbb; }
    html.doc table { display: table; overflow: visible; }
    html.doc th { background: #f3f3f3; text-align: left; }
    html.doc td, html.doc th { border-color: #c4c4c4; vertical-align: top; }
    html.doc a { color: #1d4ed8; }
    html.doc hr { border-top-color: #bbb; }
    html.doc section.eqno > eqn { min-width: 0; }
    html.doc.fitted eq, html.doc.fitted eqn { overflow: visible; max-width: none; }
    """

    /// Läuft in Antwort.html (render ist dort definiert). Ergebnis: JSON mit `Layout`
    private static let script = #"""
    const style = document.createElement("style");
    style.textContent = css;
    document.head.appendChild(style);
    const root = document.documentElement;
    root.classList.add("doc");
    const out = document.getElementById("out");
    // Genau so breit wie die Textfläche, egal wie breit WebKit die Ansicht annimmt
    out.style.width = width + "px";
    render(md);
    // Erst das Layout anstoßen: Die Schriften von KaTeX laden erst, wenn Text sie braucht
    out.getBoundingClientRect();
    await document.fonts.ready;

    // Zu breite Formeln und Tabellen kleiner setzen (höchstens auf 40 %), statt sie abzuschneiden. Ein paar Punkte
    // zählen nicht: KaTeX hängt an Indizes einen 2 Punkte breiten Abstandhalter, der immer übersteht
    const outRight = out.getBoundingClientRect().right;
    const shrink = (el, measure) => {
      for (let i = 0; i < 5; i++) {
        const [need, avail] = measure(el);
        if (need <= avail + 4) return;
        const now = parseFloat(el.style.fontSize) || 100;
        const next = Math.max(40, Math.floor(now * avail / need));
        if (next >= now) return;
        el.style.fontSize = next + "%";
      }
    };
    for (const el of out.querySelectorAll("eq, eqn")) shrink(el, (e) => [e.scrollWidth, e.clientWidth]);
    for (const el of out.querySelectorAll("table")) {
      shrink(el, (e) => { const r = e.getBoundingClientRect(); return [r.right - r.left, outRight - r.left]; });
    }
    root.classList.add("fitted");
    out.getBoundingClientRect();
    await document.fonts.ready;

    // Was nicht durchgeschnitten werden darf: jede Textzeile, jede Formel, jede Tabellenzeile
    const sy = window.scrollY, sx = window.scrollX;
    const boxes = [];
    const add = (r) => { if (r.width > 0 && r.bottom - r.top > 0.5) boxes.push([r.top + sy, r.bottom + sy]); };
    const walker = document.createTreeWalker(out, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => n.nodeType === Node.TEXT_NODE
        ? (/\S/.test(n.data) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT)
        : (n.matches("eq, eqn, .katex") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP),
    });
    const range = document.createRange();
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      range.selectNodeContents(n);
      for (const r of range.getClientRects()) add(r);
    }
    for (const el of out.querySelectorAll("eq, eqn, .katex-display, tr, hr")) add(el.getBoundingClientRect());
    boxes.sort((a, b) => a[0] - b[0]);

    // Eine Überschrift bleibt bei der ersten Zeile danach
    const keep = [];
    for (const h of out.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
      const r = h.getBoundingClientRect();
      const bottom = r.bottom + sy;
      let lo = 0, hi = boxes.length;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (boxes[mid][0] < bottom - 0.5) lo = mid + 1; else hi = mid; }
      if (lo < boxes.length) keep.push([r.top + sy, boxes[lo][1]]);
    }
    const lines = [];
    for (const b of boxes.concat(keep).sort((a, b) => a[0] - b[0])) {
      const last = lines[lines.length - 1];
      if (last && b[0] < last[1] - 0.5) last[1] = Math.max(last[1], b[1]);
      else lines.push([b[0], b[1]]);
    }

    // Seiten: so viele ganze Zeilen wie auf die Textfläche passen. Was allein höher ist als eine Seite, wird geteilt
    const outRect = out.getBoundingClientRect();
    const docHeight = Math.max(root.scrollHeight, outRect.bottom + sy);
    const pageHeight = height * outRect.width / width;
    const pages = [];
    let i = 0;
    while (i < lines.length) {
      const start = lines[i][0];
      let j = i, end = start;
      while (j < lines.length && lines[j][1] - start <= pageHeight) { end = lines[j][1]; j++; }
      if (j === i) {
        end = start + pageHeight;
        pages.push([start, end]);
        lines[i] = [end, lines[i][1]];
        continue;
      }
      pages.push([start, end]);
      i = j;
    }
    if (!pages.length) pages.push([0, Math.max(1, Math.min(pageHeight, docHeight))]);
    // Etwas Luft um jeden Ausschnitt (Unterlängen, Hintergründe), höchstens bis zur Mitte des Abstands zum nächsten
    const padded = pages.map(([a, b], k) => {
      const before = k > 0 ? pages[k - 1][1] : 0;
      const after = k + 1 < pages.length ? pages[k + 1][0] : docHeight;
      return [Math.max(0, Math.max(a - 2, (before + a) / 2)), Math.min(docHeight, Math.min(b + 2, (b + after) / 2))];
    });
    return JSON.stringify({ left: outRect.left + sx, width: outRect.width, height: docHeight, pages: padded });
    """#
}
