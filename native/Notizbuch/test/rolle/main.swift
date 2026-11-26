import Foundation

// Prüft PencilRoll (Pencil Pro zweimal hin und her drehen → Lasso) mit erfundenen Schwebe-Werten, 120 je Sekunde.
// Im Ordner native/Notizbuch am Mac:
//   swiftc -O Notizbuch/PencilRoll.swift test/rolle/main.swift -o /tmp/rolle-test && /tmp/rolle-test
// Eine Zeile je Fall, am Ende „alle richtig“ oder die Zahl der Fehler (dann Exit 1)

struct Leg {
    var to: Double
    var seconds: Double
    var dx: Double = 0
    var dy: Double = 0
    /// Danach aufgesetzt oder weggehoben: Das Schweben endet
    var reset = false
}

struct HoverPoint {
    var angle: Double
    var time: Double
    var x: Double
    var y: Double
    var reset: Bool
}

/// Zufall für das Zittern, immer gleich (Park-Miller)
var seed: UInt64 = 12345
func nextNoise() -> Double {
    seed = seed * 16807 % 2147483647
    return Double(seed) / 2147483647
}

/// Weg des Rollwinkels in Grad, ab a0: je Abschnitt in `seconds` weich (wie eine Hand) zu `to`, die Spitze wandert
/// `dx` nach rechts und `dy` nach unten
func path(_ a0: Double, _ legs: [Leg], noise: Double = 0, rate: Double = 120) -> [HoverPoint] {
    let step = 1 / rate
    var out: [HoverPoint] = []
    var a = a0, x = 400.0, y = 500.0, t = 0.0
    for leg in legs {
        let n = max(1, Int((leg.seconds / step).rounded()))
        let from = a, x0 = x, y0 = y
        for i in 1...n {
            let u = Double(i) / Double(n)
            t += step
            a = from + (leg.to - from) * (1 - cos(Double.pi * u)) / 2
            x = x0 + leg.dx * u
            y = y0 + leg.dy * u
            let jitter = noise > 0 ? (nextNoise() * 2 - 1) * noise : 0
            out.append(HoverPoint(angle: a + jitter, time: t, x: x, y: y, reset: false))
        }
        if leg.reset { out.append(HoverPoint(angle: a, time: t, x: x, y: y, reset: true)) }
    }
    return out
}

/// n Drehungen zu je `amp` Grad im Wechsel (hin, her, …), jede `seconds` lang
func swings(_ n: Int, _ amp: Double, _ seconds: Double, base: Double = 0, dx: Double = 0, dy: Double = 0) -> [Leg] {
    (0..<n).map { i in
        Leg(to: base + (i % 2 == 0 ? amp : 0), seconds: seconds, dx: dx / Double(n), dy: dy / Double(n))
    }
}

/// Erst 0,3 s ruhig, dann n Drehungen um die Ruhelage: +amp, −amp, +amp, …
func around(_ n: Int, _ amp: Double, _ seconds: Double) -> [Leg] {
    [Leg(to: 0, seconds: 0.3)] + (0..<n).map { i in Leg(to: i % 2 == 0 ? amp : -amp, seconds: seconds) }
}

/// Zeitpunkte, an denen die Geste erkannt wird. wrap: Rohwerte wie vom Pencil zwischen −180 und 180 Grad
func run(_ points: [HoverPoint], wrap: Bool = false) -> [Double] {
    var roll = PencilRoll()
    var hits: [Double] = []
    for p in points {
        if p.reset {
            roll.reset()
            continue
        }
        var raw = p.angle * Double.pi / 180
        if wrap { raw = atan2(sin(raw), cos(raw)) }
        if roll.add(roll: raw, time: p.time, x: p.x, y: p.y) { hits.append(p.time) }
    }
    return hits
}

struct Case {
    var name: String
    var points: [HoverPoint]
    var want: Int
    var wrap = false
    /// Erste Erkennung in diesem Zeitraum (Sekunden)
    var first: ClosedRange<Double>? = nil
    /// Zweite Erkennung in diesem Zeitraum (Sekunden)
    var second: ClosedRange<Double>? = nil
}

