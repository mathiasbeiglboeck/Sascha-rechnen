import SwiftUI
import UIKit

/// Vorschaubilder der Übersicht; nur so viele, wie in den Speicher passen
final class ThumbnailCache {
    let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 120_000_000
        return cache
    }()
}

/// Höchstens zwei Vorschaubilder gleichzeitig zeichnen, das zuletzt angefragte zuerst: Die Seiten, bei denen
/// man nach schnellem Scrollen stehen bleibt, kommen sofort dran, statt hinter den vorbeigeflogenen zu warten
actor ThumbnailGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        guard running >= limit else {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if let next = waiting.popLast() {
            next.resume() // der Platz geht direkt weiter
        } else {
            running = max(running - 1, 0)
        }
    }
}

private struct ImageBox: @unchecked Sendable { let image: UIImage }

/// Alle Seiten des Dokuments in drei Spalten: antippen springt hin,
/// langes Drücken (oder „Auswählen“) löscht Seiten oder fügt leere ein.
/// Liegt über der Leinwand (kein eigenes Vollbild): Die Leinwand bleibt offen und gleicht weiter ab.
@MainActor
struct PageOverview: View {
    let controller: CanvasController
    let onClose: () -> Void

    /// Seiten mit Hintergrund und Tinte; nil, solange die erste Momentaufnahme im Hintergrund entsteht
    @State private var export: PageExport?
    /// Seitenrahmen (sofort da, damit das Raster schon steht, bevor die Bilder kommen)
    @State private var frames: [CGRect]
    /// Zählt Änderungen an der Seitenordnung, damit die Vorschaubilder neu entstehen
    @State private var version = 0
    /// Zählt neue Momentaufnahmen (z. B. fremde Striche); neu gezeichnet wird nur, wo sich die Tinte geändert hat
    @State private var inkVersion = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var current: Int
    @State private var selecting = false
    @State private var selected = Set<Int>()
    @State private var busy = false
    @State private var canUndo = false
    @State private var message: String?
    @State private var cache = ThumbnailCache()
    @State private var gate = ThumbnailGate(limit: 2)

    init(controller: CanvasController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        // Nur lesen, nichts auslösen: SwiftUI ruft das bei jedem Neuaufbau des Editors auf
        _frames = State(initialValue: controller.layout.frames)
        _current = State(initialValue: controller.currentPageIndex)
    }

    private var count: Int { frames.count }

