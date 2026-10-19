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
}

enum EditorRequest {
    case crop(URL)
    case addBackground(URL)
    case annotate(URL)
    case redact(URL)
    case metadata(URL)
    case adjust(URL)
    case compress([URL])
    case trim([URL])
}

final class ConversionCenter: ObservableObject {
    @Published var jobs: [HUDJob] = []
    @Published var recent: [RecentConversion] = []

    var settings: PithSettings = .default
    var tools: ToolAvailability = .none
    var presentEditor: ((EditorRequest) -> Void)?
    var onJobsChanged: (([HUDJob]) -> Void)?

    private var runners: [UUID: ProcessRunner] = [:]
    private var cancelled: Set<UUID> = []
    private let recentKey = "pith.recent.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: recentKey),
           let stored = try? JSONDecoder().decode([RecentConversion].self, from: data) {
            recent = stored
        }
    }

    func cancel(_ id: UUID) {
        cancelled.insert(id)
        runners[id]?.cancel()
    }

    func cancelAll() {
        jobs.map(\.id).forEach(cancel)
    }

    func convert(urls: [URL], offer: ConversionOffer, anchor: CGPoint) {
        guard offer.isEnabled else { return }
        let job = startJob(title: "Converting to \(offer.label)", subtitle: subtitle(for: urls), anchor: anchor)
        Task { @MainActor in
            await self.runBatch(urls: urls, job: job) { url, index, count in
                self.update(job: job, title: count > 1 ? "Converting \(index) of \(count) to \(offer.label)" : "Converting to \(offer.label)", subtitle: url.lastPathComponent, progress: Double(index - 1) / Double(count))
                return try await self.convertOne(url, offer: offer, jobID: job) { fraction in
                    let overall = (Double(index - 1) + fraction) / Double(count)
                    self.update(job: job, title: self.jobs.first { $0.id == job }?.title ?? "", subtitle: url.lastPathComponent, progress: overall)
                }
            }
        }
    }

    func runTool(_ tool: ToolID, urls: [URL]) {
        switch tool {
        case .compress:
            presentEditor?(.compress(urls))
        case .metadata:
            if let url = urls.first { presentEditor?(.metadata(url)) }
        case .edit:
            if let url = urls.first { presentEditor?(.adjust(url)) }
        case .annotate:
            if let url = urls.first { presentEditor?(.annotate(url)) }
        case .addBackground:
            if let url = urls.first { presentEditor?(.addBackground(url)) }
        case .crop:
            if let url = urls.first { presentEditor?(.crop(url)) }
        case .redact:
            if let url = urls.first { presentEditor?(.redact(url)) }
        case .trim:
            presentEditor?(.trim(urls))
        case .mergePDF:
            merge(urls)
        case .splitPDF:
            if let url = urls.first { split(url) }
        }
    }

    func saveEditedImage(_ image: CGImage, source: URL, suffix: String, fileExtension: String, uti: String, quality: Double?) throws -> URL {
        let path = OutputNamer.destination(
            sourcePath: source.path,
            outputExtension: fileExtension,
            location: location(for: source),
            style: .suffix(suffix),
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        let url = URL(fileURLWithPath: path)
        try ImageIOBridge.write(image, to: url, uti: uti, quality: quality)
        finishSuccess(title: "Saved \(url.lastPathComponent)", subtitle: source.lastPathComponent, paths: [url])
        return url
    }

    func exportVideo(source: URL, trim: TrimRange?, bitrate: Double?, anchor: CGPoint) {
        guard let output = FileTypes.matching(path: source.path) else { return }
        var tuned = settings
        if let bitrate { tuned.videoBitrateMbps = bitrate }
        let job = startJob(title: trim == nil ? "Compressing" : "Trimming", subtitle: source.lastPathComponent, anchor: anchor)
        Task { @MainActor in
            do {
                try self.throwIfCancelled(job)
                let path = OutputNamer.destination(
                    sourcePath: source.path,
                    outputExtension: output.primaryExtension,
                    location: self.location(for: source),
                    style: .suffix(trim == nil ? " Compressed" : " Trimmed"),
                    exists: { FileManager.default.fileExists(atPath: $0) }
                )
                let destination = URL(fileURLWithPath: path)
                let runner = self.makeRunner(job)
                try await MediaRunner.convert(
                    source: source,
                    destination: destination,
                    output: output,
                    settings: tuned,
                    tools: self.tools,
                    runner: runner,
                    trim: trim
                ) { fraction in
                    Task { @MainActor in
                        self.update(job: job, title: trim == nil ? "Compressing" : "Trimming", subtitle: source.lastPathComponent, progress: fraction)
                    }
                }
                self.finishJob(job, title: "Saved \(destination.lastPathComponent)", subtitle: source.lastPathComponent, paths: [destination], success: true)
            } catch {
                self.finishJob(job, title: "Couldn't process \(source.lastPathComponent)", subtitle: error.localizedDescription, paths: [], success: false)
            }
        }
    }

    private func merge(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard pdfs.count >= 2 else { return }
        let anchor = NSEvent.mouseLocation
        let job = startJob(title: "Merging PDFs", subtitle: "\(pdfs.count) files", anchor: anchor)
        Task { @MainActor in
            do {
                let path = OutputNamer.destination(
                    sourcePath: pdfs[0].path,
                    outputExtension: "pdf",
                    location: self.location(for: pdfs[0]),
                    style: .suffix(" Merged"),
                    exists: { FileManager.default.fileExists(atPath: $0) }
                )
                let destination = URL(fileURLWithPath: path)
                let outputs = try PDFTranscoder.merge(sources: pdfs, destination: destination)
                self.finishJob(job, title: "Merged \(pdfs.count) PDFs", subtitle: destination.lastPathComponent, paths: outputs, success: true)
            } catch {
                self.finishJob(job, title: "Couldn't merge PDFs", subtitle: error.localizedDescription, paths: [], success: false)
            }
        }
    }

    private func split(_ url: URL) {
        let anchor = NSEvent.mouseLocation
        let job = startJob(title: "Splitting PDF", subtitle: url.lastPathComponent, anchor: anchor)
        Task { @MainActor in
            do {
                let outputs = try PDFTranscoder.split(source: url, location: self.location(for: url), exists: { FileManager.default.fileExists(atPath: $0) })
                self.finishJob(job, title: "Split into \(outputs.count) PDFs", subtitle: url.lastPathComponent, paths: outputs, success: true)
            } catch {
                self.finishJob(job, title: "Couldn't split PDF", subtitle: error.localizedDescription, paths: [], success: false)
            }
        }
    }

    private func runBatch(urls: [URL], job: UUID, work: (URL, Int, Int) async throws -> [URL]) async {
        var outputs: [URL] = []
        do {
            for (offset, url) in urls.enumerated() {
                try throwIfCancelled(job)
                let written = try await work(url, offset + 1, urls.count)
                outputs.append(contentsOf: written)
            }
            let title = urls.count == 1 ? "Converted \(urls[0].lastPathComponent)" : "Converted \(urls.count) files"
            finishJob(job, title: title, subtitle: outputs.last?.lastPathComponent ?? "", paths: outputs, success: true)
        } catch {
            finishJob(job, title: "Conversion failed", subtitle: error.localizedDescription, paths: outputs, success: false)
        }
    }

    private func convertOne(_ source: URL, offer: ConversionOffer, jobID: UUID, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let input = resolvedType(of: source)
        let destination = URL(fileURLWithPath: OutputNamer.destination(
            sourcePath: source.path,
            outputExtension: offer.output.primaryExtension == "bin" ? "zip" : offer.output.primaryExtension,
            location: location(for: source),
            exists: { FileManager.default.fileExists(atPath: $0) }
        ))
        if offer.id == "unzip" || offer.id == "untar" {
            return try await extract(source: source, offer: offer, jobID: jobID)
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
                try await MediaRunner.still(source: source, destination: destination, quality: quality, tools: tools, runner: makeRunner(jobID))
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
                    exists: { FileManager.default.fileExists(atPath: $0) }
                )
            }
            return try PDFTranscoder.extractText(source: source, destination: destination)
        case .avFoundation, .ffmpeg:
            let runner = makeRunner(jobID)
            try await MediaRunner.convert(source: source, destination: destination, output: offer.output, settings: settings, tools: tools, runner: runner, progress: progress)
            return [destination]
        case .pandoc:
            let runner = makeRunner(jobID)
            try await DocumentRunner.pandoc(source: source, destination: destination, input: input, output: offer.output, tools: tools, runner: runner)
            return [destination]
        case .libreOffice:
            let format = offer.output.family == "text" ? "txt" : offer.output.primaryExtension
            try await DocumentRunner.soffice(source: source, destination: destination, format: format, tools: tools, runner: makeRunner(jobID))
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
            let runner = makeRunner(jobID)
            if offer.output.family == "zip" {
                try await ArchiveRunner.zip(source: source, destination: destination, runner: runner)
            } else {
                let tarDest = URL(fileURLWithPath: OutputNamer.destination(
                    sourcePath: source.path,
                    outputExtension: "tar.gz",
                    location: location(for: source),
                    exists: { FileManager.default.fileExists(atPath: $0) }
                ))
                try await ArchiveRunner.tarGzip(source: source, destination: tarDest, runner: runner)
                return [tarDest]
            }
            return [destination]
        }
    }

    private func extract(source: URL, offer: ConversionOffer, jobID: UUID) async throws -> [URL] {
        let base = OutputNamer.baseName(of: source.path)
        let parent = OutputNamer.outputDirectory(for: source.path, location: location(for: source))
        var n = 1
        var folder = ""
        while n < 1000 {
            let name = n == 1 ? base : "\(base) \(n)"
            let candidate = (parent == "/" ? "" : parent) + "/" + name
            if !FileManager.default.fileExists(atPath: candidate) {
                folder = candidate
                break
            }
            n += 1
        }
        let destination = URL(fileURLWithPath: folder)
        let runner = makeRunner(jobID)
        if offer.id == "unzip" {
            try await ArchiveRunner.unzip(source: source, destinationDirectory: destination, runner: runner)
        } else {
            try await ArchiveRunner.untar(source: source, destinationDirectory: destination, runner: runner)
        }
        return [destination]
    }

    private func startJob(title: String, subtitle: String, anchor: CGPoint) -> UUID {
        let id = UUID()
        let job = HUDJob(id: id, title: title, subtitle: subtitle, progress: 0.04, anchor: anchor)
        jobs.append(job)
        onJobsChanged?(jobs)
        return id
    }

    /// Conversions run on background tasks; job state and every UI callback live on main.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func update(job id: UUID, title: String, subtitle: String, progress: Double) {
        onMain { self.updateOnMain(job: id, title: title, subtitle: subtitle, progress: progress) }
    }

    private func updateOnMain(job id: UUID, title: String, subtitle: String, progress: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].title = title
        jobs[index].subtitle = subtitle
        jobs[index].progress = progress
        onJobsChanged?(jobs)
    }

    private func finishJob(_ id: UUID, title: String, subtitle: String, paths: [URL], success: Bool) {
        onMain { self.finishJobOnMain(id, title: title, subtitle: subtitle, paths: paths, success: success) }
    }

    private func finishJobOnMain(_ id: UUID, title: String, subtitle: String, paths: [URL], success: Bool) {
        if success, let anchor = jobs.first(where: { $0.id == id })?.anchor {
            FinderPlacement.place(paths, at: anchor)
        }
        runners[id] = nil
        jobs.removeAll { $0.id == id }
        onJobsChanged?(jobs)
        let recentItem = RecentConversion(
            id: UUID(),
            title: title,
            subtitle: subtitle,
            outputPaths: paths.map(\.path),
            succeeded: success,
            date: Date()
        )
        recent.insert(recentItem, at: 0)
        recent = Array(recent.prefix(12))
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
        Notifier.shared.post(title: title, body: subtitle, paths: paths.map(\.path))
    }

    private func finishSuccess(title: String, subtitle: String, paths: [URL]) {
        let recentItem = RecentConversion(id: UUID(), title: title, subtitle: subtitle, outputPaths: paths.map(\.path), succeeded: true, date: Date())
        recent.insert(recentItem, at: 0)
        recent = Array(recent.prefix(12))
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
        Notifier.shared.post(title: title, body: subtitle, paths: paths.map(\.path))
    }

    private func makeRunner(_ id: UUID) -> ProcessRunner {
        let runner = ProcessRunner()
        runners[id] = runner
        if cancelled.contains(id) { runner.cancel() }
        return runner
    }

    private func throwIfCancelled(_ id: UUID) throws {
        if cancelled.contains(id) { throw ConversionFailure.cancelled }
    }

    private func subtitle(for urls: [URL]) -> String {
        if urls.count == 1 { return urls[0].lastPathComponent }
        return "\(urls.count) files"
    }

    private func location(for source: URL) -> OutputLocation {
        if case .directory = settings.outputLocation { return settings.outputLocation }
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        if source.standardizedFileURL.path.hasPrefix(temp) {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                ?? (NSHomeDirectory() + "/Downloads")
            return .directory(downloads)
        }
        return .besideSource
    }

    private func quality(for type: FileType) -> Double? {
        switch type.family {
        case "jpeg": return settings.clampedJPEGQuality
        case "heic": return settings.clampedHEICQuality
        default: return nil
        }
    }

    private func resolvedType(of url: URL) -> FileType {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return FileTypes.folder
        }
        if let matched = FileTypes.matching(path: url.path) { return matched }
        return FileTypes.text
    }
}

