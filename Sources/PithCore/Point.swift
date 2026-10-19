public struct Point: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public func offset(dx: Double, dy: Double) -> Point {
        Point(x: x + dx, y: y + dy)
    }
}
