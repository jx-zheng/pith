import SwiftUI

/// Visual tokens sampled from the reference frames.
/// Segment composite over the demo wallpaper reads as #F8C888. The highlight
/// wedge median is #EB4420. The fill here is the glass tint; the desktop blur
/// supplies the rest, so the wedge shifts with the wallpaper the way the
/// original does.
enum PithTheme {
    static let wheelDiameter: CGFloat = 400
    static let innerRatio: CGFloat = 0.40
    static let gapDegrees: Double = 6.5
    static let segmentCorner: CGFloat = 18
    static let panelPadding: CGFloat = 36

    /// Glass transparency. Lower = more see-through.
    static let segmentBlurOpacity: Double = 0.55
    static let segmentTintOpacity: Double = 0.30
    static let segmentSheenOpacity: Double = 0.08
    static let highlightOpacity: Double = 0.88

    /// #EB4420
    static let highlight = Color(red: 235 / 255, green: 68 / 255, blue: 32 / 255)
    /// Slightly deeper press color for buttons.
    static let highlightDeep = Color(red: 214 / 255, green: 52 / 255, blue: 24 / 255)
    static let ink = Color(red: 0.11, green: 0.06, blue: 0.03)
    static let cream = Color(red: 1.0, green: 0.86, blue: 0.68)
    static let windowWash = Color(red: 1.0, green: 0.62, blue: 0.38)

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
