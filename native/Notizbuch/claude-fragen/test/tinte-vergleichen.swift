// Tinte zweier PDF-Seiten vergleichen: die Seite, wie die App sie Claude schickt (nachbarseiten.pdf), und dieselbe Seite,
// wie der Helfer sie selbst zeichnet (weitere/seite-N.pdf). Je 1 Pixel pro PDF-Punkt, ohne den grauen Streifen oben
// (44 Punkte). Tinte = Helligkeit unter 128: Striche und gedruckter Text, nicht die grauen Karos.
//   xcrun swiftc -O native/Notizbuch/claude-fragen/test/tinte-vergleichen.swift -o <ordner>/tinte-vergleichen
//   <ordner>/tinte-vergleichen <app.pdf> <Seite ab 1> <helfer.pdf> <Seite ab 1> <bild.png>
// Ausgabe: Größe beider Seiten, wo der Streifen erkannt wurde, Tintenpixel und ihr Verhältnis (≈ Strichbreite), wie viel
// Tinte der einen höchstens 3 Pixel neben Tinte der anderen liegt (beide Richtungen), Schwerpunkte und ihr Abstand.
// bild.png: schwarz = beide, rot = nur App, blau = nur Helfer
import CoreGraphics
import Foundation
import ImageIO
import PDFKit

struct Seite {
    let w: Int
    let h: Int
    let ink: [Bool]
    let streifen: String
}

func lies(_ path: String, _ nummer: Int) -> Seite {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
        print("✗ \(path): kein PDF")
        exit(1)
    }
    guard nummer >= 1, nummer <= doc.pageCount, let page = doc.page(at: nummer - 1) else {
        print("✗ \(path): keine Seite \(nummer) (das PDF hat \(doc.pageCount))")
        exit(1)
    }
    let box = page.bounds(for: .mediaBox)
    let w = Int(box.width.rounded()), h = Int(box.height.rounded())
    guard w > 0, h > 88,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        print("✗ \(path): Seite \(w) × \(h) lässt sich nicht zeichnen")
        exit(1)
    }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    page.draw(with: .mediaBox, to: ctx)
    guard let data = ctx.data else {
        print("✗ keine Pixel")
        exit(1)
    }
    let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    func hell(_ x: Int, _ y: Int) -> Int {
        let k = (y * w + x) * 4
        return (299 * Int(p[k]) + 587 * Int(p[k + 1]) + 114 * Int(p[k + 2])) / 1000
    }
    // Der Streifen (Grau 0,9 ≈ 229) liegt im Speicher oben (Zeile 0 zuerst) – sonst unten: nachzählen, nicht annehmen
    func grau(_ rows: Range<Int>) -> Int {
        var n = 0
        for y in rows { for x in stride(from: 0, to: w, by: 4) where abs(hell(x, y) - 229) <= 8 { n += 1 } }
        return n
    }
    let oben = grau(0..<44) >= grau((h - 44)..<h)
    let zeilen = oben ? 44..<h : 0..<(h - 44)
    var ink = [Bool](repeating: false, count: w * h)
    for y in zeilen {
        for x in 0..<w where hell(x, y) < 128 { ink[y * w + x] = true }
    }
    return Seite(w: w, h: h, ink: ink, streifen: oben ? "oben" : "unten (Speicher von unten?)")
}

/// Tinte um r Pixel verbreitert (Quadrat 2r+1)
func weite(_ s: Seite, _ r: Int) -> [Bool] {
    let w = s.w, h = s.h
    var a = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
        var last = -1_000_000
        for x in 0..<w {
            if s.ink[y * w + x] { last = x }
            if x - last <= r { a[y * w + x] = true }
        }
        last = 1_000_000
        for x in stride(from: w - 1, through: 0, by: -1) {
            if s.ink[y * w + x] { last = x }
            if last - x <= r { a[y * w + x] = true }
        }
    }
    var b = [Bool](repeating: false, count: w * h)
    for x in 0..<w {
        var last = -1_000_000
        for y in 0..<h {
            if a[y * w + x] { last = y }
            if y - last <= r { b[y * w + x] = true }
        }
        last = 1_000_000
        for y in stride(from: h - 1, through: 0, by: -1) {
            if a[y * w + x] { last = y }
            if last - y <= r { b[y * w + x] = true }
        }
    }
    return b
}

let args = CommandLine.arguments
guard args.count == 6, let na = Int(args[2]), let nb = Int(args[4]) else {
    print("Aufruf: tinte-vergleichen <app.pdf> <Seite ab 1> <helfer.pdf> <Seite ab 1> <bild.png>")
    exit(2)
}
let a = lies(args[1], na), b = lies(args[3], nb)
print("App \(a.w) × \(a.h) (Streifen \(a.streifen)), Helfer \(b.w) × \(b.h) (Streifen \(b.streifen))")
guard a.w == b.w, a.h == b.h else {
    print("✗ verschieden groß")
    exit(1)
}
let n = a.w * a.h
let wa = weite(a, 3), wb = weite(b, 3)
var inkA = 0, inkB = 0, aNahe = 0, bNahe = 0
var sax = 0.0, say = 0.0, sbx = 0.0, sby = 0.0
for i in 0..<n {
    if a.ink[i] {
        inkA += 1
        sax += Double(i % a.w)
        say += Double(i / a.w)
        if wb[i] { aNahe += 1 }
    }
    if b.ink[i] {
        inkB += 1
        sbx += Double(i % b.w)
        sby += Double(i / b.w)
        if wa[i] { bNahe += 1 }
    }
}
guard inkA > 0, inkB > 0 else {
    print("✗ keine Tinte: App \(inkA) px, Helfer \(inkB) px")
    exit(1)
}
let ax = sax / Double(inkA), ay = say / Double(inkA), bx = sbx / Double(inkB), by = sby / Double(inkB)
print(String(format: "Tinte: App %ld px, Helfer %ld px, Helfer/App %.2f", inkA, inkB, Double(inkB) / Double(inkA)))
print(String(format: "App-Tinte höchstens 3 px neben Helfer-Tinte: %.1f %%; Helfer-Tinte höchstens 3 px neben App-Tinte: %.1f %%",
             100 * Double(aNahe) / Double(inkA), 100 * Double(bNahe) / Double(inkB)))
print(String(format: "Schwerpunkt App %.1f, %.1f; Helfer %.1f, %.1f; Abstand %.1f px (x nach rechts, y nach unten)",
             ax, ay, bx, by, hypot(bx - ax, by - ay)))

var px = [UInt8](repeating: 255, count: n * 4)
for i in 0..<n {
    let k = i * 4
    switch (a.ink[i], b.ink[i]) {
    case (true, true): px[k] = 0; px[k + 1] = 0; px[k + 2] = 0
    case (true, false): px[k] = 220; px[k + 1] = 0; px[k + 2] = 0
    case (false, true): px[k] = 0; px[k + 1] = 0; px[k + 2] = 220
    default: break
    }
}
guard let provider = CGDataProvider(data: Data(px) as CFData),
      let image = CGImage(width: a.w, height: a.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: a.w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[5]) as CFURL, "public.png" as CFString, 1, nil)
else {
    print("✗ Bild nicht geschrieben")
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
print(CGImageDestinationFinalize(dest) ? "Bild: \(args[5])" : "✗ Bild nicht geschrieben")
