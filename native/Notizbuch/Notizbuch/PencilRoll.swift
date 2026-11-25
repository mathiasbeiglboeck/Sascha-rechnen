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
    /// Nach einem Treffer endet die auslösende Drehung, sobald sie 5 Grad zurückgeht (kleineres Zittern zählt nicht), …
    static let blockEnd = 5 * Double.pi / 180
    /// … oder so lange keinen neuen äußersten Wert erreicht (Sekunden) …
    static let blockPause = 0.25
    /// … wobei ein neuer äußerster Wert mindestens 1 Grad weiter sein muss: Zittern und langsames Kriechen (unter etwa
    /// 4 Grad je Sekunde) halten sie so nicht am Leben, echtes Weiterdrehen schon. Und sie endet, sobald die Spitze
    /// weiter als `drift` von der Stelle des Treffers ist
    static let blockStep = 1 * Double.pi / 180

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
    /// Nach einem Treffer die Drehung, die ihn auslöste (1 aufwärts, −1 abwärts): Sie läuft meist noch weiter, und ihr
    /// Rest soll nie für die nächste Geste zählen, auch nicht Sekunden später (sonst schalteten sieben weite Bewegungen
    /// zweimal, die zweite erst, wenn der Pencil schon ruht). Solange sie weiterläuft, bleibt nur ihr äußerster Wert (auf
    /// 1 Grad genau) im Fenster; erst ihre Umkehr zählt als erste Drehung der nächsten Geste. 0: Zählung wie sonst
    private var block = 0
    private var blockExtreme = 0.0
    private var blockTime = 0.0
    /// Ort der Spitze beim Treffer
    private var blockX = 0.0
    private var blockY = 0.0

    init() {}

    /// Schweben zu Ende (aufgesetzt, weggehoben): neu zählen
    mutating func reset() {
        samples = []
        lastRaw = nil
        angle = 0
        block = 0
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
            block = 0
        }
        // Die auslösende Drehung läuft weiter: Alles davor fällt weg, gezählt wird erst ab ihrem äußersten Wert. Ist die
        // Spitze von der Stelle des Treffers weit weg, zählt alles wieder wie sonst
        if block != 0 {
            if hypot(x - blockX, y - blockY) > Self.drift {
                block = 0
            } else if Double(block) * (angle - blockExtreme) >= Self.blockStep {
                blockExtreme = angle
                blockTime = time
                samples = []
            } else if time - blockTime > Self.blockPause || Double(block) * (blockExtreme - angle) >= Self.blockEnd {
                block = 0
            }
        }
        samples.append(Sample(angle: angle, time: time, x: x, y: y))
        // Was zu alt ist oder zu weit von der Spitze jetzt, fällt vorne weg (der neueste Wert bleibt immer); dann endet
        // auch eine noch laufende auslösende Drehung
        var drop = 0
        while drop < samples.count - 1,
              time - samples[drop].time > Self.window
                || hypot(x - samples[drop].x, y - samples[drop].y) > Self.drift {
            drop += 1
        }
        if drop > 0 {
            samples.removeFirst(drop)
            block = 0
        }
        let (count, direction) = Self.swings(in: samples)
        guard count >= Self.swingsNeeded else { return false }
        samples = [samples[samples.count - 1]]
        block = direction
        blockExtreme = angle
        blockTime = time
        blockX = x
        blockY = y
        return true
    }

    /// Zahl der Drehungen im Wechsel und die Richtung der letzten (1 aufwärts, −1 abwärts, 0 noch keine). Die erste
    /// zählt ab `firstSwing` vom tiefsten oder höchsten Wert davor, jede weitere ab `minSwing` vom letzten Umkehrpunkt;
    /// die letzte zählt, sobald sie so weit ist, auch wenn sie noch weitergeht
    private static func swings(in samples: [Sample]) -> (count: Int, direction: Int) {
        guard let start = samples.first?.angle else { return (0, 0) }
        var low = start, high = start, extreme = start
        var direction = 0, count = 0
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
