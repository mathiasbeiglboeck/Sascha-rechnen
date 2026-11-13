import SwiftUI
import UniformTypeIdentifiers

/// Startseite: alle Notizbücher und PDFs als Karten, das zuletzt bearbeitete zuerst
struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var sync: SyncEngine
    /// Offene Dokumente: Antippen öffnet in einem neuen Tab
    @EnvironmentObject private var tabs: TabsModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var importing = false
    @State private var renaming: NoteDocument?
    @State private var newTitle = ""
    @State private var deleting: NoteDocument?
    @State private var importError: String?
    /// Geöffneter Ordner (nil = oberste Ebene)
    @State private var currentFolder: String?
    /// Name für einen neuen Ordner; `moving` ist dann das Dokument, das gleich hinein soll
    @State private var askingFolderName = false
    @State private var folderName = ""
    @State private var moving: NoteDocument?
    @State private var renamingFolder: String?
    /// Angelegte, aber noch leere Ordner (nur auf diesem Gerät; mit dem ersten Dokument gelten sie überall)
    @AppStorage("emptyFolders") private var emptyFoldersRaw = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)], spacing: 28) {
                    if currentFolder == nil {
                        ForEach(folders, id: \.self) { name in
                            FolderCard(name: name, count: store.documents.filter { $0.folder == name }.count,
                                       isTemp: name == DocumentStore.tempFolder)
                                .onTapGesture { currentFolder = name }
                                .dropDestination(for: String.self) { ids, _ in moveDocs(ids, to: name) }
                                .contextMenu {
                                    if name != DocumentStore.tempFolder {
                                    Button {
                                        folderName = name
                                        renamingFolder = name
                                    } label: { Label("Ordner umbenennen", systemImage: "pencil") }
                                    Button(role: .destructive) { removeFolder(name) } label: {
                                        Label("Ordner auflösen", systemImage: "folder.badge.minus")
                                    }
                                    }
                                }
                        }
                    }
                    ForEach(visibleDocs) { doc in
                        DocCard(doc: doc)
                            .onTapGesture { tabs.open(doc) }
                            .draggable(doc.id.uuidString)
                            .contextMenu {
                                Button {
                                    newTitle = doc.title
                                    renaming = doc
                                } label: { Label("Umbenennen", systemImage: "pencil") }
                                moveMenu(doc)
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
            // Bibliothek alle 20 Sekunden abgleichen, auch während ein Dokument offen ist
            // (sonst erfährt das andere Gerät erst nach dem Schließen von einem neuen Dokument)
            .task {
                while !Task.isCancelled {
                    for id in store.purgeTemp(keeping: Set(tabs.ids)) { sync.noteDeleted(id) }
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
            // Zurück zu den offenen Tabs, ohne ein weiteres Dokument zu öffnen
            .safeAreaInset(edge: .bottom) {
                if !tabs.ids.isEmpty {
                    Button { tabs.showEditor() } label: {
                        Label(openTabsLabel, systemImage: "square.on.square")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    }
                    .tint(.primary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                }
            }
            .overlay {
                if visibleDocs.isEmpty && (currentFolder != nil || folders.isEmpty) {
                    ContentUnavailableView(currentFolder == nil ? "Noch leer" : "Ordner ist leer", systemImage: "square.and.pencil",
                                           description: Text(currentFolder == nil
                                                             ? "Leg ein Notizbuch an oder importiere ein PDF."
                                                             : "Leg hier ein Notizbuch an, oder verschieb ein Dokument hierher (lange drücken)."))
                }
            }
            .navigationTitle(currentFolder ?? "BetterNotes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if currentFolder != nil {
                        Button { currentFolder = nil } label: { Label("Alle", systemImage: "chevron.left") }
                    } else {
                        Button { showSettings = true } label: { Label("Sync", systemImage: "gearshape") }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if currentFolder == nil {
                        Button {
                            folderName = ""
                            moving = nil
                            askingFolderName = true
                        } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
                    }
                    Button { importing = true } label: { Label("PDF importieren", systemImage: "doc.badge.plus") }
                    Button {
                        tabs.open(store.createNotebook(inFolder: currentFolder))
                        Task { await sync.syncLibrary() }
                    } label: { Label("Neues Notizbuch", systemImage: "square.and.pencil") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                do {
                    let doc = try store.importPDF(from: result.get(), inFolder: currentFolder)
                    tabs.open(doc)
                    Task { await sync.syncLibrary() }
                } catch {
                    importError = error.localizedDescription
                }
            }
            // PDFs, die aus einer anderen App (Dateien, Mail, AirDrop …) mit „Notizbuch“ geöffnet werden
            .onOpenURL { url in
                // Einrichtungslink: notizbuch://setup?url=https://…&key=…
                if url.scheme == "notizbuch", url.host == "setup",
                   let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    if let server = items.first(where: { $0.name == "url" })?.value { sync.serverURL = server }
                    if let key = items.first(where: { $0.name == "key" })?.value { sync.key = key }
                    showSettings = true
                    return
                }
                guard url.pathExtension.lowercased() == "pdf" else { return }
                do {
                    // In einem neuen Tab, auch wenn gerade ein Dokument offen ist
                    let doc = try store.importPDF(from: url)
                    tabs.open(doc)
                } catch {
                    importError = error.localizedDescription
                }
            }
            .fullScreenCover(isPresented: $tabs.editorShown, onDismiss: { store.reload() }) {
                EditorView(tabs: tabs, tools: tabs.tools).environmentObject(store).environmentObject(sync)
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
            .alert("Neuer Ordner", isPresented: $askingFolderName) {
                TextField("Name", text: $folderName)
                Button("Abbrechen", role: .cancel) { moving = nil }
                Button("Anlegen") { createFolder(folderName) }
            }
            .alert("Ordner umbenennen", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
                TextField("Name", text: $folderName)
                Button("Abbrechen", role: .cancel) {}
                Button("OK") { if let old = renamingFolder { renameFolder(old, to: folderName) } }
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
    private var emptyFolders: [String] {
        emptyFoldersRaw.split(separator: "\n").map(String.init)
    }

    /// Alle Ordner: zuerst „temp“ (immer da), dann die aus den Dokumenten (kommen auch über den Sync) und die noch leeren
    private var folders: [String] {
        let temp = DocumentStore.tempFolder
        return [temp] + Set(store.documents.compactMap(\.folder) + emptyFolders)
            .subtracting([temp])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visibleDocs: [NoteDocument] {
        store.documents.filter { $0.folder == currentFolder }
    }

    @ViewBuilder
    private func moveMenu(_ doc: NoteDocument) -> some View {
        Menu {
            ForEach(folders.filter { $0 != doc.folder }, id: \.self) { name in
                Button(name) { move(doc, to: name) }
            }
            Button {
                folderName = ""
                moving = doc
                askingFolderName = true
            } label: { Label("Neuer Ordner …", systemImage: "folder.badge.plus") }
            if doc.folder != nil {
                Divider()
                Button { move(doc, to: nil) } label: { Label("Aus dem Ordner nehmen", systemImage: "arrow.up.doc") }
            }
        } label: { Label("In Ordner verschieben", systemImage: "folder") }
    }

    private func move(_ doc: NoteDocument, to folder: String?) {
        store.move(doc, to: folder)
        if let folder { emptyFoldersRaw = emptyFolders.filter { $0 != folder }.joined(separator: "\n") }
        Task { await sync.syncLibrary() }
    }

    private func moveDocs(_ ids: [String], to folder: String) -> Bool {
        let docs = store.documents.filter { ids.contains($0.id.uuidString) }
        for doc in docs { move(doc, to: folder) }
        return !docs.isEmpty
    }

    private func createFolder(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { moving = nil }
        guard !name.isEmpty else { return }
        if let doc = moving {
            move(doc, to: name)
        } else if !folders.contains(name) {
            emptyFoldersRaw = (emptyFolders + [name]).joined(separator: "\n")
        }
    }

    private func renameFolder(_ old: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, name != DocumentStore.tempFolder else { return }
        for doc in store.documents where doc.folder == old { store.move(doc, to: name) }
        emptyFoldersRaw = emptyFolders.map { $0 == old ? name : $0 }.joined(separator: "\n")
        Task { await sync.syncLibrary() }
    }

    /// Löst einen Ordner auf; die Dokumente darin kommen auf die oberste Ebene, gelöscht wird nichts
    private func removeFolder(_ name: String) {
        for doc in store.documents where doc.folder == name { store.move(doc, to: nil) }
        emptyFoldersRaw = emptyFolders.filter { $0 != name }.joined(separator: "\n")
        Task { await sync.syncLibrary() }
    }

    /// Ein offenes Dokument: sein Titel; mehrere: wie viele
    private var openTabsLabel: String {
        if tabs.ids.count == 1, let id = tabs.ids.first { return "Zurück zu „\(tabs.title(for: id))“" }
        return "Zurück zu \(tabs.ids.count) Tabs"
    }

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

struct FolderCard: View {
    let name: String
    let count: Int
    var isTemp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.89, green: 0.87, blue: 0.80))
                Image(systemName: isTemp ? "clock.arrow.circlepath" : "folder.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color(red: 0.55, green: 0.52, blue: 0.44))
            }
            .aspectRatio(210 / 297, contentMode: .fit)
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)

            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text((count == 1 ? "1 Dokument" : "\(count) Dokumente") + (isTemp ? " · löscht nach 2 Wochen" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
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
        .task(id: "\(doc.modified.timeIntervalSince1970)-\(store.inkVersions[doc.id] ?? 0)") {
            image = store.thumbnail(for: doc, width: 300)
        }
    }
}
