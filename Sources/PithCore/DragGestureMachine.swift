public struct DragSession: Equatable, Sendable {
    public var changeCount: Int
    public var filePaths: [String]
    public var hasFilePromise: Bool
    public var promisedTypeIdentifiers: [String]
    public var location: Point

    public init(
        changeCount: Int,
        filePaths: [String],
        hasFilePromise: Bool,
        promisedTypeIdentifiers: [String],
        location: Point
    ) {
        self.changeCount = changeCount
        self.filePaths = filePaths
        self.hasFilePromise = hasFilePromise
        self.promisedTypeIdentifiers = promisedTypeIdentifiers
        self.location = location
    }

    public var isFileDrag: Bool {
        !filePaths.isEmpty || hasFilePromise
    }
}

public enum DragPhase: Equatable, Sendable {
    case idle
    /// Mouse is down. `baselineChangeCount` is the drag pasteboard's count at mouse-down.
    /// A drag whose count has not moved since then is stale and ignored.
    case pressed(baselineChangeCount: Int)
    case nonFileDrag
    case dragging(DragSession)
    case wheel(DragSession, WheelKind)
}

public enum GestureEvent: Equatable, Sendable {
    case mouseDown(time: Double, changeCount: Int, location: Point)
    case mouseDragged(
        time: Double,
        changeCount: Int,
        location: Point,
        filePaths: [String],
        hasFilePromise: Bool,
        promisedTypeIdentifiers: [String]
    )
    case mouseUp(time: Double, location: Point)
    case flagsChanged(time: Double, flags: ModifierFlags)
    case keyDown(time: Double, key: MonitorKey)
    /// The drop was accepted by the wheel. Ends tracking so a following mouse-up is a no-op.
    case dropAccepted
}

public enum GestureEffect: Equatable, Sendable {
    case dragBegan(DragSession)
    case showWheel(WheelKind, Point, DragSession)
    case switchWheel(WheelKind, DragSession)
    case dismissWheel
    case dragEnded
    case wheelKey(MonitorKey)
    /// A trigger key was tapped while no drag is in progress (click-select mode).
    case idleTap(WheelKind)
    /// The open wheel's own trigger key was tapped again (double-tap favourite).
    case repeatTap(WheelKind)
}

public struct DragGestureMachine: Equatable {
    public private(set) var phase: DragPhase
    public var bindings: KeyBindings
    private var tap: TapDetector
    private var lastLocation: Point

    public init(bindings: KeyBindings = .default) {
        self.phase = .idle
        self.bindings = bindings
        self.tap = TapDetector(maxDuration: bindings.tapMaxDuration)
        self.lastLocation = .zero
    }

    public mutating func updateBindings(_ bindings: KeyBindings) {
        self.bindings = bindings
        tap.maxDuration = bindings.tapMaxDuration
    }

    public mutating func handle(_ event: GestureEvent) -> [GestureEffect] {
        switch event {
        case let .mouseDown(_, changeCount, location):
            lastLocation = location
            tap.reset()
            phase = .pressed(baselineChangeCount: changeCount)
            return []

        case let .mouseDragged(_, changeCount, location, filePaths, hasFilePromise, promisedTypes):
            lastLocation = location
            return handleDrag(
                changeCount: changeCount,
                location: location,
                filePaths: filePaths,
                hasFilePromise: hasFilePromise,
                promisedTypes: promisedTypes
            )

        case .mouseUp:
            return endTracking(dismissWheel: true)

        case let .flagsChanged(time, flags):
            guard let key = tap.flagsChanged(time: time, flags: flags) else { return [] }
            return handleTap(key)

        case let .keyDown(_, key):
            if tap.isHolding {
                tap.contaminateAll()
            }
            guard case .wheel = phase else { return [] }
            if key == .escape {
                return dismissWheelOnly()
            }
            return [.wheelKey(key)]

        case .dropAccepted:
            return endTracking(dismissWheel: true)
        }
    }

    private mutating func handleDrag(
        changeCount: Int,
        location: Point,
        filePaths: [String],
        hasFilePromise: Bool,
        promisedTypes: [String]
    ) -> [GestureEffect] {
        switch phase {
        case .idle:
            return []
        case let .pressed(baseline):
            if changeCount == baseline {
                return []
            }
            let session = DragSession(
                changeCount: changeCount,
                filePaths: filePaths,
                hasFilePromise: hasFilePromise,
                promisedTypeIdentifiers: promisedTypes,
                location: location
            )
            if !session.isFileDrag {
                phase = .nonFileDrag
                return []
            }
            phase = .dragging(session)
            return [.dragBegan(session)]
        case .nonFileDrag:
            return []
        case var .dragging(session):
            if changeCount != session.changeCount && (!filePaths.isEmpty || hasFilePromise) {
                session.changeCount = changeCount
                session.filePaths = filePaths
                session.hasFilePromise = hasFilePromise
                session.promisedTypeIdentifiers = promisedTypes
            }
            session.location = location
            phase = .dragging(session)
            return []
        case var .wheel(session, kind):
            session.location = location
            phase = .wheel(session, kind)
            return []
        }
    }

    private mutating func handleTap(_ key: TriggerKey) -> [GestureEffect] {
        guard let kind = bindings.wheel(for: key) else { return [] }
        switch phase {
        case let .dragging(session):
            let center = session.location
            phase = .wheel(session, kind)
            return [.showWheel(kind, center, session)]
        case let .wheel(session, current):
            if current == kind {
                return [.repeatTap(kind)]
            }
            phase = .wheel(session, kind)
            return [.switchWheel(kind, session)]
        case .idle:
            return [.idleTap(kind)]
        case .pressed, .nonFileDrag:
            return []
        }
    }

    private mutating func dismissWheelOnly() -> [GestureEffect] {
        guard case let .wheel(session, _) = phase else { return [] }
        phase = .dragging(session)
        return [.dismissWheel]
    }

    private mutating func endTracking(dismissWheel: Bool) -> [GestureEffect] {
        let ending = phase
        guard ending != .idle else {
            tap.reset()
            return []
        }
        phase = .idle
        tap.reset()
        var effects: [GestureEffect] = []
        if dismissWheel, case .wheel = ending {
            effects.append(.dismissWheel)
        }
        switch ending {
        case .dragging, .wheel, .nonFileDrag:
            effects.append(.dragEnded)
        case .idle, .pressed:
            break
        }
        return effects
    }
}
