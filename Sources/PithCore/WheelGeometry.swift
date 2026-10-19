/// Donut hit testing. Angle 0 points right, positive angles move clockwise on screen
/// (y grows downward). Segment 0 is centered at 12 o'clock.
public struct WheelGeometry: Equatable, Sendable {
    public var outerRadius: Double
    public var innerRadius: Double
    public var gapRadians: Double
    public var count: Int
    public var zeroCenter: Double

    public init(
        outerRadius: Double,
        innerRadius: Double,
        gapRadians: Double,
        count: Int,
        zeroCenter: Double = -.pi / 2
    ) {
        self.outerRadius = outerRadius
        self.innerRadius = innerRadius
        self.gapRadians = gapRadians
        self.count = count
        self.zeroCenter = zeroCenter
    }

    public func segmentAngles(index: Int) -> (start: Double, end: Double) {
        guard count > 0 else { return (0, 0) }
        let sweep = (2 * Double.pi) / Double(count)
        let mid = zeroCenter + sweep * Double(index)
        let half = max(0, (sweep - gapRadians) / 2)
        return (mid - half, mid + half)
    }

    public func segmentCenterAngle(index: Int) -> Double {
        guard count > 0 else { return zeroCenter }
        let sweep = (2 * Double.pi) / Double(count)
        return zeroCenter + sweep * Double(index)
    }

    /// `point` and `center` use screen coordinates (y down).
    public func index(at point: Point, center: Point) -> Int? {
        guard count > 0 else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = pithHypot(dx, dy)
        guard radius >= innerRadius && radius <= outerRadius else { return nil }
        let angle = pithAtan2(dy, dx)
        let sweep = (2 * Double.pi) / Double(count)
        let shifted = pithWrap0to2Pi(angle - (zeroCenter - sweep / 2))
        var index = Int(shifted / sweep)
        if index >= count { index = count - 1 }
        if index < 0 { return nil }
        let pos = shifted - Double(index) * sweep
        let margin = gapRadians / 2
        if pos < margin || pos > sweep - margin {
            return nil
        }
        return index
    }
}

public struct WheelNavigation: Equatable, Sendable {
    public var count: Int
    public var index: Int?

    public init(count: Int, index: Int? = nil) {
        self.count = count
        self.index = index
    }

    public mutating func handle(_ key: MonitorKey) -> WheelNavAction {
        guard count > 0 else { return .none }
        switch key {
        case .right, .up:
            index = ((index ?? -1) + 1) % count
            return .highlight(index!)
        case .left, .down:
            let current = index ?? 0
            index = (current - 1 + count) % count
            return .highlight(index!)
        case let .number(n):
            let target = n - 1
            guard target >= 0 && target < count else { return .none }
            index = target
            return .highlight(target)
        case .return:
            guard let index else { return .none }
            return .confirm(index)
        case .escape, .other:
            return .none
        }
    }
}

public enum WheelNavAction: Equatable, Sendable {
    case none
    case highlight(Int)
    case confirm(Int)
}
