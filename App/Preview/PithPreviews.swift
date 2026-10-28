import AppKit
import SwiftUI

/// Hard-coded reference states from the author demo. Open these in the Xcode
/// canvas and set them beside the extracted frames. The orange field is the
/// demo wallpaper stand-in; the live panel blurs the real desktop instead.
enum PreviewSamples {
    static let pdfWheel: [WheelSegmentModel] = [
        WheelSegmentModel(id: "docx", title: "DOCX", symbol: nil, enabled: true, help: nil),
        WheelSegmentModel(id: "jpg", title: "JPG", symbol: nil, enabled: true, help: nil),
        WheelSegmentModel(id: "png", title: "PNG", symbol: nil, enabled: true, help: nil),
        WheelSegmentModel(id: "txt", title: "TXT", symbol: nil, enabled: true, help: nil)
    ]

    static let imageWheel: [WheelSegmentModel] = [
        "PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "GIF"
    ].map { WheelSegmentModel(id: $0, title: $0, symbol: nil, enabled: true, help: nil) }

    static let toolWheel: [WheelSegmentModel] = [
        WheelSegmentModel(id: "compress", title: "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", enabled: true, help: nil),
        WheelSegmentModel(id: "metadata", title: "METADATA", symbol: "tag", enabled: true, help: nil),
        WheelSegmentModel(id: "edit", title: "EDIT", symbol: "slider.horizontal.3", enabled: true, help: nil),
        WheelSegmentModel(id: "annotate", title: "ANNOTATE", symbol: "scribble", enabled: true, help: nil),
        WheelSegmentModel(id: "bg", title: "ADD BG", symbol: "photo", enabled: true, help: nil),
        WheelSegmentModel(id: "crop", title: "CROP", symbol: "crop", enabled: true, help: nil),
        WheelSegmentModel(id: "redact", title: "REDACT", symbol: "eye", enabled: true, help: nil)
    ]

    static func pageImage() -> CGImage {
        let width = 640
        let height = 820
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        for row in 0..<36 {
            let y = 36 + row * 20
            let bar = row % 6 == 0 ? 220 : 560
            context.fill(CGRect(x: 36, y: y, width: bar, height: 5))
        }
        return context.makeImage()!
    }
}

private struct PreviewStage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            PithTheme.referenceBackdrop
            content()
        }
    }
}

#Preview("Format wheel") {
    PreviewStage {
        WheelView(segments: PreviewSamples.pdfWheel, centerText: "JPG", highlighted: 1)
    }
    .frame(width: 640, height: 560)
}

#Preview("Image wheel") {
    PreviewStage {
        WheelView(segments: PreviewSamples.imageWheel, centerText: "1.2 MB", highlighted: nil)
    }
    .frame(width: 640, height: 560)
}

#Preview("Tools wheel") {
    PreviewStage {
        WheelView(segments: PreviewSamples.toolWheel, centerText: "1.2 MB", highlighted: 4)
    }
    .frame(width: 640, height: 560)
}

#Preview("Wheel appear") {
    WheelAppearPreview()
}

#Preview("Converting HUD") {
    PreviewStage {
        ProgressHUDView(title: "Converting to JPG", subtitle: "Page 001.pdf", progress: 0.42, onCancel: {})
    }
    .frame(width: 520, height: 220)
}

#Preview("Crop Image") {
    let image = PreviewSamples.pageImage()
    CropEditor(image: image, pixelWidth: image.width, pixelHeight: image.height, onClose: {}, onApply: { _ in })
        .frame(width: 760, height: 860)
}

#Preview("Add BG") {
    let image = PreviewSamples.pageImage()
    AddBackgroundEditor(image: image, pixelWidth: image.width, pixelHeight: image.height, onClose: {}, onApply: { _ in })
        .frame(width: 760, height: 860)
}

#Preview("Annotate") {
    let image = PreviewSamples.pageImage()
    AnnotateEditor(image: image, pixelWidth: image.width, pixelHeight: image.height, onClose: {}, onApply: { _ in })
        .frame(width: 760, height: 820)
}

#Preview("Redact") {
    let image = PreviewSamples.pageImage()
    RedactEditor(image: image, pixelWidth: image.width, pixelHeight: image.height, onClose: {}, onApply: { _ in })
        .frame(width: 760, height: 820)
}

#Preview("Edit") {
    AdjustEditor(image: PreviewSamples.pageImage(), onClose: {}, onApply: { _ in })
        .frame(width: 720, height: 780)
}

#Preview("Metadata") {
    MetadataEditor(
        source: URL(fileURLWithPath: "/tmp/Page 001.jpg"),
        rows: [("PixelWidth", "2550"), ("PixelHeight", "3300"), ("{Exif}.LensModel", "iPhone")],
        onClose: {},
        onStrip: {}
    )
    .frame(width: 560, height: 640)
}

#Preview("Compress") {
    CompressEditor(
        image: PreviewSamples.pageImage(),
        originalBytes: 1_200_000,
        isVideo: false,
        onClose: {},
        onApplyImage: { _, _ in },
        onApplyVideo: nil
    )
    .frame(width: 640, height: 720)
}

private struct WheelAppearPreview: View {
    @StateObject private var model = WheelModel()

    var body: some View {
        PreviewStage {
            WheelContainer(model: model)
        }
        .frame(width: 640, height: 560)
        .onAppear {
            model.segments = PreviewSamples.pdfWheel
            model.centerText = "1.1 MB"
            model.highlighted = nil
            model.appeared = false
        }
    }
}
