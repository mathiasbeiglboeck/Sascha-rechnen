import SwiftUI
import UIKit

enum ToolMode {
    case pen, eraser, lasso
    /// Zeigestift: leuchtet, verschwindet nach etwa zehn Sekunden, wird nicht gespeichert
    case pointer
}

/// Stift, Farbe, Dicke und ob die Menüs sichtbar sind
@MainActor
final class ToolState: ObservableObject {
    static let colors: [UIColor] = [
        UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1), // schwarz
        UIColor(red: 0.66, green: 0.66, blue: 0.68, alpha: 1), // grau
        // Blau, Rot, Grün und Orange wie in Mathias' Notizen (aus seinem Bild gemessen, Display P3)
        UIColor(displayP3Red: 0x1D / 255.0, green: 0x45 / 255.0, blue: 0x8A / 255.0, alpha: 1), // blau
        UIColor(displayP3Red: 0x6B / 255.0, green: 0x13 / 255.0, blue: 0x0A / 255.0, alpha: 1), // rot
        UIColor(displayP3Red: 0x2B / 255.0, green: 0x64 / 255.0, blue: 0x53 / 255.0, alpha: 1), // grün
        UIColor(displayP3Red: 0xE8 / 255.0, green: 0x9F / 255.0, blue: 0x43 / 255.0, alpha: 1), // orange
    ]
    static let colorNames = ["Schwarz", "Grau", "Blau", "Rot", "Grün", "Orange"]
    /// Eingestellte Strichbreiten in Seitenpunkten (Seite = 768 Punkte breit, 1 Punkt ≈ 0,27 mm auf A4). Gezeichnet
    /// werden sie anders: PencilKits Stift (.pen) brachte bei Mathias' Druck nur etwa 0,69 + 0,22 × Breite aufs Papier
    /// (gemessen 19.11. an seiner Seite mit den Stufen von 120) und geht nur von etwa 0,88 bis 25,66 Punkte der
    /// Leinwand. Daraus zurückgerechnet, damit die Striche geometrisch gleichmäßig werden, je etwa 1,7-mal so dick wie
    /// der vorige: gezeichnet ≈ 0,45 · 0,83 · 1,39 · 2,32 · 3,88 (≈ 0,12 · 0,23 · 0,38 · 0,63 · 1,06 mm). Die dünnste
    /// ist der Feinstift mit fester Breite (.monoline, ohne Druck), die zweite der Stift an seiner Untergrenze. Seit
    /// 20.11. ist der Feinstift 0,25 (≈ 0,07 mm): Mit 0,45 unterschied er sich für Mathias kaum von der zweiten Stufe.
    /// Die dickste passt auch quer am 13-Zoll-iPad noch unter die Obergrenze (14,3 × 1376/768 = 25,6), so wird sie
    /// hochkant und quer gleich dick. Fester Druck macht die dicken Stufen deutlich dicker
    static let widths: [CGFloat] = [0.25, 0.65, 3.15, 7.3, 14.3]
    /// Die dünnste Stufe zeichnet der Feinstift (siehe CanvasController.makeInkingTool)
    static let fineIndex = 0
    /// Durchmesser der Punkte, die in der Leiste für die Dicken stehen: gleiche Schritte wie die Wurzel der Dicke
    static let widthDots: [CGFloat] = [3, 6.5, 10, 13.5, 17]

    @Published var colorIndex = 0
    /// Beim Start Dicke 3 (≈ 0,38 mm), am nächsten an der bisherigen Startdicke (120: ≈ 0,32 mm)
    @Published var widthIndex = 2
    @Published var mode = ToolMode.pen
    /// Am iPhone startet jedes Dokument im Nur-Sehen-Modus
    @Published var viewOnly = UIDevice.current.userInterfaceIdiom == .phone
    @Published var menusHidden = false
    /// Am iPad mit der eigenen Zeile: Antippen des Datums blendet die Leiste aus und wieder ein (Wunsch 25.11., für das
    /// iPad mini ohne Drücken am Pencil). Uhrzeit, Datum und Akku bleiben dabei stehen, die Tabs gehen mit der Leiste
    @Published var barHidden = false
    /// Am iPad wählbar: eingeklappte Leiste mit nur Radierer und Ausklappen (für Stifte ohne Drücken, z. B. am
    /// iPad mini mit dem einfachen Pencil). Bleibt auf dem Gerät gespeichert.
    @Published var menuCollapsed = UserDefaults.standard.bool(forKey: "menuCollapsed") {
        didSet { UserDefaults.standard.set(menuCollapsed, forKey: "menuCollapsed") }
    }
    /// Kurzer Hinweis, wenn bei ausgeblendeten Menüs das Werkzeug wechselt
    @Published var flash: String?
    /// Zahl der Gäste, die gerade live zusehen (nil = nicht geteilt)
    @Published var guests: Int?
    /// Seitenübersicht (drei Spalten) ist offen
    @Published var overviewShown = false

    weak var canvas: CanvasController?
    private var flashTask: Task<Void, Never>?

    /// Kurzer Hinweis oben; ein leerer Text blendet ihn aus
    func show(_ message: String, seconds: Double = 1.6) {
        flash = message.isEmpty ? nil : message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    /// Ein anderes Dokument kommt auf die Leinwand (Tab-Wechsel, Öffnen): Was zum vorigen gehörte, fällt weg.
    /// Werkzeug, Farbe und Dicke bleiben; am iPhone beginnt jedes Dokument wieder im Nur-Sehen-Modus
    func prepareForDocument() {
        overviewShown = false
        guests = nil
        if UIDevice.current.userInterfaceIdiom == .phone { viewOnly = true }
    }

    /// Doppeltippen am Pencil oder Antippen von WLAN und Akku: Radierer ↔ Stift (vom Lasso aus zum Radierer). Ohne
    /// sichtbare Leiste sagt ein Hinweis, was jetzt gilt
    func toggleEraser() {
        mode = mode == .eraser ? .pen : .eraser
        guard menusHidden || barHidden else { return }
        show(mode == .eraser ? "Radierer" : "Stift", seconds: 0.9)
    }

    /// Pencil Pro zweimal hin und her gedreht: Lasso ↔ Stift (Wunsch 25.11.). Der Hinweis kommt auch bei eingeklappter
    /// Leiste: Sie zeigt nur den Radierer, Lasso und Stift sähen dort gleich aus
    func toggleLasso() {
        mode = mode == .lasso ? .pen : .lasso
        let collapsed = UIDevice.current.userInterfaceIdiom == .pad && menuCollapsed
        guard menusHidden || barHidden || collapsed else { return }
        show(mode == .lasso ? "Lasso" : "Stift", seconds: 0.9)
    }

    /// Drücken am Pencil Pro: alle Menüs aus und wieder ein. Beim Einblenden kommt auch eine mit dem Datum
    /// ausgeblendete Leiste wieder
    func toggleMenus() {
        menusHidden.toggle()
        if !menusHidden { barHidden = false }
    }
}

