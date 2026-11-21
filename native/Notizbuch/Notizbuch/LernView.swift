import PencilKit
import SwiftUI

/// Lernwörter üben (für Sascha): Start mit der Wortliste, dann je Wort vorsprechen, schreiben, lesen lassen,
/// bestätigen, Rückmeldung. Siehe LernModel
struct LernView: View {
    @StateObject private var model: LernModel
    @Environment(\.dismiss) private var dismiss
    @State private var radierer = false
    @State private var bearbeiten = false

    init(sync: SyncEngine) {
        _model = StateObject(wrappedValue: LernModel(sync: sync))
    }

    private static let papier = Color(red: 0.99, green: 0.98, blue: 0.94)
    private static let gruen = Color(red: 0.16, green: 0.62, blue: 0.33)
    private static let blau = Color(red: 0.18, green: 0.42, blue: 0.85)

    var body: some View {
        ZStack {
            Self.papier.ignoresSafeArea()
            switch model.phase {
            case .start: start
            case .fertig: fertig
            default: ueben
            }
        }
        .task { await model.refresh() }
        .onDisappear { model.sprecher.stop() }
        .sheet(isPresented: $bearbeiten) { LernWoerterSheet(model: model) }
        #if DEBUG
        .onOpenURL { url in debug(url) }
        #endif
    }

