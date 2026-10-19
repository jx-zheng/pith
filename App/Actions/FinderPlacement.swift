import AppKit

/// Moves freshly written files' Finder icons to the point where the user let go.
/// Works on the Desktop and in icon-view Finder windows that aren't auto-arranged;
/// anywhere else Finder ignores the request and keeps its own placement.
enum FinderPlacement {
    /// - Parameter screenPoint: Cocoa global coordinates (origin bottom-left of the main screen).
    static func place(_ files: [URL], at screenPoint: CGPoint) {
        guard !files.isEmpty, let main = NSScreen.screens.first else { return }
        // Finder uses a top-left origin anchored to the main screen.
        let x = Int(screenPoint.x.rounded())
        let y = Int((main.frame.maxY - screenPoint.y).rounded())
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.standardizedFileURL.path
        var lines: [String] = ["tell application \"Finder\""]
        for (offset, file) in files.enumerated() {
            let px = x + offset * 90
            let path = escape(file.path)
            let parent = file.deletingLastPathComponent().standardizedFileURL.path
            if parent == desktop {
                lines.append("""
                try
                    set desktop position of (POSIX file "\(path)" as alias) to {\(px), \(y)}
                end try
                """)
            } else {
                lines.append("""
                try
                    set theItem to (POSIX file "\(path)" as alias)
                    set theParent to (POSIX file "\(escape(parent))" as alias)
                    repeat with w in (every Finder window)
                        try
                            if ((target of w) as alias) is theParent and (current view of w) is icon view then
                                set b to bounds of w
                                set sb to toolbar visible of w
                                set topInset to 28
                                if sb then set topInset to 92
                                set position of item (name of (info for theItem)) of (target of w) to {\(px) - (item 1 of b), \(y) - (item 2 of b) - topInset}
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                """)
            }
        }
        lines.append("end tell")
        let source = lines.joined(separator: "\n")
        // Give Finder a moment to notice the new file before moving its icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("Pith: placement failed: %@", error) }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
