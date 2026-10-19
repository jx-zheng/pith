import AppKit
import Foundation
import PithCore
import UniformTypeIdentifiers

struct RecentConversion: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var subtitle: String
    var outputPaths: [String]
    var succeeded: Bool
    var date: Date
    /// Files edited in place (Save and Replace): undo puts each backup back over its original.
    var replaced: [ReplacedFile]? = nil

    var isUndoable: Bool { succeeded && (!outputPaths.isEmpty || !(replaced ?? []).isEmpty) }
}

/// The headless conversion pipeline: every conversion, tool save, merge, split and export the
/// app runs goes through here. `ConversionCenter` adds jobs, the HUD, Finder placement and
/// notifications on top; the PithEngine test suite drives this type directly.
struct ConversionEngine {
    var settings: PithSettings
    var tools: ToolAvailability
    /// Sources under this directory (drag promises, Mail attachments) write to Downloads instead.
    var temporaryDirectory: String = FileManager.default.temporaryDirectory.standardizedFileURL.path
    var downloadsDirectory: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ?? (NSHomeDirectory() + "/Downloads")
    /// Where Save and Replace keeps originals until they're undone or fall off the Recent list.
    var undoDirectory: URL = ReplaceStore.defaultDirectory

    init(settings: PithSettings, tools: ToolAvailability) {
        self.settings = settings
        self.tools = tools
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: Conversions

    func convert(_ source: URL, offer: ConversionOffer, runner: ProcessRunner, progress: @escaping (Double) -> Void = { _ in }) async throws -> [URL] {
        let input = resolvedType(of: source)
        let destination = URL(fileURLWithPath: OutputNamer.destination(
            sourcePath: source.path,
            outputExtension: offer.output.primaryExtension == "bin" ? "zip" : offer.output.primaryExtension,
            location: location(for: source),
            exists: exists
        ))
        if offer.id == "unzip" || offer.id == "untar" {
            return try await extract(source: source, offer: offer, runner: runner)
        }
        if offer.backend == .ffmpeg, input.kind == .image, offer.output.kind == .image {
            // WebP/AVIF: a still image, not a video transcode.
            try await stillImage(source, destination: destination, output: offer.output, runner: runner)
            progress(1)
            return [destination]
        }
        switch offer.backend {
        case .imageIO:
            let quality = quality(for: offer.output)
            do {
                try ImageIOBridge.convert(source: source, destination: destination, uti: offer.output.uti, quality: quality)
                progress(1)
                return [destination]
            } catch {
                let needsFFmpeg = offer.output.family == "webp" || offer.output.family == "avif"
                guard tools.ffmpeg != nil, needsFFmpeg else { throw error }
                try await MediaRunner.still(source: source, destination: destination, output: offer.output, quality: quality, tools: tools, runner: runner)
                return [destination]
            }
        case .pdfKit:
            if input.kind == .image {
                let image = try ImageIOBridge.loadOriented(source)
                return try PDFTranscoder.imageToPDF(image: image, destination: destination)
            }
            if offer.output.kind == .image {
                return try PDFTranscoder.renderPages(
                    source: source,
                    format: offer.output,
                    dpi: settings.pdfRenderDPI,
                    location: location(for: source),
                    quality: quality(for: offer.output),
                    exists: exists
                )
            }
            if offer.output.family == "docx" {
                return try PDFTranscoder.toDocx(source: source, destination: destination)
            }
            return try PDFTranscoder.extractText(source: source, destination: destination)
        case .avFoundation, .ffmpeg:
            try await MediaRunner.convert(source: source, destination: destination, output: offer.output, settings: settings, tools: tools, runner: runner, progress: progress)
            return [destination]
        case .pandoc:
            try await DocumentRunner.pandoc(source: source, destination: destination, input: input, output: offer.output, tools: tools, runner: runner)
            return [destination]
        case .libreOffice:
            let format = offer.output.family == "text" ? "txt" : offer.output.primaryExtension
            try await DocumentRunner.soffice(
                source: source,
                destination: destination,
                format: format,
                infilter: SofficeScripts.importFilter(input: input, outputFormat: format),
                tools: tools,
                runner: runner
            )
            return [destination]
        case .attributedString:
            try DocumentRunner.attributed(source: source, destination: destination, output: offer.output)
            return [destination]
        case .csv:
            _ = try await CSVConverter().run(source: source, destination: destination, context: ConversionContext())
            return [destination]
        case .subtitles:
            _ = try await SubtitleConverter().run(source: source, destination: destination, context: ConversionContext())
            return [destination]
        case .archive:
            if offer.output.family == "zip" {
                try await ArchiveRunner.zip(source: source, destination: destination, runner: runner)
            } else {
                let tarDest = URL(fileURLWithPath: OutputNamer.destination(
                    sourcePath: source.path,
                    outputExtension: "tar.gz",
                    location: location(for: source),
                    exists: exists
                ))
                try await ArchiveRunner.tarGzip(source: source, destination: tarDest, runner: runner)
                return [tarDest]
            }
            return [destination]
        }
    }

    /// Native ImageIO when it can encode the type (AVIF on recent macOS), else ffmpeg.
    private func stillImage(_ source: URL, destination: URL, output: FileType, runner: ProcessRunner) async throws {
        if ImageIOBridge.canWrite(output.uti) {
            do {
                try ImageIOBridge.convert(source: source, destination: destination, uti: output.uti, quality: quality(for: output))
                return
            } catch where tools.ffmpeg != nil {
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try await MediaRunner.still(source: source, destination: destination, output: output, quality: quality(for: output), tools: tools, runner: runner)
    }

    private func extract(source: URL, offer: ConversionOffer, runner: ProcessRunner) async throws -> [URL] {
        let base = OutputNamer.baseName(of: source.path)
        let parent = OutputNamer.outputDirectory(for: source.path, location: location(for: source))
        var n = 1
        var folder = ""
        while n < 1000 {
            let name = n == 1 ? base : "\(base) \(n)"
            let candidate = (parent == "/" ? "" : parent) + "/" + name
            if !exists(candidate) {
                folder = candidate
                break
            }
            n += 1
        }
        let destination = URL(fileURLWithPath: folder)
        if offer.id == "unzip" {
            try await ArchiveRunner.unzip(source: source, destinationDirectory: destination, runner: runner)
        } else {
            try await ArchiveRunner.untar(source: source, destinationDirectory: destination, runner: runner)
        }
        return [destination]
    }

    // MARK: Tools

    /// PDFs and images from a drop that Merge accepts, in drop order.
    static func mergeCandidates(_ urls: [URL]) -> [URL] {
        urls.filter {
            $0.pathExtension.lowercased() == "pdf" || (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) ?? false)
        }
    }

    func merge(_ urls: [URL]) throws -> [URL] {
        let pdfs = Self.mergeCandidates(urls)
        guard pdfs.count >= 2 else {
            throw ConversionFailure.unsupported("Merge needs two or more PDFs or images.")
        }
        let path = OutputNamer.destination(
            sourcePath: pdfs[0].path,
            outputExtension: "pdf",
            location: location(for: pdfs[0]),
            style: .suffix(" Merged"),
            exists: exists
        )
        return try PDFTranscoder.merge(sources: pdfs, destination: URL(fileURLWithPath: path))
    }

    func split(_ url: URL) throws -> [URL] {
        try PDFTranscoder.split(source: url, location: location(for: url), exists: exists)
    }

    /// Compress (bitrate set) or Trim (range set) for a video, keeping its container.
    /// Always ffmpeg: AVFoundation's export presets would ignore the chosen bitrate.
    func exportVideo(source: URL, trim: TrimRange?, bitrate: Double?, runner: ProcessRunner, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        guard let output = FileTypes.matching(path: source.path) else {
            throw ConversionFailure.unsupported("Unknown video type.")
        }
        var tuned = settings
        if let bitrate { tuned.videoBitrateMbps = bitrate }
        let path = OutputNamer.destination(
            sourcePath: source.path,
            outputExtension: output.primaryExtension,
            location: location(for: source),
            style: .suffix(trim == nil ? " Compressed" : " Trimmed"),
            exists: exists
        )
        let destination = URL(fileURLWithPath: path)
        try await MediaRunner.convert(
            source: source,
            destination: destination,
            output: output,
            settings: tuned,
            tools: tools,
            runner: runner,
            trim: trim,
            allowNative: false,
            progress: progress
        )
        return destination
    }

    func saveImage(_ image: CGImage, source: URL, suffix: String, fileExtension: String, uti: String, quality: Double?) throws -> URL {
        let path = OutputNamer.destination(
            sourcePath: source.path,
            outputExtension: fileExtension,
            location: location(for: source),
            style: .suffix(suffix),
            exists: exists
        )
        let url = URL(fileURLWithPath: path)
        try ImageIOBridge.write(image, to: url, uti: uti, quality: quality)
        return url
    }

    /// Annotate, Redact, Edit and Metadata keep the source's format.
    func saveKeepingFormat(_ image: CGImage, source: URL, suffix: String) throws -> URL {
        var matched = FileTypes.matching(path: source.path)
        // ImageIO can't encode every format it reads (WebP); those save as lossless PNG.
        if let type = matched, !ImageIOBridge.canWrite(type.uti) { matched = FileTypes.png }
        let ext = matched?.primaryExtension ?? "png"
        let uti = matched?.uti ?? FileTypes.png.uti
        let quality: Double?
        switch matched?.family {
        case "jpeg": quality = settings.clampedJPEGQuality
        case "heic": quality = settings.clampedHEICQuality
        default: quality = nil
        }
        return try saveImage(image, source: source, suffix: suffix, fileExtension: ext, uti: uti, quality: quality)
    }

    /// Metadata → "Clean": re-encode the pixels only, dropping EXIF, GPS, IPTC and XMP.
    func stripMetadata(_ source: URL) throws -> URL {
        let image = try ImageIOBridge.loadOriented(source)
        return try saveKeepingFormat(image, source: source, suffix: " Clean")
    }

    /// Compress for images: downscale to `maxEdge` and write a JPEG at `quality`.
    func compressImage(_ image: CGImage, source: URL, quality: Double, maxEdge: Int) throws -> URL {
        let scaled = ImageIOBridge.scaled(image, maxEdge: maxEdge)
        return try saveImage(scaled, source: source, suffix: " Compressed", fileExtension: "jpg", uti: FileTypes.jpeg.uti, quality: quality)
    }

    func crop(_ image: CGImage, source: URL, to rect: PixelRect) throws -> URL {
        let cropped = try ImageComposer.crop(image, to: rect)
        return try saveImage(cropped, source: source, suffix: " Cropped", fileExtension: "jpg", uti: FileTypes.jpeg.uti, quality: settings.clampedJPEGQuality)
    }

    func addBackground(_ composed: CGImage, source: URL) throws -> URL {
        try saveImage(composed, source: source, suffix: " Background", fileExtension: "png", uti: FileTypes.png.uti, quality: nil)
    }

    // MARK: Save and Replace

    /// Writes `image` over `source` in its own format, keeping a backup for undo.
    func replaceOriginal(_ image: CGImage, source: URL) throws -> ReplacedFile {
        let type = FileTypes.matching(path: source.path) ?? FileTypes.png
        return try ReplaceStore.replace(source, with: image, quality: quality(for: type), directory: undoDirectory)
    }

    func cropReplacing(_ image: CGImage, source: URL, to rect: PixelRect) throws -> ReplacedFile {
        try replaceOriginal(try ImageComposer.crop(image, to: rect), source: source)
    }

    func stripMetadataReplacing(_ source: URL) throws -> ReplacedFile {
        try replaceOriginal(try ImageIOBridge.loadOriented(source), source: source)
    }

    // MARK: Helpers

    func location(for source: URL) -> OutputLocation {
        if case .directory = settings.outputLocation { return settings.outputLocation }
        if source.standardizedFileURL.path.hasPrefix(temporaryDirectory) {
            return .directory(downloadsDirectory)
        }
        return .besideSource
    }

    func quality(for type: FileType) -> Double? {
        switch type.family {
        case "jpeg": return settings.clampedJPEGQuality
        case "heic": return settings.clampedHEICQuality
        default: return nil
        }
    }

    func resolvedType(of url: URL) -> FileType {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return FileTypes.folder
        }
        if let matched = FileTypes.matching(path: url.path) { return matched }
        return FileTypes.text
    }
}

/// Recent conversions and undo. Undo moves the newest successful entry's outputs to the Trash
/// and restores any originals it replaced in place.
enum RecentLog {
    static let limit = 12