enum WheelContents {
    struct Built {
        var segments: [WheelSegmentModel]
        var offers: [ConversionOffer]
        var tools: [ToolOffer]
        var actions: [FileActionID]
        var centerFallback: String
    }

    static func build(kind: WheelKind, session: DragSession, availability: ToolAvailability) -> Built {
        let types = fileTypes(in: session)
        let fallback = centerFallback(session)
        switch kind {
        case .convert:
            let offers = commonOffers(types, availability: availability)
            let segments = offers.map {
                WheelSegmentModel(id: $0.id, title: $0.label, symbol: nil, enabled: $0.isEnabled, help: $0.unavailableReason)
            }
            return Built(segments: segments, offers: offers, tools: [], actions: [], centerFallback: fallback)
        case .tools:
            let toolOffers = ToolRegistry.tools(for: types, tools: availability, fileCount: max(session.filePaths.count, types.count))
            let segments = toolOffers.map {
                WheelSegmentModel(id: $0.id, title: $0.tool.label, symbol: $0.tool.symbolName, enabled: $0.isEnabled, help: $0.unavailableReason)
            }
            return Built(segments: segments, offers: [], tools: toolOffers, actions: [], centerFallback: fallback)
        case .actions:
            let actions = ToolRegistry.actions()
            let segments = actions.map {
                WheelSegmentModel(id: $0.rawValue, title: $0.label, symbol: $0.symbolName, enabled: true, help: nil)
            }
            return Built(segments: segments, offers: [], tools: [], actions: actions, centerFallback: fallback)
        }
    }

