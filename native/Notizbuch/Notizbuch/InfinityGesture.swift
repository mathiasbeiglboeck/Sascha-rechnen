import CoreGraphics
import Foundation

/// Ein mit dem Lasso gezeichnetes ∞ (liegende Acht)
struct InfinityMatch {
    /// Umriss des ∞ in Seitenpunkten (alle Seiten untereinander, wie LassoPath)
    let bounds: CGRect
    /// Messwerte fürs Protokoll (Log.ink)
    let summary: String
}

/// Erkennt ein ∞ auf dem Weg des Lassos: „Was bedeutet das hier?“ ohne Menü.
///
/// Ein ∞ ist ein geschlossener Weg, der sich einmal selbst schneidet; seine beiden Schleifen laufen gegensinnig, die
/// Richtung des Stifts dreht sich insgesamt also nicht (Umlaufzahl 0; ein Lasso: ±1, doppelt umrundet ±2). Der Weg
/// wird zuerst geglättet (Zittern von Finger und Pencil), das Ende geschlossen (Überhang abgeschnitten), dann geprüft:
/// - Umlaufzahl 0; der gezeichnete Weg dreht sich höchstens 0,4 Umdrehungen (α-Lasso ≥ 0,53); keine Kehrtwende
/// - Anfang und Ende höchstens 40 % des Durchmessers auseinander (offene Zickzacks)
/// - am Schnitt zwei Schleifen: gegensinnig; die kleinere ≥ 20 % der größeren (Kringel am Ende eines Lassos); beide
///   rund genug (Sicheln, Gekritzel); nebeneinander statt ineinander; Achse höchstens 50° gegen die Waagrechte
///   (Achten über zwei Zeilen)
/// - Durchmesser 24 bis 640 Bildschirmpunkte und höchstens 260 Seitenpunkte (ein Wort oder Symbol, keine Acht über
///   die halbe Seite)
/// Schwellen in Bildschirmpunkten, also gleich in jeder Zoomstufe (außer `maxPage`). Dieselbe Logik steht Schritt für
/// Schritt in test/unendlich/detector.js und ist dort an synthetischen Wegen geprüft (run.js, rand.js; schwellen.js
/// vergleicht die Schwellen): Jede Schwelle in beiden Dateien gleich ändern.
enum InfinityGesture {
    /// Die feste Frage: steht gedruckt oben im Bild der Stelle (Server und Helfer reichen nur Bilder weiter)
    static let question = "Was bedeutet das Wort oder Symbol im pinken Rahmen an dieser Stelle? "
        + "Erkläre es im Zusammenhang der Seite."

    private static let minPoints = 24
    private static let minSide: CGFloat = 24
    private static let maxSide: CGFloat = 640
    private static let maxPage: CGFloat = 260
    private static let minLength: CGFloat = 2
    private static let maxLength: CGFloat = 12
    private static let closeWindow: CGFloat = 0.12
    private static let maxGap: CGFloat = 0.4
    private static let maxOpenTurn: CGFloat = 0.4
    private static let maxStepTurn: CGFloat = 0.9
    private static let minRatio: CGFloat = 0.2
    private static let minRound: CGFloat = 0.35
    private static let minLoopArea: CGFloat = 40
    private static let minLoopShare: CGFloat = 0.02
    private static let minSeparation: CGFloat = 0.6
    private static let maxAxis: CGFloat = 50

