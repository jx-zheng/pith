import AppKit
import PithCore

final class DragController {
    var machine: DragGestureMachine
    var onShowWheel: ((WheelKind, Point, DragSession) -> Void)?
    var onSwitchWheel: ((WheelKind, DragSession) -> Void)?
    var onDismissWheel: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onWheelKey: ((MonitorKey) -> Void)?
    /// A trigger key was tapped with no drag in progress.
    var onRepeatTap: ((WheelKind) -> Void)?
    var onIdleTap: ((WheelKind) -> Void)?
    /// Mouse-down in another app (global monitor only; clicks on Pith's own panels are excluded).
    var onGlobalMouseDown: (() -> Void)?
    /// Any key-down outside Pith, regardless of drag state.
    var onGlobalKeyDown: ((MonitorKey) -> Void)?
    /// True once a real key has been typed since the last click; used to keep
    /// click-select mode from firing while renaming a file or typing.
    private(set) var typedSinceClick = true

    private var monitors: [Any] = []
    private var lastPromiseChangeCount: Int?
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
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown:
                self.typedSinceClick = false
                self.onGlobalMouseDown?()
            case .keyDown:
                self.typedSinceClick = true
                self.onGlobalKeyDown?(self.monitorKey(from: event))
            default:
                break
            }
            self.handle(event)
        }) {
            monitors.append(monitor)
        }
        // Local monitor covers drags that start inside Pith's own windows.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
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
        let effects = machine.handle(gesture)
        for effect in effects {
            switch effect {
            case let .showWheel(kind, point, session):
                onShowWheel?(kind, point, session)
            case let .switchWheel(kind, session):
                onSwitchWheel?(kind, session)
            case .dismissWheel:
                onDismissWheel?()
            case .dragEnded:
                onDragEnded?()
            case let .wheelKey(key):
                onWheelKey?(key)
            case .dragBegan:
                break
            case let .idleTap(kind):
                onIdleTap?(kind)
            case let .repeatTap(kind):
                onRepeatTap?(kind)
            }
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