let writing = (0..<30).map { i in Leg(to: i % 2 == 1 ? 0 : 30, seconds: 0.3, reset: true) }
let fidget = (0..<10).map { i in Leg(to: i % 2 == 0 ? 20 : 0, seconds: 0.3) }
/// Nach dem Treffer 1 s lang mit 2° je Sekunde weiter, in kleinen Schritten
let creep = (1...10).map { i in Leg(to: -Double(i) * 0.2, seconds: 0.1) }
var withNaN = path(0, swings(4, 40, 0.2))
withNaN[40].angle = .nan
let cases: [Case] = [
    Case(name: "4 × 40° je 200 ms", points: path(0, swings(4, 40, 0.2)), want: 1, first: 0.6...0.8),
    Case(name: "3 × 40°", points: path(0, swings(3, 40, 0.2)), want: 0),
    Case(name: "4 × 20°", points: path(0, swings(4, 20, 0.2)), want: 0),
    Case(name: "4 × 24°", points: path(0, swings(4, 24, 0.2)), want: 0),
    Case(name: "4 × 26°", points: path(0, swings(4, 26, 0.2)), want: 1),
    Case(name: "4 × 40° je 600 ms (die vierte ist nach 2 s weit genug)", points: path(0, swings(4, 40, 0.6)), want: 1),
    Case(name: "4 × 40° je 700 ms (zu langsam)", points: path(0, swings(4, 40, 0.7)), want: 0),
    Case(name: "4 × 40° je 550 ms", points: path(0, swings(4, 40, 0.55)), want: 1),
    Case(name: "5 × 40° (einmal)", points: path(0, swings(5, 40, 0.2)), want: 1),
    Case(name: "7 × 40° (einmal)", points: path(0, swings(7, 40, 0.2)), want: 1),
    Case(name: "8 × 40° (zweimal)", points: path(0, swings(8, 40, 0.2)), want: 2),
    Case(name: "4 × 40°, Spitze wandert 200 Punkte", points: path(0, swings(4, 40, 0.2, dx: 200)), want: 0),
    Case(name: "4 × 40°, Spitze wandert 60 Punkte", points: path(0, swings(4, 40, 0.2, dx: 60)), want: 1),
    Case(name: "4 × 40° um ±180° herum", points: path(165, swings(4, 40, 0.2, base: 165)), want: 1, wrap: true),
    Case(name: "Zittern ±3° 10 s", points: path(0, [Leg(to: 0, seconds: 10)], noise: 3), want: 0),
    Case(name: "4 × 40° mit Zittern ±4°", points: path(0, swings(4, 40, 0.2), noise: 4), want: 1),
    Case(name: "langsam 60° in 3 s, dann 4 × 40°", points: path(0, [Leg(to: 60, seconds: 3)] + swings(4, 40, 0.2, base: 60)),
         want: 1),
    Case(name: "2 langsame Drehungen (je 1,5 s), dann 4 schnelle",
         points: path(0, [Leg(to: 40, seconds: 1.5), Leg(to: 0, seconds: 1.5)] + swings(4, 40, 0.2)), want: 1,
         first: 3.45...3.6),
    Case(name: "zweimal hin und her, dazwischen aufgesetzt",
         points: path(0, [Leg(to: 40, seconds: 0.2), Leg(to: 0, seconds: 0.2, reset: true),
                          Leg(to: 40, seconds: 0.2), Leg(to: 0, seconds: 0.2)]), want: 0),
    Case(name: "erst −15°, dann 4 × 40°", points: path(0, [Leg(to: -15, seconds: 0.3)] + swings(4, 40, 0.2, base: -15)),
         want: 1),
    Case(name: "Gegenrichtung zuerst: 4 × −40°", points: path(0, swings(4, -40, 0.2)), want: 1),
    Case(name: "4 × 90° je 300 ms", points: path(0, swings(4, 90, 0.3)), want: 1),
    Case(name: "Schreiben: 30 kurze Schwebephasen mit 30° Drehung", points: path(0, writing), want: 0),
    Case(name: "Spielen mit dem Pencil: 10 × 20°", points: path(0, fidget), want: 0),
    Case(name: "Rollwinkel immer 0 (Pencil ohne Rollen)", points: path(0, [Leg(to: 0, seconds: 5)]), want: 0),
    Case(name: "quer übers Blatt (300 Punkte) mit 4 × 40°", points: path(0, swings(4, 40, 0.4, dx: 300)), want: 0),
    Case(name: "4 × 40° mit 240 Werten je Sekunde", points: path(0, swings(4, 40, 0.2), rate: 240), want: 1,
         first: 0.6...0.8),
    // Seit 149: um die Ruhelage, Rest der auslösenden Drehung, Spitze nach unten, ungültige Werte, Grenzen
    Case(name: "um die Ruhelage ±20° (+20, −20, +20, −20)", points: path(0, around(4, 20, 0.2)), want: 1,
         first: 0.95...1.15),
    Case(name: "um die Ruhelage ±15°", points: path(0, around(4, 15, 0.2)), want: 1),
    Case(name: "um die Ruhelage ±10° (zu wenig)", points: path(0, around(4, 10, 0.2)), want: 0),
    Case(name: "um die Ruhelage 7 × ±30° (einmal)", points: path(0, around(7, 30, 0.25)), want: 1),
    Case(name: "7 × 90° je 250 ms (einmal)", points: path(0, swings(7, 90, 0.25)), want: 1),
    Case(name: "8 × 90° je 250 ms (zweimal)", points: path(0, swings(8, 90, 0.25)), want: 2),
    Case(name: "4 × 40°, Spitze wandert 200 Punkte nach unten", points: path(0, swings(4, 40, 0.2, dy: 200)), want: 0),
    Case(name: "4 × 40° mit einem ungültigen Wert (NaN)", points: withNaN, want: 1, first: 0.6...0.8),
    Case(name: "Zeit springt zwischen hin-her und hin-her zurück",
         points: path(0, swings(2, 40, 0.2)) + path(0, swings(2, 40, 0.2)), want: 0),
    Case(name: "Zittern ±3° um 180° herum, 10 s", points: path(180, [Leg(to: 180, seconds: 10)], noise: 3), want: 0,
         wrap: true),
    Case(name: "4 × 40° je 650 ms", points: path(0, swings(4, 40, 0.65)), want: 1),
    Case(name: "4 × 40°, Spitze wandert 150 Punkte", points: path(0, swings(4, 40, 0.2, dx: 150)), want: 1),
    Case(name: "4 × 40°, Spitze wandert 170 Punkte", points: path(0, swings(4, 40, 0.2, dx: 170)), want: 0),
    Case(name: "erst kurz zurück (−6°), dann +10, −16, +10, −16",
         points: path(0, [Leg(to: 0, seconds: 0.3), Leg(to: -6, seconds: 0.15), Leg(to: 10, seconds: 0.2),
                          Leg(to: -16, seconds: 0.2), Leg(to: 10, seconds: 0.2), Leg(to: -16, seconds: 0.2)]), want: 1),
    Case(name: "erste Drehung nur 10°: +10, −16, +10, −16",
         points: path(0, [Leg(to: 0, seconds: 0.3), Leg(to: 10, seconds: 0.2), Leg(to: -16, seconds: 0.2),
                          Leg(to: 10, seconds: 0.2), Leg(to: -16, seconds: 0.2)]), want: 0),
    Case(name: "Treffer, 2,5 s ruhig, dann ±15° um die Ruhelage (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 2.5)] + around(4, 15, 0.2)), want: 2),
    // Seit 150: Nach dem Treffer weiter schweben; der Rest der auslösenden Drehung zählt auch später nicht
    Case(name: "7 × 90° je 250 ms, dann 2,5 s schwebend (einmal)",
         points: path(0, swings(7, 90, 0.25) + [Leg(to: 90, seconds: 2.5)]), want: 1),
    Case(name: "um die Ruhelage 7 × ±30°, dann 2,5 s schwebend (einmal)",
         points: path(0, around(7, 30, 0.25) + [Leg(to: 30, seconds: 2.5)]), want: 1),
    Case(name: "7 × 45° je 200 ms, dann 2,5 s schwebend (einmal)",
         points: path(0, swings(7, 45, 0.2) + [Leg(to: 45, seconds: 2.5)]), want: 1),
    Case(name: "7 × 40° je 300 ms, dann 2,5 s schwebend (einmal)",
         points: path(0, swings(7, 40, 0.3) + [Leg(to: 40, seconds: 2.5)]), want: 1),
    Case(name: "7 × 90° mit Zittern ±2°, dann 2,5 s schwebend (einmal)",
         points: path(0, swings(7, 90, 0.25) + [Leg(to: 90, seconds: 2.5)], noise: 2), want: 1),
    Case(name: "Treffer, gleich ±20° um die Ruhelage zurück (zweimal, rechtzeitig)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.3)] + around(4, 20, 0.2)
                      + [Leg(to: -20, seconds: 0.3, reset: true)]), want: 2, first: 0.6...0.8, second: 1.9...2.3),
    Case(name: "Treffer, 0,4 s still, dann weiter −20, +20, −20, +20 (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.4), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2)]), want: 2),
    Case(name: "Treffer, aufgesetzt, dann ±15° um die Ruhelage (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.01, reset: true)] + around(4, 15, 0.2)), want: 2),
    Case(name: "erst kurz zurück (+6°), dann −10, +16, −10, +16",
         points: path(0, [Leg(to: 0, seconds: 0.3), Leg(to: 6, seconds: 0.15), Leg(to: -10, seconds: 0.2),
                          Leg(to: 16, seconds: 0.2), Leg(to: -10, seconds: 0.2), Leg(to: 16, seconds: 0.2)]), want: 1),
    Case(name: "Sägezahn abwärts −30, −10, −40, −20, −50 (keine Umkehr weit genug)",
         points: path(0, [Leg(to: -30, seconds: 0.2), Leg(to: -10, seconds: 0.2), Leg(to: -40, seconds: 0.2),
                          Leg(to: -20, seconds: 0.2), Leg(to: -50, seconds: 0.2)]), want: 0),
    Case(name: "Sägezahn aufwärts 30, 10, 40, 20, 50 (keine Umkehr weit genug)",
         points: path(0, [Leg(to: 30, seconds: 0.2), Leg(to: 10, seconds: 0.2), Leg(to: 40, seconds: 0.2),
                          Leg(to: 20, seconds: 0.2), Leg(to: 50, seconds: 0.2)]), want: 0),
    Case(name: "Treffer, aufgesetzt, gleich weiter −20, +20, −20, +20 (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.01, reset: true), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2)]), want: 2),
    Case(name: "Zeit springt nach dem Treffer zurück, dann −20, +20, −20, +20 (zweimal)",
         points: path(0, swings(4, 40, 0.2)) + path(0, [Leg(to: 0, seconds: 0.01), Leg(to: -20, seconds: 0.2),
                                                        Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                        Leg(to: 20, seconds: 0.2)]), want: 2),
    Case(name: "über-gedreht, die vierte langsam (1 s) mit Zittern ±2° (einmal)",
         points: path(0, [Leg(to: 40, seconds: 0.2), Leg(to: 0, seconds: 0.2), Leg(to: 40, seconds: 0.2),
                          Leg(to: -50, seconds: 1.0), Leg(to: 40, seconds: 0.2), Leg(to: -50, seconds: 0.2),
                          Leg(to: 40, seconds: 0.2), Leg(to: 40, seconds: 2.5)], noise: 2), want: 1),
    Case(name: "Treffer, Spitze springt 130 Punkte, dann −20, +20, −20, +20 (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.1, dx: 130), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2)]), want: 2),
    Case(name: "8 × 26° (zweimal)", points: path(0, swings(8, 26, 0.2)), want: 2),
    Case(name: "Treffer, gleich ±13° je 150 ms zurück (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 13, seconds: 0.15), Leg(to: -13, seconds: 0.15),
                                                Leg(to: 13, seconds: 0.15), Leg(to: -13, seconds: 0.15)]), want: 2),
    // Seit 151: echte Werte zittern und kriechen; die auslösende Drehung gilt nur als weiterlaufend, solange sie um
    // mindestens 1° je 0,25 s weiterkommt und die Spitze nahe der Stelle des Treffers bleibt
    Case(name: "Treffer, 0,4 s still, dann weiter −20, +20, −20, +20, alles mit Zittern ±0,3° (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.4), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2)], noise: 0.3), want: 2),
    Case(name: "Treffer, Spitze springt 130 Punkte, dann −20, +20, −20, +20, alles mit Zittern ±0,3° (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: 0, seconds: 0.1, dx: 130), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2)], noise: 0.3), want: 2),
    Case(name: "Treffer, 3 s langsam weiter (−3°), dann −20, +20, −20, +20 (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: -3, seconds: 3), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2), Leg(to: -20, seconds: 0.2),
                                                Leg(to: 20, seconds: 0.2)]), want: 2),
    Case(name: "Treffer, weiter bis −60° und dabei 200 Punkte gewandert, dann +40, −40, +40 (zweimal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: -60, seconds: 0.8, dx: 200), Leg(to: 40, seconds: 0.2),
                                                Leg(to: -40, seconds: 0.2), Leg(to: 40, seconds: 0.2)]), want: 2),
    Case(name: "Treffer, 1 s mit 2° je Sekunde weiter (−2°), dann −20, +20, −20, +20 (zweimal)",
         points: path(0, swings(4, 40, 0.2) + creep + [Leg(to: -20, seconds: 0.2), Leg(to: 20, seconds: 0.2),
                                                        Leg(to: -20, seconds: 0.2), Leg(to: 20, seconds: 0.2)]),
         want: 2),
    Case(name: "Treffer, weiter bis −60°, die Spitze wandert dabei gleich 80 Punkte, dann +40, −40, +40 (einmal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: -20, seconds: 0.2, dx: 80), Leg(to: -60, seconds: 0.4),
                                                Leg(to: 40, seconds: 0.2), Leg(to: -40, seconds: 0.2),
                                                Leg(to: 40, seconds: 0.2)]), want: 1),
    Case(name: "Treffer, langsam weiter (30° in 1,3 s), dann +40, −40, +40 (einmal)",
         points: path(0, swings(4, 40, 0.2) + [Leg(to: -30, seconds: 1.3), Leg(to: 40, seconds: 0.2),
                                                Leg(to: -40, seconds: 0.2), Leg(to: 40, seconds: 0.2)]), want: 1),
    Case(name: "Treffer, 0,15 s Stocken in der vierten Drehung, dann weiter bis 7 Bewegungen (einmal)",
         points: path(0, [Leg(to: 40, seconds: 0.2), Leg(to: 0, seconds: 0.2), Leg(to: 40, seconds: 0.2),
                          Leg(to: 10, seconds: 0.15), Leg(to: 10, seconds: 0.15), Leg(to: -30, seconds: 0.15),
                          Leg(to: 40, seconds: 0.2), Leg(to: -30, seconds: 0.2), Leg(to: 40, seconds: 0.2)]), want: 1),
    Case(name: "7 × 40°, dann zurück in die Ruhelage (8 Bewegungen: zweimal)",
         points: path(0, swings(7, 40, 0.2) + [Leg(to: 0, seconds: 0.4)]), want: 2),
]

