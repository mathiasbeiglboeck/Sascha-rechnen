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

private struct ImageBox: @unchecked Sendable { let image: UIImage }

/// Alle Seiten des Dokuments in drei Spalten: antippen springt hin,
/// langes Drücken (oder „Auswählen“) löscht Seiten oder fügt leere ein.
@MainActor
struct PageOverview: View {
    let controller: CanvasController
    let onClose: () -> Void

    @State private var export: PageExport
    /// Zählt Änderungen an den Seiten, damit die Vorschaubilder neu entstehen
    @State private var version = 0
    @State private var current: Int
    @State private var selecting = false
    @State private var selected = Set<Int>()
    @State private var busy = false
    @State private var canUndo = false
    @State private var message: String?
    @State private var cache = ThumbnailCache()

    init(controller: CanvasController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        _export = State(initialValue: controller.overviewSnapshot())
        _current = State(initialValue: controller.currentPageIndex)
    }

    private var count: Int { export.frames.count }

    var body: some View {
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
        .onDisappear { controller.discardPageUndo() }
    }

    // MARK: Zellen

    private func cell(_ i: Int) -> some View {
        let isSelected = selected.contains(i)
        let highlight = selecting ? isSelected : i == current
        return VStack(spacing: 6) {
            PageThumbnail(export: export, index: i, version: version, cache: cache)
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
            Text("\(i + 1)")
                .font(.caption.weight(i == current ? .semibold : .regular))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(i) }
        .contextMenu {
            Button { insert(at: i) } label: { Label("Leere Seite davor", systemImage: "arrow.up.doc") }
            Button { insert(at: i + 1) } label: { Label("Leere Seite danach", systemImage: "arrow.down.doc") }
            Divider()
            Button(role: .destructive) { delete([i]) } label: { Label("Seite löschen", systemImage: "trash") }
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
        guard !pages.isEmpty else { return }
        busy = true
        controller.deletePages(pages) { error in
            finished(error, success: pages.count == 1 ? "Seite gelöscht" : "\(pages.count) Seiten gelöscht")
        }
    }

    private func insert(at index: Int) {
        busy = true
        controller.insertBlankPage(at: index) { error in
            finished(error, success: "Leere Seite \(min(index, count) + 1) eingefügt")
        }
    }

    private func undo() {
        busy = true
        controller.undoPageChange { error in
            finished(error, success: "Rückgängig gemacht")
            canUndo = false
        }
    }

    private func finished(_ error: String?, success: String) {
        busy = false
        if error == nil {
            export = controller.overviewSnapshot()
            version += 1
            selected = []
            current = min(current, export.frames.count - 1)
        }
        canUndo = controller.canUndoPageChange
        show(error ?? success)
    }

    private func show(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if message == text { message = nil }
        }
    }
}

/// Ein Vorschaubild, im Hintergrund gezeichnet; außerhalb des Bildschirms wird es freigegeben
@MainActor
struct PageThumbnail: View {
    let export: PageExport
    let index: Int
    let version: Int
    let cache: ThumbnailCache
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let frame = export.frames[index]
        GeometryReader { geo in
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image).resizable().interpolation(.medium)
                }
            }
            .task(id: "\(version)-\(index)-\(Int(geo.size.width))") { await load(width: geo.size.width) }
        }
        .aspectRatio(frame.width / max(frame.height, 1), contentMode: .fit)
        .onDisappear { image = nil }
    }

    private func load(width: CGFloat) async {
        guard width > 0, export.frames.indices.contains(index) else { return }
        let px = min((width * displayScale).rounded(), 900)
        let key = "\(version)-\(index)-\(Int(px))" as NSString
        if let hit = cache.images.object(forKey: key) {
            image = hit
            return
        }
        let export = self.export, i = index
        guard let box = try? await PageExport.run({ ImageBox(image: export.thumbnail(page: i, pixelWidth: px)) }),
              !Task.isCancelled else { return }
        let img = box.image
        cache.images.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4))
        image = img
    }
}
