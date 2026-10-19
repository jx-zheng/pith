import AppKit
import Foundation
import PithCore

enum DocumentRunner {
    static func pandoc(source: URL, destination: URL, input: FileType, output: FileType, tools: ToolAvailability, runner: ProcessRunner) async throws {
        guard let pandoc = tools.pandoc else {
            throw ConversionFailure.toolMissing(PandocScripts.installHint)
        }
        var readPath = source.path
        var staging: URL?
        if input.family == "text" {
            // Pandoc has no plain-text reader; hand it the text as literal HTML paragraphs.
            let text = try String(contentsOf: source, encoding: .utf8)
            let html = FileManager.default.temporaryDirectory.appendingPathComponent("pith-text-\(UUID().uuidString).html")
            try PandocScripts.plainTextAsHTML(text).write(to: html, atomically: true, encoding: .utf8)
            readPath = html.path
            staging = html
        }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        guard let spec = PandocScripts.convert(pandoc: pandoc, input: readPath, output: destination.path, from: input, to: output) else {
            throw ConversionFailure.unsupported("Pandoc doesn't bridge \(input.label) to \(output.label).")
        }
        let (status, errorText) = try await runner.runWithError(spec)
        guard status == 0 else {
            throw ConversionFailure.toolFailed(errorText.isEmpty ? "pandoc failed." : String(errorText.suffix(500)))
        }
    }

    static func soffice(source: URL, destination: URL, format: String, infilter: String? = nil, tools: ToolAvailability, runner: ProcessRunner) async throws {
        guard let soffice = tools.soffice else {
            throw ConversionFailure.toolMissing(SofficeScripts.installHint)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pith-soffice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let spec = SofficeScripts.convert(soffice: soffice, input: source.path, outputDirectory: temp.path, format: format, infilter: infilter)
        let (status, errorText) = try await runner.runWithError(spec)
        guard status == 0 else {
            throw ConversionFailure.toolFailed(errorText.isEmpty ? "LibreOffice failed." : String(errorText.suffix(500)))
        }
        let produced = URL(fileURLWithPath: SofficeScripts.expectedOutput(input: source.path, outputDirectory: temp.path, format: format))
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if FileManager.default.fileExists(atPath: produced.path) {
            try FileManager.default.moveItem(at: produced, to: destination)
        } else if let match = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first {
            try FileManager.default.moveItem(at: match, to: destination)
        } else {
            throw ConversionFailure.writeFailed("LibreOffice didn't write an output file.")
        }
    }

    static func attributed(source: URL, destination: URL, output: FileType) throws {
        let loaded = try NSAttributedString(
            url: source,
            options: [.documentType: documentType(forPath: source.path)],
            documentAttributes: nil
        )
        let data = try loaded.data(
            from: NSRange(location: 0, length: loaded.length),
            documentAttributes: [.documentType: documentType(for: output)]
        )
        try data.write(to: destination, options: .atomic)
    }

    static func documentType(forPath path: String) -> NSAttributedString.DocumentType {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "txt": return .plain
        case "docx": return .officeOpenXML
        default: return .plain
        }
    }

    static func documentType(for type: FileType) -> NSAttributedString.DocumentType {
        switch type.family {
        case "rtf": return .rtf
        case "html": return .html
        case "text": return .plain
        case "docx": return .officeOpenXML
        default: return .plain
        }
    }
}

enum ArchiveRunner {
    static func zip(source: URL, destination: URL, runner: ProcessRunner) async throws {
        let spec = ArchiveScripts.zip(source: source.path, destinationZip: destination.path)
        try await require(spec, runner: runner, label: "ditto")
    }

    static func unzip(source: URL, destinationDirectory: URL, runner: ProcessRunner) async throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let spec = ArchiveScripts.unzip(zip: source.path, destinationDirectory: destinationDirectory.path)
        try await require(spec, runner: runner, label: "ditto")
    }

    static func tarGzip(source: URL, destination: URL, runner: ProcessRunner) async throws {
        let spec = ArchiveScripts.tarGzip(source: source.path, destination: destination.path)
        try await require(spec, runner: runner, label: "tar")
    }

    static func untar(source: URL, destinationDirectory: URL, runner: ProcessRunner) async throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let spec = ArchiveScripts.untar(archive: source.path, destinationDirectory: destinationDirectory.path)
        try await require(spec, runner: runner, label: "tar")
    }

    private static func require(_ spec: CommandSpec, runner: ProcessRunner, label: String) async throws {
        let (status, errorText) = try await runner.runWithError(spec)
        guard status == 0 else {
            throw ConversionFailure.toolFailed(errorText.isEmpty ? "\(label) failed." : String(errorText.suffix(400)))
        }
    }
}