    #if DEBUG
    /// Nur für Tests im Simulator: notizbuch://debug/lernen?start | extra | schreib (Probestrich und „Fertig“) | ja |
    /// nein | weiter | nochmal | selbst=1|0 | ende | state; Protokoll „Lern-Debug: …“
    private func debug(_ url: URL) {
        guard url.scheme == "notizbuch", url.host == "debug", url.path == "/lernen",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let has = { (n: String) in items.contains { $0.name == n } }
        if has("start") { model.starte() }
        if has("extra") { model.starte(extra: true) }
        if has("schreib") {
            let pts = (0...40).map { i -> PKStrokePoint in
                let x = 120 + Double(i) * 9, y = 150 + sin(Double(i) / 2) * 30
                return PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.02, size: CGSize(width: 5, height: 5),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
            model.drawing = PKDrawing(strokes: [stroke])
            abgeben()
        }
        if has("ja"), case .bestaetigen(let a) = model.phase { model.bestaetigt(a) }
        if has("nein") { model.nichtBestaetigt() }
        if has("weiter") { model.weiter() }
        if has("nochmal") { model.nochmalVersuchen() }
        if let v = items.first(where: { $0.name == "selbst" })?.value { model.selbstGeprueft(richtig: v == "1") }
        if has("ende") { model.beenden() }
        NSLog("Lern-Debug: phase=%@ wort=%@ versuch=%d index=%d/%d sterne=%.1f dran=%d woerter=%d log=%d status=%@ stimme=%@",
              String(describing: model.phase), model.aktuell?.wort ?? "-", model.versuch, model.index, model.queue.count,
              model.sterne, model.anzahlDran, model.aktiveWoerter.count, model.log.count, model.status ?? "-",
              model.sprecher.stimme)
    }
    #endif

    // MARK: Start

    private var start: some View {
        VStack(spacing: 20) {
            HStack {
                Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                Spacer()
                Button { bearbeiten = true } label: { Label("Wörter", systemImage: "list.bullet") }
            }
            .font(.headline)
            .padding(.horizontal)
            Spacer()
            Text("Lernwörter").font(.system(size: 44, weight: .bold, design: .rounded))
            let dran = model.anzahlDran
            if model.aktiveWoerter.isEmpty {
                Text("Noch keine Lernwörter da.\nPapa schickt sie an Claude, dann erscheinen sie hier.")
                    .multilineTextAlignment(.center).font(.title3).foregroundStyle(.secondary)
            } else if dran > 0 {
                Text(dran == 1 ? "1 Wort ist heute dran." : "\(min(dran, 10)) Wörter sind heute dran.")
                    .font(.title2.weight(.medium)).foregroundStyle(.secondary)
                grosserKnopf("Los geht's!", farbe: Self.gruen) { model.starte() }
            } else {
                Text("Heute ist alles geübt. 🎉").font(.title2.weight(.medium))
                Button("Trotzdem üben") { model.starte(extra: true) }.font(.title3)
            }
            if let s = model.status {
                Text(s).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
            }
            Spacer()
            Text("Stimme: \(model.sprecher.stimme)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical)
    }

    // MARK: Üben

    private var ueben: some View {
        VStack(spacing: 16) {
            HStack {
                Button { model.beenden() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                    .tint(.secondary)
                Spacer()
                Text("Wort \(min(model.index + 1, model.queue.count)) von \(model.queue.count)")
                    .font(.headline).foregroundStyle(.secondary)
                Spacer()
                Text("⭐ \(Self.sterne(model.sterne))").font(.headline.monospacedDigit())
            }
            .padding(.horizontal)

            Button { model.nochmalHoeren() } label: {
                Label("Nochmal hören", systemImage: "speaker.wave.2.fill")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Self.blau.opacity(0.12), in: Capsule())
            }
            .tint(Self.blau)

            if model.versuch > 1 && model.phase == .schreiben {
                Text("Zweiter Versuch – du schaffst das!").font(.headline).foregroundStyle(Self.blau)
            }

            LernCanvas(drawing: $model.drawing, radierer: radierer, aktiv: model.phase == .schreiben)
                .frame(height: 300)
                .background(Linien())
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.12)))
                .padding(.horizontal)

            if model.phase == .schreiben {
                HStack(spacing: 14) {
                    Button { radierer.toggle() } label: {
                        Label(radierer ? "Stift" : "Radierer", systemImage: radierer ? "pencil" : "eraser")
                    }
                    .buttonStyle(.bordered)
                    Button { model.drawing = PKDrawing(); radierer = false } label: {
                        Label("Alles weg", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button { abgeben() } label: {
                        Label("Fertig", systemImage: "checkmark").font(.title2.weight(.bold)).padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent).tint(Self.gruen)
                    .disabled(model.drawing.strokes.isEmpty)
                }
                .font(.title3)
                .padding(.horizontal)
            }

            karte.padding(.horizontal)
            Spacer(minLength: 0)
        }
        .padding(.vertical)
    }

    private func abgeben() {
        radierer = false
        guard let png = Self.bild(model.drawing) else { return }
        model.fertig(image: png)
    }

    @ViewBuilder private var karte: some View {
        switch model.phase {
        case .lesen:
            box {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Ich lese, was du geschrieben hast …").font(.title3)
                }
                Button("Abbrechen") { model.abbrechenLesen() }.font(.callout)
            }
        case .bestaetigen(let a):
            if a.unleserlich == true || a.gelesen.isEmpty {
                box {
                    Text("Das konnte ich nicht lesen.\nSchreib es bitte noch einmal, etwas größer.")
                        .font(.title3).multilineTextAlignment(.center)
                    grosserKnopf("Nochmal schreiben", farbe: Self.blau) { model.nichtBestaetigt() }
                }
            } else {
                box {
                    Text("Ich habe gelesen:").font(.title3).foregroundStyle(.secondary)
                    Text(a.gelesen).font(.system(size: 48, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.4).lineLimit(1)
                    Text("Hast du das so geschrieben?").font(.title3)
                    HStack(spacing: 16) {
                        grosserKnopf("Ja, genau so", farbe: Self.gruen) { model.bestaetigt(a) }
                        grosserKnopf("Nein, nochmal", farbe: .gray) { model.nichtBestaetigt() }
                    }
                }
            }
        case .richtig(let zweiter):
            box {
                Text(zweiter ? "½ ⭐" : "⭐").font(.system(size: 56))
                Text(model.lobText).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Self.gruen)
                    .multilineTextAlignment(.center)
                grosserKnopf("Weiter", farbe: Self.gruen) { model.weiter() }
            }
        case .tipp(let t):
            box {
                Text("Fast! 💡").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.orange)
                Text(t).font(.title3).multilineTextAlignment(.center)
                grosserKnopf("Nochmal versuchen", farbe: Self.blau) { model.nochmalVersuchen() }
            }
        case .aufloesung(let h):
            box {
                Text("Das war knifflig. So schreibt man es:").font(.title3)
                if let w = model.aktuell {
                    Text(w.wort).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(Self.gruen)
                        .minimumScaleFactor(0.4).lineLimit(1)
                }
                if let g = model.zuletztGelesen {
                    Text("Du hast geschrieben: \(g)").font(.callout).foregroundStyle(.secondary)
                }
                if let h { Text(h).font(.title3).multilineTextAlignment(.center) }
                Text("Es kommt später noch einmal dran.").font(.callout).foregroundStyle(.secondary)
                grosserKnopf("Weiter", farbe: Self.blau) { model.weiter() }
            }
        case .selbst(let grund):
            box {
                Text(grund).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("So schreibt man es:").font(.title3)
                if let w = model.aktuell {
                    Text(w.wort).font(.system(size: 52, weight: .bold, design: .rounded)).foregroundStyle(Self.gruen)
                        .minimumScaleFactor(0.4).lineLimit(1)
                }
                Text("Hast du es genauso geschrieben, auch groß und klein?").font(.title3).multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    grosserKnopf("Ja", farbe: Self.gruen) { model.selbstGeprueft(richtig: true) }
                    grosserKnopf("Nein", farbe: .gray) { model.selbstGeprueft(richtig: false) }
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: Fertig

    private var fertig: some View {
        var gesehen = Set<String>()
        let woerter = model.queue.map(\.wort).filter { gesehen.insert($0).inserted }
        let ersteRichtig = woerter.filter { model.ersteVersuche[$0] == "richtig" }.count
        return VStack(spacing: 18) {
            Spacer()
            Text("Geschafft! 🎉").font(.system(size: 44, weight: .bold, design: .rounded))
            Text("⭐ \(Self.sterne(model.sterne))").font(.system(size: 40, weight: .semibold))
            Text("\(ersteRichtig) von \(woerter.count) gleich beim ersten Mal richtig.").font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(woerter, id: \.self) { w in
                    HStack {
                        Text(Self.zeichen(model.ersteVersuche[w])).frame(width: 34)
                        Text(w).font(.title3)
                    }
                }
            }
            .padding()
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
            HStack(spacing: 16) {
                if model.anzahlDran > 0 {
                    grosserKnopf("Noch eine Runde", farbe: Self.blau) { model.starte() }
                }
                grosserKnopf("Fertig", farbe: Self.gruen) { model.beenden() }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: Bausteine

    private func box<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 14, content: content)
            .frame(maxWidth: 640)
            .padding(22)
            .background(.white, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private func grosserKnopf(_ titel: String, farbe: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(titel).font(.title2.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 12)
                .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .tint(farbe)
        .buttonBorderShape(.capsule)
    }

    static func sterne(_ s: Double) -> String {
        let ganz = Int(s)
        return s - Double(ganz) >= 0.5 ? (ganz == 0 ? "½" : "\(ganz)½") : "\(ganz)"
    }

    static func zeichen(_ e: String?) -> String {
        switch e {
        case "richtig": return "⭐"
        case "zweiter": return "½"
        case "falsch": return "🔁"
        default: return "·"
        }
    }

    /// Das Geschriebene als PNG auf Weiß, mit Rand
    static func bild(_ d: PKDrawing) -> Data? {
        let b = d.bounds.insetBy(dx: -24, dy: -24)
        guard !d.strokes.isEmpty, b.width > 0, b.height > 0 else { return nil }
        let scale: CGFloat = min(2, 2400 / max(b.width, b.height))
        let ink = d.image(from: b, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: b.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: b.size))
            ink.draw(in: CGRect(origin: .zero, size: b.size))
        }
        return img.pngData()
    }
}

/// Schreiblinien wie im Heft: Oberlinie, gestrichelte Mittellinie, Grundlinie (kräftiger), Unterlinie
private struct Linien: View {
    var body: some View {
        Canvas { ctx, size in
            let g: CGFloat = 55
            let top = (size.height - 3 * g) / 2
            let farbe = Color(red: 0.45, green: 0.6, blue: 0.85)
            for (i, y) in [top, top + g, top + 2 * g, top + 3 * g].enumerated() {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                let style = StrokeStyle(lineWidth: i == 2 ? 1.6 : 1, dash: i == 1 ? [6, 6] : [])
                ctx.stroke(p, with: .color(farbe.opacity(i == 2 ? 0.8 : 0.45)), style: style)
            }
        }
        .background(Color.white)
    }
}

/// Schreibfläche: PencilKit mit schwarzem Stift oder Radierer; mit dem Finger schreiben geht, wenn am iPad nicht
/// „Nur mit Apple Pencil zeichnen“ eingestellt ist
struct LernCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var radierer: Bool
    var aktiv: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .default
        v.isScrollEnabled = false
        v.drawing = drawing
        v.delegate = context.coordinator
        apply(v)
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if v.drawing != drawing { v.drawing = drawing }
        apply(v)
    }

    private func apply(_ v: PKCanvasView) {
        v.tool = radierer ? PKEraserTool(.vector) : PKInkingTool(.pen, color: .black, width: 5)
        v.isUserInteractionEnabled = aktiv
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: LernCanvas
        init(_ p: LernCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ v: PKCanvasView) {
            let d = v.drawing
            DispatchQueue.main.async { if self.parent.drawing != d { self.parent.drawing = d } }
        }
    }
}

/// Wortliste ansehen und ändern: Fach je Wort, Wörter hinzufügen („Wort | Satz“ je Zeile), wischen zum Entfernen
struct LernWoerterSheet: View {
    @ObservedObject var model: LernModel
    @Environment(\.dismiss) private var dismiss
    @State private var neu = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $neu).frame(minHeight: 90)
                    Button("Hinzufügen") {
                        let add = LernModel.parse(neu)
                        neu = ""
                        Task { await model.aendern(add: add) }
                    }
                    .disabled(LernModel.parse(neu).isEmpty)
                } header: {
                    Text("Neue Wörter")
                } footer: {
                    Text("Je Zeile ein Wort, optional mit Satz: „Fahrrad | Ich fahre mit dem Fahrrad.“ Einfacher: die Liste an Claude schicken, dann kommt zu jedem Wort ein Satz dazu.")
                }
                Section("Wörter (\(model.aktiveWoerter.count))") {
                    let k = model.karten
                    ForEach(model.aktiveWoerter) { w in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(w.wort).font(.body.weight(.medium))
                                if let s = w.satz { Text(s).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Fach(fach: k[w.wort]?.fach ?? 0)
                        }
                    }
                    .onDelete { idx in
                        let remove = idx.map { model.aktiveWoerter[$0].wort }
                        Task { await model.aendern(remove: remove) }
                    }
                }
                if let s = model.status { Section { Text(s).foregroundStyle(.orange) } }
            }
            .navigationTitle("Lernwörter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// Fach in der Lernkartei als fünf Punkte (neu: „neu“)
private struct Fach: View {
    var fach: Int
    var body: some View {
        if fach == 0 {
            Text("neu").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { i in
                    Circle().fill(i <= fach ? Color.green : Color.gray.opacity(0.25)).frame(width: 8, height: 8)
                }
            }
        }
    }
}
