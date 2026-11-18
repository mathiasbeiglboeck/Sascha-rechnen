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
    /// So viele importierte Markdown-Dateien werden gerade auf Seiten gesetzt
    @State private var typesetting = 0
    /// Geöffneter Ordner (nil = oberste Ebene)
    @State private var currentFolder: String?
    /// Name für einen neuen Ordner; `moving` ist dann das Dokument, das gleich hinein soll
    @State private var askingFolderName = false
    @State private var folderName = ""
    @State private var moving: NoteDocument?
    @State private var renamingFolder: String?
    /// Einrichtungslink, der erst nach Bestätigung gilt
    @State private var pendingSetup: SetupLink?
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
                    let before = sync.lastSync
                    await sync.syncLibrary()
                    // Fragen an Claude, die noch hinauf müssen (auch aus geschlossenen Dokumenten); war das Gerät
                    // offline und der Abgleich klappte eben, gleich
                    sync.asks.flushAll(online: sync.lastSync != before)
                    // Den temp-Ordner erst nach einem gelungenen Abgleich aufräumen, also auf dem Stand des Servers.
                    // Sonst löschte ein lange nicht geöffnetes Gerät von seinem alten Stand aus Dokumente, die ein
                    // anderes inzwischen behalten (verschoben) oder beschrieben hat, und mit ihm überall. Dokumente mit
                    // noch nicht geholten Strichen bleiben ebenso stehen
                    if !sync.isConfigured || sync.lastSync != before {
                        let purged = store.purgeTemp(keeping: Set(tabs.ids).union(sync.unfetched))
                        for doc in purged { sync.noteDeleted(doc.id, unchangedSince: doc.modified) }
                        if !purged.isEmpty { await sync.syncLibrary() }
                    }
                    try? await Task.sleep(for: .seconds(20))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        let before = sync.lastSync
                        await sync.syncLibrary()
                        sync.asks.flushAll(online: sync.lastSync != before)
                    }
                }
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
                            // Zu lang (kleines iPhone): Mitte kürzen, damit die Uhrzeit am Ende sichtbar bleibt
                            .truncationMode(.middle)
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
                                                             ? "Leg ein Notizbuch an oder importiere ein PDF oder Markdown."
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
                    Button { importing = true } label: { Label("PDF oder Markdown importieren", systemImage: "doc.badge.plus") }
                    Button {
                        tabs.open(store.createNotebook(inFolder: currentFolder))
                        Task { await sync.syncLibrary() }
                    } label: { Label("Neues Notizbuch", systemImage: "square.and.pencil") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf] + MarkdownTypesetter.contentTypes) { result in
                do {
                    let url = try result.get()
                    if MarkdownTypesetter.isMarkdown(url) {
                        importMarkdown(url, inFolder: currentFolder)
                        return
                    }
                    let doc = try store.importPDF(from: url, inFolder: currentFolder)
                    tabs.open(doc)
                    Task { await sync.syncLibrary() }
                } catch {
                    importError = error.localizedDescription
                }
            }
            // PDFs und Markdown, die aus einer anderen App (Dateien, Mail, AirDrop …) mit „Notizbuch“ geöffnet werden
            .onOpenURL { url in
                // Einrichtungslink: notizbuch://setup?url=https://…&key=…
                // Gilt erst nach Bestätigung: Ein Link, etwa von einer Webseite, soll die Synchronisation nicht unbemerkt
                // auf einen fremden Server umstellen können
                if url.scheme == "notizbuch", url.host == "setup",
                   let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    let setup = SetupLink(server: items.first(where: { $0.name == "url" })?.value,
                                          key: items.first(where: { $0.name == "key" })?.value)
                    if setup.server != nil || setup.key != nil { pendingSetup = setup }
                    return
                }
                if MarkdownTypesetter.isMarkdown(url) {
                    importMarkdown(url, inFolder: nil)
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
                Button("OK") {
                    if let doc = renaming {
                        store.rename(doc, to: newTitle)
                        Task { await sync.syncLibrary() }
                    }
                }
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
            .overlay {
                if typesetting > 0 {
                    ProgressView("Markdown wird gesetzt …")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert("Konnte nicht importiert werden",
                   isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
            .alert(pendingSetup?.title ?? "",
                   isPresented: Binding(get: { pendingSetup != nil }, set: { if !$0 { pendingSetup = nil } }),
                   presenting: pendingSetup) { setup in
                Button("Abbrechen", role: .cancel) {}
                Button("Übernehmen") {
                    if let server = setup.server { sync.serverURL = server }
                    if let key = setup.key { sync.key = key }
                    // Erst wenn die Meldung weg ist, sonst erscheinen die Einstellungen nicht
                    DispatchQueue.main.async { showSettings = true }
                }
            } message: { setup in
                Text(setup.message)
            }
        }
    }
}

/// Server und Schlüssel aus einem Einrichtungslink (notizbuch://setup?url=…&key=…), bis sie bestätigt sind
private struct SetupLink {
    let server: String?
    let key: String?

    var title: String {
        server != nil ? "Mit diesem Server synchronisieren?" : "Schlüssel für den Sync ändern?"
    }

    var message: String {
        let change: String
        if let server = server {
            // Der Rechnername des Servers (ohne Benutzerteil vor einem @), sonst die ganze Adresse
            let host = URL(string: server)?.host ?? server
            change = "Ein Link will den Sync auf „\(host)“ umstellen. Deine Notizen gehen dann an diesen Server."
        } else {
            change = "Ein Link will den Schlüssel für den Sync ändern."
        }
        return change + " Nur übernehmen, wenn der Link aus deiner eigenen Einrichtung stammt."
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

    /// Markdown wird erst auf Seiten gesetzt (ein, zwei Sekunden), dann öffnet es wie ein importiertes PDF in einem Tab
    private func importMarkdown(_ url: URL, inFolder folder: String?) {
        typesetting += 1
        Task { @MainActor in
            do {
                let doc = try await store.importMarkdown(from: url, inFolder: folder)
                typesetting -= 1
                tabs.open(doc)
                await sync.syncLibrary()
            } catch {
                typesetting -= 1
                importError = error.localizedDescription
            }
        }
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

    /// Versionsnummer dieser App-Datei. build-ipa.sh setzt sie (Zahl der Commits, „+“ bei ungespeicherten Änderungen)
    /// und trägt Commit und Zeit ein; Bauten direkt aus Xcode heißen „1.0“ und haben keinen Commit
    private static let versionNumber: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let number = info["CFBundleShortVersionString"] as? String ?? "?"
        return (info["BNCommit"] as? String)?.hasSuffix("+") == true ? number + "+" : number
    }()

    private static let versionNote: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let commit = info["BNCommit"] as? String, !commit.isEmpty else { return "Direkt aus Xcode gebaut." }
        let date = (info["BNDate"] as? String).map { "vom \($0) " } ?? ""
        return "Stand \(date)(\(commit)). Dieselbe Nummer steht im Namen der App-Datei."
    }()

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
                Section {
                    LabeledContent("Version", value: Self.versionNumber)
                } footer: {
                    Text(Self.versionNote)
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
                // Zu lang: Mitte kürzen, das Ende (Uhrzeit, Kapitel) unterscheidet oft
                Text(doc.title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
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
