import AppKit
import PithCore

final class DragController {
    var machine: DragGestureMachine
    var onShowWheel: ((WheelKind, Point, DragSession, Double) -> Void)?
    var onSwitchWheel: ((WheelKind, DragSession, Double) -> Void)?
    var onDismissWheel: ((GestureDismissCause) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDragBegan: ((DragSession) -> Void)?
    var onWheelKey: ((MonitorKey) -> Void)?
    /// A trigger key was tapped with no drag in progress.
    var onIdleTap: ((WheelKind, Double) -> Void)?
    /// Shift went down alone. Starts an anchor lookup, or cancels a close animation.
    var onPrefetchAnchor: (() -> Void)?
    /// Mouse-down in another app (global monitor only; clicks on Pith's own panels are excluded).
    var onGlobalMouseDown: (() -> Void)?
    /// Left mouse-up that the gesture machine did not already turn into a dismiss.
    var onUnguardedMouseUp: (() -> Void)?
    /// Right button, down or up. Global and local.
    var onRightMouse: ((Bool) -> Void)?
    /// Any key-down outside Pith, regardless of drag state.
    var onGlobalKeyDown: ((MonitorKey) -> Void)?
    /// Key-down delivered to Pith itself. Escape must dismiss even when the gesture phase has drifted.
    var onLocalKeyDown: ((MonitorKey) -> Void)?
    /// True once a real key has been typed since the last click; used to keep
    /// click-select mode from firing while renaming a file or typing.
    private(set) var typedSinceClick = true

    private var monitors: [Any] = []
    private var lastPromiseChangeCount: Int?
    /// Where the file drag began. The wheel uses this when the drag image has no icon piece.
    private(set) var fileDragOrigin: Point?
    /// Last drag-pasteboard read. URLs are refreshed only when `changeCount` moves.
    private var cached = DragPasteboardSnapshot(changeCount: 0, filePaths: [], hasFilePromise: false, promisedTypeIdentifiers: [])

    init(bindings: KeyBindings) {
        machine = DragGestureMachine(bindings: bindings)
    }

    func updateBindings(_ bindings: KeyBindings) {
        machine.updateBindings(bindings)
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .flagsChanged, .keyDown
        ]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown:
                self.typedSinceClick = false
                self.onGlobalMouseDown?()
                self.handle(event)
            case .rightMouseDown:
                self.onRightMouse?(true)
            case .rightMouseUp:
                self.onRightMouse?(false)
            case .keyDown:
                self.typedSinceClick = true
                self.onGlobalKeyDown?(self.monitorKey(from: event))
                self.handle(event)
            default:
                self.handle(event)
            }
        }) {
            monitors.append(monitor)
        }
        // Local monitor covers drags that start inside Pith's own windows.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .rightMouseDown:
                self.onRightMouse?(true)
            case .rightMouseUp:
                self.onRightMouse?(false)
            case .keyDown:
                self.onLocalKeyDown?(self.monitorKey(from: event))
                self.handle(event)
            default:
                self.handle(event)
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    func noteDropAccepted() {
        _ = machine.handle(.dropAccepted)
    }

    private func handle(_ event: NSEvent) {
        let gesture = gestureEvent(from: event)
        let time = event.timestamp
        let effects = machine.handle(gesture)
        let dismissed = effects.contains { effect in
            if case .dismissWheel = effect { return true }
            return false
        }
        for effect in effects {
            switch effect {
            case let .showWheel(kind, point, session):
                onShowWheel?(kind, point, session, time)
            case let .switchWheel(kind, session):
                onSwitchWheel?(kind, session, time)
            case .dismissWheel:
                onDismissWheel?(cause(for: gesture))
            case .dragEnded:
                fileDragOrigin = nil
                onDragEnded?()
            case let .wheelKey(key):
                onWheelKey?(key)
            case let .dragBegan(session):
                fileDragOrigin = session.location
                onDragBegan?(session)
            case let .idleTap(kind):
                onIdleTap?(kind, time)
            case .prefetchAnchor:
                onPrefetchAnchor?()
            }
        }
        if event.type == .leftMouseUp, !dismissed {
            onUnguardedMouseUp?()
        }
    }

    private func cause(for event: GestureEvent) -> GestureDismissCause {
        switch event {
        case .mouseDown:
            return .mouseDown
        case .mouseUp:
            return .mouseUp
        case .dropAccepted:
            return .dropAccepted
        case .keyDown(_, let key) where key == .escape:
            return .escape
        default:
            return .mouseUp
        }
    }

    private func gestureEvent(from event: NSEvent) -> GestureEvent {
        let time = event.timestamp
        let location = Point(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        switch event.type {
        case .leftMouseDown:
            // Baseline only. File URLs arrive on the first drag whose change count actually moves.
            let count = NSPasteboard(name: .drag).changeCount
            cached = DragPasteboardSnapshot(changeCount: count, filePaths: [], hasFilePromise: false, promisedTypeIdentifiers: [])
            lastPromiseChangeCount = nil
            return .mouseDown(time: time, changeCount: count, location: location)
        case .leftMouseDragged:
            switch machine.phase {
            case .idle, .nonFileDrag:
                return .mouseDragged(
                    time: time,
                    changeCount: cached.changeCount,
                    location: location,
                    filePaths: [],
                    hasFilePromise: false,
                    promisedTypeIdentifiers: []
                )
            case .pressed(_), .dragging(_), .wheel(_, _):
                let count = NSPasteboard(name: .drag).changeCount
                if count != cached.changeCount {
                    cached = readSnapshot()
                }
                return .mouseDragged(
                    time: time,
                    changeCount: cached.changeCount,
                    location: location,
                    filePaths: cached.filePaths,
                    hasFilePromise: cached.hasFilePromise,
                    promisedTypeIdentifiers: cached.promisedTypeIdentifiers
                )
            }
        case .leftMouseUp:
            return .mouseUp(time: time, location: location)
        case .flagsChanged:
            return .flagsChanged(time: time, flags: modifierFlags(from: event))
        case .keyDown:
            return .keyDown(time: time, key: monitorKey(from: event))
        default:
            return .keyDown(time: time, key: .other)
        }
    }

    /// Full URL read. Promise type identifiers are fetched once per change count.
    private func readSnapshot() -> DragPasteboardSnapshot {
        let snap = DragPasteboardReader.snapshot(readPromiseTypes: false)
        guard snap.hasFilePromise, lastPromiseChangeCount != snap.changeCount else { return snap }
        let detailed = DragPasteboardReader.snapshot(readPromiseTypes: true)
        lastPromiseChangeCount = snap.changeCount
        return DragPasteboardSnapshot(
            changeCount: snap.changeCount,
            filePaths: snap.filePaths,
            hasFilePromise: snap.hasFilePromise,
            promisedTypeIdentifiers: detailed.promisedTypeIdentifiers
        )
    }

    private func modifierFlags(from event: NSEvent) -> ModifierFlags {
        let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var flags = ModifierFlags()
        if raw.contains(.shift) { flags.insert(.shift) }
        if raw.contains(.command) { flags.insert(.command) }
        if raw.contains(.control) { flags.insert(.control) }
        if raw.contains(.option) { flags.insert(.option) }
        return flags
    }

    private func monitorKey(from event: NSEvent) -> MonitorKey {
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .return
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        default:
            if let raw = event.charactersIgnoringModifiers, raw.count == 1, let number = Int(raw), (1...9).contains(number) {
                return .number(number)
            }
            return .other
        }
    }
}
