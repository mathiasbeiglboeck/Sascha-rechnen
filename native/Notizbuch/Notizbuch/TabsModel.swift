import SwiftUI
import UIKit
import Combine

/// Stelle in einem Dokument: linker oberer Rand der Ansicht (unter der Leiste) in Seitenpunkten, und der Zoom.
/// In Seitenpunkten gilt sie auch nach dem Drehen.
struct Viewport {
    var x: CGFloat
    var y: CGFloat
    var zoom: CGFloat
}

/// Offene Dokumente als Tabs. Ein Dokument aus der Übersicht öffnet in einem neuen Tab (ist es schon offen, wechselt
/// es zu seinem Tab); zurück in der Übersicht bleiben die Tabs offen.
///
/// Nur der sichtbare Tab ist als Leinwand offen und gleicht live ab, genau wie bisher das eine offene Dokument. Die
/// anderen sind zu wie in der Übersicht: Striche von anderen Geräten holt der Abgleich der Bibliothek in ihre Datei,
/// und beim Wechsel öffnet der Tab neu, an der Stelle, an der er zuletzt stand. So bleibt der Speicher klein, und am
/// Abgleich ändert sich nichts.
@MainActor
final class TabsModel: ObservableObject {
    /// Mehr passen am iPad nicht gut in eine Zeile. Wer ein weiteres Dokument öffnet, schließt den am längsten nicht
    /// benutzten Tab (gespeichert ist ohnehin alles)
    static let maxTabs = 6

    @Published private(set) var ids: [UUID] {
        didSet { persist() }
    }
    @Published private(set) var active: UUID? {
        didSet { persist() }
    }
    /// Zählt Wechsel: Jeder Wechsel bekommt eine frische Leinwand, auch wenn derselbe Tab wieder vorne ist
    @Published private(set) var generation = 0
    /// Der Editor (Vollbild über der Übersicht) ist offen
    @Published var editorShown = false
    /// Werkzeug, Farbe und Dicke gelten für alle Tabs; so lässt sich mit dem Lasso Ausgeschnittenes gleich im
    /// nächsten Tab einsetzen
    let tools = ToolState()

    private let store: DocumentStore
    /// Wann jeder Tab zuletzt vorne war (für das Schließen des am längsten nicht benutzten); bleibt gespeichert
    private var lastUsed: [UUID: Date] = [:] {
        didSet { persist() }
    }
    /// Wo jeder Tab zuletzt stand; bleibt gespeichert, auch wenn das System die App im Hintergrund beendet
    private var viewports: [UUID: Viewport] = [:] {
        didSet { persist() }
    }
    /// Zuletzt bekannte Fassung je Tab, falls ein Dokument aus der Liste verschwindet, während es sichtbar ist
    private var known: [UUID: NoteDocument] = [:]
    private var watch: AnyCancellable?
    private var resign: AnyCancellable?
    /// Was nach dem Schließen der Leinwand geschehen soll (sie wartet vielleicht noch auf den letzten Strich).
    /// Ein neuerer Wunsch ersetzt einen wartenden
    private var afterLeave: (() -> Void)?

