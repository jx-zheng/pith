import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PithCore

enum ImageIOBridge {
    static func convert(source: URL, destination: URL, uti: String, quality: Double?) throws {
        guard source.path != destination.path else {
            throw ConversionFailure.writeFailed("Refusing to overwrite the source file.")
        }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ConversionFailure.unreadable("Couldn't read \(source.lastPathComponent).")
        }
        // Only GIF and TIFF carry every frame/page; JPEG, BMP and the rest take the first one.
        // (Asking a single-image format for N images makes the destination fail to create.)
        let frames = max(1, CGImageSourceGetCount(src))
        let count = Self.multiFrameUTIs.contains(uti) ? frames : 1
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, uti as CFString, count, nil) else {
            throw ConversionFailure.unsupported("This Mac's ImageIO can't write .\(destination.pathExtension).")
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        for index in 0..<count {
            CGImageDestinationAddImageFromSource(dest, src, index, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionFailure.writeFailed("ImageIO couldn't write \(destination.lastPathComponent).")
        }
    }

    static let multiFrameUTIs: Set<String> = [FileTypes.gif.uti, FileTypes.tiff.uti]

    /// Whether this Mac's ImageIO can encode `uti` (AVIF on macOS 15+, never WebP).
    static func canWrite(_ uti: String) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(uti)
    }

    static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard maxEdge > 0, longEdge > maxEdge else { return image }
        let scale = Double(maxEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func write(_ image: CGImage, to destination: URL, uti: String, quality: Double?) throws {
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, uti as CFString, 1, nil) else {
            throw ConversionFailure.unsupported("Can't write .\(destination.pathExtension).")
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConversionFailure.writeFailed("Couldn't write \(destination.lastPathComponent).")
        }
    }

    /// Cap for apply/save and for conversions. Editor previews pass a much smaller size.
    static let fullResolutionMaxPixelSize = 16_000

    static func loadOriented(_ url: URL, maxPixelSize: Int = fullResolutionMaxPixelSize) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionFailure.unreadable("Couldn't read \(url.lastPathComponent).")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        throw ConversionFailure.unreadable("Couldn't decode \(url.lastPathComponent).")
    }

    /// Oriented pixel size from the image header. No pixel decode.
    static func orientedPixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = integer(raw[kCGImagePropertyPixelWidth]),
              let pixelHeight = integer(raw[kCGImagePropertyPixelHeight]),
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        switch orientation(in: raw) {
        case 5, 6, 7, 8:
            return (pixelHeight, pixelWidth)
        default:
            return (pixelWidth, pixelHeight)
        }
    }

    /// Editor coordinate space: oriented pixels, capped the same way a full `loadOriented` is.
    static func editorPixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let size = orientedPixelSize(of: url) else { return nil }
        let longEdge = max(size.width, size.height)
        guard longEdge > fullResolutionMaxPixelSize else { return size }
        let scale = Double(fullResolutionMaxPixelSize) / Double(longEdge)
        return (
            max(1, Int((Double(size.width) * scale).rounded())),
            max(1, Int((Double(size.height) * scale).rounded()))
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func orientation(in raw: [CFString: Any]) -> Int {
        if let value = integer(raw[kCGImagePropertyOrientation]) { return value }
        if let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = integer(tiff[kCGImagePropertyOrientation]) {
            return value
        }
        return 1
    }

    static func properties(of url: URL) -> [(String, String)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }
        return flatten(raw, prefix: "").sorted { $0.0 < $1.0 }
    }

    static func stripMetadata(source: URL, destination: URL, quality: Double) throws {
        let image = try loadOriented(source)
        try write(image, to: destination, uti: FileTypes.matching(path: source.path)?.uti ?? FileTypes.jpeg.uti, quality: quality)
    }

    private static func flatten(_ dictionary: [CFString: Any], prefix: String) -> [(String, String)] {
        var rows: [(String, String)] = []
        for (key, value) in dictionary {
            let name = prefix.isEmpty ? (key as String) : "\(prefix).\(key as String)"
            if let nested = value as? [CFString: Any] {
                rows.append(contentsOf: flatten(nested, prefix: name))
            } else {
                rows.append((name, String(describing: value)))
            }
        }
        return rows
    }
}

enum ImageComposer {
    static func crop(_ image: CGImage, to rect: PixelRect) throws -> CGImage {
        // PixelRect and CGImage.cropping(to:) are both top-left based; no flip.
        let area = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        guard let cropped = image.cropping(to: area) else {
            throw ConversionFailure.writeFailed("The crop rectangle is outside the image.")
        }
        return cropped
    }

    static func addBackground(
        image: CGImage,
        padding: Int,
        cornerRadius: CGFloat,
        shadowRadius: CGFloat,
        background: BackgroundFill,
        aspect: AspectPreset
    ) -> CGImage? {
        let canvas = BackgroundCanvas(
            imageWidth: image.width,
            imageHeight: image.height,
            padding: padding,
            aspect: aspect
        )
        let size = canvas.size
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let canvasRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        draw(background, in: context, rect: canvasRect)
        let imageRect = CGRect(
            x: (size.width - image.width) / 2,
            y: (size.height - image.height) / 2,
            width: image.width,
            height: image.height
        )
        let radius = min(max(0, cornerRadius), min(imageRect.width, imageRect.height) / 2)
        let card = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // Shadow pass: fill the card shape with the shadow on. It must happen before any clip,
        // because a clip to the card would cut the shadow (which lies outside it) away entirely.
        if shadowRadius > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadowRadius * 0.35), blur: shadowRadius, color: CGColor(gray: 0, alpha: 0.45))
            context.addPath(card)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(card)
        context.clip()
        // Clear the black shadow-caster under the image so transparent pixels show the background.
        draw(background, in: context, rect: canvasRect)
        context.draw(image, in: imageRect)
        context.restoreGState()
        return context.makeImage()
    }

    static func draw(_ fill: BackgroundFill, in context: CGContext, rect: CGRect) {
        switch fill {
        case let .solid(red, green, blue):
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(rect)
        case let .gradient(stops, _):
            let colors = stops.map { CGColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) } as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) else { return }
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.midY), end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
        }
    }
}

