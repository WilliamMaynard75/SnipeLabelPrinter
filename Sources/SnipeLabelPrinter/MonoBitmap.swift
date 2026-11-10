import CoreGraphics
import Foundation
import ImageIO

/// A 1-bit label image in printer orientation.
/// `width` runs along the tape (one raster line per column); `height` is across the tape
/// and always equals the print head size (128 dots on the PT-P700).
struct MonoBitmap {
    static let headDots = 128
    static let dpi = 180.0

    let width: Int
    let height: Int
    /// Row-major, top row first. `true` = black.
    var ink: [Bool]

    init(width: Int, height: Int = MonoBitmap.headDots) {
        self.width = width
        self.height = height
        self.ink = Array(repeating: false, count: width * height)
    }

    subscript(x: Int, y: Int) -> Bool {
        get { ink[y * width + x] }
        set { ink[y * width + x] = newValue }
    }

    var lengthMM: Double { Double(width) / MonoBitmap.dpi * 25.4 }

    /// The 16-byte raster line for column `x`: top row is the MSB of byte 0,
    /// matching the bit order ptouch-print uses.
    func rasterLine(column x: Int) -> [UInt8] {
        var line = [UInt8](repeating: 0, count: height / 8)
        for y in 0..<height where self[x, y] {
            line[y / 8] |= 0x80 >> UInt8(y % 8)
        }
        return line
    }

    /// Joins labels end to end with `gap` blank columns between them,
    /// optionally with a dashed cut line in the middle of each gap.
    static func chain(_ labels: [MonoBitmap], gap: Int, cutMarks: Bool) -> MonoBitmap? {
        guard !labels.isEmpty else { return nil }
        let gap = max(gap, cutMarks ? 3 : 0)
        let total = labels.reduce(0) { $0 + $1.width } + gap * (labels.count - 1)
        var out = MonoBitmap(width: total)
        var x0 = 0
        for (i, label) in labels.enumerated() {
            for y in 0..<label.height {
                for x in 0..<label.width where label[x, y] {
                    out[x0 + x, y] = true
                }
            }
            x0 += label.width
            if i < labels.count - 1 {
                if cutMarks {
                    let mid = x0 + gap / 2
                    for y in 0..<out.height where (y / 3) % 2 == 1 {
                        out[mid, y] = true
                    }
                }
                x0 += gap
            }
        }
        return out
    }

    /// A copy with `columns` blank columns added at the end of the tape.
    func padded(trailing columns: Int) -> MonoBitmap {
        guard columns > 0 else { return self }
        var out = MonoBitmap(width: width + columns, height: height)
        for y in 0..<height {
            for x in 0..<width where self[x, y] {
                out[x, y] = true
            }
        }
        return out
    }

    static func dots(mm: Double) -> Int { Int((mm / 25.4 * dpi).rounded()) }

    func cgImage() -> CGImage? {
        var pixels = ink.map { $0 ? UInt8(0) : UInt8(255) }
        let space = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)?
                .makeImage()
        }
    }

    func writePNG(to url: URL) throws {
        guard let image = cgImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
