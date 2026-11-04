import SwiftUI
import UniformTypeIdentifiers

/// Startseite: alle Notizbücher und PDFs als Karten, das zuletzt bearbeitete zuerst
struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var openDoc: NoteDocument?
    @State private var importing = false
    @State private var renaming: NoteDocument?
    @State private var newTitle = ""
    @State private var deleting: NoteDocument?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)], spacing: 28) {
                    ForEach(store.documents) { doc in
                        DocCard(doc: doc)
                            .onTapGesture { openDoc = doc }
                            .contextMenu {
                                Button {
                                    newTitle = doc.title
                                    renaming = doc
                                } label: { Label("Umbenennen", systemImage: "pencil") }
                                Button(role: .destructive) {
                                    deleting = doc
                                } label: { Label("Löschen", systemImage: "trash") }
                            }
                    }
                }
                .padding(24)
            }
            .background(Color(red: 0.95, green: 0.95, blue: 0.93))
            .overlay {
                if store.documents.isEmpty {
                    ContentUnavailableView("Noch leer", systemImage: "square.and.pencil",
                                           description: Text("Leg ein Notizbuch an oder importiere ein PDF."))
                }
            }
            .navigationTitle("Notizbuch")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: { Label("PDF importieren", systemImage: "doc.badge.plus") }
                    Button { openDoc = store.createNotebook() } label: { Label("Neues Notizbuch", systemImage: "square.and.pencil") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                do {
                    openDoc = try store.importPDF(from: result.get())
                } catch {
                    importError = error.localizedDescription
                }
            }
            .fullScreenCover(item: $openDoc, onDismiss: { store.reload() }) { doc in
                EditorView(doc: doc).environmentObject(store)
            }
            .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Titel", text: $newTitle)
                Button("Abbrechen", role: .cancel) {}
                Button("OK") { if let doc = renaming { store.rename(doc, to: newTitle) } }
            }
            .confirmationDialog("„\(deleting?.title ?? "")“ löschen?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { if let doc = deleting { store.delete(doc) } }
            }
            .alert("PDF konnte nicht importiert werden",
                   isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }
}

struct DocCard: View {
    let doc: NoteDocument
    @EnvironmentObject private var store: DocumentStore
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
            .aspectRatio(210 / 297, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)

            HStack(spacing: 6) {
                if doc.kind == .pdf {
                    Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                }
                Text(doc.title).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            Text(doc.modified.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: doc.modified) {
            image = store.thumbnail(for: doc, width: 300)
        }
    }
}
