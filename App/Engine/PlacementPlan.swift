import CoreGraphics
import Foundation

/// Where freshly written files' Finder icons should go.
enum PlacementTarget: Equatable {
    /// Where the user let go of the drag, in Cocoa global coordinates (bottom-left origin).
    case dropPoint(CGPoint)
    /// Next to the source file's own icon, read from Finder when the output is written.
    case besideSource(URL)

    /// A drop point wins when there is one; otherwise sit next to the source's icon.
    static func resolve(drop: CGPoint?, source: URL?) -> PlacementTarget? {
        if let drop { return .dropPoint(drop) }
        if let source { return .besideSource(source) }
        return nil
    }
}

/// Builds the Finder AppleScript that moves output icons. Pure, so it can be unit-tested;
/// `FinderPlacement` runs the script. The script returns how many icons it placed.
enum PlacementPlan {
    /// Icon pitch when Finder won't tell us its icon size.
    static let defaultGap = 100

    static func script(files: [URL], target: PlacementTarget, desktopPath: String, mainScreenMaxY: CGFloat) -> String? {
        guard !files.isEmpty else { return nil }
        switch target {
        case let .dropPoint(point):
            return dropScript(files: files, point: point, desktopPath: desktopPath, mainScreenMaxY: mainScreenMaxY)
        case let .besideSource(source):
            return besideScript(files: files, source: source, desktopPath: desktopPath)
        }
    }

    /// Only outputs written into the source's own folder can sit next to its icon
    /// (outputs redirected to Downloads or a fixed folder keep Finder's placement).
    static func filesBeside(_ source: URL, among files: [URL]) -> [URL] {
        let parent = folder(of: source)
        return files.filter { folder(of: $0) == parent && $0.standardizedFileURL != source.standardizedFileURL }
    }

    private static func folder(of url: URL) -> String {
        url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func dropScript(files: [URL], point: CGPoint, desktopPath: String, mainScreenMaxY: CGFloat) -> String {
        // Finder uses a top-left origin anchored to the main screen.
        let x = Int(point.x.rounded())
        let y = Int((mainScreenMaxY - point.y).rounded())
        var lines = ["tell application \"Finder\"", "set placed to 0"]
        for (offset, file) in files.enumerated() {
            let px = x + offset * 90
            let path = escape(file.path)
            let parent = escape(file.deletingLastPathComponent().standardizedFileURL.path)
            if folder(of: file) == URL(fileURLWithPath: desktopPath).standardizedFileURL.resolvingSymlinksInPath().path {
                lines.append("""
                try
                    set desktop position of (POSIX file "\(path)" as alias) to {\(px), \(y)}
                    set placed to placed + 1
                end try
                """)
            } else {
                lines.append("""
                try
                    set theItem to (POSIX file "\(path)" as alias)
                    set theParent to (POSIX file "\(parent)" as alias)
                    repeat with w in (every Finder window)
                        try
                            if ((target of w) as alias) is theParent and (current view of w) is icon view then
                                set b to bounds of w
                                set topInset to 28
                                if (toolbar visible of w) then set topInset to 92
                                set position of item (name of (info for theItem)) of (target of w) to {\(px) - (item 1 of b), \(y) - (item 2 of b) - topInset}
                                set placed to placed + 1
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
                """)
            }
        }
        lines += ["return placed", "end tell"]
        return lines.joined(separator: "\n")
    }

    private static func besideScript(files: [URL], source: URL, desktopPath: String) -> String? {
        let outputs = filesBeside(source, among: files)
        guard !outputs.isEmpty else { return nil }
        let onDesktop = folder(of: source) == URL(fileURLWithPath: desktopPath).standardizedFileURL.resolvingSymlinksInPath().path
        // Desktop icons use `desktop position` (screen space); folder items use `position`
        // (their window's content space). Reading and writing the same property keeps the offset
        // in one coordinate space, so no window geometry is needed.
        let property = onDesktop ? "desktop position" : "position"
        var lines = [
            "tell application \"Finder\"",
            "set placed to 0",
            "set src to (POSIX file \"\(escape(source.path))\" as alias)",
            "set gap to \(defaultGap)",
            "set limitX to 100000",
        ]
        if onDesktop {
            lines.append("""
            try
                set gap to (icon size of icon view options of window of desktop) + 36
            end try
            if gap < 80 then set gap to 80
            try
                set limitX to item 3 of (bounds of window of desktop)
            end try
            """)
        } else {
            lines.append("""
            try
                set w to container window of (container of src)
                set gap to (icon size of icon view options of w) + 36
                set wb to bounds of w
                set limitX to (item 3 of wb) - (item 1 of wb)
            end try
            if gap < 80 then set gap to 80
            """)
        }
        lines.append("""
        set p to \(property) of src
        set sx to item 1 of p
        set sy to item 2 of p
        if sx < 0 or sy < 0 then return 0
        """)
        for (index, file) in outputs.enumerated() {
            let step = index + 1
            lines.append("""
            try
                set out to (POSIX file "\(escape(file.path))" as alias)
                try
                    update out
                end try
                set nx to sx + gap * \(step)
                set ny to sy
                if nx > limitX - (gap / 2) then
                    set nx to sx
                    set ny to sy + gap * \(step)
                end if
                set \(property) of out to {nx, ny}
                set placed to placed + 1
            end try
            """)
        }
        lines += ["return placed", "end tell"]
        return lines.joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
