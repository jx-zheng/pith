import SwiftUI
import PithCore

struct WheelView: View {
    var segments: [WheelSegmentModel]
    var centerText: String
    var highlighted: Int?
    var diameter: CGFloat = PithTheme.wheelDiameter

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: 1.25)
                .padding(0.5)
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                .padding(diameter * (1 - PithTheme.innerRatio) / 2)

            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if highlighted != index {
                    wedge(index, segment)
                }
            }
            if let highlighted, segments.indices.contains(highlighted) {
                wedge(highlighted, segments[highlighted])
            }
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                label(index, segment)
            }
            centerPill
        }
        .frame(width: diameter, height: diameter)
    }

    private func wedge(_ index: Int, _ segment: WheelSegmentModel) -> some View {
        let shape = segmentShape(index)
        let isHot = highlighted == index && segment.enabled
        return ZStack {
            if isHot {
                shape.fill(PithTheme.highlight.opacity(PithTheme.highlightOpacity))
            } else {
                // Plain translucent fills. A behind-window NSVisualEffectView ignores SwiftUI
                // opacity and renders as solid grey, so it can't be used for see-through glass.
                shape.fill(Color.white.opacity(segment.enabled ? PithTheme.segmentGlassOpacity : PithTheme.segmentGlassOpacity * 0.6))
                shape.fill(PithTheme.cream.opacity(segment.enabled ? PithTheme.segmentTintOpacity : PithTheme.segmentTintOpacity * 0.5))
                shape.fill(Color.white.opacity(segment.enabled ? PithTheme.segmentSheenOpacity : PithTheme.segmentSheenOpacity * 0.5))
            }
        }
        .overlay(
            shape.stroke(Color.white.opacity(isHot ? 0.35 : 0.62), lineWidth: 1.15)
        )
        .shadow(color: .black.opacity(isHot ? 0.22 : 0.14), radius: isHot ? 14 : 10, y: 5)
        .opacity(segment.enabled ? 1 : 0.55)
    }

    private func label(_ index: Int, _ segment: WheelSegmentModel) -> some View {
        let isHot = highlighted == index && segment.enabled
        let hasIcon = segment.symbol != nil
        return VStack(spacing: hasIcon ? 3 : 0) {
            if let symbol = segment.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
            }
            Text(segment.title)
                .font(hasIcon ? PithTheme.toolFont : PithTheme.formatFont)
                .tracking(hasIcon ? PithTheme.toolTracking : PithTheme.formatTracking)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .foregroundStyle(isHot ? Color.white : PithTheme.ink.opacity(segment.enabled ? 1 : 0.45))
        .shadow(color: isHot ? .black.opacity(0.25) : .white.opacity(0.7), radius: 2)
        .frame(width: labelWidth)
        .position(labelPosition(index))
        .allowsHitTesting(false)
    }

    private var centerPill: some View {
        Text(centerText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PithTheme.ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.white.opacity(0.62))
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.75), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
            .frame(maxWidth: PithTheme.innerRadius * 1.7)
    }

    private var labelWidth: CGFloat {
        let count = max(segments.count, 1)
        return min(108, (diameter * 0.42) / CGFloat(max(count, 4)) * 3.1)
    }

    private func labelPosition(_ index: Int) -> CGPoint {
        let geometry = geometry
        let angle = geometry.segmentCenterAngle(index: index)
        let mid = (PithTheme.outerRadius + PithTheme.innerRadius) / 2
        let pulled = mid * (segments.count > 6 ? 1.02 : 0.98)
        return CGPoint(
            x: diameter / 2 + CGFloat(cos(angle)) * pulled,
            y: diameter / 2 + CGFloat(sin(angle)) * pulled
        )
    }

    private var geometry: WheelGeometry {
        WheelGeometry(
            outerRadius: Double(PithTheme.outerRadius),
            innerRadius: Double(PithTheme.innerRadius),
            gapRadians: PithTheme.gapRadians,
            count: max(segments.count, 1)
        )
    }

    private func segmentShape(_ index: Int) -> AnnularSegmentShape {
        AnnularSegmentShape(
            index: index,
            count: max(segments.count, 1),
            innerRatio: PithTheme.innerRatio,
            gapRadians: PithTheme.gapRadians,
            cornerRadius: PithTheme.segmentCorner
        )
    }
}

struct WheelContainer: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        ZStack {
            WheelView(segments: model.segments, centerText: model.centerText, highlighted: model.highlighted)
                .id(model.generation)
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: WheelSwitchEffect(scale: 0.88, angle: -14, opacity: 0, blur: 3),
                        identity: WheelSwitchEffect(scale: 1, angle: 0, opacity: 1, blur: 0)
                    ),
                    removal: .modifier(
                        active: WheelSwitchEffect(scale: 1.1, angle: 10, opacity: 0, blur: 4),
                        identity: WheelSwitchEffect(scale: 1, angle: 0, opacity: 1, blur: 0)
                    )
                ))
        }
            .scaleEffect(model.appeared ? 1 : 0.84)
            .opacity(model.appeared ? 1 : 0)
            .onAppear { play() }
            .onChange(of: model.replay) { _, _ in play() }
            .frame(width: PithTheme.wheelDiameter + PithTheme.panelPadding, height: PithTheme.wheelDiameter + PithTheme.panelPadding)
    }

    private func play() {
        model.appeared = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) {
                model.appeared = true
            }
        }
    }
}

/// Scale, spin, fade and soften a whole wheel while it swaps for another.
struct WheelSwitchEffect: ViewModifier {
    var scale: CGFloat
    var angle: Double
    var opacity: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle))
            .blur(radius: blur)
            .opacity(opacity)
    }
}

final class WheelModel: ObservableObject {
    /// Bumped on every in-place wheel switch so SwiftUI transitions old ring to new.
    @Published var generation = 0
    @Published var segments: [WheelSegmentModel] = []
    @Published var highlighted: Int?
    @Published var centerText: String = ""
    @Published var appeared = false
    @Published var replay = 0
}