struct RGBStop: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
}

enum BackgroundFill: Equatable {
    case solid(CGFloat, CGFloat, CGFloat)
    case gradient([RGBStop], angle: Double)
}

struct AnnotationMark: Equatable {
    enum Kind: Equatable { case pen, arrow, text }
    var kind: Kind
    var points: [CGPoint]
    var text: String
    var color: RGBStop
    var width: CGFloat
}

/// Arrow shaft and head in the same coordinate space as `start` and `tip`.
enum AnnotationGeometry {
    struct Arrow {
        var shaftEnd: CGPoint
        var left: CGPoint
        var right: CGPoint
    }

    static func arrow(from start: CGPoint, to tip: CGPoint, width: CGFloat) -> Arrow? {
        let dx = tip.x - start.x, dy = tip.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return nil }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(max(14, width * 4.2), length * 0.6)
        let halfWidth = max(7, width * 2.2) * (headLength / max(14, width * 4.2))
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        let overlap = min(headLength * 0.35, width)
        let shaftEnd = CGPoint(x: base.x + ux * overlap, y: base.y + uy * overlap)
        let left = CGPoint(x: base.x + nx * halfWidth, y: base.y + ny * halfWidth)
        let right = CGPoint(x: base.x - nx * halfWidth, y: base.y - ny * halfWidth)
        return Arrow(shaftEnd: shaftEnd, left: left, right: right)
    }
}

enum AnnotationRenderer {
    static func render(base: CGImage, marks: [AnnotationMark]) -> CGImage? {
        let width = base.width
        let height = base.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        for mark in marks {
            context.setStrokeColor(CGColor(red: mark.color.r, green: mark.color.g, blue: mark.color.b, alpha: 1))
            context.setFillColor(CGColor(red: mark.color.r, green: mark.color.g, blue: mark.color.b, alpha: 1))
            context.setLineWidth(mark.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let flipped = mark.points.map { CGPoint(x: $0.x, y: CGFloat(height) - $0.y) }
            switch mark.kind {
            case .pen:
                guard let first = flipped.first else { continue }
                context.beginPath()
                context.move(to: first)
                flipped.dropFirst().forEach { context.addLine(to: $0) }
                context.strokePath()
            case .arrow:
                guard flipped.count >= 2,
                      let arrow = AnnotationGeometry.arrow(from: flipped[0], to: flipped[flipped.count - 1], width: mark.width) else { continue }
                context.beginPath()
                context.move(to: flipped[0])
                context.addLine(to: arrow.shaftEnd)
                context.setLineCap(.butt)
                context.strokePath()
                context.setLineCap(.round)
                context.beginPath()
                context.move(to: flipped[flipped.count - 1])
                context.addLine(to: arrow.left)
                context.addLine(to: arrow.right)
                context.closePath()
                context.fillPath()
            case .text:
                guard let origin = flipped.first else { continue }
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .left
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(18, mark.width * 8), weight: .semibold),
                    .foregroundColor: NSColor(calibratedRed: mark.color.r, green: mark.color.g, blue: mark.color.b, alpha: 1)
                ]
                // NSString draws into NSGraphicsContext.current, which is nil here, so wrap this
                // bitmap context. Flip it so the text hangs down from its top-left anchor, upright.
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                (mark.text as NSString).draw(at: .zero, withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
            }
        }
        return context.makeImage()
    }

    static func redact(base: CGImage, boxes: [CGRect]) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in boxes {
            let flipped = CGRect(x: box.minX, y: CGFloat(base.height) - box.maxY, width: box.width, height: box.height)
            context.fill(flipped)
        }
        return context.makeImage()
    }
}

/// Edit tool: brightness, contrast, saturation and sharpness via Core Image.
enum ImageAdjust {
    /// One context for preview and apply. Caching intermediates retained full-size rasters between slider ticks.
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func render(_ image: CGImage, brightness: Double, contrast: Double, saturation: Double, sharpness: Double) -> CGImage? {
        if brightness == 0, contrast == 1, saturation == 1, sharpness <= 0.01 { return image }
        let ci = CIImage(cgImage: image)
        guard let controls = CIFilter(name: "CIColorControls") else { return image }
        controls.setValue(ci, forKey: kCIInputImageKey)
        controls.setValue(brightness, forKey: kCIInputBrightnessKey)
        controls.setValue(contrast, forKey: kCIInputContrastKey)
        controls.setValue(saturation, forKey: kCIInputSaturationKey)
        var output = controls.outputImage
        if sharpness > 0.01, let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(output, forKey: kCIInputImageKey)
            sharpen.setValue(sharpness, forKey: "inputSharpness")
            output = sharpen.outputImage
        }
        guard let output else { return image }
        return context.createCGImage(output, from: output.extent)
    }
}
