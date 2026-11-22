import Charts
import PencilKit
import SwiftUI

/// Lernwörter üben (für Sascha): Start mit der Wortliste, dann je Wort vorsprechen, schreiben, lesen lassen,
/// bestätigen, Rückmeldung. Siehe LernModel
struct LernView: View {
    @StateObject private var model: LernModel
    @Environment(\.dismiss) private var dismiss
    @State private var radierer = false
    @State private var bearbeiten = false
    @State private var statistik = false
    /// Vorsprechen: nur das Wort (Standard) oder Wort, Beispielsatz, Wort
    @AppStorage(Sprecher.mitSatzKey) private var mitSatz = false

    init(sync: SyncEngine) {
        _model = StateObject(wrappedValue: LernModel(sync: sync))
    }

    static let papier = Color(red: 0.99, green: 0.98, blue: 0.94)
    static let gruen = Color(red: 0.16, green: 0.62, blue: 0.33)
    static let blau = Color(red: 0.18, green: 0.42, blue: 0.85)
    /// Statistik: mit dem Tipp richtig (halb) und noch nicht richtig
    static let gelb = Color(red: 0.96, green: 0.72, blue: 0.13)
    static let orange = Color(red: 0.93, green: 0.43, blue: 0.24)

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
        .sheet(isPresented: $statistik) { LernStatistikView(model: model) }
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
        if has("start") { model.starte(size: 10) }
        if has("extra") || has("fuenf") { model.starte(size: 5) }
        if has("nochmalrunde") { model.nochmalProbieren() }
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
        // Vorab lesen prüfen: zeichne = Probestrich ohne „Fertig“ (nach 0,7 s liest der Mac vorab), fertig = „Fertig“
        if has("zeichne") {
            let x0 = 120 + 60 * Double(model.drawing.strokes.count)
            let pts: [PKStrokePoint] = (0...20).map { i in
                let t = Double(i)
                let p = CGPoint(x: x0 + 2 * t, y: 120 + 4 * t)
                return PKStrokePoint(location: p, timeOffset: 0.02 * t, size: CGSize(width: 5, height: 5),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
            model.drawing = PKDrawing(strokes: model.drawing.strokes + [stroke])
        }
        if has("fertig") { abgeben() }
        if has("radierer") { radierer.toggle() }
        if has("statistik") { statistik = true }
        if has("zu") { statistik = false; bearbeiten = false }
        if has("ja"), case .bestaetigen(let a) = model.phase { model.bestaetigt(a) }
        if has("nein") { model.nichtBestaetigt() }
        if has("weiter") { model.weiter() }
        if has("nochmal") { model.nochmalVersuchen() }
        if let v = items.first(where: { $0.name == "selbst" })?.value { model.selbstGeprueft(richtig: v == "1") }
        if has("ende") { model.beenden() }
        NSLog("Lern-Debug: vorab=%d radierer=%d", model.vorabAnzahl, radierer ? 1 : 0)
        let heute = LernStatistik.zahlen(model.log, ab: Calendar.current.startOfDay(for: Date()))
        let alle = LernStatistik.zahlen(model.log)
        NSLog("Lern-Debug: reihenfolge=%@", model.reihenfolge.map(\.wort).joined(separator: ","))
        NSLog("Lern-Debug: statistik heute=%d/%d/%d gesamt=%d/%d/%d tage=%d faecher=%@", heute.richtig, heute.halb, heute.falsch,
              alle.richtig, alle.halb, alle.falsch, LernStatistik.uebungstage(model.log),
              LernStatistik.faecher(model.words, model.karten).map { String($0) }.joined(separator: ","))
        NSLog("Lern-Debug: phase=%@ wort=%@ versuch=%d index=%d/%d sterne=%.1f dran=%d woerter=%d log=%d status=%@ stimme=%@",
              String(describing: model.phase), model.aktuell?.wort ?? "-", model.versuch, model.index, model.queue.count,
              model.sterne, model.anzahlDran, model.aktiveWoerter.count, model.log.count, model.status ?? "-",
              model.sprecher.stimme)
    }
    #endif

    // MARK: Start

    private var start: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                Spacer()
                Button { statistik = true } label: { Label("Statistik", systemImage: "chart.bar.fill") }
                Button { bearbeiten = true } label: { Label("Wörter", systemImage: "list.bullet") }
            }
            .font(.headline)
            .padding(.horizontal)
            ScrollView {
                VStack(spacing: 20) {
                    Text("Lernwörter").font(.system(size: 44, weight: .bold, design: .rounded)).padding(.top, 8)
                    if model.aktiveWoerter.isEmpty {
                        Text("Noch keine Lernwörter da.\nPapa schickt sie an Claude, dann erscheinen sie hier.")
                            .multilineTextAlignment(.center).font(.title3).foregroundStyle(.secondary)
                    } else {
                        Text("Wie viele Wörter möchtest du üben?").font(.title2.weight(.medium))
                        HStack(spacing: 20) {
                            rundenKnopf(5)
                            rundenKnopf(10)
                        }
                        Toggle(isOn: $mitSatz) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mit Beispielsatz vorsprechen").font(.headline)
                                Text(mitSatz ? "Wort, Satz, nochmal das Wort" : "Nur das Wort").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 360)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) {
                                naechsteKarte.frame(minWidth: 330)
                                statistikKarte.frame(minWidth: 330)
                            }
                            VStack(spacing: 20) {
                                naechsteKarte
                                statistikKarte
                            }
                        }
                        .frame(maxWidth: 900)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    if let s = model.status {
                        Text(s).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
                    }
                    Text("Stimme: \(model.sprecher.stimme) (ändern unter „Wörter“)").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom)
            }
        }
        .padding(.top)
    }

    /// Die Wörter in der Reihenfolge, in der sie drankommen: blau die nächste Fünferrunde, grün bis zehn
    private var naechsteKarte: some View {
        let liste = model.reihenfolge
        let k = model.karten
        return VStack(alignment: .leading, spacing: 10) {
            Text("Als Nächstes dran").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(liste.enumerated()), id: \.element.id) { i, w in
                        NaechstesWort(nummer: i + 1, wort: w.wort, fach: k[w.wort]?.fach ?? 0)
                        if (i == 4 && liste.count > 5) || (i == 9 && liste.count > 10) { Divider() }
                    }
                }
            }
            .frame(maxHeight: 330)
            Text("Blau: die nächsten 5 Wörter, grün: bis 10").font(.caption).foregroundStyle(.secondary)
        }
        .lernKarte()
    }

    /// Kurz: heute und insgesamt geübt, Anteil gleich richtig; „Mehr“ öffnet die Statistik
    private var statistikKarte: some View {
        let heute = LernStatistik.zahlen(model.log, ab: Calendar.current.startOfDay(for: Date()))
        let alle = LernStatistik.zahlen(model.log)
        let tage = LernStatistik.uebungstage(model.log)
        return VStack(alignment: .leading, spacing: 14) {
            Text("So viel hast du geübt").font(.headline)
            if alle.summe == 0 {
                Text("Noch nichts. Los geht's!").foregroundStyle(.secondary)
            } else {
                if heute.summe > 0 { ZahlenZeile(titel: "Heute", zahlen: heute) }
                ZahlenZeile(titel: tage == 1 ? "Insgesamt, an 1 Tag" : "Insgesamt, an \(tage) Tagen", zahlen: alle)
                Button { statistik = true } label: { Label("Mehr Statistik", systemImage: "chart.bar.fill") }
                    .buttonStyle(.bordered)
            }
        }
        .lernKarte()
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

            if model.phase == .schreiben {
                Text(model.versuch > 1 ? "Zweiter Versuch – du schaffst das!" : "Schreib nur das eine Wort.")
                    .font(.headline).foregroundStyle(model.versuch > 1 ? Self.blau : .secondary)
            }

            LernCanvas(drawing: $model.drawing, radierer: radierer, aktiv: model.phase == .schreiben)
                .onChange(of: model.drawing) { _, _ in model.zeichnungGeaendert() }
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
                if let t {
                    Text(t).font(.title3).multilineTextAlignment(.center)
                    grosserKnopf("Nochmal versuchen", farbe: Self.blau) { model.nochmalVersuchen() }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Ich überlege mir einen Tipp für dich …").font(.title3)
                    }
                }
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
                Text("Am Ende kannst du es nochmal probieren.").font(.callout).foregroundStyle(.secondary)
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
            Text(model.nochmalRunde ? "Nochmal geübt! 🎉" : "Geschafft! 🎉").font(.system(size: 44, weight: .bold, design: .rounded))
            Text("⭐ \(Self.sterne(model.sterne))").font(.system(size: 40, weight: .semibold))
            if !model.nochmalRunde {
                Text("\(ersteRichtig) von \(woerter.count) gleich beim ersten Mal richtig.").font(.title3)
            }
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
            let nochmal = model.nochmalWoerter.count
            if nochmal > 0 {
                Text(nochmal == 1 ? "Ein Wort war noch nicht ganz richtig. Möchtest du es nochmal probieren?"
                     : "\(nochmal) Wörter waren noch nicht ganz richtig. Möchtest du sie nochmal probieren?")
                    .font(.title3).multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    grosserKnopf("Ja, nochmal", farbe: Self.blau) { model.nochmalProbieren() }
                    grosserKnopf("Nein, fertig", farbe: Self.gruen) { model.beenden() }
                }
            } else {
                grosserKnopf("Fertig", farbe: Self.gruen) { model.beenden() }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: Bausteine

    /// „5 Wörter“ / „10 Wörter“ (weniger, wenn es so viele noch nicht gibt)
    private func rundenKnopf(_ n: Int) -> some View {
        Button { model.starte(size: n) } label: {
            VStack(spacing: 2) {
                Text("\(n)").font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Wörter").font(.title3.weight(.semibold))
            }
            .frame(width: 150, height: 120)
        }
        .buttonStyle(.borderedProminent)
        .tint(n == 5 ? Self.blau : Self.gruen)
        .buttonBorderShape(.roundedRectangle(radius: 24))
    }

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
/// „Nur mit Apple Pencil zeichnen“ eingestellt ist. Der Radierer nimmt nur weg, worüber er fährt (Teile eines
/// Buchstabens), und zeigt dabei wie im Notizbuch einen kleinen Kreis
struct LernCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var radierer: Bool
    var aktiv: Bool
    /// So breit wischt der Radierer (Punkte); der Kreis zeigt genau diese Fläche
    static let radiererBreite: CGFloat = 16

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LernCanvasView {
        let v = LernCanvasView()
        v.canvas.drawing = drawing
        v.canvas.delegate = context.coordinator
        apply(v)
        return v
    }

    func updateUIView(_ v: LernCanvasView, context: Context) {
        context.coordinator.parent = self
        if v.canvas.drawing != drawing { v.canvas.drawing = drawing }
        apply(v)
    }

    private func apply(_ v: LernCanvasView) {
        v.canvas.tool = radierer ? PKEraserTool(.bitmap, width: Self.radiererBreite) : PKInkingTool(.pen, color: .black, width: 5)
        v.canvas.isUserInteractionEnabled = aktiv
        v.radierer = radierer && aktiv
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

/// PencilKit-Leinwand mit dem Radierer-Kreis wie im Notizbuch (grauer Rand, halb durchsichtig weiß): Er läuft unter
/// dem Pencil oder Finger mit, solange der Radierer gewählt ist, und mit einem Pencil, der schweben kann, schon darüber
final class LernCanvasView: UIView, UIGestureRecognizerDelegate {
    let canvas = PKCanvasView()
    private let kreis = UIView()
    private var beruehrt = false
    var radierer = false {
        didSet { if !radierer { kreis.isHidden = true } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .default
        canvas.isScrollEnabled = false
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(canvas)

        let d = LernCanvas.radiererBreite
        kreis.frame = CGRect(x: 0, y: 0, width: d, height: d)
        kreis.layer.cornerRadius = d / 2
        kreis.layer.borderWidth = 1.5
        kreis.layer.borderColor = UIColor(white: 0.35, alpha: 0.9).cgColor
        kreis.backgroundColor = UIColor(white: 1, alpha: 0.35)
        kreis.isUserInteractionEnabled = false
        kreis.isHidden = true
        addSubview(kreis)

        let mit = Mitlaeufer(target: nil, action: nil)
        mit.onTouch = { [weak self] t in self?.beruehrung(t) }
        canvas.addGestureRecognizer(mit)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(schwebt(_:)))
        hover.delegate = self
        canvas.addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func beruehrung(_ t: UITouch?) {
        beruehrt = t != nil
        zeige(t?.preciseLocation(in: self))
    }

    @objc private func schwebt(_ g: UIHoverGestureRecognizer) {
        guard !beruehrt else { return }
        switch g.state {
        case .began, .changed: zeige(g.location(in: self))
        default: zeige(nil)
        }
    }

    private func zeige(_ p: CGPoint?) {
        guard radierer, let p else {
            kreis.isHidden = true
            return
        }
        kreis.center = p
        kreis.isHidden = false
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
                StimmenSection(sprecher: model.sprecher)
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

/// Stimme wählen: automatisch oder eine der deutschen Stimmen dieses Geräts (antippen spricht eine Probe)
private struct StimmenSection: View {
    @ObservedObject var sprecher: Sprecher
    var body: some View {
        Section {
            Button { sprecher.waehle(nil) } label: {
                HStack { Text("Automatisch (die beste)"); Spacer(); if sprecher.automatisch { Image(systemName: "checkmark") } }
            }
            ForEach(Sprecher.deutsche, id: \.identifier) { v in
                Button { sprecher.waehle(v) } label: {
                    HStack {
                        Text(Sprecher.titel(v))
                        Spacer()
                        if !sprecher.automatisch && sprecher.voice?.identifier == v.identifier { Image(systemName: "checkmark") }
                    }
                }
            }
        } header: {
            Text("Stimme")
        } footer: {
            Text("Antippen zum Probehören. Schönere Stimmen am iPad laden: Settings › Accessibility › Spoken Content › Voices › German, dort „Enhanced“ oder „Premium“.")
        }
    }
}

// MARK: - Startseite und Statistik

private extension View {
    /// Weiße Karte mit Schatten
    func lernKarte() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.07), radius: 9, y: 3)
    }
}

/// Eine Zeile der Liste „Als Nächstes dran“: Nummer (blau bis 5, grün bis 10), Wort, Fach
private struct NaechstesWort: View {
    var nummer: Int
    var wort: String
    var fach: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(nummer)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(farbe, in: Circle())
            Text(wort).font(.title3.weight(.medium))
            Spacer(minLength: 8)
            Fach(fach: fach)
        }
    }

    private var farbe: Color {
        nummer <= 5 ? LernView.blau : nummer <= 10 ? LernView.gruen : Color.gray.opacity(0.45)
    }
}