    var body: some View {
        ZStack {
            Color(white: 0.92).ignoresSafeArea()
            NavigationStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 20) {
                            ForEach(0..<count, id: \.self) { i in
                                cell(i).id(i)
                            }
                        }
                        .padding(20)
                    }
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
                .background(Color(white: 0.92))
                .navigationTitle(count == 1 ? "1 Seite" : "\(count) Seiten")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) {
                    if selecting { selectionBar }
                }
                .overlay {
                    if busy {
                        ProgressView().controlSize(.large)
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let message {
                        Text(message)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, selecting ? 80 : 24)
                    }
                }
                .disabled(busy)
            }
        }
        .task {
            canUndo = controller.canUndoPageChange
            // Kommen Striche von anderen Geräten oder ändern sich dort Seiten, Vorschau nachziehen
            controller.onPagesChanged = { scheduleRefresh() }
            if let fresh = await snapshot() { install(fresh) }
        }
        .onDisappear {
            refreshTask?.cancel()
            controller.onPagesChanged = nil
            controller.discardPageUndo()
        }
    }

    /// Momentaufnahme: fremde Striche zuerst auf die Leinwand, dann im Hintergrund umrechnen und nach Seiten ordnen
    private func snapshot() async -> PageExport? {
        let source = controller.overviewSource()
        return try? await PageExport.run { source.build() }
    }

    /// Neue Momentaufnahme übernehmen; `reordered`: Seiten wurden hier gelöscht oder eingefügt
    private func install(_ fresh: PageExport, reordered: Bool = false) {
        if reordered || fresh.frames != frames || (export != nil && fresh.pdf !== export?.pdf) {
            // Andere Seitenordnung: alle Bilder neu, die Auswahl passt nicht mehr
            version += 1
            selected = []
        }
        export = fresh
        frames = fresh.frames
        inkVersion += 1
        current = min(current, max(fresh.frames.count - 1, 0))
        canUndo = controller.canUndoPageChange
    }

    // MARK: Zellen

    private func cell(_ i: Int) -> some View {
        let isSelected = selected.contains(i)
        let highlight = selecting ? isSelected : i == current
        return VStack(spacing: 6) {
            PageThumbnail(export: export, frame: frames[i], index: i, version: version, inkVersion: inkVersion,
                          cache: cache, gate: gate)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(highlight ? Color.accentColor : Color.black.opacity(0.12), lineWidth: highlight ? 3 : 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .background(Circle().fill(.white))
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            ZStack {
                Text("\(i + 1)")
                    .font(.caption.weight(i == current ? .semibold : .regular))
                    .foregroundStyle(.secondary)
                if !selecting {
                    HStack {
                        Spacer()
                        // Sichtbarer Weg zum Seitenmenü (langes Drücken geht auch)
                        Menu { pageActions(i) } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 26)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(i) }
        .contextMenu { pageActions(i) }
    }

    @ViewBuilder
    private func pageActions(_ i: Int) -> some View {
        Button { insert(at: i) } label: { Label("Leere Seite davor", systemImage: "arrow.up.doc") }
        Button { insert(at: i + 1) } label: { Label("Leere Seite danach", systemImage: "arrow.down.doc") }
        Divider()
        Button(role: .destructive) { delete([i]) } label: { Label("Seite löschen", systemImage: "trash") }
    }

    /// Neue Momentaufnahme kurz nach der letzten Änderung von außen (nicht bei jedem einzelnen Strich)
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, !busy else { return }
            guard let fresh = await snapshot(), !Task.isCancelled, !busy else { return }
            install(fresh)
        }
    }

    private func tap(_ i: Int) {
        if selecting {
            if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
        } else {
            controller.scrollToPage(i)
            onClose()
        }
    }

    // MARK: Leisten

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { onClose() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if canUndo {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
            }
            Button { insert(at: count) } label: { Image(systemName: "plus") }
            Button(selecting ? "Fertig" : "Auswählen") {
                selecting.toggle()
                selected = []
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 22) {
            Text(selected.isEmpty ? "Seiten antippen" : selected.count == 1 ? "1 Seite" : "\(selected.count) Seiten")
                .foregroundStyle(.secondary)
            Spacer()
            if selected.count == 1, let i = selected.first {
                Button { insert(at: i) } label: { Label("Davor", systemImage: "arrow.up.doc") }
                Button { insert(at: i + 1) } label: { Label("Danach", systemImage: "arrow.down.doc") }
            }
            Button(role: .destructive) { delete(selected) } label: { Label("Löschen", systemImage: "trash") }
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: Aktionen

    private func delete(_ pages: Set<Int>) {
        guard !pages.isEmpty, !busy else { return }
        busy = true
        refreshTask?.cancel()
        let before = controller.pageTotal
        controller.deletePages(pages) { error in
            finished(error) { after in
                // Gezählt wird, was wirklich wegfiel (die leere Seite am Ende bleibt immer)
                let n = before - after
                return n == 1 ? "Seite gelöscht" : "\(max(n, 0)) Seiten gelöscht"
            }
        }
    }

    private func insert(at index: Int) {
        guard !busy else { return }
        busy = true
        refreshTask?.cancel()
        let number = min(max(index, 0), count) + 1
        controller.insertBlankPage(at: index) { error in
            finished(error) { _ in "Leere Seite \(number) eingefügt" }
        }
    }

    private func undo() {
        guard !busy else { return }
        busy = true
        refreshTask?.cancel()
        controller.undoPageChange { error in
            finished(error) { _ in "Rückgängig gemacht" }
        }
    }

    /// Nach einer Seitenänderung: neue Vorschau (im Hintergrund), dann Meldung
    private func finished(_ error: String?, success: @escaping (Int) -> String) {
        Task {
            if error == nil, let fresh = await snapshot() { install(fresh, reordered: true) }
            busy = false
            canUndo = controller.canUndoPageChange
            show(error ?? success(controller.pageTotal))
        }
    }

    private func show(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if message == text { message = nil }
        }
    }
}

/// Ein Vorschaubild, im Hintergrund gezeichnet. Außerhalb des Bildschirms wird es freigegeben, bleibt aber
/// im Zwischenspeicher, sodass es beim Zurückscrollen sofort wieder da ist.
@MainActor
struct PageThumbnail: View {
    let export: PageExport?
    let frame: CGRect
    let index: Int
    let version: Int
    let inkVersion: Int
    let cache: ThumbnailCache
    let gate: ThumbnailGate
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image).resizable().interpolation(.medium)
                }
            }
            .task(id: "\(version)-\(inkVersion)-\(index)-\(Int(geo.size.width))") { await load(width: geo.size.width) }
        }
        .aspectRatio(frame.width / max(frame.height, 1), contentMode: .fit)
        .onDisappear { image = nil }
    }

    private func load(width: CGFloat) async {
        guard let export, width > 0, export.frames.indices.contains(index) else { return }
        let px = min((width * displayScale).rounded(), 900)
        let i = index, version = self.version
        let ink = (try? await PageExport.run { export.inkFingerprint(page: i) }) ?? 0
        guard !Task.isCancelled else { return }
        let key = "\(version)-\(i)-\(ink)-\(Int(px))" as NSString
        if let hit = cache.images.object(forKey: key) {
            image = hit
            return
        }
        // Was beim schnellen Scrollen nur vorbeifliegt, gar nicht erst zeichnen
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        await gate.enter()
        guard !Task.isCancelled else {
            await gate.leave()
            return
        }
        let box = try? await PageExport.run { ImageBox(image: export.thumbnail(page: i, pixelWidth: px)) }
        await gate.leave()
        guard let img = box?.image else { return }
        // Auch wenn die Zelle inzwischen weg ist: merken, damit das Bild beim Zurückscrollen sofort da ist
        cache.images.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4))
        if !Task.isCancelled { image = img }
    }
}
