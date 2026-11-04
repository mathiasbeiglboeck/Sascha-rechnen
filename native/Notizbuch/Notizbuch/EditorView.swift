import SwiftUI
import UIKit

enum ToolMode {
    case pen, eraser, lasso
}

/// Stift, Farbe, Dicke und ob die Menüs sichtbar sind
@MainActor
final class ToolState: ObservableObject {
    static let colors: [UIColor] = [
        UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1), // schwarz
        UIColor(red: 0.12, green: 0.27, blue: 0.64, alpha: 1), // blau
        UIColor(red: 0.80, green: 0.17, blue: 0.15, alpha: 1), // rot
        UIColor(red: 0.13, green: 0.52, blue: 0.29, alpha: 1), // grün
        UIColor(red: 0.92, green: 0.52, blue: 0.10, alpha: 1), // orange
    ]
    /// Strichbreiten in Seitenpunkten (Seite = 768 Punkte breit)
    static let widths: [CGFloat] = [1.2, 2.2, 3.5, 5.5, 9]

    @Published var colorIndex = 0
    @Published var widthIndex = 1
    @Published var mode = ToolMode.pen
    /// Am iPhone startet jedes Dokument im Nur-Sehen-Modus
    @Published var viewOnly = UIDevice.current.userInterfaceIdiom == .phone
    @Published var menusHidden = false
    /// Kurzer Hinweis, wenn bei ausgeblendeten Menüs das Werkzeug wechselt
    @Published var flash: String?
    /// Zahl der Gäste, die gerade live zusehen (nil = nicht geteilt)
    @Published var guests: Int?

    weak var canvas: CanvasController?
    private var flashTask: Task<Void, Never>?

    /// Doppeltippen am Pencil: Radierer ↔ Stift (vom Lasso aus zum Radierer)
    func show(_ message: String, seconds: Double = 1.6) {
        flash = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    func toggleEraser() {
        mode = mode == .eraser ? .pen : .eraser
        guard menusHidden else { return }
        flash = mode == .eraser ? "Radierer" : "Stift"
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}

struct EditorView: View {
    let doc: NoteDocument
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tools = ToolState()

    var body: some View {
        // Leiste als Overlay: Wird sie breiter, darf das nie die Größe der Leinwand ändern
        Color.clear
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if !tools.menusHidden {
                        ToolBar(tools: tools, onClose: { dismiss() })
                            .padding(.top, 6)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let flash = tools.flash {
                        Text(flash)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, tools.menusHidden ? 10 : 64)
                            .transition(.opacity)
                    }
                }
            }
            .background {
                CanvasRepresentable(doc: doc, store: store, sync: sync, tools: tools)
                    .ignoresSafeArea()
            }
        .statusBarHidden(tools.menusHidden)
        .persistentSystemOverlays(tools.menusHidden ? .hidden : .automatic)
        .animation(.easeOut(duration: 0.2), value: tools.menusHidden)
        .animation(.easeOut(duration: 0.2), value: tools.flash)
    }
}

struct CanvasRepresentable: UIViewControllerRepresentable {
    let doc: NoteDocument
    let store: DocumentStore
    let sync: SyncEngine
    @ObservedObject var tools: ToolState

    func makeUIViewController(context: Context) -> CanvasController {
        let controller = CanvasController(doc: doc, store: store, sync: sync)
        controller.onFlash = { [weak tools] in tools?.show($0) }
        controller.onGuests = { [weak tools] in tools?.guests = $0 }
        controller.onToggleMenus = { [weak tools] in tools?.menusHidden.toggle() }
        controller.onToggleEraser = { [weak tools] in tools?.toggleEraser() }
        tools.canvas = controller
        return controller
    }

    func updateUIViewController(_ controller: CanvasController, context: Context) {
        controller.apply(color: ToolState.colors[tools.colorIndex],
                         width: ToolState.widths[tools.widthIndex],
                         mode: tools.mode,
                         viewOnly: tools.viewOnly)
    }
}