/// Ein Balken, nach Anzahl in farbige Teile geteilt
struct AnteilBalken: View {
    struct Teil {
        var anzahl: Int
        var farbe: Color
    }
    var teile: [Teil]

    /// Gleich richtig (grün), mit Tipp (gelb), noch üben (orange)
    init(_ z: LernStatistik.Zahlen) {
        teile = [Teil(anzahl: z.richtig, farbe: LernView.gruen), Teil(anzahl: z.halb, farbe: LernView.gelb),
                 Teil(anzahl: z.falsch, farbe: LernView.orange)]
    }

    init(teile: [Teil]) { self.teile = teile }

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(teile.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(t.farbe).frame(width: breite(t, g.size.width))
                }
            }
        }
        .background(Color.gray.opacity(0.15))
        .clipShape(Capsule())
    }

    private func breite(_ t: Teil, _ gesamt: CGFloat) -> CGFloat {
        let summe = teile.reduce(0) { $0 + $1.anzahl }
        return summe == 0 ? 0 : gesamt * CGFloat(t.anzahl) / CGFloat(summe)
    }
}

/// Geübte Wörter mit Balken und Anteil gleich richtig (Startseite)
private struct ZahlenZeile: View {
    var titel: String
    var zahlen: LernStatistik.Zahlen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(titel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(zahlen.summe == 1 ? "1 Wort" : "\(zahlen.summe) Wörter").font(.title3.weight(.bold).monospacedDigit())
            }
            AnteilBalken(zahlen).frame(height: 14)
            Text("⭐ \(zahlen.richtig) gleich richtig · ½ \(zahlen.halb) mit Tipp · 🔁 \(zahlen.falsch) noch üben")
                .font(.caption).foregroundStyle(.secondary)
            if let a = zahlen.anteil {
                Text("\(Int((a * 100).rounded())) % gleich richtig").font(.callout.weight(.semibold)).foregroundStyle(LernView.gruen)
            }
        }
    }
}

