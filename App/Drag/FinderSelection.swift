import AppKit

/// Reads the current Finder selection (including Desktop icons) via Apple Events.
/// The script is compiled once at launch. Callers that need a path before the
/// ring draws should use the cached anchor instead of blocking on this.
enum FinderSelection {
    static func paths() -> [String] {
        CompiledFinderScript.shared.pathsFromAnyQueue()
    }
}