var failures = 0
for c in cases {
    let hits = run(c.points, wrap: c.wrap)
    var ok = hits.count == c.want
    if let range = c.first, let t = hits.first, !range.contains(t) { ok = false }
    if let range = c.second, hits.count > 1, !range.contains(hits[1]) { ok = false }
    if !ok { failures += 1 }
    let at = hits.isEmpty ? "" : " bei " + hits.map { String(format: "%.3f s", $0) }.joined(separator: ", ")
    print("\(ok ? "ok  " : "FEHL") \(c.name): \(hits.count) (erwartet \(c.want))\(at)")
}

// Aufwand: eine Minute Schweben mit 240 Werten je Sekunde (das Fenster hält dann 480 Werte)
let long = path(0, [Leg(to: 0, seconds: 60)], noise: 3, rate: 240)
var roll = PencilRoll()
let started = Date()
for p in long { _ = roll.add(roll: p.angle * Double.pi / 180, time: p.time, x: p.x, y: p.y) }
let micros = Date().timeIntervalSince(started) / Double(long.count) * 1_000_000
let fast = micros < 50
if !fast { failures += 1 }
print("\(fast ? "ok  " : "FEHL") Aufwand: \(String(format: "%.1f", micros)) µs je Wert (höchstens 50)")

print(failures == 0 ? "alle richtig" : "\(failures) Fehler")
exit(failures == 0 ? 0 : 1)
