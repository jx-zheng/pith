import AppKit
import PithCore

/// Accessibility off the main thread. The compiled Finder script runs on the main
/// thread only when that walk did not already name the selected icon, so an open
/// that Accessibility can answer sends no Apple Events.
enum AnchorLookup {
    static func resolveClick(
        mouse: CGPoint,
        mainScreenMaxY: Double,
        finderPIDs: Set<pid_t>,
        completion: @escaping (FinderSnapshot) -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            let snapshot = FinderIconLocator.snapshot(
                near: mouse,
                knownPaths: [],
                mainScreenMaxY: mainScreenMaxY,
                finderPIDs: finderPIDs
            )
            if snapshot.located.center != nil, !snapshot.paths.isEmpty {
                DispatchQueue.main.async { completion(snapshot) }
                return
            }
            DispatchQueue.main.async {
                let paths = CompiledFinderScript.shared.execute()
                guard !paths.isEmpty else {
                    completion(snapshot)
                    return
                }
                DispatchQueue.global(qos: .userInteractive).async {
                    let located = FinderIconLocator.snapshot(
                        near: mouse,
                        knownPaths: paths,
                        mainScreenMaxY: mainScreenMaxY,
                        finderPIDs: finderPIDs
                    )
                    DispatchQueue.main.async { completion(located) }
                }
            }
        }
    }

    /// Drag already knows the file paths from the pasteboard, so this is Accessibility only.
    static func resolveDrag(
        mouse: CGPoint,
        paths: [String],
        mainScreenMaxY: Double,
        finderPIDs: Set<pid_t>,
        completion: @escaping (LocatedIcon) -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            let snapshot = FinderIconLocator.snapshot(
                near: mouse,
                knownPaths: paths,
                mainScreenMaxY: mainScreenMaxY,
                finderPIDs: finderPIDs
            )
            DispatchQueue.main.async { completion(snapshot.located) }
        }
    }
}

/// One compiled `NSAppleScript`. Compile and execute both happen on the main
/// thread; Apple documents the class as main-thread-only, and a background
/// queue can deadlock the Apple Event manager against the main run loop.
/// The script is compiled once, so the XProtect check is not paid on every open.
final class CompiledFinderScript {
    static let shared = CompiledFinderScript()

    private var script: NSAppleScript?
    private var compiled = false

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

    /// Schedules the one-time compile on the main queue, after the caller returns.
    func prewarm() {
        DispatchQueue.main.async {
            self.compileIfNeeded()
        }
    }

    /// Must run on the main thread. Call it only after the ring frame is committed.
    func execute() -> [String] {
        dispatchPrecondition(condition: .onQueue(.main))
        compileIfNeeded()
        guard let script else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return [] }
        return (result.stringValue ?? "")
            .split(separator: "\n")
            .map { String($0) }
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
    }

    private func compileIfNeeded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !compiled else { return }
        compiled = true
        let script = NSAppleScript(source: Self.source)
        var error: NSDictionary?
        if script?.compileAndReturnError(&error) == true, error == nil {
            self.script = script
        }
    }
}
