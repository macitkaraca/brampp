// BRAMPP ikonu v2 — kupa YOK (StayAwake PC çakışması).
// Kompozisyon: koyu lacivert zemin + amber sunucu rack katmanları (stack) +
// servis durum LED'leri (uygulamanın yeşil/amber durum renkleri) + tek ince buhar (brew).
import AppKit

let master: CGFloat = 1024

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    NSColor(calibratedRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a).cgColor
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    let s = size / master

    // ── Zemin: macOS yuvarlatılmış kare, koyu lacivert→petrol dikey gradyan ──
    let margin: CGFloat = 100 * s
    let box = CGRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
    let bgPath = CGPath(roundedRect: box, cornerWidth: 185*s, cornerHeight: 185*s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10*s), blur: 24*s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(bgPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()
    let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(7, 14, 26), rgb(15, 34, 54), rgb(21, 51, 77)] as CFArray,
        locations: [0.0, 0.6, 1.0])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: size/2, y: box.minY),
                           end: CGPoint(x: size/2, y: box.maxY), options: [])

    // ── Rack katmanları: 3 amber bar ──
    let barW: CGFloat = 560 * s
    let barH: CGFloat = 118 * s
    let gap:  CGFloat = 46 * s
    let barX = size/2 - barW/2
    let stackH = 3*barH + 2*gap
    let bottomY = box.minY + (box.height - stackH)/2 - 38*s   // buhara yer için hafif aşağı

    // LED renkleri (alttan üste): yeşil, yeşil, amber — uygulamadaki servis durumları
    let ledColors: [CGColor] = [rgb(52, 211, 153), rgb(52, 211, 153), rgb(251, 191, 36)]

    for i in 0..<3 {
        let y = bottomY + CGFloat(i) * (barH + gap)
        let r = CGRect(x: barX, y: y, width: barW, height: barH)
        let p = CGPath(roundedRect: r, cornerWidth: 36*s, cornerHeight: 36*s, transform: nil)

        // Bar gövdesi — soldan sağa amber gradyan
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let barGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [rgb(180, 83, 9), rgb(245, 158, 11)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(barGrad, start: CGPoint(x: r.minX, y: r.midY),
                               end: CGPoint(x: r.maxX, y: r.midY), options: [])
        // Üst kenarda ince parlaklık
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.fill(CGRect(x: r.minX, y: r.maxY - 10*s, width: r.width, height: 10*s))
        ctx.restoreGState()

        // Havalandırma çizgileri (solda 3 dikey yuvarlak slot)
        ctx.setFillColor(rgb(0, 0, 0, 0.28))
        for k in 0..<3 {
            let vx = r.minX + 46*s + CGFloat(k) * 40*s
            let vr = CGRect(x: vx, y: r.midY - 30*s, width: 16*s, height: 60*s)
            ctx.addPath(CGPath(roundedRect: vr, cornerWidth: 8*s, cornerHeight: 8*s, transform: nil))
            ctx.fillPath()
        }

        // Durum LED'i (sağda) — hafif ışıma ile
        let ledC = CGPoint(x: r.maxX - 72*s, y: r.midY)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26*s, color: ledColors[i].copy(alpha: 0.9))
        ctx.setFillColor(ledColors[i])
        ctx.fillEllipse(in: CGRect(x: ledC.x - 22*s, y: ledC.y - 22*s, width: 44*s, height: 44*s))
        ctx.restoreGState()
        // LED iç parlak nokta
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.fillEllipse(in: CGRect(x: ledC.x - 8*s, y: ledC.y - 2*s, width: 14*s, height: 14*s))
    }

    // ── "Brew" göndermesi: en üst bardan yükselen TEK ince buhar kıvrımı ──
    let steamX = size/2 + barW/2 - 72*s   // LED kolonuyla hizalı — 'servisler dumanı üstünde'
    let steamY0 = bottomY + stackH + 26*s
    let steamH: CGFloat = 150 * s
    let path = CGMutablePath()
    path.move(to: CGPoint(x: steamX, y: steamY0))
    path.addCurve(to: CGPoint(x: steamX, y: steamY0 + steamH),
                  control1: CGPoint(x: steamX - 44*s, y: steamY0 + steamH*0.35),
                  control2: CGPoint(x: steamX + 44*s, y: steamY0 + steamH*0.7))
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(245, 158, 11, 0.75))
    ctx.setLineWidth(22*s)
    ctx.setLineCap(.round)
    ctx.strokePath()

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String, pixelSize: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let masterImg = drawIcon(size: master)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    savePNG(masterImg, to: "\(outDir)/\(px).png", pixelSize: px)
}
