import Foundation

/// Decides whether a plain ⌘Z belongs to Pith: only in Finder, right after a Pith conversion or
/// replace, and only once per entry. Everything else passes through to the frontmost app.
public enum UndoShortcut {
    /// How long after an entry finishes ⌘Z in Finder undoes it instead of Finder's last action.
    public static let window: TimeInterval = 5
    public static let finderBundleID = "com.apple.finder"
    public static let zKeyCode: Int64 = 6

    /// CGEventFlags bits (stable values from IOKit's NX_* masks).
    public static let commandMask: UInt64 = 0x0010_0000
    public static let shiftMask: UInt64 = 0x0002_0000
    public static let controlMask: UInt64 = 0x0004_0000
    public static let optionMask: UInt64 = 0x0008_0000

    /// True when `flags` hold Command and none of Shift, Control or Option.
    /// Caps Lock, Fn and the numeric-pad bit don't count.
    public static func isPlainCommand(_ flags: UInt64) -> Bool {
        flags & (commandMask | shiftMask | controlMask | optionMask) == commandMask
    }

    /// - Parameters:
    ///   - entryDate: when the newest undoable Pith entry finished, or nil when there is none.
    ///   - lastUndoneEntryDate: the finish date of the newest entry a ⌘Z already undid. Older or
    ///     equal entries are left to Finder, so a second ⌘Z goes to Finder rather than walking back
    ///     through Pith's history (⌃⌥⌘Z still does that).
    public static func shouldConsume(
        keyCode: Int64,
        flags: UInt64,
        isAutoRepeat: Bool = false,
        frontmostBundleID: String?,
        entryDate: Date?,
        lastUndoneEntryDate: Date?,
        now: Date
    ) -> Bool {
        guard keyCode == zKeyCode, isPlainCommand(flags), !isAutoRepeat else { return false }
        guard frontmostBundleID == finderBundleID else { return false }
        guard let entryDate else { return false }
        let age = now.timeIntervalSince(entryDate)
        guard age >= 0, age <= window else { return false }
        if let lastUndoneEntryDate, entryDate <= lastUndoneEntryDate { return false }
        return true
    }
}
