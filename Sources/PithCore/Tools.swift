public enum ToolID: String, Codable, Sendable, Equatable, CaseIterable {
    case compress
    case metadata
    case edit
    case annotate
    case addBackground
    case crop
    case redact
    case trim
    case mergePDF
    case splitPDF

    public var label: String {
        switch self {
        case .compress: return "COMPRESS"
        case .metadata: return "METADATA"
        case .edit: return "EDIT"
        case .annotate: return "ANNOTATE"
        case .addBackground: return "ADD BG"
        case .crop: return "CROP"
        case .redact: return "REDACT"
        case .trim: return "TRIM"
        case .mergePDF: return "MERGE"
        case .splitPDF: return "SPLIT"
        }
    }

    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "tag"
        case .edit: return "slider.horizontal.3"
        case .annotate: return "scribble"
        case .addBackground: return "photo"
        case .crop: return "crop"
        case .redact: return "eye"
        case .trim: return "scissors"
        case .mergePDF: return "square.stack"
        case .splitPDF: return "rectangle.split.2x1"
        }
    }
}

public struct ToolOffer: Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: ToolID
    public var isEnabled: Bool
    public var unavailableReason: String?

    public init(tool: ToolID, isEnabled: Bool = true, unavailableReason: String? = nil) {
        self.id = tool.rawValue
        self.tool = tool
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
    }
}

public enum FileActionID: String, Codable, Sendable, Equatable, CaseIterable {
    case airDrop
    case copy
    case move
    case copyPath
    case openInTerminal
    case reveal

    public var label: String {
        switch self {
        case .airDrop: return "AIRDROP"
        case .copy: return "COPY"
        case .move: return "MOVE"
        case .copyPath: return "COPY PATH"
        case .openInTerminal: return "TERMINAL"
        case .reveal: return "REVEAL"
        }
    }

    public var symbolName: String {
        switch self {
        case .airDrop: return "antenna.radiowaves.left.and.right"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "link"
        case .openInTerminal: return "terminal"
        case .reveal: return "magnifyingglass"
        }
    }
}

public enum ToolRegistry {
    /// Tools-wheel tools. Image tools match the reference order, clockwise from 12 o'clock.
    public static func tools(for inputs: [FileType], tools: ToolAvailability, fileCount: Int) -> [ToolOffer] {
        let kinds = Set(inputs.map(\.kind))
        if kinds.isEmpty { return [] }
        if kinds == [.image] || (kinds.count == 1 && kinds.contains(.image)) {
            return [
                ToolOffer(tool: .compress),
                ToolOffer(tool: .metadata),
                ToolOffer(tool: .edit),
                ToolOffer(tool: .annotate),
                ToolOffer(tool: .addBackground),
                ToolOffer(tool: .crop),
                ToolOffer(tool: .redact)
            ] + (fileCount >= 2 ? [ToolOffer(tool: .mergePDF)] : [])
        }
        if kinds == [.image, .pdf] {
            return [ToolOffer(tool: .mergePDF, isEnabled: fileCount >= 2, unavailableReason: fileCount >= 2 ? nil : "Drop two or more files")]
        }
        if kinds == [.video] {
            let enabled = tools.hasFFmpeg
            let reason = enabled ? nil : "Install via \(ExternalTool.ffmpeg.brewInstallLine)"
            return [
                ToolOffer(tool: .compress, isEnabled: enabled, unavailableReason: reason),
                ToolOffer(tool: .trim, isEnabled: enabled, unavailableReason: reason)
            ]
        }
        if kinds == [.pdf] || inputs.allSatisfy({ $0.kind == .pdf }) {
            return [
                ToolOffer(tool: .mergePDF, isEnabled: fileCount >= 2, unavailableReason: fileCount >= 2 ? nil : "Drop two or more PDFs"),
                ToolOffer(tool: .splitPDF, isEnabled: fileCount == 1, unavailableReason: fileCount == 1 ? nil : "Split one PDF at a time")
            ]
        }
        return []
    }

    public static func actions() -> [FileActionID] {
        FileActionID.allCases
    }
}

public struct BatchItem: Equatable, Sendable {
    public var sourcePath: String
    public var destinationPath: String

    public init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public enum BatchPlanner {
    public static func plan(
        sources: [String],
        outputExtension: String,
        location: OutputLocation,
        style: OutputNameStyle = .sameBase,
        exists: (String) -> Bool
    ) -> [BatchItem] {
        let taken = TakenPaths()
        return sources.map { source in
            let destination = OutputNamer.destination(
                sourcePath: source,
                outputExtension: outputExtension,
                location: location,
                style: style,
                exists: { exists($0) || taken.contains($0) }
            )
            taken.insert(destination)
            return BatchItem(sourcePath: source, destinationPath: destination)
        }
    }
}

private final class TakenPaths {
    private var paths = Set<String>()
    func contains(_ path: String) -> Bool { paths.contains(path) }
    func insert(_ path: String) { paths.insert(path) }
}
