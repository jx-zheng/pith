import Foundation
import XCTest
import PithCore
@testable import PithEngine

@MainActor
final class OutputNamingIntegrationTests: XCTestCase {
    private func offer(_ input: FileType, _ label: String) -> ConversionOffer {
        ConverterRegistry.conversionOffers(for: input, tools: Env.tools).first { $0.label == label }!
    }

    func testCollisionsGetFinderStyleSuffixes() async throws {
        let out = Env.outputDir("naming/collisions")
        let engine = Env.engine(output: out)
        let png = Fixtures.fixture(FileTypes.png)!
        var names: [String] = []
        for _ in 0..<3 {
            names += try await engine.convert(png, offer: offer(FileTypes.png, "JPG"), runner: ProcessRunner()).map(\.lastPathComponent)
        }
        XCTAssertEqual(names, ["sample.jpg", "sample 2.jpg", "sample 3.jpg"])

        // Multi-page renders reserve every page name; a second run moves all of them.
        let pdf = Fixtures.fixture(FileTypes.pdf)!
        let first = try await engine.convert(pdf, offer: offer(FileTypes.pdf, "JPG"), runner: ProcessRunner()).map(\.lastPathComponent)
        let second = try await engine.convert(pdf, offer: offer(FileTypes.pdf, "JPG"), runner: ProcessRunner()).map(\.lastPathComponent)
        XCTAssertEqual(first, ["sample page 1.jpg", "sample page 2.jpg", "sample page 3.jpg"])
        XCTAssertEqual(second, ["sample page 1 2.jpg", "sample page 2 2.jpg", "sample page 3 2.jpg"])
    }

    func testBesideSourceAndTemporarySources() async throws {
        let dir = Env.outputDir("naming/beside")
        let source = dir.appendingPathComponent("Photo.png")
        try FileManager.default.copyItem(at: Fixtures.fixture(FileTypes.png)!, to: source)
        var engine = Env.engine(output: nil)
        XCTAssertEqual(engine.settings.outputLocation, .besideSource)
        let beside = try await engine.convert(source, offer: offer(FileTypes.png, "HEIC"), runner: ProcessRunner())
        XCTAssertEqual(beside.map(\.path), [dir.appendingPathComponent("Photo.heic").path])

        // Sources inside the temporary directory (drag promises) write to Downloads instead.
        let downloads = Env.outputDir("naming/downloads")
        engine.temporaryDirectory = dir.path
        engine.downloadsDirectory = downloads.path
        let redirected = try await engine.convert(source, offer: offer(FileTypes.png, "TIFF"), runner: ProcessRunner())
        XCTAssertEqual(redirected.map(\.path), [downloads.appendingPathComponent("Photo.tif").path])
    }

    func testArchiveNames() async throws {
        let out = Env.outputDir("naming/archives")
        let engine = Env.engine(output: out)
        let folder = Fixtures.fixture(FileTypes.folder)!
        let zip = try await engine.convert(folder, offer: offer(FileTypes.folder, "ZIP"), runner: ProcessRunner())
        let gz = try await engine.convert(folder, offer: offer(FileTypes.folder, "GZIP"), runner: ProcessRunner())
        XCTAssertEqual(zip.map(\.lastPathComponent), ["Sample Folder.zip"])
        XCTAssertEqual(gz.map(\.lastPathComponent), ["Sample Folder.tar.gz"])

        // Extracting twice never merges into the first folder.
        let unzipOffer = offer(FileTypes.zip, "UNZIP")
        let a = try await engine.convert(Fixtures.fixture(FileTypes.zip)!, offer: unzipOffer, runner: ProcessRunner())
        let b = try await engine.convert(Fixtures.fixture(FileTypes.zip)!, offer: unzipOffer, runner: ProcessRunner())
        XCTAssertEqual([a[0].lastPathComponent, b[0].lastPathComponent], ["sample", "sample 2"])

        // `sample.tar.gz` extracts to `sample`, not `sample.tar`.
        let tgz = try await engine.convert(Fixtures.fixture(FileTypes.gzip)!, offer: offer(FileTypes.gzip, "EXTRACT"), runner: ProcessRunner())
        XCTAssertEqual(tgz.map(\.lastPathComponent), ["sample 3"])
    }

    func testRefusesToOverwriteTheSource() throws {
        XCTAssertThrowsError(try ImageIOBridge.convert(source: Fixtures.fixture(FileTypes.png)!, destination: Fixtures.fixture(FileTypes.png)!, uti: FileTypes.png.uti, quality: nil))
    }
}

final class UndoTests: XCTestCase {
    private func item(_ paths: [URL], ok: Bool = true) -> RecentConversion {
        RecentConversion(id: UUID(), title: "t", subtitle: "s", outputPaths: paths.map(\.path), succeeded: ok, date: Date())
    }

    private func makeFile(_ dir: URL, _ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    func testUndoTrashesNewestSuccessfulOutputs() {
        let dir = Env.outputDir("undo/basic")
        let old = makeFile(dir, "old.jpg")
        let a = makeFile(dir, "a page 1.jpg"), b = makeFile(dir, "a page 2.jpg")
        let partial = makeFile(dir, "partial.jpg")
        var recent: [RecentConversion] = []
        RecentLog.record(item([old]), into: &recent)
        RecentLog.record(item([a, b]), into: &recent)
        RecentLog.record(item([partial], ok: false), into: &recent)   // failed batch: not undoable
        var trashed: [String] = []
        let count = RecentLog.undoLast(&recent) { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(trashed, ["a page 1.jpg", "a page 2.jpg"])
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(RecentLog.message(trashed: 2), "Moved 2 files to the Trash")
        XCTAssertEqual(RecentLog.message(trashed: 1), "Moved 1 file to the Trash")

        // Next undo takes the older one; then nothing is left.
        XCTAssertEqual(RecentLog.undoLast(&recent) { try FileManager.default.removeItem(at: $0) }, 1)
        XCTAssertFalse(RecentLog.canUndo(recent))
        XCTAssertNil(RecentLog.undoLast(&recent) { _ in XCTFail("nothing to trash") })
    }

    func testUndoSkipsFilesAlreadyGoneAndCapsHistory() {
        let dir = Env.outputDir("undo/gone")
        var recent: [RecentConversion] = []
        RecentLog.record(item([dir.appendingPathComponent("deleted.jpg")]), into: &recent)
        XCTAssertEqual(RecentLog.undoLast(&recent) { _ in XCTFail("missing file trashed") }, 0)
        for index in 0..<20 { RecentLog.record(item([makeFile(dir, "\(index).txt")]), into: &recent) }
        XCTAssertEqual(recent.count, RecentLog.limit)
    }

    /// Real Trash, real folder output (e.g. from UNZIP): moved, then removed from the Trash again.
    func testUndoUsesTheRealTrash() throws {
        let dir = Env.outputDir("undo/real")
        let folder = dir.appendingPathComponent("Extracted \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = makeFile(folder, "inner.txt")
        let file = makeFile(dir, "Converted \(UUID().uuidString.prefix(6)).jpg")
        var recent: [RecentConversion] = []
        RecentLog.record(item([file, folder]), into: &recent)
        var inTrash: [URL] = []
        let count = RecentLog.undoLast(&recent) { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result { inTrash.append(result as URL) }
        }
        XCTAssertEqual(count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(inTrash.count, 2)
        for url in inTrash {
            XCTAssertTrue(url.path.contains(".Trash"), url.path)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
