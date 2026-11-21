import AVFoundation
import AVKit
import SwiftUI

/// Hosts the live preview and the delayed replay, and listens to the volume buttons.
struct CameraView: UIViewRepresentable {
    let engine: CameraEngine

    func makeUIView(context: Context) -> CameraHostView { CameraHostView(engine: engine) }
    func updateUIView(_ view: CameraHostView, context: Context) {}
}

final class CameraHostView: UIView {
    private let engine: CameraEngine

    init(engine: CameraEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(engine.previewLayer)
        layer.addSublayer(engine.displayLayer)

        // Volume up and down (and the Camera Control button where there is one).
        // Only delivered while the capture session runs and the app is in front.
        let interaction = AVCaptureEventInteraction { [weak engine] event in
            if event.phase == .ended { engine?.primaryAction() }
        }
        addInteraction(interaction)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        engine.previewLayer.frame = bounds
        engine.displayLayer.frame = bounds
        CATransaction.commit()
    }
}
