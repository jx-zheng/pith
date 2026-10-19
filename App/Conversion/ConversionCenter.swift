import AppKit
import Foundation
import PithCore

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

/// Runs `ConversionEngine` work as HUD jobs, places results in Finder, and keeps the recent list.
final class ConversionCenter: ObservableObject {
    @Published var jobs: [HUDJob] = []
    @Published var recent: [RecentConversion] = []

    var settings: PithSettings = .default
    var tools: ToolAvailability = .none
    var presentEditor: ((EditorRequest) -> Void)?
    var onJobsChanged: (([HUDJob]) -> Void)?

    var engine: ConversionEngine { ConversionEngine(settings: settings, tools: tools) }

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

    /// - Parameters:
    ///   - anchor: where the HUD appears.
    ///   - drop: where the user let go of a drag; nil (click mode) puts outputs next to each source's icon.
    func convert(urls: [URL], offer: ConversionOffer, anchor: CGPoint, drop: CGPoint?) {
        guard offer.isEnabled else { return }
        let job = startJob(title: "Converting to \(offer.label)", subtitle: subtitle(for: urls), anchor: anchor)
        let engine = self.engine
        Task { @MainActor in
            await self.runBatch(urls: urls, job: job, drop: drop) { url, index, count in
                self.update(job: job, title: count > 1 ? "Converting \(index) of \(count) to \(offer.label)" : "Converting to \(offer.label)", subtitle: url.lastPathComponent, progress: Double(index - 1) / Double(count))
                return try await engine.convert(url, offer: offer, runner: self.makeRunner(job)) { fraction in
                    let overall = (Double(index - 1) + fraction) / Double(count)
                    self.update(job: job, title: self.jobs.first { $0.id == job }?.title ?? "", subtitle: url.lastPathComponent, progress: overall)
                }
            }
        }
    }

