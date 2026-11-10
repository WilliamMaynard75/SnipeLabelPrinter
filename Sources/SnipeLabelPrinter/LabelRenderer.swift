import CoreGraphics
import Foundation

struct RenderOptions: Equatable {
    /// Printable dots across the tape (128 for 24 mm tape).
    var tapeDots = 128
    /// Blank dots kept above and below the content.
    var marginDots = 2
    /// Gray level (0...1) below which a pixel prints black.
    var threshold = 0.5
    /// Crop white space around the label content before scaling.
    var trimWhitespace = true
    /// Turn portrait labels sideways so their long side runs along the tape.
    var autoRotate = true
}

enum RenderError: LocalizedError {
    case unreadablePDF, blankPage, bitmapFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: "Couldn't open the PDF."
        case .blankPage: "The page is blank."
        case .bitmapFailed: "Couldn't create the bitmap."
        }
    }
}

/// Turns the first page of a Snipe-IT label PDF into a 1-bit image sized for the tape.
enum LabelRenderer {
    /// Resolution used to rasterize the PDF before downscaling to 180 dpi.
    private static let sourceDPI = 600.0

    static func render(pdf url: URL, options: RenderOptions) throws -> MonoBitmap {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else {
            throw RenderError.unreadablePDF
        }
        let source = try rasterize(page)
        let crop = options.trimWhitespace ? try contentBounds(of: source) : CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let cropped = source.cropping(to: crop) else { throw RenderError.bitmapFailed }
        return try fit(cropped, options: options)
    }

    /// Draws the page on white at `sourceDPI` in 8-bit grayscale.
    private static func rasterize(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((Int(page.rotationAngle) % 360 + 360) % 360) / 90
        let scale = sourceDPI / 72
        var w = Int((box.width * scale).rounded())
        var h = Int((box.height * scale).rounded())
        if quarterTurns % 2 == 1 { swap(&w, &h) }

        guard let ctx = grayContext(width: w, height: h) else { throw RenderError.bitmapFailed }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Honor the page's /Rotate entry, then map the crop box onto the bitmap.
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.midX, y: -box.midY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw RenderError.bitmapFailed }
        return image
    }

    /// Bounding box (top-left origin, as `CGImage.cropping` expects) of everything that isn't near-white.
    private static func contentBounds(of image: CGImage) throws -> CGRect {
        let w = image.width, h = image.height
        guard let ctx = grayContext(width: w, height: h), let data = ctx.data else { throw RenderError.bitmapFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = ctx.bytesPerRow
        let px = data.assumingMemoryBound(to: UInt8.self)

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = px + y * rowBytes
            for x in 0..<w where row[x] < 240 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { throw RenderError.blankPage }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Scales the content to the printable height, centers it on the 128-dot head and thresholds it.
    private static func fit(_ image: CGImage, options: RenderOptions) throws -> MonoBitmap {
        let rotate = options.autoRotate && image.height > image.width
        let srcW = Double(rotate ? image.height : image.width)
        let srcH = Double(rotate ? image.width : image.height)

        let tapeDots = min(options.tapeDots, MonoBitmap.headDots)
        let contentH = max(tapeDots - 2 * options.marginDots, 8)
        let outW = max(Int((srcW * Double(contentH) / srcH).rounded()), 1)
        let outH = MonoBitmap.headDots
        let bottom = (outH - contentH) / 2

        guard let ctx = grayContext(width: outW, height: outH), let data = ctx.data else { throw RenderError.bitmapFailed }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high
        let target = CGRect(x: 0, y: bottom, width: outW, height: contentH)
        if rotate {
            // Quarter turn clockwise: the image's top ends up at the far end of the tape.
            ctx.translateBy(x: target.minX, y: target.maxY)
            ctx.rotate(by: -.pi / 2)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: target.height, height: target.width))
        } else {
            ctx.draw(image, in: target)
        }

        let cutoff = UInt8(max(0, min(255, options.threshold * 255)))
        let rowBytes = ctx.bytesPerRow
        let px = data.assumingMemoryBound(to: UInt8.self)
        var bitmap = MonoBitmap(width: outW, height: outH)
        for y in 0..<outH {
            let row = px + y * rowBytes
            for x in 0..<outW where row[x] < cutoff {
                bitmap[x, y] = true
            }
        }
        return bitmap
    }

    private static func grayContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }
}
