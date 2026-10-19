import AppKit
import CoreImage
import SwiftUI
import PithCore

struct AnnotateEditor: View {
    var image: CGImage
    var onClose: () -> Void
    var onApply: (CGImage) -> Void

    @State private var marks: [AnnotationMark] = []
    @State private var draft: [CGPoint] = []
    @State private var tool: AnnotationMark.Kind = .pen
    @State private var color = RGBStop(r: 0.92, g: 0.27, b: 0.16)
    @State private var width: Double = 4
    @State private var text = "Note"

    private let colors: [RGBStop] = [
        RGBStop(r: 0.92, g: 0.27, b: 0.16),
        RGBStop(r: 0.12, g: 0.12, b: 0.12),
        RGBStop(r: 0.95, g: 0.75, b: 0.15),
        RGBStop(r: 0.15, g: 0.45, b: 0.9),
        RGBStop(r: 0.15, g: 0.65, b: 0.35)
    ]

    var body: some View {
        EditorChrome(title: "Annotate", primaryTitle: "Save", onClose: onClose, onReset: { marks = []; draft = [] }, onPrimary: apply) {
            VStack(spacing: 12) {
                canvas
                    .padding(.horizontal, 18)
                HStack(spacing: 8) {
                    toolButton(.pen, "Pen", "pencil.tip")
                    toolButton(.arrow, "Arrow", "arrow.up.right")
                    toolButton(.text, "Text", "textformat")
                    Spacer()
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, swatch in
                        Circle()
                            .fill(Color(red: swatch.r, green: swatch.g, blue: swatch.b))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white, lineWidth: color == swatch ? 2 : 0))
                            .onTapGesture { color = swatch }
                    }
                }
                .padding(.horizontal, 18)
                if tool == .text {
                    TextField("Text", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 18)
                }
                LabeledSlider(title: "Width", value: $width, range: 1...24, display: "\(Int(width)) px")
                    .padding(.horizontal, 18)
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let fitted = fit(geo.size)
            ZStack {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let point = imagePoint(value.location, fitted: fitted)
                if tool == .text {
                    return
                }
                if draft.isEmpty { draft = [point] } else { draft.append(point) }
            }.onEnded { value in
                if tool == .text {
                    marks.append(AnnotationMark(kind: .text, points: [imagePoint(value.location, fitted: fitted)], text: text, color: color, width: width))
                    return
                }
                guard draft.count > 1 else { draft = []; return }
                let stored = tool == .arrow ? [draft[0], draft[draft.count - 1]] : draft
                marks.append(AnnotationMark(kind: tool, points: stored, text: "", color: color, width: width))
                draft = []
            })
        }
    }

    private var rendered: CGImage {
        var live = marks
        if draft.count > 1 {
            let stored = tool == .arrow ? [draft[0], draft[draft.count - 1]] : draft
            live.append(AnnotationMark(kind: tool, points: stored, text: "", color: color, width: width))
        }
        return AnnotationRenderer.render(base: image, marks: live) ?? image
    }

    private func apply() {
        if let image = AnnotationRenderer.render(base: image, marks: marks) {
            onApply(image)
        }
    }

    private func toolButton(_ kind: AnnotationMark.Kind, _ title: String, _ symbol: String) -> some View {
        Button {
            tool = kind
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(tool == kind ? PithTheme.highlight : Color.white.opacity(0.4)))
                .foregroundStyle(tool == kind ? Color.white : PithTheme.ink)
        }
        .buttonStyle(.plain)
    }

    private func fit(_ size: CGSize) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        if aspect > size.width / max(size.height, 1) {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        let x = (point.x - fitted.minX) / max(fitted.width, 1) * CGFloat(image.width)
        let y = (point.y - fitted.minY) / max(fitted.height, 1) * CGFloat(image.height)
        return CGPoint(x: min(max(0, x), CGFloat(image.width)), y: min(max(0, y), CGFloat(image.height)))
    }
}

struct RedactEditor: View {
    var image: CGImage
    var onClose: () -> Void
    var onApply: (CGImage) -> Void
    @State private var boxes: [CGRect] = []
    @State private var draft: CGRect?

    var body: some View {
        EditorChrome(title: "Redact", primaryTitle: "Save", onClose: onClose, onReset: { boxes = []; draft = nil }, onPrimary: apply) {
            GeometryReader { geo in
                let fitted = fit(geo.size)
                ZStack {
                    Image(decorative: rendered, scale: 1)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    let start = imagePoint(value.startLocation, fitted: fitted)
                    let end = imagePoint(value.location, fitted: fitted)
                    draft = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                }.onEnded { _ in
                    if let draft, draft.width > 2, draft.height > 2 { boxes.append(draft) }
                    draft = nil
                })
            }
            .padding(18)
        }
    }

    private var rendered: CGImage {
        var all = boxes
        if let draft { all.append(draft) }
        return AnnotationRenderer.redact(base: image, boxes: all) ?? image
    }

    private func apply() {
        if let image = AnnotationRenderer.redact(base: image, boxes: boxes) { onApply(image) }
    }

    private func fit(_ size: CGSize) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        if aspect > size.width / max(size.height, 1) {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - fitted.minX) / max(fitted.width, 1) * CGFloat(image.width),
            y: (point.y - fitted.minY) / max(fitted.height, 1) * CGFloat(image.height)
        )
    }
}