    /// ∞ oder nil. `page`: der rohe Weg in Seitenpunkten (LassoTracker), `s`: Bildschirmpunkte je Seitenpunkt
    /// (k · Zoom)
    static func detect(_ page: [CGPoint], scale s: CGFloat) -> InfinityMatch? {
        guard page.count >= 3, s > 0 else { return nil }
        // In Bildschirmpunkten rechnen; über je 5 Abtastpunkte mitteln (Rauschen von Punkt zu Punkt)
        let raw = binomial5(page.map { CGPoint(x: $0.x * s, y: $0.y * s) })
        let rb = LassoGeometry.bounds(raw)
        let rawSide = max(rb.width, rb.height)
        let length = pathLength(raw)
        // Billige Ausschlüsse zuerst: Antippen, Striche, Verschieben, große Achten, Gekritzel
        guard rawSide >= minSide, rawSide / s <= maxPage * 1.1, rawSide <= maxSide * 1.1,
              length >= minLength * rawSide, length <= maxLength * rawSide else { return nil }
        // Fein abtasten, glätten (σ wächst mit der Größe), grob abtasten (etwa 40 Punkte je lange Seite)
        let step = max(2.5, rawSide / 40)
        let pts = resample(smooth(resample(raw, step: 1), sigma: max(1.5, rawSide / 60)), step: step)
        guard pts.count >= minPoints else { return nil }

        // Ende schließen: nächstes Paar aus den ersten und letzten 12 % der Weglänge, der Überhang fällt weg
        var arc: [CGFloat] = [0]
        arc.reserveCapacity(pts.count)
        for i in 1..<pts.count { arc.append(arc[i - 1] + dist(pts[i - 1], pts[i])) }
        let total = arc[arc.count - 1]
        var bi = 0, bj = pts.count - 1
        var best = dist(pts[0], pts[pts.count - 1])
        var i = 0
        while i < pts.count, arc[i] <= closeWindow * total {
            var j = pts.count - 1
            while j > i + 2, arc[j] >= (1 - closeWindow) * total {
                let d = dist(pts[i], pts[j])
                if d < best { best = d; bi = i; bj = j }
                j -= 1
            }
            i += 1
        }
        var poly = Array(pts[bi...bj])
        if poly.count > 3, dist(poly[0], poly[poly.count - 1]) < step * 0.5 { poly.removeLast() }
        let n = poly.count
        guard n >= minPoints else { return nil }

        // Drehung zuerst (billig, schließt fast jedes Lasso aus): Umlaufzahl des geschlossenen Vielecks, Drehung des
        // gezeichneten Wegs (ohne die beiden Knicke an der Schließkante), größter Knick
        var dirs: [CGFloat] = []
        dirs.reserveCapacity(n)
        for k in 0..<n {
            let a = poly[k], b = poly[(k + 1) % n]
            dirs.append(atan2(b.y - a.y, b.x - a.x))
        }
        var turnClosed: CGFloat = 0, turnDrawn: CGFloat = 0, maxStep: CGFloat = 0
        for k in 0..<n {
            let d = wrap(dirs[(k + 1) % n] - dirs[k])
            turnClosed += d
            maxStep = max(maxStep, abs(d))
            if k < n - 2 { turnDrawn += d }
        }
        let winding = Int((turnClosed / (2 * CGFloat.pi)).rounded())
        guard winding == 0, abs(turnDrawn) / (2 * CGFloat.pi) <= maxOpenTurn,
              maxStep / CGFloat.pi <= maxStepTurn else { return nil }

        // Größe: Durchmesser (größter Abstand zweier Punkte), gleich in jeder Neigung
        var side2: CGFloat = 0
        for a in 0..<n {
            for b in (a + 1)..<n {
                let dx = poly[a].x - poly[b].x, dy = poly[a].y - poly[b].y
                side2 = max(side2, dx * dx + dy * dy)
            }
        }
        let side = side2.squareRoot()
        guard side >= minSide, best / side <= maxGap else { return nil }

        // Selbstschnitte; zwei Schleifen an dem Schnitt, der die kleinere am größten macht
        var crossings = 0
        var bestSplit: (first: [CGPoint], second: [CGPoint], area1: CGFloat, area2: CGFloat, small: CGFloat)?
        for a in 0..<n {
            for b in stride(from: a + 2, to: n, by: 1) where !(a == 0 && b == n - 1) {
                guard let x = intersect(poly[a], poly[(a + 1) % n], poly[b], poly[(b + 1) % n]) else { continue }
                crossings += 1
                var first: [CGPoint] = [x]
                first.append(contentsOf: poly[(a + 1)...b])
                var second: [CGPoint] = [x]
                if b + 1 < n { second.append(contentsOf: poly[(b + 1)..<n]) }
                second.append(contentsOf: poly[0...a])
                let area1 = signedArea(first), area2 = signedArea(second)
                let small = min(abs(area1), abs(area2))
                if small > (bestSplit?.small ?? -1) {
                    bestSplit = (first: first, second: second, area1: area1, area2: area2, small: small)
                }
            }
        }
        guard let loops = bestSplit else { return nil }
        let area1 = loops.area1, area2 = loops.area2
        let ratio = loops.small / max(abs(area1), abs(area2))
        let p1 = perimeter(loops.first), p2 = perimeter(loops.second)
        let roundness = min(4 * CGFloat.pi * abs(area1) / (p1 * p1), 4 * CGFloat.pi * abs(area2) / (p2 * p2))
        let c1 = centroid(loops.first, area: area1), c2 = centroid(loops.second, area: area2)
        let r1 = (abs(area1) / CGFloat.pi).squareRoot(), r2 = (abs(area2) / CGFloat.pi).squareRoot()
        let separation = dist(c1, c2) / (r1 + r2)
        let angle = abs(atan2(c2.y - c1.y, c2.x - c1.x)) * 180 / CGFloat.pi
        let axis = min(angle, 180 - angle)
        guard area1 * area2 < 0,                                           // gegensinnig
              ratio >= minRatio,                                           // kein Kringel am Ende eines Lassos
              roundness >= minRound,                                       // keine Sichel, kein Gekritzel
              loops.small >= max(minLoopArea, minLoopShare * side * side), // keine winzige Schleife
              separation >= minSeparation,                                 // nebeneinander, nicht ineinander
              axis <= maxAxis,                                             // liegend, nicht stehend
              side / s <= maxPage, side <= maxSide                         // ein Wort, keine Acht über die halbe Seite
        else { return nil }

        let box = LassoGeometry.bounds(poly)
        let pageBox = CGRect(x: box.minX / s, y: box.minY / s, width: box.width / s, height: box.height / s)
        let summary = "∞ \(Int(pageBox.width))×\(Int(pageBox.height)) Seitenpunkte, Lücke \(f2(best / side)), "
            + "Schleifen \(f2(ratio)), rund \(f2(roundness)), Abstand \(f2(separation)), Achse \(Int(axis))°, "
            + "Schnitte \(crossings)"
        return InfinityMatch(bounds: pageBox, summary: summary)
    }

