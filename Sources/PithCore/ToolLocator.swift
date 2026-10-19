public enum ToolLocator {
    public static func candidates(for tool: ExternalTool) -> [String] {
        switch tool {
        case .ffmpeg:
            return ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        case .ffprobe:
            return ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        case .pandoc:
            return ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]
        case .soffice:
            return [
                "/Applications/LibreOffice.app/Contents/MacOS/soffice",
                "/opt/homebrew/bin/soffice",
                "/usr/local/bin/soffice"
            ]
        }
    }

    /// `override` wins when that path exists. Otherwise the known prefixes, then `PATH`.
    public static func resolve(
        tool: ExternalTool,
        override: String?,
        pathEnvironment: String,
        exists: (String) -> Bool
    ) -> String? {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && exists(trimmed) {
                return trimmed
            }
        }
        for candidate in candidates(for: tool) where exists(candidate) {
            return candidate
        }
        let binary = tool == .soffice ? "soffice" : tool.rawValue
        for directory in pathEnvironment.split(separator: ":") {
            let path = directory.hasSuffix("/") ? "\(directory)\(binary)" : "\(directory)/\(binary)"
            if exists(path) { return path }
        }
        return nil
    }

    public static func availability(
        settings: PithSettings,
        pathEnvironment: String,
        exists: (String) -> Bool
    ) -> ToolAvailability {
        let ffmpeg = resolve(tool: .ffmpeg, override: settings.ffmpegOverride, pathEnvironment: pathEnvironment, exists: exists)
        let ffprobeOverride = sibling(of: settings.ffmpegOverride, named: "ffprobe")
        var ffprobe = resolve(tool: .ffprobe, override: ffprobeOverride, pathEnvironment: pathEnvironment, exists: exists)
        if ffprobe == nil, let ffmpeg {
            let siblingProbe = sibling(of: ffmpeg, named: "ffprobe") ?? ""
            if exists(siblingProbe) { ffprobe = siblingProbe }
        }
        let pandoc = resolve(tool: .pandoc, override: settings.pandocOverride, pathEnvironment: pathEnvironment, exists: exists)
        let soffice = resolve(tool: .soffice, override: settings.sofficeOverride, pathEnvironment: pathEnvironment, exists: exists)
        return ToolAvailability(ffmpeg: ffmpeg, ffprobe: ffprobe, pandoc: pandoc, soffice: soffice)
    }

    private static func sibling(of path: String, named name: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/") { return trimmed + name }
        let parent = OutputNamer.parentDirectory(of: trimmed)
        if parent == "/" { return "/\(name)" }
        return parent + "/" + name
    }
}
