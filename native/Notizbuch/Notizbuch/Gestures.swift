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
final class EraserGesture: SingleTouchGesture {
    /// Sobald der Pencil oder ein Finger aufsetzt, noch bevor die Geste beginnt (ein kurzes Antippen mit dem Finger
    /// beginnt nie, es endet gleich)
    var onTouchDown: (() -> Void)?

    override func trackingBegan(_ touch: UITouch, _ event: UIEvent) {
        onTouchDown?()
    }
}

/// Beobachtet das Lasso, ohne je selbst zu erkennen. PencilKit verrät nicht, was es ausgewählt hat; für „Claude
/// fragen“ merkt sich die App deshalb den Weg des Lassos, in den Koordinaten von `space` (die Seiten: Seitenpunkte,
/// unabhängig von Zoom und Gerät). PencilKits Lasso bekommt davon nichts mit: Diese Geste hält nichts auf, verhindert
/// nichts und lässt sich nicht verhindern. Die Leinwand stellt sie so ein, dass sie keine Berührung verzögert
final class LassoTracker: UIGestureRecognizer {
    weak var space: UIView?
    /// Ein Weg beginnt (Finger oder Pencil setzt auf, auch zum Antippen)
    var onBegan: (() -> Void)?
    /// Der ganze Weg, sobald der Finger oder Pencil abhebt
    var onEnded: (([CGPoint]) -> Void)?
    private var tracked: UITouch?
    private var points: [CGPoint] = []

    /// Wird gerade ein Weg gezogen?
    var isTracking: Bool { tracked != nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Ein zweiter Finger (am iPhone: scrollen): Dieser Weg zählt nicht
        guard tracked == nil, touches.count == 1, let t = touches.first else {
            tracked = nil
            points = []
            if state == .possible { state = .failed }
            return
        }
        tracked = t
        points = [t.location(in: space ?? view)]
        onBegan?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        let space = self.space ?? view
        for c in event.coalescedTouches(for: t) ?? [t] { points.append(c.location(in: space)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        points.append(t.location(in: space ?? view))
        let path = points
        tracked = nil
        points = []
        // Erkennt nie: PencilKits Lasso bleibt unberührt
        if state == .possible { state = .failed }
        onEnded?(path)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked = nil
        points = []
        if state == .possible { state = .failed }
    }

    override func reset() {
        super.reset()
        tracked = nil
        points = []
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// Antippen einer Markierung von „Claude fragen“. Die Leinwand gibt ihr nur Berührungen, die auf einer Markierung
/// beginnen (siehe CanvasController), und nur auf die wartet PencilKit: Bewegt sich der Pencil oder Finger mehr als
/// 8 Punkte oder bleibt er länger als 0,6 s liegen, scheitert die Geste, und PencilKit schreibt oder wählt aus wie
/// sonst. Scrollen und Zoomen warten nie
final class MarkTapGesture: UIGestureRecognizer {
    /// PencilKits Zeichnen (auch das Lasso): wartet auf diese Geste
    weak var drawing: UIGestureRecognizer?
    /// Kann die Berührung auf der Markierung selbst zeichnen (Pencil; am iPhone beim Schreiben auch der Finger)? Nur
    /// dann wartet PencilKit: Ein Finger oder Handballen am iPad hielte sonst jeden Strich des Pencils auf. Setzt der
    /// Delegate, bevor UIKit nach dem Warten fragt
    var touchCanDraw = true
    private var tracked: UITouch?
    private var start = CGPoint.zero
    private var timeout: DispatchWorkItem?

    static let slop: CGFloat = 8
    static let maxDuration: TimeInterval = 0.6

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, touches.count == 1, let t = touches.first else {
            if state == .possible { state = .failed }
            return
        }
        tracked = t
        start = t.location(in: view)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible else { return }
            self.state = .failed
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t), state == .possible else { return }
        let p = t.location(in: view)
        if hypot(p.x - start.x, p.y - start.y) > Self.slop { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t), state == .possible else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    override func reset() {
        super.reset()
        tracked = nil
        timeout?.cancel()
        timeout = nil
        touchCanDraw = true
    }

    /// PencilKit (Stift und Lasso) wartet, ob es ein Antippen wird; Scrollen, Zoomen, Schweben und die eigenen
    /// Gesten der App nicht
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard touchCanDraw else { return false }
        if otherGestureRecognizer === drawing { return true }
        if otherGestureRecognizer is UIPanGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
            || otherGestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is SingleTouchGesture
            || otherGestureRecognizer is LassoTracker {
            return false
        }
        let name = NSStringFromClass(type(of: otherGestureRecognizer))
        return (name.hasPrefix("PK") || name.hasPrefix("_PK")) && !name.contains("PencilObserver")
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventedGestureRecognizer is UIPanGestureRecognizer || preventedGestureRecognizer is UIPinchGestureRecognizer {
            return false
        }
        return super.canPrevent(preventedGestureRecognizer)
    }
}
