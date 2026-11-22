import Foundation

public enum RingOpenMode: Equatable, Sendable {
    case click
    case drag
}

/// Last icon we already measured. The open path reads this and draws immediately.
public struct CachedAnchor: Equatable, Sendable {
    public var paths: [String]
    public var center: Point
    public var grab: Point?
    public var source: RingAnchorSource
    public var filename: String
    public var icon: RingRect?
    public var cell: RingRect?

    public init(
        paths: [String],
        center: Point,
        grab: Point?,
        source: RingAnchorSource,
        filename: String,
        icon: RingRect?,
        cell: RingRect?
    ) {
        self.paths = paths
        self.center = center
        self.grab = grab
        self.source = source
        self.filename = filename
        self.icon = icon
        self.cell = cell
    }
}

public struct RingOpenRequest: Equatable, Sendable {
    public var mode: RingOpenMode
    public var pointer: Point
    public var dragOrigin: Point?
    public var cache: CachedAnchor?

    public init(mode: RingOpenMode, pointer: Point, dragOrigin: Point?, cache: CachedAnchor?) {
        self.mode = mode
        self.pointer = pointer
        self.dragOrigin = dragOrigin
        self.cache = cache
    }
}

public struct RingFirstPosition: Equatable, Sendable {
    public var center: Point
    public var source: RingAnchorSource
    public var reason: String
    /// True when the first frame is the pointer because no icon position was cached.
    /// A later lookup may not move it farther than `RingOpenPosition.jumpLimit`.
    public var provisionalPointer: Bool

    public init(center: Point, source: RingAnchorSource, reason: String, provisionalPointer: Bool) {
        self.center = center
        self.source = source
        self.reason = reason
        self.provisionalPointer = provisionalPointer
    }
}

public enum RingRefine: Equatable, Sendable {
    case stay(String)
    case move(Point, String)
}

/// Where the ring is on the first frame, and whether a later measurement may move it.
///
/// A cached icon (or a drag offset from one) is preferred over the pointer so the
/// ring does not appear under the cursor and then jump. A lookup that finishes
/// afterwards may nudge within `jumpLimit`. A provisional pointer stays put when
/// the correction would be larger than that, unless `allowLongMove` says the
/// selection itself changed.
public enum RingOpenPosition {
    /// About a large Finder icon. Farther than this reads as a jump.
    public static let jumpLimit: Double = 192
    /// Same budget `DragGrab` uses for a drag image that is still the grabbed icon.
    public static let dragOffsetLimit: Double = 400

    public static func first(_ request: RingOpenRequest) -> RingFirstPosition {
        switch request.mode {
        case .drag:
            let grab = request.cache?.grab ?? request.dragOrigin
            if let cache = request.cache, let grab,
               let offset = DragGrab.offset(iconCenter: cache.center, grab: grab, limit: dragOffsetLimit) {
                let center = DragGrab.center(pointer: request.pointer, offset: offset)
                return RingFirstPosition(
                    center: center,
                    source: .dragOffset,
                    reason: "cached-offset",
                    provisionalPointer: false
                )
            }
            return RingFirstPosition(
                center: request.pointer,
                source: .pointer,
                reason: "pointer-pending",
                provisionalPointer: true
            )
        case .click:
            if let cache = request.cache {
                return RingFirstPosition(
                    center: cache.center,
                    source: cache.source,
                    reason: "cached-selection",
                    provisionalPointer: false
                )
            }
            return RingFirstPosition(
                center: request.pointer,
                source: .pointer,
                reason: "pointer-pending",
                provisionalPointer: true
            )
        }
    }

    public static func refine(
        shown: Point,
        provisionalPointer: Bool,
        proposed: Point,
        allowLongMove: Bool,
        jumpLimit: Double = RingOpenPosition.jumpLimit
    ) -> RingRefine {
        let dx = proposed.x - shown.x
        let dy = proposed.y - shown.y
        let limit = jumpLimit > 0 ? jumpLimit : Self.jumpLimit
        if dx * dx + dy * dy <= 1 {
            return .stay("already-there")
        }
        if dx * dx + dy * dy <= limit * limit {
            return .move(proposed, "refine")
        }
        if allowLongMove {
            return .move(proposed, "reanchor")
        }
        if provisionalPointer {
            return .stay("keep-pointer")
        }
        return .stay("keep-anchor")
    }
}

/// Log lines the owner filters with `subsystem == "com.kevinzheng.pith"`.
public enum LatencyMark {
    public static func key(_ action: String) -> String {
        "latency \(action) key"
    }

    public static func show(_ action: String) -> String {
        "latency \(action) show"
    }

    public static func frame(_ action: String, keyToFrameMilliseconds: Double) -> String {
        String(format: "latency %@ key->frame=%.1fms", action, keyToFrameMilliseconds)
    }
}
