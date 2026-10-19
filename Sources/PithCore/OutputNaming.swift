import Foundation

public enum OutputNameStyle: Equatable, Sendable {
    /// `Report.pdf` -> `Report.jpg`
    case sameBase
    /// `Report.pdf` + " Cropped" -> `Report Cropped.jpg`
    case suffix(String)
    /// Multi-page: page 1 keeps the plain name when `pageCount == 1`.
    /// Otherwise `Report page 1.jpg`.
    case page(number: Int, count: Int)
}

public enum OutputNamer {
    /// Next free path beside the source (or in `location`). Never returns `sourcePath`.
    /// The first collision uses the suffix `" 2"`, then `" 3"`, matching Finder's style.
    public static func destination(
        sourcePath: String,
        outputExtension: String,
        location: OutputLocation,
        style: OutputNameStyle = .sameBase,
        exists: (String) -> Bool
    ) -> String {
        let ext = outputExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let directory = outputDirectory(for: sourcePath, location: location)
        let stem = stem(for: sourcePath, style: style)
        var n = 1
        while n < 10_000 {
            let filename = n == 1 ? "\(stem).\(ext)" : "\(stem) \(n).\(ext)"
            let candidate = join(directory: directory, name: filename)
            if candidate != sourcePath && !exists(candidate) {
                return candidate
            }
            n += 1
        }
        return join(directory: directory, name: "\(stem) \(n).\(ext)")
    }

    public static func outputDirectory(for sourcePath: String, location: OutputLocation) -> String {
        switch location {
        case .besideSource:
            return parentDirectory(of: sourcePath)
        case let .directory(path):
            return path
        }
    }

    public static func parentDirectory(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    public static func baseName(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        if base.isEmpty || base == "/" {
            return url.lastPathComponent
        }
        // `notes.tar.gz` → `notes`, so extracting or re-archiving doesn't leave `notes.tar`.
        if url.lastPathComponent.lowercased().hasSuffix(".tar.gz"), base.lowercased().hasSuffix(".tar") {
            return String(base.dropLast(4))
        }
        return base
    }

    private static func stem(for sourcePath: String, style: OutputNameStyle) -> String {
        let base = baseName(of: sourcePath)
        switch style {
        case .sameBase:
            return base
        case let .suffix(suffix):
            return base + suffix
        case let .page(number, count):
            if count <= 1 { return base }
            return "\(base) page \(number)"
        }
    }

    private static func join(directory: String, name: String) -> String {
        if directory == "/" { return "/\(name)" }
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return trimmed + "/" + name
    }
}
