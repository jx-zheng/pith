import CoreGraphics
import Foundation
import ImageIO
import PithCore

/// One file overwritten by Save and Replace, and where its pre-edit copy is kept for undo.
struct ReplacedFile: Codable, Equatable {
    var original: String
    var backup: String
}

/// Save and Replace: back up the original, then swap the edited pixels in under the same name.
/// The swap uses `replaceItemAt`, so the file keeps its name, Finder tags and (because Finder keys
/// icon positions by name) its spot on the Desktop or in an icon-view window.
enum ReplaceStore {
    static let defaultDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("Pith/Undo", isDirectory: true)
    }()

    /// Why Save and Replace isn't offered for this file, or nil when it is.
    static func blocker(for source: URL) -> String? {
        guard let type = FileTypes.matching(path: source.path), type.kind == .image else {
            return "Only images can be replaced in place."
        }
        guard ImageIOBridge.canWrite(type.uti) else {
            return "macOS can't write .\(source.pathExtension.lowercased()) files, so this can't be replaced in place. Save as New writes a PNG."
        }
        if let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 1 {
            return "This file has several frames or pages; replacing it would keep only the first. Use Save as New."
        }
        guard FileManager.default.isWritableFile(atPath: source.path) else {
            return "\(source.lastPathComponent) is read-only."
        }
        return nil
    }

    /// Writes `image` over `source` in the source's own format. The original goes to `directory`/<uuid>/ first.
    static func replace(
        _ source: URL,
        with image: CGImage,
        quality: Double?,
        directory: URL = defaultDirectory
    ) throws -> ReplacedFile {
        if let reason = blocker(for: source) { throw ConversionFailure.unsupported(reason) }
        let type = FileTypes.matching(path: source.path)!
        let fm = FileManager.default
        let slot = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: slot, withIntermediateDirectories: true)
        let backup = slot.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: backup)
            try swapIn(over: source) { staged in
                try ImageIOBridge.write(image, to: staged, uti: type.uti, quality: quality)
            }
        } catch {
            try? fm.removeItem(at: slot)
            throw error
        }
        return ReplacedFile(original: source.path, backup: backup.path)
    }

    /// Undo of a replace: the backup goes back over the edited file (or back into place if it was deleted).
    static func restore(_ entry: ReplacedFile) throws {
        let fm = FileManager.default
        let original = URL(fileURLWithPath: entry.original)
        let backup = URL(fileURLWithPath: entry.backup)
        guard fm.fileExists(atPath: backup.path) else { throw CocoaError(.fileNoSuchFile) }
        if fm.fileExists(atPath: original.path) {
            try swapIn(over: original) { staged in try fm.copyItem(at: backup, to: staged) }
        } else {
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: backup, to: original)
        }
        discard(entry)
    }

    /// Deletes a backup and its per-replace folder. Only touches folders named by a UUID.
    static func discard(_ entry: ReplacedFile) {
        let slot = URL(fileURLWithPath: entry.backup).deletingLastPathComponent()
        guard UUID(uuidString: slot.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: slot)
    }

    /// Stages a file on the destination's volume, then atomically swaps it in under the same name.
    private static func swapIn(over destination: URL, write: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(destination.lastPathComponent)
        try write(staged)
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
    }
}
