import SwiftUI
import UIKit
import WebKit

/// Welche Frage die Karte zeigt. Am iPhone bleibt die Seite unter der halb hohen Karte bedienbar: Antippen einer
/// anderen Markierung tauscht nur die Frage aus
@MainActor
final class AnswerCardModel: ObservableObject {
    let doc: UUID
    let asks: AskStore
    @Published var askID: String
    var onDelete: (String) -> Void = { _ in }

    init(doc: UUID, askID: String, asks: AskStore) {
        self.doc = doc
        self.askID = askID
        self.asks = asks
    }
}

/// Die Karte mit der Antwort: am iPad als Sprechblase neben der Markierung, am iPhone von unten
final class AnswerCardController: UIHostingController<AnswerCard> {
    let model: AnswerCardModel
    /// Die Karte ist zu (weggetippt, weggewischt, gelöscht)
    var onClose: () -> Void = {}

    init(model: AnswerCardModel) {
        self.model = model
        super.init(rootView: AnswerCard(model: model, asks: model.asks))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onClose() }
    }
}

struct AnswerCard: View {
    @ObservedObject var model: AnswerCardModel
    @ObservedObject var asks: AskStore
    @State private var confirmDelete = false
    @State private var copied = false

    var body: some View {
        let ask = asks.ask(model.doc, model.askID)
        VStack(alignment: .leading, spacing: 0) {
            header(ask)
            Divider()
            content(ask)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { markSeen(ask) }
        .onChange(of: ask?.status) { _, _ in markSeen(asks.ask(model.doc, model.askID)) }
        .onChange(of: model.askID) { _, _ in
            copied = false
            markSeen(asks.ask(model.doc, model.askID))
        }
        .confirmationDialog("Markierung löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) { model.onDelete(model.askID) }
        } message: {
            Text(ask?.isWaiting == true
                 ? "Die Frage wird zurückgezogen, auf allen Geräten."
                 : "Markierung und Antwort verschwinden auf allen Geräten.")
        }
    }

    private func header(_ ask: Ask?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(ask))
                .font(.title3)
                .foregroundStyle(color(ask))
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude").font(.headline)
                if let ask {
                    Text(subtitle(ask)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let ask {
                Menu {
                    if ask.isAnswered, let answer = ask.answer {
                        Button {
                            UIPasteboard.general.string = answer
                            copied = true
                        } label: {
                            Label(copied ? "Kopiert" : "Antwort kopieren", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(ask.isWaiting ? "Frage zurückziehen" : "Markierung löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Mehr")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func content(_ ask: Ask?) -> some View {
        if let ask {
            switch ask.status {
            case "answered":
                AnswerWebView(markdown: ask.answer ?? "")
            case "failed":
                message(ask.note ?? "Das hat nicht geklappt.",
                        hint: "Zum neuen Versuch die Markierung löschen und noch einmal fragen.", color: .orange)
            case "claimed":
                waiting("Claude denkt nach …", note: nil, spinning: true)
            case "local":
                waiting("Wird gesendet …", note: ask.localNote, spinning: false)
            default:
                waiting("Wartet auf den Mac …", note: ask.note, spinning: false)
            }
        } else {
            message("Diese Markierung gibt es nicht mehr.", hint: nil, color: .secondary)
        }
    }

    private func waiting(_ title: String, note: String?, spinning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if spinning { ProgressView() }
                Text(title).font(.body)
            }
            if let note, !note.isEmpty {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func message(_ text: String, hint: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.body).foregroundStyle(color).textSelection(.enabled)
            if let hint { Text(hint).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(16)
    }

    private func subtitle(_ ask: Ask) -> String {
        let time = Date(timeIntervalSince1970: ask.created)
        let when = Calendar.current.isDateInToday(time)
            ? time.formatted(date: .omitted, time: .shortened)
            : time.formatted(date: .abbreviated, time: .shortened)
        let effort = ask.isThorough ? "gründlich gefragt" : "gefragt"
        return "\(effort) \(when)" + (ask.from.map { $0.isEmpty ? "" : " am \($0)" } ?? "")
    }

    private func symbol(_ ask: Ask?) -> String {
        switch ask?.status {
        case "answered": return "text.bubble.fill"
        case "failed": return "exclamationmark.bubble.fill"
        case "claimed": return "ellipsis.bubble.fill"
        default: return "bubble.left.fill"
        }
    }

    private func color(_ ask: Ask?) -> Color {
        switch ask?.status {
        case "answered": return .blue
        case "failed": return .orange
        default: return .gray
        }
    }

    /// Eine angezeigte Antwort gilt als gelesen (nach dem Zeichnen, nicht mitten darin)
    private func markSeen(_ ask: Ask?) {
        guard let ask, ask.isAnswered, ask.seen != true else { return }
        let doc = model.doc, store = asks
        DispatchQueue.main.async { store.markSeen(doc, ask.id) }
    }
}

/// Die Antwort: Markdown mit Formeln, gesetzt von KaTeX in einer eingebauten Seite (Antwort.html, ohne Netz)
struct AnswerWebView: UIViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.navigationDelegate = context.coordinator
        context.coordinator.pending = markdown
        if let page = Bundle.main.url(forResource: "Antwort", withExtension: "html") {
            context.coordinator.page = page
            web.loadFileURL(page, allowingReadAccessTo: page)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.show(markdown, in: web)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var page: URL?
        var loaded = false
        var pending: String?
        private var shown: String?

        func show(_ markdown: String, in web: WKWebView) {
            guard loaded else {
                pending = markdown
                return
            }
            guard markdown != shown else { return }
            shown = markdown
            web.callAsyncJavaScript("render(md)", arguments: ["md": markdown], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending {
                self.pending = nil
                show(pending, in: webView)
            }
        }

        /// Nur die eingebaute Seite; Links (sollte es keine geben) öffnen im Browser
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .linkActivated {
                if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(url?.isFileURL == true && url?.path == page?.path ? .allow : .cancel)
        }
    }
}
