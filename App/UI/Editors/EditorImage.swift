import CoreGraphics
import Foundation
import PithCore

/// A display bitmap plus the full-resolution pixel space edits are stored in.
/// Apply/save reloads the source when the preview was downscaled.
struct EditorImage {
    var preview: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
    var source: URL

    static func load(url: URL, windowLongEdge: CGFloat) -> EditorImage? {
        let maxPixel = PreviewDecode.maxPixelSize(windowLongEdge: Double(windowLongEdge))
        guard let preview = try? ImageIOBridge.loadOriented(url, maxPixelSize: maxPixel) else { return nil }
        let size = ImageIOBridge.editorPixelSize(of: url) ?? (width: preview.width, height: preview.height)
        return EditorImage(preview: preview, pixelWidth: size.width, pixelHeight: size.height, source: url)
    }

    func fullImage() throws -> CGImage {
        if preview.width == pixelWidth && preview.height == pixelHeight { return preview }
        let full = try ImageIOBridge.loadOriented(source)
        // ImageIO's 16000px thumbnail can land 1px off editorPixelSize's rounded short edge.
        guard abs(full.width - pixelWidth) <= 1, abs(full.height - pixelHeight) <= 1 else {
            throw ConversionFailure.unreadable("\(source.lastPathComponent) changed on disk while it was open, so this edit wasn't applied.")
        }
        return full
    }

    func cropSource(for rect: PixelRect) throws -> (CGImage, PixelRect) {
        let full = try fullImage()
        return (full, map(rect, onto: full))
    }

    func annotated(_ marks: [AnnotationMark]) throws -> CGImage {
        let full = try fullImage()
        let mapped = marks.map { map($0, onto: full) }
        guard let rendered = AnnotationRenderer.render(base: full, marks: mapped) else {
            throw ConversionFailure.writeFailed("Couldn't draw annotations.")
        }
        return rendered
    }

    func redacted(_ boxes: [CGRect]) throws -> CGImage {
        let full = try fullImage()
        guard let rendered = AnnotationRenderer.redact(base: full, boxes: boxes.map { map($0, onto: full) }) else {
            throw ConversionFailure.writeFailed("Couldn't redact the image.")
        }
        return rendered
    }

    func adjusted(_ edit: ImageAdjustments) throws -> CGImage {
        let full = try fullImage()
        guard let rendered = ImageAdjust.render(
            full,
            brightness: edit.brightness,
            contrast: edit.contrast,
            saturation: edit.saturation,
            sharpness: edit.sharpness
        ) else {
            throw ConversionFailure.writeFailed("Couldn't apply the adjustments.")
        }
        return rendered
    }

    func backed(_ edit: BackgroundEdit) throws -> CGImage {
        let full = try fullImage()
        let scale = (scaleX(onto: full) + scaleY(onto: full)) / 2
        guard let rendered = ImageComposer.addBackground(
            image: full,
            padding: Int((CGFloat(edit.padding) * scale).rounded()),
            cornerRadius: edit.cornerRadius * scale,
            shadowRadius: edit.shadowRadius * scale,
            background: edit.fill,
            aspect: edit.aspect
        ) else {
            throw ConversionFailure.writeFailed("Couldn't build the background.")
        }
        return rendered
    }

    private func scaleX(onto image: CGImage) -> CGFloat {
        CGFloat(image.width) / CGFloat(max(pixelWidth, 1))
    }

    private func scaleY(onto image: CGImage) -> CGFloat {
        CGFloat(image.height) / CGFloat(max(pixelHeight, 1))
    }

    private func map(_ point: CGPoint, onto image: CGImage) -> CGPoint {
        CGPoint(x: point.x * scaleX(onto: image), y: point.y * scaleY(onto: image))
    }

    private func map(_ mark: AnnotationMark, onto image: CGImage) -> AnnotationMark {
        let sx = scaleX(onto: image)
        return AnnotationMark(
            kind: mark.kind,
            points: mark.points.map { map($0, onto: image) },
            text: mark.text,
            color: mark.color,
            width: mark.width * sx
        )
    }

    private func map(_ box: CGRect, onto image: CGImage) -> CGRect {
        let origin = map(CGPoint(x: box.minX, y: box.minY), onto: image)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: box.width * scaleX(onto: image),
            height: box.height * scaleY(onto: image)
        )
    }

    private func map(_ rect: PixelRect, onto image: CGImage) -> PixelRect {
        let sx = Double(image.width) / Double(max(pixelWidth, 1))
        let sy = Double(image.height) / Double(max(pixelHeight, 1))
        let mapped = PixelRect(
            x: Int((Double(rect.x) * sx).rounded()),
            y: Int((Double(rect.y) * sy).rounded()),
            width: max(1, Int((Double(rect.width) * sx).rounded())),
            height: max(1, Int((Double(rect.height) * sy).rounded()))
        )
        return CropGeometry.clamped(mapped, imageWidth: image.width, imageHeight: image.height)
    }
}