    static func fileTypes(in session: DragSession) -> [FileType] {
        if !session.filePaths.isEmpty {
            return session.filePaths.map(resolvePath)
        }
        let promised = session.promisedTypeIdentifiers.compactMap(resolveUTI)
        return promised
    }

    static func resolvePath(_ path: String) -> FileType {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return FileTypes.folder
        }
        if let matched = FileTypes.matching(path: path) { return matched }
        let ext = URL(fileURLWithPath: path).pathExtension
        if let ut = UTType(filenameExtension: ext) {
            if let matched = FileTypes.matching(uti: ut.identifier) { return matched }
            if ut.conforms(to: .image) { return FileTypes.jpeg }
            if ut.conforms(to: .movie) || ut.conforms(to: .video) { return FileTypes.mp4 }
            if ut.conforms(to: .audio) { return FileTypes.m4a }
            if ut.conforms(to: .pdf) { return FileTypes.pdf }
        }
        return FileType(uti: "public.data", extensions: [ext], label: ext.uppercased(), family: ext.lowercased(), kind: .other)
    }

    static func resolveUTI(_ identifier: String) -> FileType? {
        if let matched = FileTypes.matching(uti: identifier) { return matched }
        guard let ut = UTType(identifier) else { return nil }
        if ut.conforms(to: .image) { return FileTypes.jpeg }
        if ut.conforms(to: .movie) || ut.conforms(to: .video) { return FileTypes.mp4 }
        if ut.conforms(to: .pdf) { return FileTypes.pdf }
        if ut.conforms(to: .audio) { return FileTypes.m4a }
        return nil
    }

    static func centerFallback(_ session: DragSession) -> String {
        if session.filePaths.count > 1 { return "\(session.filePaths.count) FILES" }
        if session.filePaths.isEmpty && session.hasFilePromise { return "FILE" }
        guard let path = session.filePaths.first else { return "" }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let number = attributes?[.size] as? NSNumber {
            return ByteCountFormat.string(bytes: number.int64Value)
        }
        return URL(fileURLWithPath: path).pathExtension.uppercased()
    }

    private static func commonOffers(_ types: [FileType], availability: ToolAvailability) -> [ConversionOffer] {
        guard let first = types.first else { return [] }
        var offers = ConverterRegistry.conversionOffers(for: first, tools: availability)
        for type in types.dropFirst() {
            let labels = Set(ConverterRegistry.conversionOffers(for: type, tools: availability).map(\.label))
            offers = offers.filter { labels.contains($0.label) }
        }
        return offers
    }
}
