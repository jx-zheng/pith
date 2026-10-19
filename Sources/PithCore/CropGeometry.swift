public enum AspectPreset: String, Equatable, Sendable, CaseIterable, Codable {
    case free
    case square
    case widescreen
    case portrait
    case fourThree
    case threeFour
    case fourFive
    case auto

    public var ratio: Double? {
        switch self {
        case .free, .auto: return nil
        case .square: return 1
        case .widescreen: return 16.0 / 9.0
        case .portrait: return 9.0 / 16.0
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .fourFive: return 4.0 / 5.0
        }
    }

    public var label: String {
        switch self {
        case .free: return "Free"
        case .square: return "1:1"
        case .widescreen: return "16:9"
        case .portrait: return "9:16"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .fourFive: return "4:5"
        case .auto: return "Auto"
        }
    }
}

public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum CropGeometry {
    public static func clamped(_ rect: PixelRect, imageWidth: Int, imageHeight: Int) -> PixelRect {
        let width = max(1, min(rect.width, imageWidth))
        let height = max(1, min(rect.height, imageHeight))
        let x = min(max(0, rect.x), max(0, imageWidth - width))
        let y = min(max(0, rect.y), max(0, imageHeight - height))
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    /// Locks `rect` to `ratio` (width / height), keeping the top-left and fitting inside the image.
    public static func applying(aspect: AspectPreset, to rect: PixelRect, imageWidth: Int, imageHeight: Int) -> PixelRect {
        guard let ratio = aspect.ratio, ratio > 0 else {
            return clamped(rect, imageWidth: imageWidth, imageHeight: imageHeight)
        }
        var width = max(1, rect.width)
        var height = max(1, Int((Double(width) / ratio).rounded()))
        if height > imageHeight {
            height = imageHeight
            width = max(1, Int((Double(height) * ratio).rounded()))
        }
        if width > imageWidth {
            width = imageWidth
            height = max(1, Int((Double(width) / ratio).rounded()))
        }
        return clamped(PixelRect(x: rect.x, y: rect.y, width: width, height: height), imageWidth: imageWidth, imageHeight: imageHeight)
    }
}

public struct BackgroundCanvas: Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var padding: Int
    public var aspect: AspectPreset

    public init(imageWidth: Int, imageHeight: Int, padding: Int, aspect: AspectPreset) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.padding = padding
        self.aspect = aspect
    }

    /// Canvas size after padding. `.auto` and `.free` keep the image aspect plus padding.
    public var size: (width: Int, height: Int) {
        let pad = max(0, padding)
        let baseW = imageWidth + pad * 2
        let baseH = imageHeight + pad * 2
        guard let ratio = aspect.ratio else { return (baseW, baseH) }
        let baseRatio = Double(baseW) / Double(max(1, baseH))
        if baseRatio > ratio {
            let height = Int((Double(baseW) / ratio).rounded())
            return (baseW, height)
        }
        let width = Int((Double(baseH) * ratio).rounded())
        return (width, baseH)
    }
}
