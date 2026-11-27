import AVFoundation
import AVKit
import SwiftUI

/// The delayed replay. Also listens to the volume buttons: up = longer delay,
/// down = shorter delay.
struct ReplayView: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView(hosted: engine.displayLayer)
        // Only delivered while the capture session runs and the app is in front.
        // Primary = volume down (and Camera Control), secondary = volume up.
        let interaction = AVCaptureEventInteraction(
            primary: { [weak engine] event in
                if event.phase == .began { engine?.stepDelay(-1) }
            },
            secondary: { [weak engine] event in
                if event.phase == .began { engine?.stepDelay(+1) }
            })
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {}
}

/// The small live picture for aiming the phone.
struct LiveView: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> LayerHostView { LayerHostView(hosted: engine.previewLayer) }
    func updateUIView(_ view: LayerHostView, context: Context) {}
}

final class LayerHostView: UIView {
    private let hosted: CALayer

    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(hosted)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}
