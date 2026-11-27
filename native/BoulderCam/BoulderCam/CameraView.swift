import AVFoundation
import AVKit
import SwiftUI

/// The delayed replay. Also listens to the volume buttons: up = longer delay,
/// down = shorter delay.
struct ReplayView: UIViewRepresentable {
    let engine: CameraEngine
    /// The zoomed part of the picture, in 0…1 coordinates.
    let crop: CGRect

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
        view.crop = crop
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) { view.crop = crop }
}

/// The small live picture for aiming the phone.
struct LiveView: UIViewRepresentable {
    let engine: CameraEngine
    let crop: CGRect

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView(hosted: engine.liveLayer)
        view.crop = crop
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) { view.crop = crop }
}

/// Shows a video layer; with a crop smaller than the whole picture the layer
/// is enlarged and moved so only that part is visible (digital zoom).
final class LayerHostView: UIView {
    private let hosted: CALayer
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet { if crop != oldValue { setNeedsLayout() } }
    }

    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(hosted)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width / crop.width, h = bounds.height / crop.height
        hosted.frame = CGRect(x: -crop.minX * w, y: -crop.minY * h, width: w, height: h)
        CATransaction.commit()
    }
}
