import SwiftUI
import UniformTypeIdentifiers

/// Startseite: alle Notizbücher und PDFs als Karten, das zuletzt bearbeitete zuerst
struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
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

                if sync.isConfigured {
                    Text(syncLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 24)
                }
            }
            .refreshable { await sync.syncLibrary() }
            // Bibliothek alle 20 Sekunden abgleichen, solange die Übersicht sichtbar ist
            .task(id: openDoc == nil) {
                guard openDoc == nil else { return }
                while !Task.isCancelled {
                    await sync.syncLibrary()
                    try? await Task.sleep(for: .seconds(20))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await sync.syncLibrary() } }
            }
            .sheet(isPresented: $showSettings) {
                SyncSettingsView().environmentObject(sync)
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Label("Sync", systemImage: "gearshape") }
                }
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
            // PDFs, die aus einer anderen App (Dateien, Mail, AirDrop …) mit „Notizbuch“ geöffnet werden
            .onOpenURL { url in
                guard url.pathExtension.lowercased() == "pdf" else { return }
                do {
                    let doc = try store.importPDF(from: url)
                    openDoc = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openDoc = doc }
                } catch {
                    importError = error.localizedDescription
                }
            }
            .fullScreenCover(item: $openDoc, onDismiss: { store.reload() }) { doc in
                EditorView(doc: doc).environmentObject(store).environmentObject(sync)
            }
            .alert("Umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Titel", text: $newTitle)
                Button("Abbrechen", role: .cancel) {}
                Button("OK") { if let doc = renaming { store.rename(doc, to: newTitle) } }
            }
            .confirmationDialog("„\(deleting?.title ?? "")“ löschen?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Löschen", role: .destructive) { if let doc = deleting {
                    sync.noteDeleted(doc.id)
                    store.delete(doc)
                } }
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

extension LibraryView {
    private var syncLine: String {
        if !sync.status.isEmpty { return "Sync: " + sync.status }
        guard let last = sync.lastSync else { return "Sync …" }
        return "Abgeglichen " + last.formatted(date: .omitted, time: .shortened)
    }
}

/// Server-Adresse und Schlüssel, einmal je Gerät eintragen
struct SyncSettingsView: View {
    @EnvironmentObject private var sync: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://notizbuch.….workers.dev", text: $sync.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Schlüssel", text: $sync.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Auf iPad und iPhone dieselbe Adresse und denselben Schlüssel eintragen.")
                }
                Section {
                    Button(testing ? "Prüfe …" : "Verbindung prüfen") {
                        testing = true
                        Task {
                            do {
                                let n = try await sync.test()
                                result = "Verbunden, \(n) Dokumente am Server"
                                await sync.syncLibrary()
                            } catch {
                                result = error.localizedDescription
                            }
                            testing = false
                        }
                    }
                    .disabled(!sync.isConfigured || testing)
                    if let result { Text(result).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
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