    init(store: DocumentStore) {
        self.store = store
        let defaults = UserDefaults.standard
        // Erst alles lesen, dann setzen (jedes Setzen schreibt den ganzen Stand zurück)
        let saved = (defaults.stringArray(forKey: "tabs") ?? []).compactMap(UUID.init(uuidString:))
        let savedActive = defaults.string(forKey: "activeTab").flatMap(UUID.init(uuidString:))
        let places = defaults.dictionary(forKey: "tabPlaces") as? [String: [Double]] ?? [:]
        let used = defaults.dictionary(forKey: "tabsUsed") as? [String: Double] ?? [:]
        ids = saved
        active = savedActive
        for (key, v) in places {
            guard let id = UUID(uuidString: key), saved.contains(id), v.count == 3 else { continue }
            viewports[id] = Viewport(x: CGFloat(v[0]), y: CGFloat(v[1]), zoom: CGFloat(v[2]))
        }
        for (key, t) in used {
            guard let id = UUID(uuidString: key), saved.contains(id) else { continue }
            lastUsed[id] = Date(timeIntervalSince1970: t)
        }
        prune(store.documents)
        if let current = active, !ids.contains(current) { active = ids.last }
        // Gelöschte Dokumente (hier oder auf einem anderen Gerät) verschwinden auch aus den Tabs
        watch = store.$documents.sink { [weak self] docs in
            MainActor.assumeIsolated { self?.prune(docs) }
        }
        // Die App geht vielleicht in den Hintergrund und wird dort beendet: Stelle des sichtbaren Tabs sichern
        resign = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.rememberPlace() }
            }
    }

    // MARK: Für die Ansichten

    var activeDocument: NoteDocument? {
        guard let id = active else { return nil }
        return store.documents.first { $0.id == id } ?? known[id]
    }

    func title(for id: UUID) -> String {
        store.documents.first { $0.id == id }?.title ?? known[id]?.title ?? "…"
    }

    func viewport(for id: UUID) -> Viewport? { viewports[id] }

    // MARK: Öffnen, wechseln, schließen

    /// Öffnet ein Dokument in einem neuen Tab, oder wechselt zu seinem Tab, und zeigt den Editor
    func open(_ doc: NoteDocument) {
        known[doc.id] = doc
        lastUsed[doc.id] = Date()
        if !ids.contains(doc.id) {
            if ids.count >= Self.maxTabs { closeLeastUsed() }
            ids.append(doc.id)
        }
        if editorShown {
            select(doc.id)
        } else {
            active = doc.id
            presentEditor()
        }
    }

    /// Zurück zu den offenen Tabs (aus der Übersicht, ohne ein weiteres Dokument zu öffnen)
    func showEditor() {
        guard let last = ids.last else { return }
        if active.map({ !ids.contains($0) }) ?? true { active = last }
        if let current = active { lastUsed[current] = Date() }
        presentEditor()
    }

    /// Zurück zur Übersicht; die Tabs bleiben offen
    func closeEditor() {
        leaveCanvas { [weak self] in self?.editorShown = false }
    }

    /// Wechselt zu einem Tab. Die offene Leinwand schließt vorher (speichert, gleicht ab, merkt sich die Stelle)
    func select(_ id: UUID) {
        guard ids.contains(id) else { return }
        lastUsed[id] = Date()
        guard id != active else {
            // Ein noch wartender Wechsel weg von hier entfällt
            afterLeave = nil
            return
        }
        leaveCanvas { [weak self] in
            guard let self else { return }
            if self.ids.contains(id) {
                self.show(id)
            } else {
                // Der Tab ging inzwischen zu: ein anderer, sonst derselbe wieder (mit frischer Leinwand)
                self.show(self.ids.first { $0 != self.active } ?? self.active)
            }
        }
    }

    /// Schließt einen Tab (das Kreuz). Statt des sichtbaren kommt sein rechter Nachbar nach vorne, sonst der linke
    func close(_ id: UUID) {
        guard let i = ids.firstIndex(of: id) else { return }
        guard editorShown, id == active else {
            remove(id)
            return
        }
        let next = i + 1 < ids.count ? ids[i + 1] : (i > 0 ? ids[i - 1] : nil)
        leaveCanvas { [weak self] in
            guard let self else { return }
            self.remove(id)
            if let target = next.flatMap({ self.ids.contains($0) ? $0 : nil }) ?? self.ids.last {
                self.show(target)
            } else {
                self.active = nil
                self.editorShown = false
            }
        }
    }

    // MARK: Intern

    private func presentEditor() {
        tools.menusHidden = false
        tools.prepareForDocument()
        editorShown = true
    }

    /// Bringt einen Tab nach vorne, mit frischer Leinwand
    private func show(_ id: UUID?) {
        generation += 1
        active = id
        tools.prepareForDocument()
    }

    /// Schließt die Leinwand des sichtbaren Tabs und merkt sich ihre Stelle; `done` läuft danach. Ist gerade ein
    /// Strich unterwegs oder eben abgesetzt (PencilKit übernimmt ihn erst kurz danach in die Zeichnung), wartet es so
    /// lange, sonst ginge der Strich verloren
    private func leaveCanvas(then done: @escaping () -> Void) {
        let waiting = afterLeave != nil
        afterLeave = done
        if !waiting { attemptLeave(tries: 0) }
    }

    private func attemptLeave(tries: Int) {
        // Inzwischen abgebrochen (derselbe Tab wieder angetippt)
        guard let done = afterLeave else { return }
        if let canvas = tools.canvas, canvas.isSettling, tries < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.attemptLeave(tries: tries + 1)
            }
            return
        }
        afterLeave = nil
        if let canvas = tools.canvas {
            if let place = canvas.viewport { viewports[canvas.doc.id] = place }
            canvas.leave()
            tools.canvas = nil
        }
        done()
    }

    /// Zu viele Tabs: Der am längsten nicht benutzte geht zu (nie der gerade sichtbare)
    private func closeLeastUsed() {
        let candidates = ids.enumerated().filter { !(editorShown && $0.element == active) }
        let oldest = candidates.min { a, b in
            let ta = lastUsed[a.element] ?? .distantPast, tb = lastUsed[b.element] ?? .distantPast
            return ta == tb ? a.offset < b.offset : ta < tb
        }
        guard let victim = oldest?.element else { return }
        let name = title(for: victim)
        remove(victim)
        tools.show("„\(name)“ geschlossen (höchstens \(Self.maxTabs) Tabs)", seconds: 3)
    }

    private func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
        viewports[id] = nil
        lastUsed[id] = nil
        known[id] = nil
        if active == id, !editorShown { active = ids.last }
    }

    /// Tabs gelöschter Dokumente fallen weg. Der sichtbare bleibt, solange der Editor offen ist (wie bisher ein offenes
    /// Dokument, das anderswo gelöscht wird)
    private func prune(_ docs: [NoteDocument]) {
        for doc in docs where ids.contains(doc.id) { known[doc.id] = doc }
        let existing = Set(docs.map(\.id))
        let gone = ids.filter { !existing.contains($0) && !(editorShown && $0 == active) }
        for id in gone { remove(id) }
    }

    /// Merkt sich, wo der sichtbare Tab gerade steht
    private func rememberPlace() {
        guard let canvas = tools.canvas, ids.contains(canvas.doc.id), let place = canvas.viewport else { return }
        viewports[canvas.doc.id] = place
    }

    /// Tabs, der vordere, und je Tab Stelle und letzte Benutzung: bleiben über einen Neustart der App erhalten
    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(ids.map(\.uuidString), forKey: "tabs")
        defaults.set(active?.uuidString, forKey: "activeTab")
        var places: [String: [Double]] = [:]
        var used: [String: Double] = [:]
        for id in ids {
            if let v = viewports[id] { places[id.uuidString] = [Double(v.x), Double(v.y), Double(v.zoom)] }
            if let t = lastUsed[id] { used[id.uuidString] = t.timeIntervalSince1970 }
        }
        defaults.set(places, forKey: "tabPlaces")
        defaults.set(used, forKey: "tabsUsed")
    }
}

/// Die offenen Dokumente als kleine, dezente Reiter über der Leiste: Antippen wechselt, das Kreuz schließt.
/// Passen nicht alle in eine Zeile, lässt sich die Zeile seitlich schieben.
struct TabStrip: View {
    @ObservedObject var tabs: TabsModel
    /// Titel kommen aus der Dokumentliste (umbenannt, auch auf einem anderen Gerät): bei Änderungen neu zeichnen
    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row
                }
                .frame(height: 26)
                .onAppear {
                    if let id = tabs.active { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: tabs.active) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(tabs.ids, id: \.self) { id in
                tab(id).id(id)
            }
        }
        .padding(.horizontal, 12)
    }

    private func tab(_ id: UUID) -> some View {
        let isActive = id == tabs.active
        return HStack(spacing: 0) {
            Text(tabs.title(for: id))
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 12)
            Button { tabs.close(id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tab schließen")
        }
        .frame(maxWidth: 190)
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .background {
            Capsule().fill(.regularMaterial).opacity(isActive ? 1 : 0.55)
        }
        .contentShape(Capsule())
        .onTapGesture { tabs.select(id) }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
