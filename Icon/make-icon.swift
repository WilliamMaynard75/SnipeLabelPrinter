// Draws the app icon and writes Icon/AppIcon.icns.
// Run from the repo root: swift Icon/make-icon.swift
import AppKit
import CoreGraphics

let canvas = 1024.0

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: an 824 pt rounded square centered on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.42, blue: 0.20, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.30, green: 0.66, blue: 0.33, alpha: 1),
                                       CGColor(srgbRed: 0.10, green: 0.38, blue: 0.18, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()

    // The label: a strip of white tape, tilted slightly.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: 8 * .pi / 180)
    let label = CGRect(x: -330, y: -125, width: 660, height: 250)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(CGPath(roundedRect: label, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    drawQR(in: ctx, origin: CGPoint(x: label.minX + 30, y: label.minY + 30), size: 190)

    // Text lines: a heavy asset tag line, then lighter detail lines.
    let ink = CGColor(gray: 0.08, alpha: 1)
    let gray = CGColor(gray: 0.55, alpha: 1)
    let textX = label.minX + 250
    let bars: [(y: Double, w: Double, h: Double, c: CGColor)] = [
        (label.maxY - 70, 360, 34, ink),
        (label.maxY - 118, 240, 18, gray),
        (label.maxY - 160, 320, 26, ink),
        (label.maxY - 202, 200, 18, gray),
    ]
    for bar in bars {
        ctx.addPath(CGPath(roundedRect: CGRect(x: textX, y: bar.y, width: bar.w, height: bar.h),
                           cornerWidth: bar.h / 2, cornerHeight: bar.h / 2, transform: nil))
        ctx.setFillColor(bar.c)
        ctx.fillPath()
    }
    ctx.restoreGState()
}

/// A QR-looking pattern: three finder squares plus fixed pseudo-random modules.
func drawQR(in ctx: CGContext, origin: CGPoint, size: Double) {
    let n = 21
    let m = size / Double(n)
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    func module(_ col: Int, _ row: Int) {
        ctx.fill(CGRect(x: origin.x + Double(col) * m, y: origin.y + Double(n - 1 - row) * m, width: m, height: m))
    }
    func finder(_ c0: Int, _ r0: Int) {
        for r in 0..<7 { for c in 0..<7 {
            let edge = r == 0 || r == 6 || c == 0 || c == 6
            let core = (2...4).contains(r) && (2...4).contains(c)
            if edge || core { module(c0 + c, r0 + r) }
        } }
    }
    finder(0, 0); finder(n - 7, 0); finder(0, n - 7)
    var seed: UInt32 = 90167
    for r in 0..<n { for c in 0..<n {
        let inFinder = (r < 8 && c < 8) || (r < 8 && c >= n - 8) || (r >= n - 8 && c < 8)
        seed = seed &* 1_103_515_245 &+ 12345
        if !inFinder && (seed >> 16) & 1 == 1 { module(c, r) }
    } }
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let master = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                       space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
drawIcon(in: master)
let image = master.makeImage()!

let iconset = URL(fileURLWithPath: "Icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print("Wrote \(iconset.path)")
