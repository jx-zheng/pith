import AppKit

/// Reads the current Finder selection (including Desktop icons) via Apple Events.
/// First use triggers the macOS Automation prompt ("Pith wants to control Finder").
enum FinderSelection {
    private static let source = """
    tell application "Finder"
        set sel to selection
        set out to ""
        repeat with i in sel
            set out to out & POSIX path of (i as alias) & linefeed
        end repeat
        return out
    end tell
    """

    static func paths() -> [String] {
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("Pith: Finder selection failed: %@", error)
            return []
        }
        return (result.stringValue ?? "")
            .split(separator: "\n")
            .map { String($0) }
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }
}
