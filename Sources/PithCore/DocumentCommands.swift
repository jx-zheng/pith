import Foundation

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

    /// Reader for `type`. Pandoc has no plain-text reader, so TXT is wrapped as HTML first
    /// (`plainTextAsHTML`) and read with the HTML reader; that keeps `*`, `#` and `_` literal.
    public static func readerName(for type: FileType) -> String? {
        if type.family == "text" { return "html" }
        if type.family == "pdf" { return nil }
        return formatName(for: type)
    }

    /// `--standalone` so RTF gets its `{\rtf1` header and HTML is a full document, not a fragment.
    public static func convert(pandoc: String, input: String, output: String, from: FileType, to: FileType) -> CommandSpec? {
        guard let fromName = readerName(for: from), let toName = formatName(for: to), to.family != "pdf" else { return nil }
        var arguments = ["--from", fromName, "--to", toName, "--standalone"]
        if to.family == "html" {
            arguments += ["--metadata", "pagetitle=\(OutputNamer.baseName(of: output))"]
        }
        arguments += ["--output", output, input]
        return CommandSpec(executable: pandoc, arguments: arguments, progressOnStdout: false)
    }

    /// Plain text as minimal HTML: blank lines split paragraphs, single newlines become `<br>`.
    public static func plainTextAsHTML(_ text: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .map { "<p>" + $0.split(separator: "\n", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: "<br>\n") + "</p>" }
        return "<!doctype html>\n<html><head><meta charset=\"utf-8\"></head><body>\n" + paragraphs.joined(separator: "\n") + "\n</body></html>\n"
    }
}

public enum SofficeScripts: ExternalToolBackend {
    public static var tool: ExternalTool { .soffice }
    public static var installHint: String { "Install via \(ExternalTool.soffice.brewInstallLine)" }

    /// `infilter` forces an import filter, e.g. `writer_pdf_import` so a PDF opens in Writer
    /// (Draw is the default and can't save DOCX).
    public static func convert(soffice: String, input: String, outputDirectory: String, format: String, infilter: String? = nil) -> CommandSpec {
        var arguments = ["--headless", "--norestore", "--nolockcheck"]
        if let infilter { arguments.append("--infilter=\(infilter)") }
        arguments += ["--convert-to", format, "--outdir", outputDirectory, input]
        return CommandSpec(executable: soffice, arguments: arguments, progressOnStdout: false)
    }

    public static func importFilter(input: FileType, outputFormat: String) -> String? {
        if input.family == "pdf" && ["docx", "doc", "odt", "rtf", "txt"].contains(outputFormat) { return "writer_pdf_import" }
        return nil
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
