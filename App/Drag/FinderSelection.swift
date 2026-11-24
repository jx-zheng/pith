import AppKit

/// Reads the current Finder selection (including Desktop icons) via Apple Events.
/// The script is compiled once. This call is main-thread-only; the open path
/// uses the cached anchor and does not wait on it.
enum FinderSelection {
    static func paths() -> [String] {
        if Thread.isMainThread {
            return CompiledFinderScript.shared.execute()
        }
        return DispatchQueue.main.sync {
            CompiledFinderScript.shared.execute()
        }
    }
}
