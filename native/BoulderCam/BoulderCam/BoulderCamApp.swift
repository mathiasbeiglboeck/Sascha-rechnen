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
    @AppStorage("verzoegerung") private var savedDelay = CameraEngine.defaultDelay
    @AppStorage("useBack") private var useBack = false
    @State private var flashDelay = false
    @State private var flashToken = 0

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
            cam.start(back: useBack)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                cam.start(back: useBack)
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
        ReplayView(engine: cam)
            .aspectRatio(cam.aspect, contentMode: .fit)
            .overlay(alignment: .topLeading) { recordingBadge.padding(10) }
            .overlay { waitingHint }
            .overlay { delayFlash }
            .overlay(alignment: .bottom) { toastView.padding(.bottom, 16) }
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
                    ForEach(CameraEngine.delayChoices, id: \.self) { d in
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
            Button {
                useBack.toggle()
                cam.switchCamera(back: useBack)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .disabled(cam.isRecording)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                // Live picture for aiming: mirrored like a normal selfie camera.
                LiveView(engine: cam)
                    .aspectRatio(cam.aspect, contentMode: .fit)
                    .scaleEffect(x: useBack ? 1 : -1, y: 1)
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
                Button { cam.toggleRecording() } label: {
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
