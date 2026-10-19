import AppKit
import PithCore

/// Plain ⌘Z in Finder right after a Pith entry: an active session event tap that swallows the
/// key and runs Pith's undo. Everything else, including ⌘Z at any other moment, passes through.
final class UndoKeyTap {
    /// Finish date of the newest undoable entry, or nil. Read on the main run loop in the callback.
    var newestEntryDate: () -> Date? = { nil }
    var onUndo: () -> Void = {}

    /// Set after a ⌘Z undo, so the same burst never walks back into older entries.
    private(set) var lastUndoneEntryDate: Date?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isInstalled: Bool { tap != nil }

    /// Returns false when macOS refuses the tap (no Accessibility permission yet).
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
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
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    /// Records that an undo (from any route) consumed the entry finished at `date`.
    func noteUndone(entryDate: Date?) {
        guard let entryDate else { return }
        lastUndoneEntryDate = max(lastUndoneEntryDate ?? entryDate, entryDate)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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
