import Foundation
import PithCore

/// Per-wheel favourite segment, stored by its label (e.g. "JPG"), so one setting
/// works for whatever file type is on the wheel.
enum Favourites {
    static func key(_ kind: WheelKind) -> String { "pith.favourite.\(kind.rawValue)" }

    static func label(for kind: WheelKind) -> String? {
        let value = UserDefaults.standard.string(forKey: key(kind))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Index of the enabled segment whose label or id matches the favourite.
    static func index(for kind: WheelKind, in segments: [WheelSegmentModel]) -> Int? {
        guard let wanted = label(for: kind)?.lowercased() else { return nil }
        return segments.firstIndex {
            $0.enabled && ($0.title.lowercased() == wanted || $0.id.lowercased() == wanted)
        }
    }
}
