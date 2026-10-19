import Foundation

public enum ConversionBackend: String, Codable, Sendable, Equatable {
    case imageIO
    case pdfKit
    case avFoundation
    case ffmpeg
    case pandoc
    case libreOffice
    case attributedString
    case csv
    case subtitles
    case archive
}

public struct ConversionOffer: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var symbolName: String?
    public var output: FileType
    public var backend: ConversionBackend
    public var isEnabled: Bool
    public var unavailableReason: String?

    public init(
        id: String,
        label: String,
        symbolName: String? = nil,
        output: FileType,
        backend: ConversionBackend,
        isEnabled: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.label = label
        self.symbolName = symbolName
        self.output = output
        self.backend = backend
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
    }
}

public struct ConversionContext {
    public var jpegQuality: Double
    public var heicQuality: Double
    public var pdfRenderDPI: Double
    public var tools: ToolAvailability
    public var progress: (Double) -> Void

    public init(
        jpegQuality: Double = 0.9,
        heicQuality: Double = 0.85,
        pdfRenderDPI: Double = 300,
        tools: ToolAvailability = .none,
        progress: @escaping (Double) -> Void = { _ in }
    ) {
        self.jpegQuality = jpegQuality
        self.heicQuality = heicQuality
        self.pdfRenderDPI = pdfRenderDPI
        self.tools = tools
        self.progress = progress
    }
}

public protocol Converter: AnyObject {
    var id: String { get }
    var inputTypes: [FileType] { get }
    var outputTypes: [FileType] { get }
    func run(source: URL, destination: URL, context: ConversionContext) async throws -> [URL]
}

public enum ConversionFailure: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)
    case writeFailed(String)
    case toolMissing(String)
    case toolFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case let .unreadable(message): return message
        case let .unsupported(message): return message
        case let .writeFailed(message): return message
        case let .toolMissing(message): return message
        case let .toolFailed(message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

public enum ExternalTool: String, Codable, Sendable, Equatable, CaseIterable {
    case ffmpeg
    case ffprobe
    case pandoc
    case soffice

    public var brewInstallLine: String {
        switch self {
        case .ffmpeg, .ffprobe: return "brew install ffmpeg"
        case .pandoc: return "brew install pandoc"
        case .soffice: return "brew install --cask libreoffice"
        }
    }

    public var displayName: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .ffprobe: return "ffprobe"
        case .pandoc: return "pandoc"
        case .soffice: return "LibreOffice"
        }
    }
}

/// Process-based backends (ffmpeg, pandoc, LibreOffice) implement this.
/// Argument construction is pure and tested; the app spawns the process.
public protocol ExternalToolBackend {
    static var tool: ExternalTool { get }
    static var installHint: String { get }
}

public struct CommandSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// When true, stdout is a machine-readable progress stream (ffmpeg `-progress pipe:1`).
    public var progressOnStdout: Bool

    public init(executable: String, arguments: [String], progressOnStdout: Bool) {
        self.executable = executable
        self.arguments = arguments
        self.progressOnStdout = progressOnStdout
    }
}
