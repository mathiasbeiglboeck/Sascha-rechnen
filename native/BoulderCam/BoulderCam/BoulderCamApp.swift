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
    @AppStorage("delay") private var delay = 60            // 0 = live
    @AppStorage("lastDelay") private var lastDelay = 60    // last delay other than live
    @AppStorage("useBack") private var useBack = false
    @AppStorage("mirrorFront") private var mirrorFront = true
    @AppStorage("mirrorBack") private var mirrorBack = false

    private var mirrored: Bool { useBack ? mirrorBack : mirrorFront }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.permissionDenied {
                permissionHint
            } else {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    picture
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            cam.setDelay(delay, remembered: lastDelay)
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
        .onChange(of: delay) { _, d in
            if d > 0 { lastDelay = d }
            cam.setDelay(d, remembered: lastDelay)
        }
    }

    // MARK: Picture

    private var picture: some View {
        CameraView(engine: cam)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .overlay(alignment: .topLeading) { badges.padding(10) }
            .overlay { waitingHint }
            .overlay(alignment: .bottom) { toastView.padding(.bottom, 16) }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { delay = delay == 0 ? lastDelay : 0 }
    }

    private var badges: some View {
        HStack(spacing: 8) {
            if delay > 0 {
                Text("−\(Self.label(delay))")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.black)
            }
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
    }

    @ViewBuilder private var waitingHint: some View {
        let remaining = Int((Double(delay) - cam.bufferedSeconds).rounded(.up))
        if delay > 0 && remaining > 0 {
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
                Picker("Wiedergabe", selection: $delay) {
                    Text("Live").tag(0)
                    ForEach(CameraEngine.delayChoices, id: \.self) { d in
                        Text("\(Self.label(d)) verzögert").tag(d)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: delay == 0 ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                    Text(delay == 0 ? "Live" : "\(Self.label(delay)) verzögert")
                }
                .font(.system(.body, design: .rounded).weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            Spacer()
            roundButton(mirrored ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                                 : "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        active: mirrored) {
                if useBack { mirrorBack.toggle() } else { mirrorFront.toggle() }
            }
            roundButton("arrow.triangle.2.circlepath.camera", active: false) {
                useBack.toggle()
                cam.switchCamera(back: useBack)
            }
            .disabled(cam.isRecording)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func roundButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(active ? 0.3 : 0.12), in: Circle())
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button { cam.primaryAction() } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    if cam.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                    } else if delay > 0 {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.orange)
                            .offset(y: -2)
                    } else {
                        Circle().fill(.red).frame(width: 62, height: 62)
                    }
                }
            }
            Text(hintText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
    }

    private var hintText: String {
        if cam.isRecording { return "Lautstärketaste beendet die Aufnahme" }
        if delay > 0 { return "Lautstärketaste speichert die Wiederholung in Fotos" }
        return "Lautstärketaste startet die Aufnahme"
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
        switch seconds {
        case 60: return "1 min"
        case 90: return "1½ min"
        case 120: return "2 min"
        default: return "\(seconds) s"
        }
    }
}
