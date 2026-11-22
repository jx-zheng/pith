import AppKit
import PithCore

struct AnchorRead {
    var paths: [String]
    var located: LocatedIcon
}

/// Finder selection and icon geometry. Compiled once, then run off the main thread
/// so a Shift tap can draw the ring before any Apple event returns.
enum AnchorLookup {
    static func prewarm() {
        CompiledFinderScript.shared.prewarm()
    }

    static func resolve(
        mouse: CGPoint,
        mainScreenMaxY: Double,
        finderPIDs: Set<pid_t>,
        knownPaths: [String],
        completion: @escaping (AnchorRead) -> Void
    ) {
        let mouse = mouse
        let knownPaths = knownPaths
        CompiledFinderScript.shared.async {
            var snapshot = FinderIconLocator.snapshot(
                near: mouse,
                knownPaths: knownPaths,
                mainScreenMaxY: mainScreenMaxY,
                finderPIDs: finderPIDs
            )
            if snapshot.paths.isEmpty && knownPaths.isEmpty {
                let scripted = CompiledFinderScript.shared.execute()
                if !scripted.isEmpty {
                    snapshot = FinderIconLocator.snapshot(
                        near: mouse,
                        knownPaths: scripted,
                        mainScreenMaxY: mainScreenMaxY,
                        finderPIDs: finderPIDs
                    )
                    if snapshot.paths.isEmpty {
                        snapshot = FinderSnapshot(paths: scripted, located: snapshot.located)
                    }
                }
            }
            let read = AnchorRead(paths: snapshot.paths, located: snapshot.located)
            DispatchQueue.main.async {
                completion(read)
            }
        }
    }
}

/// One `NSAppleScript`, compiled on a background queue the first time Pith launches.
/// Reusing it skips the per-open OpenScripting compile and the XProtect check that
/// went with it. Execution stays on that queue, never on the main thread.
final class CompiledFinderScript: @unchecked Sendable {
    static let shared = CompiledFinderScript()

    private let queue = DispatchQueue(label: "com.kevinzheng.pith.finder-script")
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

    func prewarm() {
        queue.async { self.compileIfNeeded() }
    }

    /// For callers that are not already on the script queue. The open path does not use this.
    func pathsFromAnyQueue() -> [String] {
        queue.sync { execute() }
    }

    func async(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    /// Runs on the script queue. Callers that are already on it must use this
    /// rather than hopping again.
    func execute() -> [String] {
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
        guard !compiled else { return }
        compiled = true
        let script = NSAppleScript(source: Self.source)
        var error: NSDictionary?
        if script?.compileAndReturnError(&error) == true, error == nil {
            self.script = script
        }
    }
}
