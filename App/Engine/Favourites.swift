import Foundation
import PithCore

/// Per-wheel favourite segment, stored by its label (e.g. "JPG"), so one setting
/// works for whatever file type is on the wheel. Settings offers the labels from
/// `FavouriteCatalog`.
enum Favourites {
    static func key(_ kind: WheelKind) -> String { "pith.favourite.\(kind.rawValue)" }

    static func label(for kind: WheelKind, defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: key(kind))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Index of the enabled segment whose label or id matches the stored favourite.
    static func index(for kind: WheelKind, in segments: [WheelSegmentModel], defaults: UserDefaults = .standard) -> Int? {
        index(matching: label(for: kind, defaults: defaults), in: segments)
    }

    static func index(matching favourite: String?, in segments: [WheelSegmentModel]) -> Int? {
        guard let wanted = favourite?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !wanted.isEmpty else { return nil }
        return segments.firstIndex {
            $0.enabled && ($0.title.lowercased() == wanted || $0.id.lowercased() == wanted)
        }
    }
}