    /// Die Stelle auf ihrer Seite (relativ zur Seite): Umriss des ∞ mit 4 Punkten Rand, auf die Seite beschnitten
    static func spot(_ bounds: CGRect, frame: CGRect) -> CGRect? {
        let r = bounds.offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -4, dy: -4)
            .intersection(CGRect(origin: .zero, size: frame.size))
        return r.isNull || r.isEmpty ? nil : r
    }

    /// Ausschnitt für das Bild der Stelle: links und rechts ihre Breite (mindestens 100 Seitenpunkte), darüber und
    /// darunter ihre Höhe (mindestens 40, gut eine Zeile), auf der Seite
    static func context(around spot: CGRect, pageSize: CGSize) -> CGRect {
        spot.insetBy(dx: -max(spot.width, 100), dy: -max(spot.height, 40))
            .intersection(CGRect(origin: .zero, size: pageSize))
    }

    // MARK: Geometrie (wie detector.js)

    private static func f2(_ x: CGFloat) -> String { String(format: "%.2f", Double(x)) }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Winkel nach (−π, π]
    private static func wrap(_ angle: CGFloat) -> CGFloat {
        var a = angle
        while a > CGFloat.pi { a -= 2 * CGFloat.pi }
        while a <= -CGFloat.pi { a += 2 * CGFloat.pi }
        return a
    }

    private static func pathLength(_ p: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in p.indices.dropFirst() { sum += dist(p[i - 1], p[i]) }
        return sum
    }

    /// Über je 5 Abtastpunkte mitteln (1-4-6-4-1)
    private static func binomial5(_ p: [CGPoint]) -> [CGPoint] {
        let g: [CGFloat] = [1, 4, 6, 4, 1]
        return p.indices.map { i -> CGPoint in
            var sx: CGFloat = 0, sy: CGFloat = 0, sw: CGFloat = 0
            for k in -2...2 where p.indices.contains(i + k) {
                sx += g[k + 2] * p[i + k].x
                sy += g[k + 2] * p[i + k].y
                sw += g[k + 2]
            }
            return CGPoint(x: sx / sw, y: sy / sw)
        }
    }

    /// Gleichmäßig neu abtasten, Abstand `step` entlang des Wegs
    private static func resample(_ p: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard let first = p.first, let last = p.last else { return [] }
        var out = [first]
        var carry: CGFloat = 0
        for i in p.indices.dropFirst() {
            let a = p[i - 1], b = p[i], seg = dist(a, b)
            if seg == 0 { continue }
            var t = step - carry
            while t <= seg {
                out.append(CGPoint(x: a.x + (b.x - a.x) * t / seg, y: a.y + (b.y - a.y) * t / seg))
                t += step
            }
            carry = seg - (t - step)
        }
        if let end = out.last, dist(end, last) > step * 0.3 { out.append(last) }
        return out
    }

    /// Gauß-Glättung entlang des Wegs (Punkte im Abstand 1, `sigma` in Punkten); an den Enden kürzeres Fenster
    private static func smooth(_ p: [CGPoint], sigma: CGFloat) -> [CGPoint] {
        let rad = Int((2.5 * sigma).rounded(.up))
        let w: [CGFloat] = (-rad...rad).map { k in exp(-CGFloat(k * k) / (2 * sigma * sigma)) }
        return p.indices.map { i -> CGPoint in
            var sx: CGFloat = 0, sy: CGFloat = 0, sw: CGFloat = 0
            for k in max(-rad, -i)...min(rad, p.count - 1 - i) {
                let g = w[k + rad]
                sx += g * p[i + k].x
                sy += g * p[i + k].y
                sw += g
            }
            return CGPoint(x: sx / sw, y: sy / sw)
        }
    }

    private static func signedArea(_ p: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    private static func perimeter(_ p: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in p.indices { sum += dist(p[i], p[(i + 1) % p.count]) }
        return sum
    }

    /// Schwerpunkt einer Schleife (`area`: ihre Fläche mit Vorzeichen); ohne Fläche die Mitte ihres Umrisses
    private static func centroid(_ p: [CGPoint], area: CGFloat) -> CGPoint {
        guard abs(area) >= 1e-9 else {
            let b = LassoGeometry.bounds(p)
            return CGPoint(x: b.midX, y: b.midY)
        }
        var cx: CGFloat = 0, cy: CGFloat = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count], c = a.x * b.y - b.x * a.y
            cx += (a.x + b.x) * c
            cy += (a.y + b.y) * c
        }
        return CGPoint(x: cx / (6 * area), y: cy / (6 * area))
    }

    /// Schnittpunkt der Strecken a→b und c→d (je halboffen, [0, 1)), sonst nil
    private static func intersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y
        let den = rx * sy - ry * sx
        guard abs(den) >= 1e-12 else { return nil }
        let qx = c.x - a.x, qy = c.y - a.y
        let t = (qx * sy - qy * sx) / den, u = (qx * ry - qy * rx) / den
        guard t >= 0, t < 1, u >= 0, u < 1 else { return nil }
        return CGPoint(x: a.x + t * rx, y: a.y + t * ry)
    }
}
