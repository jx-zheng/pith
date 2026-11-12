import Foundation

/// A Finder item the accessibility tree named. An element with neither a URL
/// nor a filename is not represented here: it cannot be a positive match.
public struct FinderNamedItem: Equatable, Sendable {
    public var url: String?
    public var filename: String?
    public var frame: RingRect

    public init(url: String?, filename: String?, frame: RingRect) {
        self.url = url
        self.filename = filename
        self.frame = frame
    }
}

/// Identity match for a Shift tap or a drag grab. Fresh every call. An element
/// is kept only when its URL or filename positively names a selected path.
public enum FinderIdentity {
    public static func normalizedPath(_ raw: String) -> String {
        let decoded: String
        if raw.hasPrefix("file://") {
            decoded = URL(string: raw)?.path ?? raw
        } else {
            decoded = raw
        }
        if decoded.count > 1, decoded.hasSuffix("/") {
            return String(decoded.dropLast())
        }
        return decoded
    }

    /// `true` only for a published URL or filename that names one of `paths`.
    /// A URL that names some other file is rejected, and so is an element that
    /// publishes neither.
    public static func positivelyMatches(url: String?, filename: String?, paths: [String]) -> Bool {
        let paths = paths.map(normalizedPath).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return false }
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.filter { !$0.isEmpty }
        if let url {
            let path = normalizedPath(url)
            if !path.isEmpty {
                if paths.contains(path) { return true }
                if path.hasPrefix("/") { return false }
            }
        }
        let name = filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !name.isEmpty && names.contains(name)
    }

    /// Matches whose frame contains `pointer` come first. Otherwise the nearest
    /// center wins. Unnamed elements are already gone.
    public static func ranked(_ items: [FinderNamedItem], paths: [String], pointer: Point) -> [FinderNamedItem] {
        let matched = items.filter { positivelyMatches(url: $0.url, filename: $0.filename, paths: paths) }
        return matched.sorted { lhs, rhs in
            let leftIn = IconRingGeometry.contains(lhs.frame, point: pointer)
            let rightIn = IconRingGeometry.contains(rhs.frame, point: pointer)
            if leftIn != rightIn { return leftIn }
            let leftDistance = distanceSquared(lhs.frame.center, pointer)
            let rightDistance = distanceSquared(rhs.frame.center, pointer)
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
    }

    public static func choose(_ items: [FinderNamedItem], paths: [String], pointer: Point) -> FinderNamedItem? {
        ranked(items, paths: paths, pointer: pointer).first
    }

    private static func distanceSquared(_ a: Point, _ b: Point) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}

/// The dragged icon stays a fixed grab offset from the pointer.
public enum DragGrab {
    /// `iconCenter - grab`. Nil when that vector is as long as `limit` or longer.
    public static func offset(iconCenter: Point, grab: Point, limit: Double) -> Point? {
        let dx = iconCenter.x - grab.x
        let dy = iconCenter.y - grab.y
        guard limit > 0, dx * dx + dy * dy < limit * limit else { return nil }
        return Point(x: dx, y: dy)
    }

    public static func center(pointer: Point, offset: Point) -> Point {
        Point(x: pointer.x + offset.x, y: pointer.y + offset.y)
    }
}

public enum WheelClickDecision: Equatable, Sendable {
    case act(Int)
    case close
}

/// Click mode: a wedge with an action runs. The centre hole, a gap, a corner
/// of the panel, and a disabled wedge all close the wheel.
public enum WheelClick {
    public static func decide(index: Int?, enabled: Bool) -> WheelClickDecision {
        guard let index, enabled else { return .close }
        return .act(index)
    }
}

/// One public log line per ring placement.
public struct RingLog: Equatable, Sendable {
    public var mode: String
    public var source: RingAnchorSource
    public var filename: String
    public var icon: RingRect?
    public var cell: RingRect?
    public var pointer: Point
    public var center: Point
    public var selectedCount: Int
    public var reason: String

    public init(
        mode: String,
        source: RingAnchorSource,
        filename: String,
        icon: RingRect?,
        cell: RingRect?,
        pointer: Point,
        center: Point,
        selectedCount: Int,
        reason: String
    ) {
        self.mode = mode
        self.source = source
        self.filename = filename
        self.icon = icon
        self.cell = cell
        self.pointer = pointer
        self.center = center
        self.selectedCount = selectedCount
        self.reason = reason
    }

    public var line: String {
        String(
            format: "Pith: ring mode=%@ source=%@ file=%@ icon=%@ cell=%@ pointer=(%.1f,%.1f) center=(%.1f,%.1f) selected=%d reason=%@",
            mode,
            source.rawValue,
            filename.isEmpty ? "-" : filename,
            Self.box(icon),
            Self.box(cell),
            pointer.x, pointer.y,
            center.x, center.y,
            selectedCount,
            reason.isEmpty ? "-" : reason
        )
    }

    private static func box(_ rect: RingRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "%.0f,%.0f %.0fx%.0f", rect.x, rect.y, rect.width, rect.height)
    }
}