    func runTool(_ tool: ToolID, urls: [URL], drop: CGPoint?) {
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
            merge(urls, drop: drop)
        case .splitPDF:
            if let url = urls.first { split(url, drop: drop) }
        }
    }

    /// Records an editor save (crop, annotate, …) so it shows in Recent and can be undone,
    /// and moves the new file's icon next to the source's. The editor window is wherever the
    /// user left it, so neither it nor the mouse says anything about where the file belongs.
    @discardableResult
    func recordSaved(_ url: URL, source: URL) -> URL {
        FinderPlacement.place([url], target: .besideSource(source))
        finishSuccess(title: "Saved \(url.lastPathComponent)", subtitle: source.lastPathComponent, paths: [url])
        return url
    }

    /// Records a Save and Replace. Same name, same folder, so Finder keeps the icon where it was.
    func recordReplaced(_ entry: ReplacedFile, source: URL) {
        onMain {
            let item = RecentConversion(id: UUID(), title: "Replaced \(source.lastPathComponent)", subtitle: "Edited in place",
                                        outputPaths: [], succeeded: true, date: Date(), replaced: [entry])
            RecentLog.record(item, into: &self.recent)
            self.persistRecent()
            Notifier.shared.post(title: item.title, body: item.subtitle, paths: [entry.original])
        }
    }

    /// Video Compress and Trim run from an editor window; outputs go next to the source's icon.
    func exportVideo(source: URL, trim: TrimRange?, bitrate: Double?, anchor: CGPoint) {
        let title = trim == nil ? "Compressing" : "Trimming"
        let job = startJob(title: title, subtitle: source.lastPathComponent, anchor: anchor)
        let engine = self.engine
        Task { @MainActor in
            do {
                try self.throwIfCancelled(job)
                let destination = try await engine.exportVideo(source: source, trim: trim, bitrate: bitrate, runner: self.makeRunner(job)) { fraction in
                    Task { @MainActor in
                        self.update(job: job, title: title, subtitle: source.lastPathComponent, progress: fraction)
                    }
                }
                self.finishJob(job, title: "Saved \(destination.lastPathComponent)", subtitle: source.lastPathComponent, paths: [destination], success: true,
                               placements: [(.besideSource(source), [destination])])
            } catch {
                self.finishJob(job, title: "Couldn't process \(source.lastPathComponent)", subtitle: error.localizedDescription, paths: [], success: false)
            }
        }
    }

    private func merge(_ urls: [URL], drop: CGPoint?) {
        let count = ConversionEngine.mergeCandidates(urls).count
        guard count >= 2 else { return }
        let job = startJob(title: "Merging into one PDF", subtitle: "\(count) files", anchor: NSEvent.mouseLocation)
        let engine = self.engine
        Task { @MainActor in
            do {
                let outputs = try engine.merge(urls)
                let target = PlacementTarget.resolve(drop: drop, source: ConversionEngine.mergeCandidates(urls).first)
                self.finishJob(job, title: "Merged \(count) files", subtitle: outputs.first?.lastPathComponent ?? "", paths: outputs, success: true,
                               placements: target.map { [($0, outputs)] } ?? [])
            } catch {
                self.finishJob(job, title: "Couldn't merge PDFs", subtitle: error.localizedDescription, paths: [], success: false)
            }
        }
    }

    private func split(_ url: URL, drop: CGPoint?) {
        let job = startJob(title: "Splitting PDF", subtitle: url.lastPathComponent, anchor: NSEvent.mouseLocation)
        let engine = self.engine
        Task { @MainActor in
            do {
                let outputs = try engine.split(url)
                let target = PlacementTarget.resolve(drop: drop, source: url)!
                self.finishJob(job, title: "Split into \(outputs.count) PDFs", subtitle: url.lastPathComponent, paths: outputs, success: true,
                               placements: [(target, outputs)])
            } catch {
                self.finishJob(job, title: "Couldn't split PDF", subtitle: error.localizedDescription, paths: [], success: false)
            }
        }
    }

    private func runBatch(urls: [URL], job: UUID, drop: CGPoint?, work: (URL, Int, Int) async throws -> [URL]) async {
        var outputs: [URL] = []
        var bySource: [(URL, [URL])] = []
        do {
            for (offset, url) in urls.enumerated() {
                try throwIfCancelled(job)
                let written = try await work(url, offset + 1, urls.count)
                outputs.append(contentsOf: written)
                bySource.append((url, written))
            }
            let title = urls.count == 1 ? "Converted \(urls[0].lastPathComponent)" : "Converted \(urls.count) files"
            let placements: [(PlacementTarget, [URL])] = drop.map { [(.dropPoint($0), outputs)] }
                ?? bySource.map { (.besideSource($0.0), $0.1) }
            finishJob(job, title: title, subtitle: outputs.last?.lastPathComponent ?? "", paths: outputs, success: true, placements: placements)
        } catch {
            finishJob(job, title: "Conversion failed", subtitle: error.localizedDescription, paths: outputs, success: false)
        }
    }

    /// Moves the newest successful conversion's outputs to the Trash.
    /// Returns a short description for the HUD, or nil when there's nothing to undo.
    @discardableResult
    func undoLast() -> String? {
        guard let outcome = RecentLog.undo(&recent) else { return nil }
        persistRecent()
        return RecentLog.message(outcome)
    }

    /// A short self-dismissing HUD card, used for undo feedback.
    func flash(title: String, subtitle: String) {
        let id = startJob(title: title, subtitle: subtitle, anchor: NSEvent.mouseLocation)
        update(job: id, title: title, subtitle: subtitle, progress: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            self.jobs.removeAll { $0.id == id }
            self.onJobsChanged?(self.jobs)
        }
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

    private func finishJob(_ id: UUID, title: String, subtitle: String, paths: [URL], success: Bool, placements: [(PlacementTarget, [URL])] = []) {
        onMain { self.finishJobOnMain(id, title: title, subtitle: subtitle, paths: paths, success: success, placements: placements) }
    }

    private func finishJobOnMain(_ id: UUID, title: String, subtitle: String, paths: [URL], success: Bool, placements: [(PlacementTarget, [URL])]) {
        if success {
            for (target, files) in placements where !files.isEmpty {
                FinderPlacement.place(files, target: target)
            }
        }
        runners[id] = nil
        cancelled.remove(id)
        jobs.removeAll { $0.id == id }
        onJobsChanged?(jobs)
        record(title: title, subtitle: subtitle, paths: paths, success: success)
    }

    private func finishSuccess(title: String, subtitle: String, paths: [URL]) {
        onMain { self.record(title: title, subtitle: subtitle, paths: paths, success: true) }
    }

    private func record(title: String, subtitle: String, paths: [URL], success: Bool) {
        let item = RecentConversion(id: UUID(), title: title, subtitle: subtitle, outputPaths: paths.map(\.path), succeeded: success, date: Date())
        RecentLog.record(item, into: &recent)
        persistRecent()
        Notifier.shared.post(title: title, body: subtitle, paths: paths.map(\.path))
    }

    private func persistRecent() {
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
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
}
