import Foundation
import PencilKit
import PDFKit
import UIKit

enum DocKind: String, Codable {
    case notebook, pdf
}

/// Ein Notizbuch oder ein PDF mit Notizen. Liegt als Ordner in Dokumente/Notizbuch/<id>/:
/// meta.json, drawing.data (alle Striche über alle Seiten) und bei PDFs source.pdf.
struct NoteDocument: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var kind: DocKind
    var created: Date
    var modified: Date
    /// Seitenzahl eines Notizbuchs; bei PDFs bestimmt das PDF die Seiten
    var pageCount: Int
    /// Version des Seitenlayouts, mit dem die Striche gespeichert sind (fehlt = 1)
    var layoutVersion: Int?
    /// Ordner in der Übersicht (nil = oberste Ebene)
    var folder: String?
    /// Stand des PDFs selbst (Zeitpunkt in ms); ändert sich, wenn Seiten gelöscht oder eingefügt werden
    var pdfVersion: Int? = nil
    /// Zeitpunkt (ms) der letzten Seitenänderung (löschen, einfügen) auf irgendeinem Gerät. Seitenzahl und
    /// PDF-Version folgen der neuesten Seitenänderung, nicht der letzten Änderung am Dokument überhaupt
    var pagesVersion: Int? = nil
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [NoteDocument] = []
    /// Zählt Schreibvorgänge der Zeichnung je Dokument (für Vorschaubilder; `modified` ändert sich
    /// bei übernommenen fremden Strichen nicht)
    @Published private(set) var inkVersions: [UUID: Int] = [:]
    let root: URL
    private let fm = FileManager.default
    /// Schreibt Zeichnungen und den Sync-Stand im Hintergrund, der Reihe nach
    private let io = DispatchQueue(label: "de.beiglboeck.notizbuch.io", qos: .userInitiated)
    /// Zeichnungen, die gerade geschrieben werden: Wer liest, bekommt sie, nie einen älteren Stand von der Platte
    private var writing: [UUID: PendingDrawing] = [:]
    private var writes = 0

    private struct PendingDrawing {
        let number: Int
        let drawing: PKDrawing
        let toPage: CGAffineTransform
    }

    init() {
        root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notizbuch", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Pfade

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func metaURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("meta.json") }
    func drawingURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("drawing.data") }
    func pdfURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("source.pdf") }

    // MARK: Liste

    func reload() {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        documents = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
            return try? decoder.decode(NoteDocument.self, from: data)
        }
        .sorted { $0.modified > $1.modified }
    }

    func createNotebook(inFolder: String? = nil) -> NoteDocument {
        let now = Date()
        let doc = NoteDocument(id: UUID(), title: "Notizen " + now.formatted(date: .abbreviated, time: .omitted),
                               kind: .notebook, created: now, modified: now, pageCount: 1,
                               layoutVersion: PageLayout.currentVersion, folder: inFolder)
        try? fm.createDirectory(at: folder(doc.id), withIntermediateDirectories: true)
        save(doc)
        return doc
    }

    func importPDF(from url: URL, inFolder: String? = nil) throws -> NoteDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let now = Date()
        let doc = NoteDocument(id: UUID(), title: url.deletingPathExtension().lastPathComponent,
                               kind: .pdf, created: now, modified: now, pageCount: 0,
                               layoutVersion: PageLayout.currentVersion, folder: inFolder)
        try fm.createDirectory(at: folder(doc.id), withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: pdfURL(doc.id))
        save(doc)
        return doc
    }

    func save(_ doc: NoteDocument) {
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: metaURL(doc.id), options: .atomic)
        }
        if let i = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[i] = doc
        } else {
            documents.insert(doc, at: 0)
        }
    }

    /// Fester Ordner für Durchlaufendes: PDFs von Claude und ChatGPT landen hier
    static let tempFolder = "temp"
    /// Nach so vielen Tagen ohne Änderung wird ein Dokument im temp-Ordner gelöscht
    static let tempDays = 14

    /// Löscht Dokumente im temp-Ordner, die seit `tempDays` Tagen nicht geändert wurden; gibt ihre IDs zurück
    func purgeTemp(keeping open: UUID?) -> [UUID] {
        let limit = Date().addingTimeInterval(-Double(Self.tempDays) * 86400)
        let old = documents.filter { $0.folder == Self.tempFolder && $0.modified < limit && $0.id != open }
        for doc in old { delete(doc) }
        return old.map(\.id)
    }

    /// Verschiebt ein Dokument in einen Ordner (nil = oberste Ebene); gilt nach dem Sync auf allen Geräten
    func move(_ doc: NoteDocument, to folder: String?) {
        var d = doc
        let name = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        d.folder = (name?.isEmpty ?? true) ? nil : name
        guard d.folder != doc.folder else { return }
        d.modified = Date()
        save(d)
    }

    func rename(_ doc: NoteDocument, to title: String) {
        var d = doc
        d.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.title.isEmpty else { return }
        save(d)
    }

    func delete(_ doc: NoteDocument) {
        writing[doc.id] = nil
        try? fm.removeItem(at: folder(doc.id))
        documents.removeAll { $0.id == doc.id }
    }

    // MARK: Zeichnung

    func loadDrawing(_ doc: NoteDocument) -> PKDrawing {
        if let p = writing[doc.id] {
            return p.toPage.isIdentity ? p.drawing : p.drawing.transformed(using: p.toPage)
        }
        guard let data = try? Data(contentsOf: drawingURL(doc.id)),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        guard (doc.layoutVersion ?? 1) < PageLayout.currentVersion else { return drawing }
        // Version 1 hatte 24 Punkte Abstand zwischen den Seiten: Striche mit ihrer Seite verschieben
        let old: PageLayout, new: PageLayout
        if doc.kind == .pdf, let pdf = CGPDFDocument(pdfURL(doc.id) as CFURL) {
            old = .pdf(pdf, gap: 24)
            new = .pdf(pdf)
        } else {
            old = .notebook(pages: doc.pageCount, gap: 24)
            new = .notebook(pages: doc.pageCount)
        }
        let migrated = new.migrate(drawing, from: old)
        try? migrated.dataRepresentation().write(to: drawingURL(doc.id), options: .atomic)
        var d = doc
        d.layoutVersion = PageLayout.currentVersion
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: metaURL(d.id), options: .atomic) }
        if let i = documents.firstIndex(where: { $0.id == d.id }) { documents[i].layoutVersion = d.layoutVersion }
        return migrated
    }

    /// Speichert die Zeichnung im Hintergrund: Umrechnen und Kodieren dauert bei großen Dokumenten,
    /// und der Stift soll dabei nie stocken. Bis die Datei geschrieben ist, liefert `loadDrawing` diesen Stand.
    /// - Parameters:
    ///   - toPage: rechnet die Zeichnung in Seitenpunkte um (identity: liegt schon in Seitenpunkten)
    ///   - touch: false, wenn nur Striche von anderen Geräten übernommen werden. Dann bleibt
    ///     `modified` stehen: Sonst würde der eigene (ältere) Stand von Titel, Ordner usw. beim nächsten
    ///     Abgleich als „neuer“ gelten und den wirklich neueren Stand der anderen überschreiben.
    ///   - base: Stand nach dem letzten Laden oder Speichern. Ist die Zeichnung genau gleich (PencilKit meldet
    ///     beim Öffnen manchmal eine „Änderung“), wird nichts geschrieben.
    func saveDrawing(_ drawing: PKDrawing, toPage: CGAffineTransform = .identity, for id: UUID, pageCount: Int,
                     touch: Bool = true, unlessEqualTo base: PKDrawing? = nil) {
        writes += 1
        let number = writes
        writing[id] = PendingDrawing(number: number, drawing: drawing, toPage: toPage)
        let url = drawingURL(id)
        let box = UncheckedBox((drawing, base))
        let task = UIApplication.shared.beginBackgroundTask(withName: "Zeichnung speichern")
        io.async { [weak self] in
            let (drawing, base) = box.value
            var changed = true
            if let base, base.dataRepresentation() == drawing.dataRepresentation() {
                changed = false
            } else {
                let page = toPage.isIdentity ? drawing : drawing.transformed(using: toPage)
                try? page.dataRepresentation().write(to: url, options: .atomic)
            }
            DispatchQueue.main.async {
                self?.finishedWriting(id, number: number, changed: changed, pageCount: pageCount, touch: touch)
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }

    private func finishedWriting(_ id: UUID, number: Int, changed: Bool, pageCount: Int, touch: Bool) {
        if writing[id]?.number == number { writing[id] = nil }
        guard changed else { return }
        inkVersions[id, default: 0] += 1
        guard var doc = documents.first(where: { $0.id == id }) else { return }
        guard touch || doc.pageCount != pageCount else { return }
        if touch { doc.modified = Date() }
        doc.pageCount = pageCount
        save(doc)
    }

    /// Schreibt eine kleine Datei (z. B. den Sync-Stand) nach allen schon angestoßenen Zeichnungen
    func enqueueWrite(to url: URL, _ make: @escaping @Sendable () -> Data?) {
        io.async {
            if let data = make() { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Seiten wurden gelöscht oder eingefügt (bei PDFs auch das PDF selbst geändert): Die anderen Geräte
    /// übernehmen Seitenzahl bzw. PDF, weil diese Version neuer ist als ihre
    func notePagesChanged(_ id: UUID, pdf: Bool) {
        guard var doc = documents.first(where: { $0.id == id }) else { return }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        // Nie rückwärts, auch wenn die Uhr eines Geräts nachgeht
        let version = max(now, (doc.pagesVersion ?? 0) + 1, (doc.pdfVersion ?? 0) + 1)
        doc.pagesVersion = version
        if pdf { doc.pdfVersion = version }
        doc.modified = Date()
        save(doc)
    }

    // MARK: Vorschaubild der ersten Seite

    func thumbnail(for doc: NoteDocument, width: CGFloat) -> UIImage? {
        let pdfPage = doc.kind == .pdf ? CGPDFDocument(pdfURL(doc.id) as CFURL)?.page(at: 1) : nil
        let layout: PageLayout
        if let pdfPage { layout = .stack([PageLayout.height(of: pdfPage)]) } else { layout = .notebook(pages: 1) }
        guard let page = layout.frames.first else { return nil }
        let scale = width / page.width
        let size = CGSize(width: width, height: page.height * scale)
        let drawing = loadDrawing(doc)
        return UIGraphicsImageRenderer(size: size).image { r in
            let ctx = r.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            if let pdfPage {
                PageView.drawPDF(pdfPage, in: ctx, size: page.size)
            } else {
                PageView.drawGrid(in: ctx, rect: CGRect(origin: .zero, size: page.size), lineWidth: 1)
            }
            ctx.restoreGState()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing.image(from: page, scale: scale * 2).draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
