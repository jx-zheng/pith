public enum PandocScripts: ExternalToolBackend {
    public static var tool: ExternalTool { .pandoc }
    public static var installHint: String { "Install via \(ExternalTool.pandoc.brewInstallLine)" }

    public static func formatName(for type: FileType) -> String? {
        switch type.family {
        case "docx": return "docx"
        case "markdown": return "markdown"
        case "html": return "html"
        case "epub": return "epub"
        case "text": return "plain"
        case "rtf": return "rtf"
        case "pdf": return "pdf"
        default: return nil
        }
    }

    public static func convert(pandoc: String, input: String, output: String, from: FileType, to: FileType) -> CommandSpec? {
        guard let fromName = formatName(for: from), let toName = formatName(for: to) else { return nil }
        return CommandSpec(
            executable: pandoc,
            arguments: ["--from", fromName, "--to", toName, "--output", output, input],
            progressOnStdout: false
        )
    }
}

public enum SofficeScripts: ExternalToolBackend {
    public static var tool: ExternalTool { .soffice }
    public static var installHint: String { "Install via \(ExternalTool.soffice.brewInstallLine)" }

    public static func convert(soffice: String, input: String, outputDirectory: String, format: String) -> CommandSpec {
        CommandSpec(
            executable: soffice,
            arguments: [
                "--headless",
                "--norestore",
                "--nolockcheck",
                "--convert-to", format,
                "--outdir", outputDirectory,
                input
            ],
            progressOnStdout: false
        )
    }

    /// File soffice will write into `outputDirectory` for a given input path.
    public static func expectedOutput(input: String, outputDirectory: String, format: String) -> String {
        let base = OutputNamer.baseName(of: input)
        let ext = format.split(separator: ":").first.map(String.init) ?? format
        let directory = outputDirectory.hasSuffix("/") ? String(outputDirectory.dropLast()) : outputDirectory
        if directory == "/" { return "/\(base).\(ext)" }
        return directory + "/" + base + "." + ext
    }
}

public enum ArchiveScripts {
    public static func zip(ditto: String = "/usr/bin/ditto", source: String, destinationZip: String) -> CommandSpec {
        CommandSpec(
            executable: ditto,
            arguments: ["-c", "-k", "--keepParent", source, destinationZip],
            progressOnStdout: false
        )
    }

    public static func unzip(ditto: String = "/usr/bin/ditto", zip: String, destinationDirectory: String) -> CommandSpec {
        CommandSpec(
            executable: ditto,
            arguments: ["-xk", zip, destinationDirectory],
            progressOnStdout: false
        )
    }

    public static func tarGzip(tar: String = "/usr/bin/tar", source: String, destination: String) -> CommandSpec {
        let parent = OutputNamer.parentDirectory(of: source)
        let name = URLName.lastComponent(source)
        return CommandSpec(
            executable: tar,
            arguments: ["-czf", destination, "-C", parent, name],
            progressOnStdout: false
        )
    }

    public static func untar(tar: String = "/usr/bin/tar", archive: String, destinationDirectory: String) -> CommandSpec {
        let gzip = archive.lowercased().hasSuffix(".gz") || archive.lowercased().hasSuffix(".tgz")
        let flags = gzip ? "-xzf" : "-xf"
        return CommandSpec(
            executable: tar,
            arguments: [flags, archive, "-C", destinationDirectory],
            progressOnStdout: false
        )
    }
}

enum URLName {
    static func lastComponent(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
