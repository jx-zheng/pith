import CoreGraphics
import Foundation
import ImageIO
import XCTest
import PithCore
@testable import PithEngine

final class ReplaceTests: XCTestCase {
    private var failures: [String] = []
    private var passed = 0

    override func tearDown() {
        if passed + failures.count > 0 { Matrix.shared.report("Tools: replace + undo", passed: passed, failed: failures) }
        super.tearDown()
    }

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        if condition { passed += 1 } else {
            failures.append(message())
            XCTFail(message(), file: file, line: line)
        }
    }

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, width: Int = 64, height: Int = 48) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func centre(_ url: URL) -> (r: Int, g: Int, b: Int) {
        let image = try! ImageIOBridge.loadOriented(url)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    /// Every writable single-frame image format: replace in place, same name and format,
    /// nothing new in the folder, then undo restores the original byte for byte.
    func testReplaceThenUndoRestoresEveryWritableFormat() throws {
        let types = [FileTypes.jpeg, FileTypes.png, FileTypes.heic, FileTypes.tiff, FileTypes.bmp, FileTypes.gif, FileTypes.avif]
            .filter { ImageIOBridge.canWrite($0.uti) }
        let undoDir = Env.outputDir("replace/undo-store")
        for type in types {
            let dir = Env.outputDir("replace/\(type.family)")
            let source = dir.appendingPathComponent("photo.\(type.primaryExtension)")
            try ImageIOBridge.write(solid(0.1, 0.4, 0.9), to: source, uti: type.uti, quality: 0.9)
            let originalBytes = try Data(contentsOf: source)
            let before = listing(dir)
            XCTAssertNil(ReplaceStore.blocker(for: source), type.label)

            var engine = Env.engine(output: nil)
            engine.undoDirectory = undoDir
            let entry = try engine.replaceOriginal(solid(0.9, 0.1, 0.1), source: source)
            let edited = centre(source)
            let format = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
            expect(edited.r > 200 && edited.b < 60, "\(type.label): replaced pixels are red, got \(edited)")
            expect(format == type.uti, "\(type.label): format kept, got \(format ?? "nil")")
            expect(listing(dir) == before, "\(type.label): no sibling written, folder is \(listing(dir))")
            expect(entry.original == source.path, "\(type.label): entry points at the source")
            expect((try? Data(contentsOf: URL(fileURLWithPath: entry.backup))) == originalBytes, "\(type.label): backup is the original")

            var recent: [RecentConversion] = []
            RecentLog.record(RecentConversion(id: UUID(), title: "Replaced", subtitle: "", outputPaths: [], succeeded: true, date: Date(), replaced: [entry]), into: &recent)
            XCTAssertTrue(RecentLog.canUndo(recent))
            let outcome = RecentLog.undo(&recent, trash: { _ in XCTFail("replace has nothing to trash") })
            expect(outcome?.restored == [source.lastPathComponent], "\(type.label): undo restored \(outcome?.restored ?? [])")
            expect((try? Data(contentsOf: source)) == originalBytes, "\(type.label): original bytes are back")
            expect(listing(dir) == before, "\(type.label): folder unchanged after undo")
            expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: entry.backup).deletingLastPathComponent().path), "\(type.label): backup slot cleaned up")
            expect(recent.isEmpty, "\(type.label): entry consumed")
        }
        XCTAssertEqual(RecentLog.message(RecentLog.UndoOutcome(trashed: 0, restored: ["a.jpg"])), "Restored a.jpg")
    }

    func testCropAndMetadataReplaceKeepFormat() throws {
        let dir = Env.outputDir("replace/crop")
        let source = dir.appendingPathComponent("shot.png")
        try ImageIOBridge.write(solid(0.2, 0.6, 0.3, width: 200, height: 100), to: source, uti: FileTypes.png.uti, quality: nil)
        var engine = Env.engine(output: nil)
        engine.undoDirectory = Env.outputDir("replace/crop-undo")
        let image = try ImageIOBridge.loadOriented(source)
        let crop = try engine.cropReplacing(image, source: source, to: PixelRect(x: 10, y: 10, width: 50, height: 40))
        let cropped = try ImageIOBridge.loadOriented(source)
        XCTAssertEqual([cropped.width, cropped.height], [50, 40])
        XCTAssertEqual(listing(dir), ["shot.png"])
        let strip = try engine.stripMetadataReplacing(source)
        XCTAssertNotEqual(crop.backup, strip.backup)
        // Two undos in order: strip first, then crop, ending on the 200×100 original.
        var recent: [RecentConversion] = []
        for entry in [crop, strip] {
            RecentLog.record(RecentConversion(id: UUID(), title: "", subtitle: "", outputPaths: [], succeeded: true, date: Date(), replaced: [entry]), into: &recent)
        }
        XCTAssertEqual(RecentLog.undoLast(&recent), 1)
        XCTAssertEqual(try ImageIOBridge.loadOriented(source).width, 50)
        XCTAssertEqual(RecentLog.undoLast(&recent), 1)
        XCTAssertEqual(try ImageIOBridge.loadOriented(source).width, 200)
    }

    func testUndoRestoresEvenIfTheEditedFileWasDeleted() throws {
        let dir = Env.outputDir("replace/deleted")
        let source = dir.appendingPathComponent("gone.jpg")
        try ImageIOBridge.write(solid(0.1, 0.4, 0.9), to: source, uti: FileTypes.jpeg.uti, quality: 0.9)
        let original = try Data(contentsOf: source)
        let entry = try ReplaceStore.replace(source, with: solid(1, 0, 0), quality: 0.9, directory: Env.outputDir("replace/deleted-undo"))
        try FileManager.default.removeItem(at: source)
        try ReplaceStore.restore(entry)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testBackupsOfEntriesThatFallOffRecentAreDeleted() throws {
        let undoDir = Env.outputDir("replace/evict-undo")
        let dir = Env.outputDir("replace/evict")
        let source = dir.appendingPathComponent("a.png")
        try ImageIOBridge.write(solid(0.1, 0.4, 0.9), to: source, uti: FileTypes.png.uti, quality: nil)
        let first = try ReplaceStore.replace(source, with: solid(1, 0, 0), quality: nil, directory: undoDir)
        var recent: [RecentConversion] = []
        RecentLog.record(RecentConversion(id: UUID(), title: "", subtitle: "", outputPaths: [], succeeded: true, date: Date(), replaced: [first]), into: &recent)
        for _ in 0..<RecentLog.limit {
            RecentLog.record(RecentConversion(id: UUID(), title: "", subtitle: "", outputPaths: ["/nonexistent"], succeeded: true, date: Date()), into: &recent)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.backup))
        // The safety check: discard never deletes a folder that isn't a per-replace UUID slot.
        let keep = undoDir.appendingPathComponent("keep.txt")
        FileManager.default.createFile(atPath: keep.path, contents: Data())
        ReplaceStore.discard(ReplacedFile(original: "/x", backup: keep.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    func testOldRecentEntriesStillDecode() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","title":"t","subtitle":"s","outputPaths":["/a"],"succeeded":true,"date":0}]"#
        let decoded = try JSONDecoder().decode([RecentConversion].self, from: Data(json.utf8))
        XCTAssertNil(decoded[0].replaced)
        XCTAssertTrue(decoded[0].isUndoable)
    }

    func testReplaceIsBlockedWhereItWouldLoseData() throws {
        let dir = Env.outputDir("replace/blocked")
        // WebP: ImageIO reads it but can't write it.
        let webp = dir.appendingPathComponent("a.webp")
        try FileManager.default.copyItem(at: Fixtures.fixture(FileTypes.webp)!, to: webp)
        XCTAssertNotNil(ReplaceStore.blocker(for: webp))
        XCTAssertThrowsError(try ReplaceStore.replace(webp, with: solid(1, 0, 0), quality: nil, directory: dir))
        // Animated GIF: replacing would keep one frame.
        let gif = dir.appendingPathComponent("anim.gif")
        let dest = CGImageDestinationCreateWithURL(gif as CFURL, FileTypes.gif.uti as CFString, 2, nil)!
        CGImageDestinationAddImage(dest, solid(1, 0, 0), nil)
        CGImageDestinationAddImage(dest, solid(0, 1, 0), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertNotNil(ReplaceStore.blocker(for: gif))
        // Not an image.
        XCTAssertNotNil(ReplaceStore.blocker(for: Fixtures.fixture(FileTypes.pdf)!))
        // Read-only file.
        let locked = dir.appendingPathComponent("locked.png")
        try ImageIOBridge.write(solid(0, 0, 1), to: locked, uti: FileTypes.png.uti, quality: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        XCTAssertNotNil(ReplaceStore.blocker(for: locked))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        XCTAssertNil(ReplaceStore.blocker(for: locked))
        XCTAssertEqual(listing(dir).filter { $0.contains("Edited") || $0.contains("Redacted") }, [])
    }
}

final class PlacementPlanTests: XCTestCase {
    private let desktop = "/Users/k/Desktop"

    func testDropPointWinsOtherwiseBesideSource() {
        let source = URL(fileURLWithPath: "/Users/k/Desktop/a.png")
        XCTAssertEqual(PlacementTarget.resolve(drop: CGPoint(x: 5, y: 6), source: source), .dropPoint(CGPoint(x: 5, y: 6)))
        XCTAssertEqual(PlacementTarget.resolve(drop: nil, source: source), .besideSource(source))
        XCTAssertNil(PlacementTarget.resolve(drop: nil, source: nil))
    }

    func testBesideSourceOnDesktopReadsAndWritesDesktopPosition() throws {
        let source = URL(fileURLWithPath: "\(desktop)/shot.png")
        let outputs = [URL(fileURLWithPath: "\(desktop)/shot Redacted.png"), URL(fileURLWithPath: "\(desktop)/shot 2.png")]
        let script = try XCTUnwrap(PlacementPlan.script(files: outputs, target: .besideSource(source), desktopPath: desktop, mainScreenMaxY: 900))
        XCTAssertTrue(script.contains("set p to desktop position of src"))
        XCTAssertTrue(script.contains("set desktop position of out to {nx, ny}"))
        XCTAssertTrue(script.contains("POSIX file \"\(desktop)/shot.png\""))
        XCTAssertTrue(script.contains("set nx to sx + gap * 1"))
        XCTAssertTrue(script.contains("set nx to sx + gap * 2"))
        XCTAssertFalse(script.contains("mouse"))
    }

    func testBesideSourceInAFolderUsesItsIconPosition() throws {
        let source = URL(fileURLWithPath: "/Users/k/Pictures/a.jpg")
        let script = try XCTUnwrap(PlacementPlan.script(files: [URL(fileURLWithPath: "/Users/k/Pictures/a Cropped.jpg")],
                                                        target: .besideSource(source), desktopPath: desktop, mainScreenMaxY: 900))
        XCTAssertTrue(script.contains("set p to position of src"))
        XCTAssertTrue(script.contains("set position of out to {nx, ny}"))
        XCTAssertFalse(script.contains("desktop position"))
    }

    func testOnlyOutputsInTheSourceFolderAreMovedBesideIt() {
        let source = URL(fileURLWithPath: "/tmp/promise/a.png")
        let elsewhere = [URL(fileURLWithPath: "/Users/k/Downloads/a.jpg")]
        XCTAssertNil(PlacementPlan.script(files: elsewhere, target: .besideSource(source), desktopPath: desktop, mainScreenMaxY: 900))
        XCTAssertEqual(PlacementPlan.filesBeside(source, among: elsewhere + [source, URL(fileURLWithPath: "/tmp/promise/b.png")]).map(\.lastPathComponent), ["b.png"])
        XCTAssertNil(PlacementPlan.script(files: [], target: .dropPoint(.zero), desktopPath: desktop, mainScreenMaxY: 900))
    }

    func testDropPointFlipsToFinderCoordinatesAndEscapesPaths() throws {
        let file = URL(fileURLWithPath: "\(desktop)/say \"hi\".png")
        let script = try XCTUnwrap(PlacementPlan.script(files: [file, URL(fileURLWithPath: "\(desktop)/b.png")],
                                                        target: .dropPoint(CGPoint(x: 300, y: 200)), desktopPath: desktop, mainScreenMaxY: 900))
        XCTAssertTrue(script.contains("to {300, 700}"))
        XCTAssertTrue(script.contains("to {390, 700}"))
        XCTAssertTrue(script.contains(#"say \"hi\".png"#))
    }

    /// The generated AppleScript must at least compile (no Finder needed for that).
    func testScriptsCompile() throws {
        let source = URL(fileURLWithPath: "\(desktop)/a.png")
        for target in [PlacementTarget.besideSource(source), .besideSource(URL(fileURLWithPath: "/Users/k/Pictures/a.png")), .dropPoint(CGPoint(x: 1, y: 2))] {
            let folder: String
            if case let .besideSource(s) = target { folder = s.deletingLastPathComponent().path } else { folder = desktop }
            let script = try XCTUnwrap(PlacementPlan.script(files: [URL(fileURLWithPath: "\(folder)/a 2.png")], target: target, desktopPath: desktop, mainScreenMaxY: 900))
            let path = Env.outputDir("placement-scripts").appendingPathComponent("s.applescript")
            try script.write(to: path, atomically: true, encoding: .utf8)
            let result = Env.run("/usr/bin/osacompile", ["-o", path.deletingPathExtension().appendingPathExtension("scpt").path, path.path])
            XCTAssertEqual(result.status, 0, "\(target): \(result.err)\n\(script)")
        }
    }
}
