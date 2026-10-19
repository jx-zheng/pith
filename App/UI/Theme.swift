import SwiftUI

/// Visual tokens sampled from the reference frames.
/// Segment composite over the demo wallpaper reads as #F8C888. The highlight
/// wedge median is #EB4420. The fill here is the glass tint; the desktop blur
/// supplies the rest, so the wedge shifts with the wallpaper the way the
/// original does.
enum PithTheme {
    /// In-place wheel switch (Shift/Command/Control while a wheel is open).
    static let wheelSwitchAnimation: Animation = .spring(response: 0.34, dampingFraction: 0.82)
    static let wheelDiameter: CGFloat = 400
    static let innerRatio: CGFloat = 0.40
    static let gapDegrees: Double = 6.5
    static let segmentCorner: CGFloat = 18
    static let panelPadding: CGFloat = 36

    /// Glass transparency: lower values show more of what's behind the wheel.
    static let segmentGlassOpacity: Double = 0.44
    static let segmentTintOpacity: Double = 0.16
    static let segmentSheenOpacity: Double = 0.06
    static let highlightOpacity: Double = 0.88

    /// Accent colours follow the theme picked in Settings.
    static var accent: AccentTheme { AccentTheme.current }
    static var highlight: Color { accent.highlight }
    /// Slightly deeper press color for buttons.
    static var highlightDeep: Color { accent.deep }
    static let ink = Color(red: 0.11, green: 0.06, blue: 0.03)
    static var cream: Color { accent.tint }
    static var windowWash: Color { accent.wash }

    static let formatFont = Font.system(size: 14, weight: .bold)
    static let toolFont = Font.system(size: 11, weight: .bold)
    static let formatTracking: CGFloat = 1.8
    static let toolTracking: CGFloat = 0.7

    static var outerRadius: CGFloat { wheelDiameter / 2 }
    static var innerRadius: CGFloat { outerRadius * innerRatio }
    static var gapRadians: Double { gapDegrees * .pi / 180 }

    static var referenceBackdrop: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.96, green: 0.42, blue: 0.27),
                Color(red: 0.98, green: 0.62, blue: 0.28),
                Color(red: 0.72, green: 0.42, blue: 0.78)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct WheelSegmentModel: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String?
    var enabled: Bool
    var help: String?
}

struct DesktopBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Selectable accent palettes. `tangerine` is the original look (#EB4420).
enum AccentTheme: String, CaseIterable, Identifiable {
    case tangerine, cherry, grape, blueberry, mint, lime, graphite

    static let defaultsKey = "pithAccentTheme"

    static var current: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .tangerine
    }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    /// Hot wedge, sliders, buttons.
    var highlight: Color {
        switch self {
        case .tangerine: return Self.rgb(235, 68, 32)
        case .cherry: return Self.rgb(222, 38, 86)
        case .grape: return Self.rgb(132, 64, 214)
        case .blueberry: return Self.rgb(36, 104, 232)
        case .mint: return Self.rgb(18, 168, 140)
        case .lime: return Self.rgb(92, 172, 34)
        case .graphite: return Self.rgb(72, 76, 84)
        }
    }

    var deep: Color {
        switch self {
        case .tangerine: return Self.rgb(214, 52, 24)
        case .cherry: return Self.rgb(190, 24, 68)
        case .grape: return Self.rgb(108, 46, 186)
        case .blueberry: return Self.rgb(24, 82, 200)
        case .mint: return Self.rgb(10, 140, 116)
        case .lime: return Self.rgb(70, 144, 22)
        case .graphite: return Self.rgb(50, 54, 60)
        }
    }

    /// Glass tint on idle wedges.
    var tint: Color {
        switch self {
        case .tangerine: return Self.rgb(255, 219, 173)
        case .cherry: return Self.rgb(255, 204, 218)
        case .grape: return Self.rgb(226, 208, 255)
        case .blueberry: return Self.rgb(200, 222, 255)
        case .mint: return Self.rgb(196, 245, 230)
        case .lime: return Self.rgb(218, 245, 188)
        case .graphite: return Self.rgb(228, 230, 234)
        }
    }

    /// Editor window wash.
    var wash: Color {
        switch self {
        case .tangerine: return Self.rgb(255, 158, 97)
        case .cherry: return Self.rgb(255, 128, 160)
        case .grape: return Self.rgb(178, 136, 255)
        case .blueberry: return Self.rgb(120, 170, 255)
        case .mint: return Self.rgb(100, 220, 190)
        case .lime: return Self.rgb(160, 220, 100)
        case .graphite: return Self.rgb(170, 174, 182)
        }
    }
}
