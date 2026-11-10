import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Eine Geste mit genau einem Finger oder dem Pencil (Zeigestift, Radierer).
///
/// Der Pencil beginnt sofort. Ein Finger (iPhone) beginnt erst nach 4 Punkten Bewegung oder 70 ms:
/// Kommt bis dahin ein zweiter Finger dazu, scheitert die Geste, und die Leinwand scrollt oder zoomt.
/// Kommt der zweite Finger später, bricht die laufende Geste ab (`.cancelled`, nie `.failed` mitten in
/// der Geste, das kennt UIKit nicht). Ein kurzes Antippen, bevor die Geste begann, endet direkt mit `.ended`.
class SingleTouchGesture: UIGestureRecognizer {
    /// Die Geste kommt vom Pencil (dann wird das Scrollen gesperrt, Handballen)
    private(set) var isPencil = false
    private var tracked: UITouch?
    private var start = CGPoint.zero
    private var startWork: DispatchWorkItem?

    static let slop: CGFloat = 4
    static let delay: TimeInterval = 0.07

    // Für Unterklassen: Punkte des verfolgten Fingers bzw. Stifts
    func trackingBegan(_ touch: UITouch, _ event: UIEvent) {}
    func trackingMoved(_ touch: UITouch, _ event: UIEvent) {}
    func trackingEnded(_ touch: UITouch, _ event: UIEvent) {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracked != nil || touches.count > 1 {
            // Zweiter Finger: Scrollen und Zoomen haben Vorrang
            for t in touches where t !== tracked { ignore(t, for: event) }
            giveUp()
            return
        }
        guard state == .possible, let t = touches.first else { return }
        tracked = t
        isPencil = t.type == .pencil
        start = t.location(in: view)
        trackingBegan(t, event)
        if isPencil {
            state = .began
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .possible, self.tracked != nil else { return }
                self.state = .began
            }
            startWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        trackingMoved(t, event)
        switch state {
        case .possible:
            let p = t.location(in: view)
            if hypot(p.x - start.x, p.y - start.y) >= Self.slop {
                startWork?.cancel()
                state = .began
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        trackingEnded(t, event)
        startWork?.cancel()
        switch state {
        case .possible, .began, .changed:
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        giveUp()
    }

    private func giveUp() {
        startWork?.cancel()
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
    }

    override func reset() {
        super.reset()
        startWork?.cancel()
        startWork = nil
        tracked = nil
        isPencil = false
    }

    /// Scrollen und Zoomen der Leinwand nie verhindern: Kommt ein zweiter Finger, bricht diese Geste ab,
    /// und die Leinwand soll dann sofort mit zwei Fingern scrollen oder zoomen können
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventedGestureRecognizer is UIPanGestureRecognizer || preventedGestureRecognizer is UIPinchGestureRecognizer {
            return false
        }
        return super.canPrevent(preventedGestureRecognizer)
    }
}

/// Zeigestift: sammelt alle Punkte (auch die zwischen zwei Bildern, „coalesced“) in den Koordinaten von `space`
final class PointerGesture: SingleTouchGesture {
    weak var space: UIView?
    private var samples: [CGPoint] = []

    /// Neue Punkte seit dem letzten Abholen
    func takeSamples() -> [CGPoint] {
        defer { samples.removeAll() }
        return samples
    }

    override func trackingBegan(_ touch: UITouch, _ event: UIEvent) {
        samples.append(touch.location(in: space ?? view))
    }

    override func trackingMoved(_ touch: UITouch, _ event: UIEvent) {
        let space = self.space ?? view
        for t in event.coalescedTouches(for: touch) ?? [touch] {
            samples.append(t.location(in: space))
        }
    }

    override func trackingEnded(_ touch: UITouch, _ event: UIEvent) {
        samples.append(touch.location(in: space ?? view))
    }

    override func reset() {
        super.reset()
        samples.removeAll()
    }
}

/// Radierer: löscht jeden Strich, den der Kreis berührt
final class EraserGesture: SingleTouchGesture {}
