import AppKit
import CoreImage
import SwiftUI
import PithCore

struct AnnotateEditor: View {
    var image: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
    var onClose: () -> Void
    var onApply: ([AnnotationMark]) -> Void
    var onReplace: (([AnnotationMark]) -> Void)? = nil
    var replaceBlocker: String? = nil

    init(
        image: CGImage,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        onClose: @escaping () -> Void,
        onApply: @escaping ([AnnotationMark]) -> Void,
        onReplace: (([AnnotationMark]) -> Void)? = nil,
        replaceBlocker: String? = nil
    ) {
        self.image = image
        self.pixelWidth = pixelWidth ?? image.width
        self.pixelHeight = pixelHeight ?? image.height
        self.onClose = onClose
        self.onApply = onApply
        self.onReplace = onReplace
        self.replaceBlocker = replaceBlocker
    }

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
        EditorChrome(title: "Annotate", primaryTitle: onReplace == nil ? "Save" : "Save as New", onClose: onClose, onReset: { marks = []; draft = [] }, onPrimary: { apply(onApply) },
                     replace: onReplace.map { handler in ReplaceButton(blocker: replaceBlocker) { apply(handler) } }) {
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
            let fitted = MarkupViewport.fit(pixelWidth: pixelWidth, pixelHeight: pixelHeight, in: geo.size)
            let viewport = MarkupViewport(fitted: fitted, pixelWidth: CGFloat(pixelWidth), pixelHeight: CGFloat(pixelHeight))
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                Canvas { context, _ in
                    draw(liveMarks(), in: &context, viewport: viewport)
                }
                .allowsHitTesting(false)
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

    private func liveMarks() -> [AnnotationMark] {
        var live = marks
        if draft.count > 1 {
            let stored = tool == .arrow ? [draft[0], draft[draft.count - 1]] : draft
            live.append(AnnotationMark(kind: tool, points: stored, text: "", color: color, width: width))
        }
        return live
    }

    /// Marks stay in full-image pixels until Save. `AnnotationRenderer` runs once, on the full-resolution image.
    private func apply(_ handler: ([AnnotationMark]) -> Void) {
        handler(marks)
    }

    private func draw(_ marks: [AnnotationMark], in context: inout GraphicsContext, viewport: MarkupViewport) {
        for mark in marks {
            let color = Color(red: mark.color.r, green: mark.color.g, blue: mark.color.b)
            switch mark.kind {
            case .pen:
                let points = mark.points.map { viewport.viewPoint($0) }
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: viewport.viewLength(mark.width), lineCap: .round, lineJoin: .round)
                )
            case .arrow:
                guard mark.points.count >= 2,
                      let arrow = AnnotationGeometry.arrow(from: mark.points[0], to: mark.points[mark.points.count - 1], width: mark.width) else { continue }
                var shaft = Path()
                shaft.move(to: viewport.viewPoint(mark.points[0]))
                shaft.addLine(to: viewport.viewPoint(arrow.shaftEnd))
                context.stroke(
                    shaft,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: viewport.viewLength(mark.width), lineCap: .butt)
                )
                var head = Path()
                head.move(to: viewport.viewPoint(mark.points[mark.points.count - 1]))
                head.addLine(to: viewport.viewPoint(arrow.left))
                head.addLine(to: viewport.viewPoint(arrow.right))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            case .text:
                guard let origin = mark.points.first else { continue }
                let size = max(1, viewport.viewLength(max(18, mark.width * 8)))
                context.draw(
                    Text(mark.text)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(color),
                    at: viewport.viewPoint(origin),
                    anchor: .topLeading
                )
            }
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

    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        let x = (point.x - fitted.minX) / max(fitted.width, 1) * CGFloat(pixelWidth)
        let y = (point.y - fitted.minY) / max(fitted.height, 1) * CGFloat(pixelHeight)
        return CGPoint(x: min(max(0, x), CGFloat(pixelWidth)), y: min(max(0, y), CGFloat(pixelHeight)))
    }
}

private struct MarkupViewport {
    var fitted: CGRect
    var pixelWidth: CGFloat
    var pixelHeight: CGFloat

    func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: fitted.minX + point.x / max(pixelWidth, 1) * fitted.width,
            y: fitted.minY + point.y / max(pixelHeight, 1) * fitted.height
        )
    }

    func viewLength(_ pixels: CGFloat) -> CGFloat {
        pixels / max(pixelWidth, 1) * fitted.width
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        let origin = viewPoint(CGPoint(x: rect.minX, y: rect.minY))
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width / max(pixelWidth, 1) * fitted.width,
            height: rect.height / max(pixelHeight, 1) * fitted.height
        )
    }

    static func fit(pixelWidth: Int, pixelHeight: Int, in size: CGSize) -> CGRect {
        let aspect = CGFloat(pixelWidth) / CGFloat(max(pixelHeight, 1))
        let viewAspect = size.width / max(size.height, 1)
        if aspect > viewAspect {
            let height = size.width / max(aspect, 0.0001)
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }
}

struct RedactEditor: View {
    var image: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
    var onClose: () -> Void
    var onApply: ([CGRect]) -> Void
    var onReplace: (([CGRect]) -> Void)? = nil
    var replaceBlocker: String? = nil
    @State private var boxes: [CGRect] = []
    @State private var draft: CGRect?