struct MetadataEditor: View {
    var source: URL
    var rows: [(String, String)]
    var onClose: () -> Void
    var onStrip: () -> Void

    var body: some View {
        EditorChrome(title: "Metadata", primaryTitle: "Strip Metadata", onClose: onClose, onReset: {}, onPrimary: onStrip) {
            VStack(alignment: .leading, spacing: 8) {
                Text(source.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PithTheme.ink.opacity(0.65))
                    .padding(.horizontal, 18)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if rows.isEmpty {
                            Text("No metadata on this file.")
                                .foregroundStyle(PithTheme.ink.opacity(0.7))
                        }
                        ForEach(Array(rows.prefix(80).enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top) {
                                Text(short(row.0))
                                    .frame(width: 180, alignment: .leading)
                                    .foregroundStyle(PithTheme.ink.opacity(0.6))
                                Text(row.1)
                                    .foregroundStyle(PithTheme.ink)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .font(.system(size: 11, design: .monospaced))
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private func short(_ key: String) -> String {
        key.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }
}

struct AdjustEditor: View {
    var image: CGImage
    var onClose: () -> Void
    var onApply: (CGImage) -> Void
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var sharpness: Double = 0

    var body: some View {
        EditorChrome(title: "Edit", primaryTitle: "Save", onClose: onClose, onReset: reset, onPrimary: apply) {
            VStack(spacing: 14) {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 18)
                VStack(spacing: 8) {
                    LabeledSlider(title: "Brightness", value: $brightness, range: -0.4...0.4, display: String(format: "%+.2f", brightness))
                    LabeledSlider(title: "Contrast", value: $contrast, range: 0.5...1.6, display: String(format: "%.2f", contrast))
                    LabeledSlider(title: "Saturation", value: $saturation, range: 0...2, display: String(format: "%.2f", saturation))
                    LabeledSlider(title: "Sharpness", value: $sharpness, range: 0...1.5, display: String(format: "%.2f", sharpness))
                }
                .padding(.horizontal, 18)
            }
        }
    }

    private var preview: CGImage { rendered() ?? image }

    private func rendered() -> CGImage? {
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
        return CIContext().createCGImage(output, from: output.extent)
    }

    private func reset() {
        brightness = 0
        contrast = 1
        saturation = 1
        sharpness = 0
    }

    private func apply() { if let image = rendered() { onApply(image) } }
}

struct CompressEditor: View {
    var image: CGImage?
    var originalBytes: Int64
    var isVideo: Bool
    var onClose: () -> Void
    var onApplyImage: ((CGImage, Double, Int) -> Void)?
    var onApplyVideo: ((Double) -> Void)?

    @State private var quality: Double = 0.7
    @State private var maxEdge: Double = 2400
    @State private var bitrate: Double = 4

    var body: some View {
        EditorChrome(title: "Compress", primaryTitle: "Save", onClose: onClose, onReset: reset, onPrimary: apply) {
            VStack(spacing: 16) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 360)
                        .padding(.horizontal, 18)
                }
                Text("Original \(ByteCountFormat.string(bytes: originalBytes))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PithTheme.ink)
                if isVideo {
                    LabeledSlider(title: "Bitrate", value: $bitrate, range: 0.5...20, display: String(format: "%.1f Mbps", bitrate))
                        .padding(.horizontal, 18)
                } else {
                    LabeledSlider(title: "Quality", value: $quality, range: 0.2...0.95, display: "\(Int(quality * 100))%")
                        .padding(.horizontal, 18)
                    LabeledSlider(title: "Max edge", value: $maxEdge, range: 480...6000, display: "\(Int(maxEdge)) px")
                        .padding(.horizontal, 18)
                }
                Spacer()
            }
        }
    }

    private func reset() {
        quality = 0.7
        maxEdge = 2400
        bitrate = 4
    }

    private func apply() {
        if isVideo {
            onApplyVideo?(bitrate)
        } else if let image {
            onApplyImage?(image, quality, Int(maxEdge))
        }
    }
}

struct TrimEditor: View {
    var filename: String
    var duration: Double
    var onClose: () -> Void
    var onApply: (TrimRange) -> Void
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        EditorChrome(title: "Trim", primaryTitle: "Save", onClose: onClose, onReset: { start = 0; end = duration }, onPrimary: {
            onApply(TrimRange(startSeconds: start, endSeconds: end > start ? end : nil))
        }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(filename)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PithTheme.ink.opacity(0.7))
                Text(duration > 0 ? "Duration \(format(duration))" : "Duration unknown")
                    .font(.system(size: 12))
                    .foregroundStyle(PithTheme.ink.opacity(0.6))
                LabeledSlider(title: "Start", value: $start, range: 0...max(duration, 1), display: format(start))
                LabeledSlider(title: "End", value: $end, range: 0...max(duration, 1), display: format(end))
                Spacer()
            }
            .padding(18)
            .onAppear { if end == 0 { end = duration } }
        }
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
