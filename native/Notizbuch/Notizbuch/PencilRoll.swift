import Foundation

/// Pencil Pro zweimal hin und her drehen (Wunsch 25.11.): schaltet zum Lasso. Gezählt wird im Schweben am Rollwinkel des
/// Pencils: vier Drehungen im Wechsel (hin, her, hin, her), jede mindestens `minSwing` weit (die erste nur halb so weit,
/// `firstSwing`), in den letzten `window` Sekunden, während die Spitze in `drift` Punkten um dieselbe Stelle blieb.
/// Schreiben zählt nicht: Aufsetzen beendet das Schweben, und mit ihm beginnt die Zählung neu (`reset`). Pencils ohne
/// Rollwinkel melden immer 0, dort passiert nie etwas. Nur Rechnen, ohne UIKit: test/rolle prüft es für sich
struct PencilRoll {
    /// Mindestweite einer Drehung von Umkehrpunkt zu Umkehrpunkt: 25 Grad (im Bogenmaß)
    static let minSwing = 25 * Double.pi / 180
    /// Die erste Drehung braucht nur die halbe Weite: Wer um die Ruhelage dreht (+20°, −20°, +20°, −20°), beginnt sie in
    /// der Mitte, die übrigen gehen von Rand zu Rand und sind doppelt so weit
    static let firstSwing = minSwing / 2
    /// Hin, her, hin, her
    static let swingsNeeded = 4
    /// In so vielen Sekunden (bis zum Moment, in dem die vierte Drehung weit genug ist)
    static let window = 2.0
    /// So weit darf die Spitze dabei wandern (Bildschirmpunkte)
    static let drift = 120.0

    private struct Sample {
        var angle: Double
        var time: Double
        var x: Double
        var y: Double
    }

    /// Die Werte der letzten `window` Sekunden, soweit die Spitze nicht weiter als `drift` vom neuesten weg war (im
    /// Schweben etwa 120 je Sekunde, also höchstens einige hundert)
    private var samples: [Sample] = []
    /// Letzter Rohwert: Der entfaltete Winkel läuft über ±180 Grad hinweg stetig weiter
    private var lastRaw: Double?
    private var angle = 0.0
    /// Nach einem Treffer die Richtung der Drehung, die ihn auslöste (1 oder −1): Sie läuft meist noch weiter, und ihr
    /// Rest soll nicht als erste Drehung der nächsten Geste zählen (sonst schalteten sieben weite Bewegungen zweimal).
    /// Erst ihre Umkehr zählt wieder. 0: Zählung wie sonst
    private var continuing = 0

    init() {}

    /// Schweben zu Ende (aufgesetzt, weggehoben): neu zählen
    mutating func reset() {
        samples = []
        lastRaw = nil
        angle = 0
        continuing = 0
    }

    /// Nächster Wert im Schweben: Rollwinkel im Bogenmaß, Zeit in Sekunden, Ort der Spitze in Bildschirmpunkten.
    /// true: Damit sind es vier Drehungen im Wechsel; die Zählung beginnt dann von vorn
    mutating func add(roll raw: Double, time: Double, x: Double, y: Double) -> Bool {
        guard raw.isFinite, time.isFinite, x.isFinite, y.isFinite else { return false }
        if let last = lastRaw {
            var step = raw - last
            if step > .pi { step -= 2 * .pi } else if step < -.pi { step += 2 * .pi }
            angle += step
        } else {
            angle = raw
        }
        lastRaw = raw
        // Rückwärts laufende Zeit kommt nicht vor; wenn doch, von hier aus neu
        if let last = samples.last, time < last.time {
            samples = []
            continuing = 0
        }
        samples.append(Sample(angle: angle, time: time, x: x, y: y))
        // Was zu alt ist oder zu weit von der Spitze jetzt, fällt vorne weg (der neueste Wert bleibt immer). Fällt der
        // Wert des letzten Treffers weg, zählt alles wieder wie sonst
        var drop = 0
        while drop < samples.count - 1,
              time - samples[drop].time > Self.window
                || hypot(x - samples[drop].x, y - samples[drop].y) > Self.drift {
            drop += 1
        }
        if drop > 0 {
            samples.removeFirst(drop)
            continuing = 0
        }
        let (count, direction) = Self.swings(in: samples, continuing: continuing)
        guard count >= Self.swingsNeeded else { return false }
        samples = [samples[samples.count - 1]]
        continuing = direction
        return true
    }

    /// Zahl der Drehungen im Wechsel und die Richtung der letzten (1 aufwärts, −1 abwärts, 0 noch keine). Die erste
    /// zählt ab `firstSwing` vom tiefsten oder höchsten Wert davor, jede weitere ab `minSwing` vom letzten Umkehrpunkt;
    /// die letzte zählt, sobald sie so weit ist, auch wenn sie noch weitergeht. Mit `continuing` läuft beim ersten Wert
    /// noch eine Drehung in diese Richtung: Erst ihre Umkehr zählt
    private static func swings(in samples: [Sample], continuing: Int) -> (count: Int, direction: Int) {
        guard let start = samples.first?.angle else { return (0, 0) }
        var low = start, high = start, extreme = start
        var direction = continuing, count = 0
        for sample in samples {
            let a = sample.angle
            switch direction {
            case 0:
                low = min(low, a)
                high = max(high, a)
                if a - low >= firstSwing {
                    direction = 1
                    extreme = a
                    count = 1
                } else if high - a >= firstSwing {
                    direction = -1
                    extreme = a
                    count = 1
                }
            case 1:
                if a > extreme {
                    extreme = a
                } else if extreme - a >= minSwing {
                    direction = -1
                    extreme = a
                    count += 1
                }
            default:
                if a < extreme {
                    extreme = a
                } else if a - extreme >= minSwing {
                    direction = 1
                    extreme = a
                    count += 1
                }
            }
        }
        return (count, direction)
    }
}