/// Eine schmale Leiste: zurück, Farben, Dicken, Radierer, Rückgängig
struct ToolBar: View {
    @ObservedObject var tools: ToolState
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: sizeClass == .compact ? 8 : 14) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }
            divider
            if tools.viewOnly {
                shareMenu
                divider
                Button { tools.viewOnly = false } label: {
                    Label("Bearbeiten", systemImage: "pencil.tip").labelStyle(.titleAndIcon)
                }
            } else {
            if sizeClass == .compact {
                compactPickers
            } else {
                colorButtons
                divider
                widthButtons
            }
            divider
            modeButton(.eraser, symbol: "eraser")
            modeButton(.lasso, symbol: "lasso")
            Button { tools.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            Button { tools.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
            divider
            shareMenu
            if UIDevice.current.userInterfaceIdiom == .phone {
                divider
                Button { tools.viewOnly = true } label: { Image(systemName: "eye") }
            }
            }
        }
        .font(.body)
        .tint(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var shareMenu: some View {
        HStack(spacing: 4) {
            shareMenuButton
            // Außerhalb des Menüs: dessen Beschriftung zeigt nur Symbole, die Zahl fehlte sonst
            if let n = tools.guests, n > 0 {
                Image(systemName: "eye").font(.caption)
                Text("\(n)").font(.caption.weight(.semibold))
            }
        }
    }

    private var shareMenuButton: some View {
        Menu {
            Button { tools.canvas?.startLiveSharing() } label: { Label("Live teilen (Link)", systemImage: "link") }
            if tools.guests != nil {
                Button(role: .destructive) { tools.canvas?.stopLiveSharing() } label: {
                    Label("Live-Teilen beenden", systemImage: "xmark.circle")
                }
            }
            Divider()
            Button { share(.pagePDF) } label: { Label("Diese Seite als PDF", systemImage: "doc") }
            Button { share(.pageImage) } label: { Label("Diese Seite als Bild", systemImage: "photo") }
            Button { share(.documentPDF) } label: { Label("Alles als PDF", systemImage: "doc.on.doc") }
            Divider()
            Menu {
                Button { share(.sendTo("claude")) } label: { Label("Diese Seite", systemImage: "doc") }
                Button { share(.sendDocumentTo("claude")) } label: { Label("Ganzes Dokument", systemImage: "doc.on.doc") }
            } label: { Label("An Claude senden", systemImage: "tray.and.arrow.up") }
            Menu {
                Button { share(.sendTo("chatgpt")) } label: { Label("Diese Seite", systemImage: "doc") }
                Button { share(.sendDocumentTo("chatgpt")) } label: { Label("Ganzes Dokument", systemImage: "doc.on.doc") }
            } label: { Label("An ChatGPT senden", systemImage: "tray.and.arrow.up") }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
    }

    private func share(_ kind: ShareKind) {
        guard let canvas = tools.canvas else { return }
        let b = canvas.view.bounds
        canvas.share(kind, from: CGRect(x: b.midX, y: 60, width: 1, height: 1))
    }

    private func modeButton(_ mode: ToolMode, symbol: String) -> some View {
        Button {
            tools.mode = tools.mode == mode ? .pen : mode
        } label: {
            Image(systemName: symbol)
                .padding(5)
                .background(tools.mode == mode ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 20)
    }

    private var colorButtons: some View {
        ForEach(ToolState.colors.indices, id: \.self) { i in
            let selected = tools.mode == .pen && tools.colorIndex == i
            Circle()
                .fill(Color(uiColor: ToolState.colors[i]))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
                .contentShape(Circle())
                .onTapGesture {
                    tools.colorIndex = i
                    tools.mode = .pen
                }
        }
    }

    private var widthButtons: some View {
        ForEach(ToolState.widths.indices, id: \.self) { i in
            let selected = tools.widthIndex == i
            Circle()
                .fill(Color.primary.opacity(selected ? 0.9 : 0.3))
                .frame(width: 4 + CGFloat(i) * 3, height: 4 + CGFloat(i) * 3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    tools.widthIndex = i
                    tools.mode = .pen
                }
        }
    }

    /// Am iPhone ist zu wenig Platz: Farbe und Dicke je als kleines Menü
    private var compactPickers: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(ToolState.colors.indices, id: \.self) { i in
                    Button {
                        tools.colorIndex = i
                        tools.mode = .pen
                    } label: {
                        Label(["Schwarz", "Blau", "Rot", "Grün", "Orange"][i], systemImage: "circle.fill")
                    }
                }
            } label: {
                Circle().fill(Color(uiColor: ToolState.colors[tools.colorIndex])).frame(width: 20, height: 20)
            }
            Menu {
                ForEach(ToolState.widths.indices, id: \.self) { i in
                    Button("Dicke \(i + 1)") {
                        tools.widthIndex = i
                        tools.mode = .pen
                    }
                }
            } label: {
                Circle().fill(Color.primary).frame(width: 4 + CGFloat(tools.widthIndex) * 3,
                                                   height: 4 + CGFloat(tools.widthIndex) * 3)
                    .frame(width: 24, height: 24)
            }
        }
    }
}
