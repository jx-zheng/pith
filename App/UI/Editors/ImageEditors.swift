import AppKit
import SwiftUI
import PithCore

struct CropEditor: View {
    var image: CGImage
    var onClose: () -> Void
    var onApply: (CGImage) -> Void

    @State private var aspect: AspectPreset = .free
    @State private var crop: PixelRect

    init(image: CGImage, onClose: @escaping () -> Void, onApply: @escaping (CGImage) -> Void) {
        self.image = image
        self.onClose = onClose
        self.onApply = onApply
        _crop = State(initialValue: PixelRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    var body: some View {
        EditorChrome(title: "Crop Image", primaryTitle: "Apply", onClose: onClose, onReset: reset, onPrimary: apply) {
            VStack(spacing: 14) {
                CropCanvas(image: image, crop: $crop, aspect: aspect)
                    .padding(.horizontal, 18)
                AspectChips(presets: [.free, .square, .widescreen, .portrait, .fourThree, .threeFour], selection: $aspect)
                    .onChange(of: aspect) { _, newValue in
                        crop = CropGeometry.applying(aspect: newValue, to: crop, imageWidth: image.width, imageHeight: image.height)
                    }
                HStack(spacing: 10) {
                    Text("W").foregroundStyle(PithTheme.ink.opacity(0.7))
                    TextField("", value: widthBinding, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("H").foregroundStyle(PithTheme.ink.opacity(0.7))
                    TextField("", value: heightBinding, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("px").foregroundStyle(PithTheme.ink.opacity(0.7))
                    Spacer()
                }
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .padding(.horizontal, 18)
            }
        }
    }

    private var widthBinding: Binding<Int> {
        Binding(get: { crop.width }, set: { newValue in
            var next = crop
            next.width = max(1, newValue)
            crop = CropGeometry.applying(aspect: aspect, to: next, imageWidth: image.width, imageHeight: image.height)
        })
    }

    private var heightBinding: Binding<Int> {
        Binding(get: { crop.height }, set: { newValue in
            var next = crop
            next.height = max(1, newValue)
            if aspect == .free {
                crop = CropGeometry.clamped(next, imageWidth: image.width, imageHeight: image.height)
            } else if let ratio = aspect.ratio {
                next.width = max(1, Int((Double(next.height) * ratio).rounded()))
                crop = CropGeometry.clamped(next, imageWidth: image.width, imageHeight: image.height)
            }
        })
    }

    private func reset() {
        aspect = .free
        crop = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    private func apply() {
        if let cropped = try? ImageComposer.crop(image, to: crop) {
            onApply(cropped)
        }
    }
}

private struct CropCanvas: View {
    var image: CGImage
    @Binding var crop: PixelRect
    var aspect: AspectPreset
    @State private var dragOrigin: PixelRect?
    @State private var handle: CropHandle?

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedRect(in: geo.size)
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)
                dimmer(fitted: fitted)
                cropBorder(fitted: fitted)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(fitted: fitted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dragGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = crop
                    handle = hitHandle(at: value.startLocation, fitted: fitted)
                }
                guard let origin = dragOrigin else { return }
                let dx = Int(((value.location.x - value.startLocation.x) / max(fitted.width, 1)) * CGFloat(image.width))
                let dy = Int(((value.location.y - value.startLocation.y) / max(fitted.height, 1)) * CGFloat(image.height))
                var next = origin
                switch handle ?? .move {
                case .move:
                    next.x += dx
                    next.y += dy
                case .top:
                    next.y += dy
                    next.height -= dy
                case .bottom:
                    next.height += dy
                case .left:
                    next.x += dx
                    next.width -= dx
                case .right:
                    next.width += dx
                case .topLeft:
                    next.x += dx
                    next.width -= dx
                    next.y += dy
                    next.height -= dy
                case .topRight:
                    next.width += dx
                    next.y += dy
                    next.height -= dy
                case .bottomLeft:
                    next.x += dx
                    next.width -= dx
                    next.height += dy
                case .bottomRight:
                    next.width += dx
                    next.height += dy
                }
                next.width = max(1, next.width)
                next.height = max(1, next.height)
                crop = CropGeometry.applying(aspect: aspect, to: next, imageWidth: image.width, imageHeight: image.height)
            }
            .onEnded { _ in
                dragOrigin = nil
                handle = nil
            }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let imageAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let viewAspect = size.width / max(size.height, 1)
        if imageAspect > viewAspect {
            let height = size.width / imageAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * imageAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private func viewRect(fitted: CGRect) -> CGRect {
        let sx = fitted.width / CGFloat(max(image.width, 1))
        let sy = fitted.height / CGFloat(max(image.height, 1))
        return CGRect(
            x: fitted.minX + CGFloat(crop.x) * sx,
            y: fitted.minY + CGFloat(crop.y) * sy,
            width: CGFloat(crop.width) * sx,
            height: CGFloat(crop.height) * sy
        )
    }

    private func dimmer(fitted: CGRect) -> some View {
        let rect = viewRect(fitted: fitted)
        return Canvas { context, size in
            var area = Path(CGRect(origin: .zero, size: size))
            area.addRect(rect)
            context.fill(area, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        }
    }

    private func cropBorder(fitted: CGRect) -> some View {
        let rect = viewRect(fitted: fitted)
        return ZStack {
            Rectangle()
                .stroke(PithTheme.highlight, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            ForEach(CropHandle.allCases.filter { $0 != .move }, id: \.self) { handle in
                RoundedRectangle(cornerRadius: 1)
                    .fill(PithTheme.highlight)
                    .frame(width: handle.isCorner ? 14 : 18, height: handle.isCorner ? 14 : 5)
                    .position(handle.point(in: rect))
            }
        }
    }

    private func hitHandle(at point: CGPoint, fitted: CGRect) -> CropHandle {
        let rect = viewRect(fitted: fitted)
        for handle in CropHandle.allCases where hypot(handle.point(in: rect).x - point.x, handle.point(in: rect).y - point.y) < 18 {
            return handle
        }
        return rect.contains(point) ? .move : .bottomRight
    }
}

private enum CropHandle: CaseIterable {
    case move, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }
    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .move: return CGPoint(x: rect.midX, y: rect.midY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

struct AddBackgroundEditor: View {
    var image: CGImage
    var onClose: () -> Void
    var onApply: (CGImage) -> Void

    @State private var padding: Double = 160
    @State private var corners: Double = 24
    @State private var shadow: Double = 24
    @State private var aspect: AspectPreset = .auto
    @State private var fill: BackgroundFill = BackgroundSwatches.all[0]

    var body: some View {
        EditorChrome(title: "Add BG", primaryTitle: "Save with Background", onClose: onClose, onReset: reset, onPrimary: apply) {
            VStack(spacing: 16) {
                preview
                    .padding(.horizontal, 18)
                swatches
                VStack(spacing: 8) {
                    LabeledSlider(title: "Padding", value: $padding, range: 0...800, display: "\(Int(padding)) px")
                    LabeledSlider(title: "Corners", value: $corners, range: 0...240, display: "\(Int(corners)) px")
                    LabeledSlider(title: "Shadow", value: $shadow, range: 0...80, display: "\(Int(shadow)) px")
                }
                .padding(.horizontal, 18)
                AspectChips(presets: [.auto, .square, .widescreen, .fourFive], selection: $aspect)
            }
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                fillView
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(CGFloat(padding) / 8)
                    .clipShape(RoundedRectangle(cornerRadius: corners / 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: shadow / 4, y: 4)
                    .padding(12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var fillView: some View {
        switch fill {
        case let .solid(r, g, b):
            Color(red: r, green: g, blue: b)
        case let .gradient(stops, _):
            LinearGradient(colors: stops.map { Color(red: $0.r, green: $0.g, blue: $0.b) }, startPoint: .leading, endPoint: .trailing)
        }
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PithTheme.ink)
            HStack(spacing: 8) {
                ForEach(Array(BackgroundSwatches.all.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        fill = swatch
                    } label: {
                        swatchCircle(swatch)
                            .overlay(Circle().stroke(Color.white, lineWidth: fill == swatch ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder private func swatchCircle(_ swatch: BackgroundFill) -> some View {
        switch swatch {
        case let .solid(r, g, b):
            Circle().fill(Color(red: r, green: g, blue: b)).frame(width: 26, height: 26)
        case let .gradient(stops, _):
            Circle().fill(LinearGradient(colors: stops.map { Color(red: $0.r, green: $0.g, blue: $0.b) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
        }
    }

    private func reset() {
        padding = 48
        corners = 24
        shadow = 24
        aspect = .auto
        fill = BackgroundSwatches.all[0]
    }

    private func apply() {
        if let rendered = ImageComposer.addBackground(
            image: image,
            padding: Int(padding),
            cornerRadius: corners,
            shadowRadius: shadow,
            background: fill,
            aspect: aspect
        ) {
            onApply(rendered)
        }
    }
}

enum BackgroundSwatches {
    static let all: [BackgroundFill] = [
        .gradient([RGBStop(r: 0.98, g: 0.45, b: 0.25), RGBStop(r: 0.98, g: 0.78, b: 0.28)], angle: 0),
        .gradient([RGBStop(r: 0.98, g: 0.35, b: 0.55), RGBStop(r: 0.45, g: 0.55, b: 0.98), RGBStop(r: 0.35, g: 0.85, b: 0.55)], angle: 0),
        .gradient([RGBStop(r: 0.99, g: 0.72, b: 0.78), RGBStop(r: 0.99, g: 0.86, b: 0.45)], angle: 0),
        .gradient([RGBStop(r: 0.62, g: 0.45, b: 0.95), RGBStop(r: 0.45, g: 0.7, b: 0.98)], angle: 0),
        .gradient([RGBStop(r: 0.25, g: 0.75, b: 0.45), RGBStop(r: 0.55, g: 0.9, b: 0.4)], angle: 0),
        .solid(1, 1, 1),
        .solid(0.98, 0.86, 0.22),
        .solid(0.55, 0.8, 0.28),
        .solid(0.1, 0.62, 0.45),
        .solid(0.2, 0.55, 0.95),
        .solid(0.12, 0.18, 0.45),
        .solid(0.45, 0.28, 0.85)
    ]
}