/// Statistik: geübt heute, in den letzten 7 Tagen und insgesamt; Verlauf der letzten 14 Tage; wie gut die Wörter
/// sitzen (Fächer der Lernkartei); welche noch schwer fallen. Zählt alle Geräte (das Protokoll am Server)
struct LernStatistikView: View {
    @ObservedObject var model: LernModel
    @Environment(\.dismiss) private var dismiss

    static let richtigText = "gleich richtig"
    static let halbText = "mit Tipp"
    static let falschText = "noch üben"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    kacheln
                    karte("Die letzten 14 Tage") { verlauf }
                    karte("So gut sitzen die Wörter") { faecher }
                    schwierig
                    Text("Jedes geschriebene Wort zählt einmal, auch beim Nochmal-Probieren. ⭐ gleich richtig, ½ mit dem Tipp richtig, 🔁 noch üben.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .background(LernView.papier.ignoresSafeArea())
            .navigationTitle("Statistik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .environment(\.locale, Locale(identifier: "de_AT"))
    }

    private var kacheln: some View {
        let cal = Calendar.current
        let heute = cal.startOfDay(for: Date())
        let woche = cal.date(byAdding: .day, value: -6, to: heute) ?? heute
        let tage = LernStatistik.uebungstage(model.log)
        return HStack(alignment: .top, spacing: 14) {
            Kachel(titel: "Heute", zahlen: LernStatistik.zahlen(model.log, ab: heute), unten: nil)
            Kachel(titel: "Letzte 7 Tage", zahlen: LernStatistik.zahlen(model.log, ab: woche), unten: nil)
            Kachel(titel: "Insgesamt", zahlen: LernStatistik.zahlen(model.log), unten: tage == 1 ? "an 1 Tag" : "an \(tage) Tagen")
        }
    }

    private var verlauf: some View {
        let tage = LernStatistik.tage(model.log)
        return Chart {
            ForEach(tage) { t in
                BarMark(x: .value("Tag", t.tag, unit: .day), y: .value("Wörter", t.zahlen.richtig))
                    .foregroundStyle(by: .value("Ergebnis", Self.richtigText))
                BarMark(x: .value("Tag", t.tag, unit: .day), y: .value("Wörter", t.zahlen.halb))
                    .foregroundStyle(by: .value("Ergebnis", Self.halbText))
                BarMark(x: .value("Tag", t.tag, unit: .day), y: .value("Wörter", t.zahlen.falsch))
                    .foregroundStyle(by: .value("Ergebnis", Self.falschText))
            }
        }
        .chartForegroundStyleScale([Self.richtigText: LernView.gruen, Self.halbText: LernView.gelb, Self.falschText: LernView.orange])
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.defaultDigits))
            }
        }
        .chartLegend(position: .bottom)
        .frame(height: 220)
    }

    private struct Gruppe: Identifiable {
        var name: String
        var anzahl: Int
        var farbe: Color
        var id: String { name }
    }

    private var faecher: some View {
        let f = LernStatistik.faecher(model.words, model.karten)
        let gruppen = [
            Gruppe(name: "neu", anzahl: f[0], farbe: Color.gray.opacity(0.45)),
            Gruppe(name: "noch üben", anzahl: f[1], farbe: LernView.orange),
            Gruppe(name: "wird besser", anzahl: f[2] + f[3], farbe: LernView.gelb),
            Gruppe(name: "sitzt", anzahl: f[4] + f[5], farbe: LernView.gruen),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            AnteilBalken(teile: gruppen.map { AnteilBalken.Teil(anzahl: $0.anzahl, farbe: $0.farbe) }).frame(height: 18)
            HStack(spacing: 18) {
                ForEach(gruppen) { g in
                    HStack(spacing: 6) {
                        Circle().fill(g.farbe).frame(width: 10, height: 10)
                        Text("\(g.name): \(g.anzahl)").font(.callout)
                    }
                }
            }
            Text("Ist ein Wort gleich richtig, rückt es ein Fach weiter und kommt seltener dran. Nach einem Fehler beginnt es wieder vorne.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var schwierig: some View {
        let schwer = LernStatistik.schwierig(model.words, model.karten)
        if !schwer.isEmpty {
            karte("Diese Wörter üben wir noch") {
                ForEach(schwer) { s in
                    HStack {
                        Text(s.wort).font(.title3.weight(.medium))
                        Spacer()
                        Text("\(s.karte.richtig) von \(s.karte.versuche) gleich richtig").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func karte<C: View>(_ titel: String, @ViewBuilder _ inhalt: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titel).font(.headline)
            inhalt()
        }
        .lernKarte()
    }
}

/// Eine Kachel oben in der Statistik: Zahl der geübten Wörter, Balken, Anteil gleich richtig
private struct Kachel: View {
    var titel: String
    var zahlen: LernStatistik.Zahlen
    var unten: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(titel).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(zahlen.summe)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
            Text(zahlen.summe == 1 ? "Wort geübt" : "Wörter geübt").font(.callout)
            AnteilBalken(zahlen).frame(height: 10)
            Text(prozent).font(.caption.weight(.semibold)).foregroundStyle(LernView.gruen)
            if let unten { Text(unten).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private var prozent: String {
        guard let a = zahlen.anteil else { return "–" }
        return "\(Int((a * 100).rounded())) % gleich richtig"
    }
}
