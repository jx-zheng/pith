import Foundation
import PDFKit
import XCTest
import PithCore
@testable import PithEngine

/// Every registered conversion for every input type, through `ConversionEngine.convert`,
/// the same entry point the wheel's Convert segments use. Outputs are decoded and checked.
@MainActor
final class ConversionMatrixTests: XCTestCase {
    func testEveryCatalogTypeHasAFixtureAndOffers() {
        var missing: [String] = []
        for type in FileTypes.catalog {
            if Fixtures.fixture(type) == nil { missing.append("\(type.label): no fixture") }
            let offers = ConverterRegistry.conversionOffers(for: type, tools: Env.tools)
            if offers.isEmpty { missing.append("\(type.label): no offers") }
            for offer in offers where !offer.isEnabled {
                missing.append("\(type.label) → \(offer.label) disabled with tools installed: \(offer.unavailableReason ?? "")")
            }
        }
        XCTAssertEqual(missing, [])
        XCTAssertNotNil(Env.tools.ffmpeg, "ffmpeg not found")
        XCTAssertNotNil(Env.tools.ffprobe, "ffprobe not found")
        XCTAssertNotNil(Env.tools.pandoc, "pandoc not found")
        XCTAssertNotNil(Env.tools.soffice, "LibreOffice not found")
    }

    func testImageConversions() async { await matrix("Images", kinds: [.image]) }
    func testPDFConversions() async { await matrix("PDF", kinds: [.pdf]) }
    func testVideoConversions() async { await matrix("Video", kinds: [.video]) }
    func testAudioConversions() async { await matrix("Audio", kinds: [.audio]) }
    func testDocumentConversions() async { await matrix("Documents", kinds: [.document]) }
    func testPresentationConversions() async { await matrix("Presentations", kinds: [.presentation]) }
    func testSpreadsheetConversions() async { await matrix("Spreadsheets", kinds: [.spreadsheet]) }
    func testSubtitleConversions() async { await matrix("Subtitles", kinds: [.subtitle]) }
    func testArchiveAndFolderConversions() async { await matrix("Archives", kinds: [.archive, .folder]) }

    /// Without pandoc, TXT/RTF/HTML/DOCX fall back to NSAttributedString.
    func testDocumentConversionsWithoutPandoc() async {
        var tools = Env.tools
        tools.pandoc = nil
        await matrix("Documents (no pandoc, native)", kinds: [.document], tools: tools, enabledOnly: true)
    }

    /// Without LibreOffice, PDF → DOCX is written natively from PDFKit text.
    func testPDFConversionsWithoutLibreOffice() async {
        var tools = Env.tools
        tools.soffice = nil
        await matrix("PDF (no LibreOffice, native)", kinds: [.pdf], tools: tools, enabledOnly: true)
    }

    /// Without ffmpeg, MP4/MOV still convert to each other and to M4A through AVFoundation.
    func testVideoConversionsWithoutFFmpeg() async {
        var tools = Env.tools
        tools.ffmpeg = nil
        await matrix("Video (no ffmpeg, AVFoundation)", kinds: [.video], tools: tools, enabledOnly: true)
    }

    // MARK: -

    private func matrix(_ category: String, kinds: Set<FileKind>, tools: ToolAvailability = Env.tools, enabledOnly: Bool = false) async {
        let out = Env.outputDir("matrix/\(category)")
        var passed = 0
        var failures: [String] = []
        for type in FileTypes.catalog where kinds.contains(type.kind) {
            guard let source = Fixtures.fixture(type) else {
                failures.append("\(type.label): no fixture")
                continue
            }
            let dir = out.appendingPathComponent(type.family, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let engine = Env.engine(output: dir, tools: tools)
            let sourceDuration = (type.kind == .video || type.kind == .audio) ? (Validate.probe(source)?.duration ?? 0) : 0
            for offer in ConverterRegistry.conversionOffers(for: type, tools: tools) {
                let name = "\(type.label) → \(offer.label) [\(offer.backend.rawValue)]"
                guard offer.isEnabled else {
                    if !enabledOnly { failures.append("\(name): disabled (\(offer.unavailableReason ?? ""))") }
                    continue
                }
                do {
                    let outputs = try await withTimeout(90) { runner in
                        try await engine.convert(source, offer: offer, runner: runner)
                    }
                    var problems: [String] = []
                    if outputs.isEmpty { problems.append("no outputs") }
                    let expected = expectedType(for: offer)
                    for output in outputs {
                        let duration = (expected.kind == .video || expected.kind == .audio) ? sourceDuration : 0
                        if let problem = Validate.check(output, as: expected, sourceDuration: duration) {
                            problems.append("\(output.lastPathComponent): \(problem)")
                        }
                    }
                    if type.kind == .pdf, offer.output.kind == .image, outputs.count != 3 {
                        problems.append("expected 3 page images, got \(outputs.count)")
                    }
                    if problems.isEmpty { passed += 1 } else { failures.append("\(name): \(problems.joined(separator: "; "))") }
                } catch {
                    failures.append("\(name): threw \(error)")
                }
            }
        }
        Matrix.shared.report(category, passed: passed, failed: failures)
        XCTAssertEqual(failures, [], "\(category) failures")
        XCTAssertGreaterThan(passed, 0)
    }

    private func expectedType(for offer: ConversionOffer) -> FileType {
        if offer.id == "unzip" || offer.id == "untar" { return FileTypes.folder }
        return offer.output
    }
}

/// Runs `work` with a fresh ProcessRunner, cancelling it if it outlives `seconds`.
func withTimeout<T>(_ seconds: Double, _ work: (ProcessRunner) async throws -> T) async throws -> T {
    let runner = ProcessRunner()
    let watchdog = Task {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        runner.cancel()
    }
    defer { watchdog.cancel() }
    return try await work(runner)
}
