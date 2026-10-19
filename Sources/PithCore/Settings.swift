public enum OutputLocation: Equatable, Sendable, Codable {
    case besideSource
    case directory(String)
}

public enum VideoCodecPreference: String, Codable, Sendable, Equatable, CaseIterable {
    case h264
    case hevc
}

public struct PithSettings: Equatable, Sendable, Codable {
    public var bindings: KeyBindings
    public var outputLocation: OutputLocation
    public var jpegQuality: Double
    public var heicQuality: Double
    public var pdfRenderDPI: Double
    public var ffmpegOverride: String
    public var pandocOverride: String
    public var sofficeOverride: String
    public var launchAtLogin: Bool
    public var videoCodec: VideoCodecPreference
    public var videoBitrateMbps: Double
    public var gifFramesPerSecond: Int
    public var gifMaxWidth: Int

    public init(
        bindings: KeyBindings = .default,
        outputLocation: OutputLocation = .besideSource,
        jpegQuality: Double = 0.90,
        heicQuality: Double = 0.85,
        pdfRenderDPI: Double = 300,
        ffmpegOverride: String = "",
        pandocOverride: String = "",
        sofficeOverride: String = "",
        launchAtLogin: Bool = false,
        videoCodec: VideoCodecPreference = .h264,
        videoBitrateMbps: Double = 8,
        gifFramesPerSecond: Int = 12,
        gifMaxWidth: Int = 480
    ) {
        self.bindings = bindings
        self.outputLocation = outputLocation
        self.jpegQuality = jpegQuality
        self.heicQuality = heicQuality
        self.pdfRenderDPI = pdfRenderDPI
        self.ffmpegOverride = ffmpegOverride
        self.pandocOverride = pandocOverride
        self.sofficeOverride = sofficeOverride
        self.launchAtLogin = launchAtLogin
        self.videoCodec = videoCodec
        self.videoBitrateMbps = videoBitrateMbps
        self.gifFramesPerSecond = gifFramesPerSecond
        self.gifMaxWidth = gifMaxWidth
    }

    public static let `default` = PithSettings()

    public var clampedJPEGQuality: Double { min(1, max(0.05, jpegQuality)) }
    public var clampedHEICQuality: Double { min(1, max(0.05, heicQuality)) }
}

public struct ToolAvailability: Equatable, Sendable, Codable {
    public var ffmpeg: String?
    public var ffprobe: String?
    public var pandoc: String?
    public var soffice: String?

    public init(ffmpeg: String? = nil, ffprobe: String? = nil, pandoc: String? = nil, soffice: String? = nil) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.pandoc = pandoc
        self.soffice = soffice
    }

    public static let none = ToolAvailability()

    public var hasFFmpeg: Bool { ffmpeg != nil }
    public var hasPandoc: Bool { pandoc != nil }
    public var hasSoffice: Bool { soffice != nil }
}