    struct UndoOutcome: Equatable {
        var trashed = 0
        var restored: [String] = []
        var total: Int { trashed + restored.count }
    }

    static func record(
        _ item: RecentConversion,
        into recent: inout [RecentConversion],
        discardBackup: (ReplacedFile) -> Void = ReplaceStore.discard
    ) {
        recent.insert(item, at: 0)
        // Entries that fall off the list can no longer be undone, so their backups go too.
        for dropped in recent.dropFirst(limit) {
            (dropped.replaced ?? []).forEach(discardBackup)
        }
        recent = Array(recent.prefix(limit))
    }

    static func canUndo(_ recent: [RecentConversion]) -> Bool {
        recent.contains { $0.isUndoable }
    }

    /// The entry the next undo acts on.
    static func nextUndoable(_ recent: [RecentConversion]) -> RecentConversion? {
        recent.first { $0.isUndoable }
    }

    /// Returns how many outputs went to the Trash plus originals restored, or nil when there's nothing to undo.
    static func undoLast(
        _ recent: inout [RecentConversion],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Int? {
        undo(&recent, trash: trash)?.total
    }

    static func undo(
        _ recent: inout [RecentConversion],
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> UndoOutcome? {
        guard let index = recent.firstIndex(where: { $0.isUndoable }) else { return nil }
        let item = recent[index]
        var outcome = UndoOutcome()
        for path in item.outputPaths where FileManager.default.fileExists(atPath: path) {
            if (try? trash(URL(fileURLWithPath: path))) != nil {
                outcome.trashed += 1
            }
        }
        for replaced in item.replaced ?? [] {
            if (try? ReplaceStore.restore(replaced)) != nil {
                outcome.restored.append(URL(fileURLWithPath: replaced.original).lastPathComponent)
            }
        }
        recent.remove(at: index)
        return outcome
    }

    static func message(trashed: Int) -> String {
        trashed == 1 ? "Moved 1 file to the Trash" : "Moved \(trashed) files to the Trash"
    }

    static func message(_ outcome: UndoOutcome) -> String {
        if outcome.restored.isEmpty { return message(trashed: outcome.trashed) }
        let restored = outcome.restored.count == 1 ? "Restored \(outcome.restored[0])" : "Restored \(outcome.restored.count) originals"
        return outcome.trashed == 0 ? restored : restored + ", " + message(trashed: outcome.trashed).lowercased()
    }
}