    init(
        image: CGImage,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        onClose: @escaping () -> Void,
        onApply: @escaping ([CGRect]) -> Void,
        onReplace: (([CGRect]) -> Void)? = nil,
        replaceBlocker: String? = nil
    ) {
        self.image = image
        self.pixelWidth = pixelWidth ?? image.width
        self.pixelHeight = pixelHeight ?? image.height
        self.onClose = onClose
        self.onApply = onApply
        self.onReplace = onReplace
        self.replaceBlocker = replaceBlocker
    }

    var body: some View {
        EditorChrome(title: "Redact", primaryTitle: onReplace == nil ? "Save" : "Save as New", onClose: onClose, onReset: { boxes = []; draft = nil }, onPrimary: { apply(onApply) },
                     replace: onReplace.map { handler in ReplaceButton(blocker: replaceBlocker) { apply(handler) } }) {
            GeometryReader { geo in
                let fitted = MarkupViewport.fit(pixelWidth: pixelWidth, pixelHeight: pixelHeight, in: geo.size)
                let viewport = MarkupViewport(fitted: fitted, pixelWidth: CGFloat(pixelWidth), pixelHeight: CGFloat(pixelHeight))
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                    Canvas { context, _ in
                        var all = boxes
                        if let draft { all.append(draft) }
                        for box in all {
                            context.fill(Path(viewport.viewRect(box)), with: .color(.black))
                        }
                    }
                    .allowsHitTesting(false)
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

    private func apply(_ handler: ([CGRect]) -> Void) {
        handler(boxes)
    }

    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - fitted.minX) / max(fitted.width, 1) * CGFloat(pixelWidth),
            y: (point.y - fitted.minY) / max(fitted.height, 1) * CGFloat(pixelHeight)
        )
    }
}

struct MetadataEditor: View {
    var source: URL
    var rows: [(String, String)]
    var onClose: () -> Void
    var onStrip: () -> Void
    var onStripReplacing: (() -> Void)? = nil
    var replaceBlocker: String? = nil

    var body: some View {
        EditorChrome(title: "Metadata", primaryTitle: onStripReplacing == nil ? "Strip Metadata" : "Save as New", onClose: onClose, onReset: {}, onPrimary: onStrip,
                     replace: onStripReplacing.map { ReplaceButton(blocker: replaceBlocker, action: $0) }) {
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

struct ImageAdjustments: Equatable {
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var sharpness: Double
}

struct AdjustEditor: View {
    var image: CGImage
    var onClose: () -> Void
    var onApply: (ImageAdjustments) -> Void
    var onReplace: ((ImageAdjustments) -> Void)? = nil
    var replaceBlocker: String? = nil
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var sharpness: Double = 0
    /// Nil shows the source. Updated at about 30Hz while a slider moves, and immediately on release.
    @State private var shown: CGImage?
    @State private var lastPreviewAt = Date.distantPast

    var body: some View {
        EditorChrome(title: "Edit", primaryTitle: onReplace == nil ? "Save" : "Save as New", onClose: onClose, onReset: reset, onPrimary: { apply(onApply) },
                     replace: onReplace.map { handler in ReplaceButton(blocker: replaceBlocker) { apply(handler) } }) {
            VStack(spacing: 14) {
                Image(decorative: shown ?? image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(.horizontal, 18)
                VStack(spacing: 8) {
                    slider("Brightness", value: $brightness, range: -0.4...0.4, display: String(format: "%+.2f", brightness))
                    slider("Contrast", value: $contrast, range: 0.5...1.6, display: String(format: "%.2f", contrast))
                    slider("Saturation", value: $saturation, range: 0...2, display: String(format: "%.2f", saturation))
                    slider("Sharpness", value: $sharpness, range: 0...1.5, display: String(format: "%.2f", sharpness))
                }
                .padding(.horizontal, 18)
            }
            .onChange(of: adjustmentToken) { _, _ in schedulePreview() }
        }
    }

    private var adjustmentToken: ImageAdjustments {
        ImageAdjustments(brightness: brightness, contrast: contrast, saturation: saturation, sharpness: sharpness)
    }

    private var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && sharpness == 0
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        LabeledSlider(title: title, value: value, range: range, display: display) { editing in
            if !editing { renderPreview() }
        }
    }

    /// Slider events arrive faster than the preview can render. Keep up at 30Hz; release paints the final value.
    private func schedulePreview() {
        if isIdentity {
            lastPreviewAt = Date()
            shown = nil
            return
        }
        guard Date().timeIntervalSince(lastPreviewAt) >= 1.0 / 30.0 else { return }
        renderPreview()
    }

    private func renderPreview() {
        lastPreviewAt = Date()
        if isIdentity {
            shown = nil
            return
        }
        shown = ImageAdjust.render(image, brightness: brightness, contrast: contrast, saturation: saturation, sharpness: sharpness) ?? image
    }

    private func reset() {
        brightness = 0
        contrast = 1
        saturation = 1
        sharpness = 0
    }

    private func apply(_ handler: (ImageAdjustments) -> Void) {
        handler(adjustmentToken)
    }
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
