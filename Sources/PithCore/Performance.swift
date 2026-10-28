import Foundation

/// Long edge of an editor preview bitmap: about twice the window, clamped to 1600...2048.
public enum PreviewDecode {
    public static let lowerBound = 1600
    public static let upperBound = 2048

    public static func maxPixelSize(windowLongEdge: Double) -> Int {
        let doubled = Int((windowLongEdge * 2).rounded())
        return min(upperBound, max(lowerBound, doubled))
    }
}

/// Drops ffmpeg progress samples that moved less than 0.5% and arrived sooner than 100ms.
public struct ProgressPublishGate: Equatable {
    public var minDelta: Double
    public var minInterval: TimeInterval
    public private(set) var lastFraction: Double?
    public private(set) var lastTime: TimeInterval?

    public init(minDelta: Double = 0.005, minInterval: TimeInterval = 0.1) {
        self.minDelta = minDelta
        self.minInterval = minInterval
    }

    /// True when `fraction` should reach the HUD. The first sample always publishes.
    public mutating func shouldPublish(_ fraction: Double, now: TimeInterval) -> Bool {
        if let lastFraction, let lastTime {
            let moved = abs(fraction - lastFraction) >= minDelta
            let aged = now - lastTime >= minInterval
            if !moved && !aged { return false }
        }
        markPublished(fraction, now: now)
        return true
    }

    public mutating func markPublished(_ fraction: Double, now: TimeInterval) {
        lastFraction = fraction
        lastTime = now
    }
}

/// When a drag monitor is allowed to read file URLs off the drag pasteboard.
public enum DragPasteboardRead: Equatable, Sendable {
    /// Idle, or a drag that already proved it isn't files. Don't touch the pasteboard.
    case skip
    /// Pressed, dragging, or wheel: read URLs only after `changeCount` moves.
    case urlsWhenChangeCountChanges
}

public enum DragPasteboardPolicy {
    public static func read(for phase: DragPhase) -> DragPasteboardRead {
        switch phase {
        case .idle, .nonFileDrag:
            return .skip
        case .pressed, .dragging, .wheel:
            return .urlsWhenChangeCountChanges
        }
    }

    public static func shouldReadURLs(phase: DragPhase, changeCount: Int, cachedChangeCount: Int) -> Bool {
        switch read(for: phase) {
        case .skip:
            return false
        case .urlsWhenChangeCountChanges:
            return changeCount != cachedChangeCount
        }
    }
}