/// Der Editor mit den offenen Dokumenten als Tabs; sichtbar ist immer eines davon
struct EditorView: View {
    @ObservedObject var tabs: TabsModel
    @ObservedObject var tools: ToolState
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var sync: SyncEngine

    /// Höhe der Tab-Zeile samt Abstand zur Leiste
    static let tabRowHeight: CGFloat = 32

    /// Am iPad zeichnet die App die Zeile über der Leiste selbst (Uhrzeit, Tabs, Akku) statt der Statusleiste des
    /// Systems: So stehen die Tabs oben zwischen Uhrzeit und Akku, und eine Zeile wird frei. Erst ab iPadOS 26: Davor
    /// läge oben in der Mitte der Knopf fürs Multitasking („•••“) über den Tabs; ab 26 sitzen die Fensterknöpfe links,
    /// und die Zeile weicht ihnen aus (StatusLine)
    private var ownStatusLine: Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        if #available(iOS 26, *) { return true }
        return false
    }
    private var collapsed: Bool { UIDevice.current.userInterfaceIdiom == .pad && tools.menuCollapsed }
    /// Tabs stehen über der Leiste, wenn sie eingeblendet und ausgeklappt ist; auch ein einzelner, damit sich jeder
    /// Tab mit seinem Kreuz schließen lässt (der letzte führt zurück zur Übersicht)
    private var tabsShown: Bool { !tools.menusHidden && !tools.barHidden && !collapsed && !tabs.ids.isEmpty }
    /// Was über der Leiste steht: am iPad die eigene Zeile, am iPhone die Tabs
    private var aboveBar: CGFloat { ownStatusLine ? StatusLine.height : (tabsShown ? Self.tabRowHeight : 0) }
    /// Hinweise stehen unter der Leiste; ohne sie gleich unter der eigenen Zeile, ohne Menüs ganz oben
    private var flashTop: CGFloat {
        if tools.menusHidden { return 10 }
        return tools.barHidden ? aboveBar + 10 : 64 + aboveBar
    }

    // Antippen in der eigenen Zeile am iPad (Wunsch 25.11.)

    /// Uhrzeit: zur Übersicht der Notizbücher, wie „zurück“ in der Leiste (die Tabs bleiben offen)
    private func tapClock() { tabs.closeEditor() }
    /// Datum: Leiste aus und wieder ein
    private func tapDate() { tools.barHidden.toggle() }
    /// WLAN und Akku: Stift ↔ Radierer, wie Doppeltippen am Pencil
    private func tapDevice() { tools.toggleEraser() }

    var body: some View {
        // Leiste als Overlay: Wird sie breiter, darf das nie die Größe der Leinwand ändern
        Color.clear
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if !tools.menusHidden {
                        VStack(spacing: 6) {
                            if ownStatusLine {
                                StatusLine(tabs: tabs, showTabs: tabsShown,
                                           onClock: { tapClock() }, onDate: { tapDate() }, onDevice: { tapDevice() })
                            } else if tabsShown {
                                TabStrip(tabs: tabs)
                                    .transition(.opacity)
                            }
                            if !tools.barHidden {
                                ToolBar(tools: tools, onClose: { tabs.closeEditor() })
                                    .padding(.horizontal, 12)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.top, ownStatusLine ? 0 : 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if let flash = tools.flash {
                        // Lange Hinweise (etwa mit einem Dokumentnamen) brechen am iPhone um: dann mittig, und die
                        // Ecken runden sich wie eine Kapsel, ohne den Text anzuschneiden
                        Text(flash)
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .padding(.horizontal, 16)
                            .padding(.top, flashTop)
                            .transition(.opacity)
                    }
                }
            }
            .background {
                // Je Tab und Wechsel eine eigene Leinwand: Die vorige ist da schon geschlossen (TabsModel). Platz für
                // die Tab-Zeile (am iPad die eigene Zeile) hat sie immer, auch bei eingeklappter Leiste: Die Zeile
                // kommt und geht ohne neue Leinwand (Ausklappen, Menüs ein), ihr Rand oben gilt aber ab dem Öffnen
                if let doc = tabs.activeDocument {
                    CanvasRepresentable(doc: doc, store: store, sync: sync, tools: tools,
                                        start: tabs.viewport(for: doc.id),
                                        topExtra: ownStatusLine ? StatusLine.height : Self.tabRowHeight,
                                        ownStatusLine: ownStatusLine)
                        .id("\(doc.id.uuidString)-\(tabs.generation)")
                        .ignoresSafeArea()
                }
            }
        // Die Übersicht liegt über der Leinwand statt in einem eigenen Vollbild: So bleibt die Leinwand offen,
        // gleicht weiter ab und bekommt fremde Striche direkt (ein Vollbild würde sie wie beim Schließen abmelden)
        .overlay {
            if tools.overviewShown, let canvas = tools.canvas {
                // Auch über der Übersicht die eigene Zeile statt der Statusleiste: Kommt diese beim Öffnen wieder,
                // ändert sich der sichere Bereich, und Leiste und Leinwand darunter springen. Die Zeile steht über der
                // Übersicht, nicht als safeAreaInset: Dessen Rand übergeht die Titelzeile der NavigationStack, sie lag
                // dann unter Uhrzeit und WLAN (Runde 7)
                VStack(spacing: 0) {
                    // Die Uhrzeit führt auch von hier zu den Notizbüchern; Datum und Akku tun hier nichts (keine Leiste,
                    // kein Stift)
                    if ownStatusLine { StatusLine(tabs: tabs, showTabs: false, onClock: { tapClock() }) }
                    PageOverview(controller: canvas) { tools.overviewShown = false }
                }
                .background(Color(white: 0.92).ignoresSafeArea())
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: tools.overviewShown)
        // Am iPad ersetzt die eigene Zeile die Statusleiste, auch über der Seitenübersicht
        .statusBarHidden(tools.menusHidden || ownStatusLine)
        .persistentSystemOverlays(tools.menusHidden ? .hidden : .automatic)
        .animation(.easeOut(duration: 0.2), value: tools.menusHidden)
        .animation(.easeOut(duration: 0.2), value: tools.barHidden)
        .animation(.easeOut(duration: 0.2), value: tools.menuCollapsed)
        .animation(.easeOut(duration: 0.2), value: tools.flash)
        .animation(.easeOut(duration: 0.2), value: tabsShown)
        #if DEBUG
        // Nur für Tests im Simulator: notizbuch://debug/… (CanvasController.debugCommand)
        .onOpenURL { url in
            guard url.scheme == "notizbuch", url.host == "debug" else { return }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            // debug/tool?mode=pen|eraser|lasso|pointer&edit: Werkzeug wie in der Leiste wählen (edit: wie „Bearbeiten“);
            // &width=0…4, &overview=1|0 (Seitenübersicht), &collapsed=1|0 (eingeklappte Leiste), &menus=0|1 (Menüs aus/an),
            // &bar=0|1 (Leiste aus/an wie mit dem Datum)
            if url.path == "/tool" {
                switch value("mode") {
                case "pen"?: tools.mode = .pen
                case "eraser"?: tools.mode = .eraser
                case "lasso"?: tools.mode = .lasso
                case "pointer"?: tools.mode = .pointer
                default: break
                }
                if items.contains(where: { $0.name == "edit" }) { tools.viewOnly = false }
                if let i = value("width").flatMap({ Int($0) }), ToolState.widths.indices.contains(i) { tools.widthIndex = i }
                if let v = value("overview") { tools.overviewShown = v == "1" }
                if let v = value("collapsed") { tools.menuCollapsed = v == "1" }
                if let v = value("menus") { tools.menusHidden = v == "0" }
                if let v = value("bar") { tools.barHidden = v == "0" }
                return
            }
            // debug/status?tap=clock|date|device: wie Antippen von Uhrzeit, Datum oder WLAN/Akku in der eigenen Zeile;
            // tap=squeeze wie Drücken am Pencil Pro. Eine halbe Sekunde danach steht im Protokoll („Status-Debug: …“),
            // was dann gilt (ein Hinweis steht 0,9 s)
            if url.path == "/status" {
                let tap = value("tap") ?? "-"
                let tools = self.tools, tabs = self.tabs
                switch tap {
                case "clock": tapClock()
                case "date": tapDate()
                case "device": tapDevice()
                case "squeeze": tools.toggleMenus()
                default: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSLog("Status-Debug: %@ → Editor %@, Leiste %@, Menüs %@, Übersicht %@, Werkzeug %@, Hinweis %@", tap,
                          tabs.editorShown ? "offen" : "zu", tools.barHidden ? "aus" : "an",
                          tools.menusHidden ? "aus" : "an", tools.overviewShown ? "offen" : "zu", "\(tools.mode)",
                          tools.flash ?? "-")
                }
                return
            }
            // debug/awake?lowpower=1|0|auto&seconds=N: Stromsparmodus vortäuschen, Frist verkürzen; meldet den Stand
            if url.path == "/awake" {
                KeepAwake.shared.debug(lowPower: value("lowpower"), seconds: value("seconds").flatMap { Double($0) })
                return
            }
            tools.canvas?.debugCommand(url)
        }
        #endif
    }
}

struct CanvasRepresentable: UIViewControllerRepresentable {
    let doc: NoteDocument
    let store: DocumentStore
    let sync: SyncEngine
    @ObservedObject var tools: ToolState
    /// Wo die Leinwand öffnet (zurück in einem Tab); nil = oben
    var start: Viewport? = nil
    /// Platz für die Tabs über der Leiste (am iPad für die eigene Zeile)
    var topExtra: CGFloat = 0
    /// Am iPad steht die eigene Zeile an Stelle der Statusleiste des Systems
    var ownStatusLine = false

    func makeUIViewController(context: Context) -> CanvasController {
        let controller = CanvasController(doc: doc, store: store, sync: sync, start: start, topExtra: topExtra,
                                          ownStatusLine: ownStatusLine)
        controller.onFlash = { [weak tools] in tools?.show($0) }
        controller.onFlashTimed = { [weak tools] in tools?.show($0, seconds: $1) }
        // Gästezahl nur für das Dokument, das gerade zu sehen ist: Eine späte Antwort einer schon verlassenen Leinwand
        // (Teilen wartet noch auf den Server) gilt so wieder, wenn ihr Dokument vorne ist, aber nie für einen anderen Tab
        let id = doc.id
        controller.onGuests = { [weak tools] guests in
            if tools?.canvas?.doc.id == id { tools?.guests = guests }
        }
        controller.onToggleMenus = { [weak tools] in tools?.toggleMenus() }
        controller.onToggleEraser = { [weak tools] in tools?.toggleEraser() }
        controller.onToggleLasso = { [weak tools] in tools?.toggleLasso() }
        tools.canvas = controller
        return controller
    }

    func updateUIViewController(_ controller: CanvasController, context: Context) {
        controller.apply(color: ToolState.colors[tools.colorIndex],
                         width: ToolState.widths[tools.widthIndex],
                         fine: tools.widthIndex == ToolState.fineIndex,
                         mode: tools.mode,
                         viewOnly: tools.viewOnly)
    }

    /// Die Leinwand verschwindet (Tab-Wechsel, Editor zu): spätestens jetzt speichern und abmelden. Meist ist das
    /// schon geschehen (TabsModel schließt sie vor dem Wechsel), dann ändert es nichts
    static func dismantleUIViewController(_ controller: CanvasController, coordinator: ()) {
        controller.leave()
    }
}

/// Eine schmale Leiste: zurück, Farben, Dicken, Radierer, Rückgängig
struct ToolBar: View {
    @ObservedObject var tools: ToolState
    let onClose: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isPad && tools.menuCollapsed {
            collapsedBar
        } else if sizeClass == .compact {
            // Am iPhone (und in schmalen Fenstern am iPad) über die ganze Breite: Jedes Feld wird so breit, wie Platz
            // ist, und so hoch wie die Leiste, das Tippen geht leichter
            bar(spacing: 0, compact: true, wide: true)
        } else {
            // Schmale iPads (iPad mini: 744 bis 768 Punkte im Hochformat) und geteilter Bildschirm: erst enger, dann
            // wie am iPhone, statt über den Rand hinaus
            ViewThatFits(in: .horizontal) {
                bar(spacing: 14, compact: false)
                bar(spacing: 8, compact: false)
                bar(spacing: 7, compact: true)
            }
        }
    }

    private func bar(spacing: CGFloat, compact: Bool, wide: Bool = false) -> some View {
        HStack(spacing: spacing) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold)).cell(wide)
            }
            Button { tools.overviewShown = true } label: { Image(systemName: "square.grid.3x3").cell(wide) }
            divider
            if tools.viewOnly {
                shareMenu(wide)
                divider
                Button { tools.viewOnly = false } label: {
                    // Nie gekürzt und nie über die Nachbarn: Das Feld ist genau so breit wie die Beschriftung, die
                    // anderen teilen sich den Rest
                    Label("Bearbeiten", systemImage: "pencil.tip").labelStyle(.titleAndIcon)
                        .padding(.horizontal, wide ? 10 : 0)
                        .frame(minHeight: wide ? 44 : nil)
                        .contentShape(Rectangle())
                        .fixedSize()
                }
            } else {
            if compact {
                compactPickers(wide)
            } else {
                colorButtons
                divider
                widthButtons
            }
            divider
            if compact {
                // Am iPhone ist zu wenig Platz: Werkzeuge in einem Menü
                modeMenu(wide)
            } else {
                modeButton(.pointer, symbol: "scribble", tint: Color(uiColor: PointerOverlay.ownColor))
                modeButton(.eraser, symbol: "eraser")
                modeButton(.lasso, symbol: "lasso")
            }
            Button { tools.canvas?.undo() } label: { Image(systemName: "arrow.uturn.backward").cell(wide) }
            Button { tools.canvas?.redo() } label: { Image(systemName: "arrow.uturn.forward").cell(wide) }
            divider
            shareMenu(wide)
            if UIDevice.current.userInterfaceIdiom == .phone {
                divider
                Button { tools.viewOnly = true } label: { Image(systemName: "eye").cell(wide) }
            }
            if isPad {
                divider
                Button { tools.menuCollapsed = true } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").cell(wide)
                }
                .accessibilityLabel("Leiste einklappen")
            }
            }
        }
        .font(.body)
        .tint(.primary)
        .padding(.horizontal, wide ? 6 : (compact ? 12 : 16))
        .padding(.vertical, wide ? 2 : 8)
        // Quer am iPhone nicht über die ganze, sehr breite Zeile
        .frame(maxWidth: wide ? 600 : nil)
        .barBackground()
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Eingeklappt: nur Radierer (an/aus) und Ausklappen
    private var collapsedBar: some View {
        HStack(spacing: 10) {
            modeButton(.eraser, symbol: "eraser")
            Button { tools.menuCollapsed = false } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").padding(5)
            }
            .accessibilityLabel("Leiste ausklappen")
        }
        .font(.body)
        .tint(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .barBackground()
    }

    private func shareMenu(_ wide: Bool) -> some View {
        HStack(spacing: 4) {
            shareMenuButton(wide)
            // Außerhalb des Menüs: dessen Beschriftung zeigt nur Symbole, die Zahl fehlte sonst
            if let n = tools.guests, n > 0 {
                Image(systemName: "eye").font(.caption)
                Text("\(n)").font(.caption.weight(.semibold))
            }
        }
    }

    private func shareMenuButton(_ wide: Bool) -> some View {
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
            Image(systemName: "square.and.arrow.up").cell(wide)
        }
    }

    private func share(_ kind: ShareKind) {
        guard let canvas = tools.canvas else { return }
        let b = canvas.view.bounds
        canvas.share(kind, from: CGRect(x: b.midX, y: 60, width: 1, height: 1))
    }

    /// Stift, Zeigestift, Radierer und Lasso in einem Menü; zeigt das aktuelle Werkzeug
    private func modeMenu(_ wide: Bool) -> some View {
        Menu {
            Button { tools.mode = .pen } label: { Label("Stift", systemImage: "pencil.tip") }
            Button { tools.mode = .pointer } label: { Label("Zeigestift", systemImage: "scribble") }
            Button { tools.mode = .eraser } label: { Label("Radierer", systemImage: "eraser") }
            Button { tools.mode = .lasso } label: { Label("Lasso", systemImage: "lasso") }
        } label: {
            Image(systemName: Self.symbol(for: tools.mode))
                .foregroundStyle(tools.mode == .pointer ? Color(uiColor: PointerOverlay.ownColor) : Color.primary)
                .padding(5)
                .background(tools.mode == .pen ? Color.clear : Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .cell(wide)
        }
    }

    private static func symbol(for mode: ToolMode) -> String {
        switch mode {
        case .pen: return "pencil.tip"
        case .pointer: return "scribble"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        }
    }

    private func modeButton(_ mode: ToolMode, symbol: String, tint: Color? = nil) -> some View {
        Button {
            tools.mode = tools.mode == mode ? .pen : mode
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? Color.primary)
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
                .frame(width: ToolState.widthDots[i], height: ToolState.widthDots[i])
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    tools.widthIndex = i
                    tools.mode = .pen
                }
        }
    }

    /// Am iPhone ist zu wenig Platz: Farbe und Dicke je als kleines Menü. Zwei eigene Felder der Leiste (Group statt
    /// HStack): In der breiten Leiste bekommt so jedes so viel Platz wie die anderen
    private func compactPickers(_ wide: Bool) -> some View {
        Group {
            Menu {
                ForEach(ToolState.colors.indices, id: \.self) { i in
                    Button {
                        tools.colorIndex = i
                        tools.mode = .pen
                    } label: {
                        Label(ToolState.colorNames[i], systemImage: "circle.fill")
                    }
                }
            } label: {
                Self.dot(ToolState.colors[tools.colorIndex], diameter: 20).cell(wide)
            }
            // Schmales iPad: wie bisher etwas mehr Abstand zwischen Farbe und Dicke
            .padding(.trailing, wide ? 0 : 7)
            Menu {
                ForEach(ToolState.widths.indices, id: \.self) { i in
                    Button("Dicke \(i + 1)") {
                        tools.widthIndex = i
                        tools.mode = .pen
                    }
                }
            } label: {
                Self.dot(colorScheme == .dark ? .white : UIColor(white: 0.1, alpha: 1),
                         diameter: ToolState.widthDots[tools.widthIndex]).cell(wide)
            }
        }
    }

    /// Ein gefüllter Kreis als fertiges Bild (24 × 24 Punkte): Die Beschriftung eines Menüs zeigt ein Bild verlässlich
    /// so, wie es ist; der Punkt für die Dicke war als Form darin am iPhone nicht zu sehen
    private static func dot(_ color: UIColor, diameter: CGFloat) -> some View {
        let box: CGFloat = 24
        let image = UIGraphicsImageRenderer(size: CGSize(width: box, height: box)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: (box - diameter) / 2, y: (box - diameter) / 2,
                                        width: diameter, height: diameter)).fill()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
    }
}

private extension View {
    /// Hintergrund der Leiste: undurchsichtig mit leichtem Schatten, wie vor dem 19.11. (Wunsch 25.11.: halbdurchsichtig
    /// war zu unruhig). Die Tabs bleiben halbdurchsichtig
    func barBackground() -> some View {
        background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    /// Ein Feld der breiten Leiste am iPhone: so breit, wie Platz ist (alle gleich), und 44 Punkte hoch; die ganze
    /// Fläche nimmt das Tippen an, nicht nur das Symbol
    @ViewBuilder func cell(_ wide: Bool) -> some View {
        if wide {
            frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        } else {
            self
        }
    }
}
