import SwiftUI

@main
struct BoulderCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraEngine()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("verzoegerungSekunden") private var savedDelay = CameraEngine.defaultDelay
    // Digital zoom: the part of the picture shown (live and replay alike) and
    // later saved. The buffer always keeps the whole picture.
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("zoomX") private var zoomX = 0.5
    @AppStorage("zoomY") private var zoomY = 0.5
    @State private var pinchStart: Double?
    @State private var dragStart: CGPoint?
    @State private var replaySize = CGSize(width: 300, height: 400)
    @State private var flashDelay = false
    @State private var flashToken = 0

    static let maxZoom = 5.0

    private var crop: CGRect {
        let w = 1 / max(zoom, 1)
        let x = min(max(zoomX - w / 2, 0), 1 - w)
        let y = min(max(zoomY - w / 2, 0), 1 - w)
        return CGRect(x: x, y: y, width: w, height: w)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.permissionDenied {
                permissionHint
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    replay
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            cam.setDelay(savedDelay)
            cam.start(back: false)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                cam.start(back: false)
            case .background:
                cam.stop()
            default:
                break
            }
        }
        .onChange(of: cam.delay) { _, d in savedDelay = d }
        .onChange(of: cam.delayChangeCount) { _, _ in
            flashToken += 1
            let token = flashToken
            withAnimation(.easeOut(duration: 0.15)) { flashDelay = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if flashToken == token { withAnimation(.easeIn(duration: 0.3)) { flashDelay = false } }
            }
        }
    }

    // MARK: Delayed picture (never mirrored: it looks like a played-back video)

    private var replay: some View {
        ReplayView(engine: cam, crop: crop)
            .aspectRatio(cam.aspect, contentMode: .fit)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { replaySize = g.size }
                    .onChange(of: g.size) { _, size in replaySize = size }
            })
            .overlay(alignment: .topLeading) { recordingBadge.padding(10) }
            .overlay { waitingHint }
            .overlay { delayFlash }
            .overlay(alignment: .bottom) { toastView.padding(.bottom, 16) }
            .contentShape(Rectangle())
            .gesture(zoomGesture)
            .onTapGesture(count: 2) { resetZoom() }
    }

    /// Two fingers zoom, one finger moves the zoomed part.
    private var zoomGesture: some Gesture {
        let pinch = MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                zoom = min(max(start * Double(value.magnification), 1), Self.maxZoom)
                clampCenter()
            }
            .onEnded { _ in pinchStart = nil }
        let drag = DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard zoom > 1.01 else { return }
                let start = dragStart ?? CGPoint(x: zoomX, y: zoomY)
                dragStart = start
                zoomX = Double(start.x) - Double(value.translation.width / max(replaySize.width, 1)) / zoom
                zoomY = Double(start.y) - Double(value.translation.height / max(replaySize.height, 1)) / zoom
                clampCenter()
            }
            .onEnded { _ in dragStart = nil }
        return SimultaneousGesture(pinch, drag)
    }

    private func clampCenter() {
        let half = 0.5 / max(zoom, 1)
        zoomX = min(max(zoomX, half), 1 - half)
        zoomY = min(max(zoomY, half), 1 - half)
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            zoomX = 0.5
            zoomY = 0.5
        }
    }

    @ViewBuilder private var recordingBadge: some View {
        if cam.isRecording {
            TimelineView(.periodic(from: cam.recordingStart, by: 1)) { context in
                let s = max(0, Int(context.date.timeIntervalSince(cam.recordingStart)))
                Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "circle.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private var waitingHint: some View {
        let remaining = Int((Double(cam.delay) - cam.bufferedSeconds).rounded(.up))
        if remaining > 0 && !flashDelay {
            VStack(spacing: 6) {
                Text("\(remaining)")
                    .font(.system(size: 64, weight: .light, design: .rounded).monospacedDigit())
                Text("Sekunden bis zur Wiederholung")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var delayFlash: some View {
        if flashDelay {
            Text("−\(Self.label(cam.delay))")
                .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var toastView: some View {
        if let text = cam.toast {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 16)
                .transition(.opacity)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Verzögerung", selection: Binding(get: { cam.delay }, set: { cam.setDelay($0) })) {
                    // The menu offers round values; the volume buttons go in 2-s steps.
                    ForEach(Array(Set(Array(stride(from: 10, through: 120, by: 10)) + [cam.delay])).sorted(),
                            id: \.self) { d in
                        Text("\(Self.label(d)) verzögert").tag(d)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("\(Self.label(cam.delay)) verzögert")
                        .monospacedDigit()
                }
                .font(.system(.body, design: .rounded).weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            Spacer()
            if zoom > 1.01 {
                // Shows the zoom; tapping it goes back to the whole picture.
                Button { resetZoom() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.magnifyingglass")
                        Text(zoom.formatted(.number.precision(.fractionLength(1))) + "×")
                            .monospacedDigit()
                    }
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                // Live picture for aiming: mirrored like a normal selfie camera.
                LiveView(engine: cam, crop: crop)
                    .aspectRatio(cam.aspect, contentMode: .fit)
                    .scaleEffect(x: -1, y: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomLeading) {
                        Text("LIVE")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(5)
                    }
                    .frame(width: 110, height: 140, alignment: .leading)
                Spacer()
                Button { cam.toggleRecording(crop: crop) } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        if cam.isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(.red).frame(width: 62, height: 62)
                        }
                    }
                }
                Spacer()
                Color.clear.frame(width: 110, height: 1)
            }
            Text(cam.isRecording ? "Nimmt die Wiederholung auf · Knopf beendet"
                                 : "Lauter / Leiser ändert die Verzögerung")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var permissionHint: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash").font(.system(size: 44))
            Text("BoulderCam braucht Zugriff auf die Kamera.")
            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    static func label(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return String(format: "%d:%02d min", seconds / 60, seconds % 60)
    }
}
