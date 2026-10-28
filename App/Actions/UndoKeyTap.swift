import AppKit
import PithCore

/// Plain ⌘Z in Finder right after a Pith entry: a session event tap that swallows the
/// key and runs Pith's undo. The tap is created disabled and only enabled for
/// `UndoShortcut.window` after a conversion or replace, so it does not see every keystroke.
final class UndoKeyTap {
    /// Finish date of the newest undoable entry, or nil. Read on the main run loop in the callback.
    var newestEntryDate: () -> Date? = { nil }
    var onUndo: () -> Void = {}

    /// Set after a ⌘Z undo, so the same burst never walks back into older entries.
    private(set) var lastUndoneEntryDate: Date?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// While true, a system timeout may re-enable the tap. False once the undo window has closed.
    private var armed = false
    /// Absolute deadline (`entryDate + UndoShortcut.window`). Nil when the tap should stay quiet.
    private var listenUntil: Date?
    private var disarmTimer: Timer?

    var isInstalled: Bool { tap != nil }

    /// Returns false when macOS refuses the tap (no Accessibility permission yet).
    /// The port is left disabled until `arm` opens an undo window.
    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<UndoKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let listen = shouldListen(at: Date())
        armed = listen
        CGEvent.tapEnable(tap: port, enable: listen)
        return true
    }

    /// Listen until `entryDate + UndoShortcut.window`, then disable the tap.
    /// Called from `ConversionCenter.record` / `recordReplaced` when the entry is undoable.
    func arm(entryDate: Date) {
        listenUntil = entryDate.addingTimeInterval(UndoShortcut.window)
        guard shouldListen(at: Date()) else {
            disarmIfExpired()
            return
        }
        if install() {
            armed = true
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        scheduleDisarm()
    }

    /// Records that an undo (from any route) consumed the entry finished at `date`.
    func noteUndone(entryDate: Date?) {
        guard let entryDate else { return }
        lastUndoneEntryDate = max(lastUndoneEntryDate ?? entryDate, entryDate)
    }

    private func scheduleDisarm() {
        disarmTimer?.invalidate()
        guard let listenUntil else { return }
        let interval = listenUntil.timeIntervalSinceNow
        if interval <= 0 {
            disarmIfExpired()
            return
        }
        disarmTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.disarmIfExpired()
        }
        disarmTimer?.tolerance = 0.05
    }

    private func disarmIfExpired() {
        guard !shouldListen(at: Date()) else { return }
        armed = false
        listenUntil = nil
        disarmTimer?.invalidate()
        disarmTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func shouldListen(at now: Date) -> Bool {
        guard let listenUntil else { return false }
        return now <= listenUntil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Only revive the tap during an undo window. A programmatic disable must stay off.
            if armed, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        // Cheap checks first: almost every key stops here.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == UndoShortcut.zKeyCode, UndoShortcut.isPlainCommand(event.flags.rawValue) else {
            return Unmanaged.passUnretained(event)
        }
        let entryDate = newestEntryDate()
        let consume = UndoShortcut.shouldConsume(
            keyCode: keyCode,
            flags: event.flags.rawValue,
            isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            entryDate: entryDate,
            lastUndoneEntryDate: lastUndoneEntryDate,
            now: Date()
        )
        guard consume else { return Unmanaged.passUnretained(event) }
        noteUndone(entryDate: entryDate)
        DispatchQueue.main.async { self.onUndo() }
        return nil
    }
}
