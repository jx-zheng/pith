import AppKit
import PithCore

struct AnchorRead {
    var paths: [String]
    var located: LocatedIcon
}

/// Icon geometry from Accessibility, off the main thread. The Finder AppleScript
/// is not run here: `NSAppleScript` is main-thread-only, and the open path asks
/// for it only after the ring has been told to draw.
enum AnchorLookup {
    static func resolve(
        mouse: CGPoint,
        mainScreenMaxY: Double,
        finderPIDs: Set<pid_t>,
        knownPaths: [String],
        completion: @escaping (AnchorRead) -> Void
    ) {
        let mouse = mouse
        let knownPaths = knownPaths
        DispatchQueue.global(qos: .userInteractive).async {
            let snapshot = FinderIconLocator.snapshot(
                near: mouse,
                knownPaths: knownPaths,
                mainScreenMaxY: mainScreenMaxY,
                finderPIDs: finderPIDs
            )
            let read = AnchorRead(paths: snapshot.paths, located: snapshot.located)
            DispatchQueue.main.async {
                completion(read)
            }
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
