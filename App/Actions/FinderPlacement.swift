import AppKit

/// Moves freshly written files' Finder icons: to the drop point, or next to the source's icon.
/// Works on the Desktop and in icon-view Finder windows that aren't auto-arranged;
/// anywhere else Finder ignores the request and keeps its own placement.
enum FinderPlacement {
    static func place(_ files: [URL], target: PlacementTarget) {
        guard let main = NSScreen.screens.first else { return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? (NSHomeDirectory() + "/Desktop")
        guard let source = PlacementPlan.script(files: files, target: target, desktopPath: desktop, mainScreenMaxY: main.frame.maxY) else { return }
        let expected: Int
        if case let .besideSource(origin) = target {
            expected = PlacementPlan.filesBeside(origin, among: files).count
        } else {
            expected = files.count
        }
        // Finder needs a moment to notice a new file before it will move its icon. If it hasn't
        // by the first pass, try once more; setting the same position twice is harmless.
        run(source, after: 0.6, expected: expected, retries: 1)
    }

    /// - Parameter screenPoint: Cocoa global coordinates (origin bottom-left of the main screen).
    static func place(_ files: [URL], at screenPoint: CGPoint) {
        place(files, target: .dropPoint(screenPoint))
    }

    private static func run(_ source: String, after delay: Double, expected: Int, retries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("Pith: placement failed: %@", error) }
            let placed = Int(result?.int32Value ?? 0)
            if placed < expected, retries > 0 {
                run(source, after: 1.0, expected: expected, retries: retries - 1)
            }
        }
    }
}
