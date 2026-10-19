import SwiftUI
import PithCore

/// Rounded annular wedge. Angles match `WheelGeometry`: 0 is east, positive
/// sweeps clockwise on screen, segment 0 is centered at 12 o'clock.
struct AnnularSegmentShape: Shape {
    var index: Int
    var count: Int
    var innerRatio: CGFloat
    var gapRadians: Double
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard count > 0 else { return Path() }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let geometry = WheelGeometry(
            outerRadius: Double(outer),
            innerRadius: Double(inner),
            gapRadians: gapRadians,
            count: count
        )
        let angles = geometry.segmentAngles(index: index)
        return AnnularPath.rounded(
            center: center,
            inner: inner,
            outer: outer,
            start: CGFloat(angles.start),
            end: CGFloat(angles.end),
            corner: cornerRadius
        )
    }
}

enum AnnularPath {
    static func rounded(center: CGPoint, inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat, corner: CGFloat) -> Path {
        let span = max(0.01, end - start)
        let outerInset = min(corner / max(outer, 1), span * 0.28)
        let innerInset = min(corner / max(inner, 1), span * 0.28)
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + CGFloat(cos(Double(angle))) * radius,
                y: center.y + CGFloat(sin(Double(angle))) * radius
            )
        }

        var path = Path()
        let outerStart = start + outerInset
        let outerEnd = end - outerInset
        path.move(to: point(outer, outerStart))
        addArc(to: &path, radius: outer, from: outerStart, to: outerEnd, center: center)

        let radialEndOuter = point(outer, end)
        let innerEnd = point(inner, end - innerInset)
        path.addQuadCurve(to: innerEnd, control: radialEndOuter)

        addArc(to: &path, radius: inner, from: end - innerInset, to: start + innerInset, center: center)

        let radialStartInner = point(inner, start)
        path.addQuadCurve(to: point(outer, start + outerInset), control: radialStartInner)
        path.closeSubpath()
        return path
    }

    private static func addArc(to path: inout Path, radius: CGFloat, from start: CGFloat, to end: CGFloat, center: CGPoint) {
        let steps = 28
        guard steps > 0 else { return }
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let angle = start + (end - start) * t
            path.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(Double(angle))) * radius,
                y: center.y + CGFloat(sin(Double(angle))) * radius
            ))
        }
    }
}
