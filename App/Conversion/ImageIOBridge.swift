import AppKit
import CoreGraphics
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
        let count = max(1, CGImageSourceGetCount(src))
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

    static func loadOriented(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionFailure.unreadable("Couldn't read \(url.lastPathComponent).")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 16000
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        throw ConversionFailure.unreadable("Couldn't decode \(url.lastPathComponent).")
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
        let flipped = CGRect(
            x: rect.x,
            y: image.height - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        guard let cropped = image.cropping(to: flipped) else {
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
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -shadowRadius * 0.25), blur: shadowRadius, color: CGColor(gray: 0, alpha: 0.28))
        let card = CGPath(roundedRect: imageRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        context.addPath(card)
        context.clip()
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
                guard flipped.count >= 2 else { continue }
                let start = flipped[0]
                let end = flipped[flipped.count - 1]
                context.beginPath()
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head: CGFloat = max(10, mark.width * 3)
                let left = CGPoint(x: end.x - head * cos(angle - .pi / 6), y: end.y - head * sin(angle - .pi / 6))
                let right = CGPoint(x: end.x - head * cos(angle + .pi / 6), y: end.y - head * sin(angle + .pi / 6))
                context.beginPath()
                context.move(to: end)
                context.addLine(to: left)
                context.addLine(to: right)
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
                context.saveGState()
                context.translateBy(x: origin.x, y: origin.y)
                context.scaleBy(x: 1, y: -1)
                (mark.text as NSString).draw(at: .zero, withAttributes: attributes)
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
