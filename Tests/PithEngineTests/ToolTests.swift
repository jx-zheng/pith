import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
import PithCore
@testable import PithEngine

/// Command-wheel tools through the same engine calls the editors make on Apply.
/// The editor windows themselves (dragging a crop box, drawing a stroke) are GUI-only;
/// these tests feed the editors' outputs (rects, marks, CGImages) straight in.
@MainActor
final class ToolTests: XCTestCase {
    private var failures: [String] = []
    private var passed = 0

    override func tearDown() {
        Matrix.shared.report("Tools: \(name)", passed: passed, failed: failures)
        super.tearDown()
    }

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        if condition { passed += 1 } else {
            failures.append(message())
            XCTFail(message(), file: file, line: line)
        }
    }

    private var imageFixtures: [FileType] { FileTypes.catalog.filter { $0.kind == .image } }

    // MARK: Compress

    func testCompressImageEveryFormat() throws {
        let out = Env.outputDir("tools/compress-image")
        let engine = Env.engine(output: out)
        for type in imageFixtures {
            guard let source = Fixtures.fixture(type) else { expect(false, "\(type.label): no fixture"); continue }
            let image = try ImageIOBridge.loadOriented(source)
            let url = try engine.compressImage(image, source: source, quality: 0.6, maxEdge: 200)
            guard let info = Validate.image(url) else { expect(false, "\(type.label): compressed output unreadable"); continue }
            expect(info.type == FileTypes.jpeg.uti, "\(type.label): compressed type \(info.type)")
            expect(max(info.width, info.height) <= 200, "\(type.label): not downscaled (\(info.width)×\(info.height))")
            expect(url.lastPathComponent == "sample Compressed.jpg" || url.lastPathComponent.hasPrefix("sample Compressed "), "\(type.label): name \(url.lastPathComponent)")
        }
    }

    /// Transparent pixels must not turn black when an image is written as JPEG.
    func testJPEGOutputFlattensTransparencyOntoWhite() async throws {
        let out = Env.outputDir("tools/jpeg-alpha")
        let engine = Env.engine(output: out)
        let png = Fixtures.fixture(FileTypes.png)!
        // Compress (editor path).
        let compressed = try engine.compressImage(try ImageIOBridge.loadOriented(png), source: png, quality: 0.8, maxEdge: 0)
        let c = Validate.pixel(try ImageIOBridge.loadOriented(compressed), x: 380, y: 290)
        expect(c.r > 240 && c.g > 240 && c.b > 240, "Compress: transparent area became (\(c.r),\(c.g),\(c.b))")
        // Convert (wheel path).
        let offer = ConverterRegistry.conversionOffers(for: FileTypes.png, tools: Env.tools).first { $0.label == "JPG" }!
        let converted = try await engine.convert(png, offer: offer, runner: ProcessRunner())[0]
        let p = Validate.pixel(try ImageIOBridge.loadOriented(converted), x: 380, y: 290)
        expect(p.r > 240 && p.g > 240 && p.b > 240, "PNG → JPG: transparent area became (\(p.r),\(p.g),\(p.b))")
        // Opaque areas are untouched.
        let blue = Validate.pixel(try ImageIOBridge.loadOriented(converted), x: 20, y: 20)
        expect(blue.b > 180 && blue.r < 90, "PNG → JPG: opaque pixel changed to (\(blue.r),\(blue.g),\(blue.b))")
    }

    func testCompressVideoHonoursBitrate() async throws {
        let out = Env.outputDir("tools/compress-video")
        let engine = Env.engine(output: out)
        guard let ffmpeg = Env.tools.ffmpeg else { return XCTFail("ffmpeg missing") }
        // A noisy 640×480 clip encoded at ~6 Mb/s, so a 0.5 Mb/s compress has to work for it.
        let noisy = ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30:duration=2,noise=alls=8:allf=t",
                     "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-shortest"]
        let codecs: [String: [String]] = [
            "mp4": ["-c:v", "libx264", "-b:v", "6M", "-pix_fmt", "yuv420p", "-c:a", "aac"],
            "mov": ["-c:v", "libx264", "-b:v", "6M", "-pix_fmt", "yuv420p", "-c:a", "aac"],
            "mkv": ["-c:v", "libx264", "-b:v", "6M", "-pix_fmt", "yuv420p", "-c:a", "aac"],
            "webm": ["-c:v", "libvpx-vp9", "-b:v", "6M", "-deadline", "realtime", "-c:a", "libopus"],
            "avi": ["-c:v", "mpeg4", "-b:v", "6M", "-c:a", "libmp3lame"]
        ]
        for type in FileTypes.catalog where type.kind == .video {
            let source = out.appendingPathComponent("noisy.\(type.primaryExtension)")
            Env.run(ffmpeg, noisy + (codecs[type.family] ?? []) + [source.path])
            let sourceRate = Validate.probe(source)?.bitRate ?? 0
            guard sourceRate > 2_000_000 else { expect(false, "\(type.label): noisy fixture only \(Int(sourceRate / 1000)) kb/s"); continue }
            do {
                let url = try await withTimeout(120) { try await engine.exportVideo(source: source, trim: nil, bitrate: 0.5, runner: $0) }
                expect(Validate.check(url, as: type, sourceDuration: 2) == nil, "\(type.label): \(Validate.check(url, as: type, sourceDuration: 2) ?? "")")
                expect(url.lastPathComponent == "noisy Compressed.\(type.primaryExtension)", "\(type.label): name \(url.lastPathComponent)")
                let rate = Validate.probe(url)?.bitRate ?? .infinity
                // One-pass VP9 and MPEG-4 Part 2 overshoot on 2 s of noise; H.264 lands close.
                let ceiling = type.family == "avi" ? sourceRate * 0.5 : 1_250_000
                expect(rate < ceiling, "\(type.label): asked for 0.5 Mb/s, got \(Int(rate / 1000)) kb/s from a \(Int(sourceRate / 1000)) kb/s source")
                expect(Validate.size(url) < Validate.size(source), "\(type.label): compressed file isn't smaller")
            } catch {
                expect(false, "\(type.label): compress threw \(error)")
            }
        }
    }

    // MARK: Trim

    func testTrimEveryVideoFormat() async throws {
        let out = Env.outputDir("tools/trim")
        let engine = Env.engine(output: out)
        for type in FileTypes.catalog where type.kind == .video {
            guard let source = Fixtures.fixture(type) else { expect(false, "\(type.label): no fixture"); continue }
            do {
                let url = try await withTimeout(90) { try await engine.exportVideo(source: source, trim: TrimRange(startSeconds: 0.5, endSeconds: 1.5), bitrate: nil, runner: $0) }
                let info = Validate.probe(url)
                expect(info?.streams.contains("video") == true, "\(type.label): trimmed file has no video")
                expect(abs((info?.duration ?? 0) - 1.0) < 0.35, "\(type.label): trimmed duration \(info?.duration ?? 0), expected ~1.0")
                expect(url.lastPathComponent == "sample Trimmed.\(type.primaryExtension)", "\(type.label): name \(url.lastPathComponent)")
            } catch {
                expect(false, "\(type.label): trim threw \(error)")
            }
        }
        // Open-ended trim (start only).
        let mp4 = Fixtures.fixture(FileTypes.mp4)!
        let tail = try await engine.exportVideo(source: mp4, trim: TrimRange(startSeconds: 1.2, endSeconds: nil), bitrate: nil, runner: ProcessRunner())
        expect(abs((Validate.probe(tail)?.duration ?? 0) - 0.8) < 0.35, "open-ended trim duration \(Validate.probe(tail)?.duration ?? 0)")
    }

    // MARK: Metadata

    func testMetadataStripRemovesGPSAndExifAndKeepsOrientation() throws {
        let out = Env.outputDir("tools/metadata")
        let engine = Env.engine(output: out)
        let jpg = Fixtures.fixture(FileTypes.jpeg)!
        let before = ImageIOBridge.properties(of: jpg).map(\.0)
        expect(before.contains { $0.hasPrefix("{GPS}") }, "fixture lacks GPS")
        let clean = try engine.stripMetadata(jpg)
        let after = ImageIOBridge.properties(of: clean)
        expect(!after.contains { $0.0.hasPrefix("{GPS}") }, "GPS survived: \(after.filter { $0.0.hasPrefix("{GPS}") })")
        expect(!after.contains { $0.1.contains("secret comment") || $0.1.contains("PithCam") }, "EXIF/TIFF text survived")
        expect(clean.lastPathComponent == "sample Clean.jpg", "name \(clean.lastPathComponent)")

        // A rotated (orientation 6) photo comes out upright with its pixels rotated.
        let rotated = Env.fixturesDir.appendingPathComponent("rotated.jpg")
        Fixtures.writeImage(Fixtures.sampleImage(width: 401, height: 301), rotated, FileTypes.jpeg.uti, properties: Fixtures.exifWithGPS(orientation: 6))
        let upright = try engine.stripMetadata(rotated)
        let info = Validate.image(upright)
        expect(info?.width == 301 && info?.height == 401, "rotated photo cleaned to \(info?.width ?? 0)×\(info?.height ?? 0), expected 301×401")
        let orientation = ImageIOBridge.properties(of: upright).first { $0.0 == "Orientation" }?.1
        expect(orientation == nil || orientation == "1", "orientation tag \(orientation ?? "")")

        // Every writable format keeps its format.
        for type in imageFixtures {
            guard let source = Fixtures.fixture(type) else { continue }
            do {
                let url = try engine.stripMetadata(source)
                expect(Validate.image(url) != nil, "\(type.label): cleaned output unreadable")
            } catch {
                expect(false, "\(type.label): metadata strip threw \(error)")
            }
        }
    }

    // MARK: Edit, annotate, redact, add background, crop

    func testEditorsSaveEveryImageFormat() throws {
        let out = Env.outputDir("tools/editors")
        let engine = Env.engine(output: out)
        for type in imageFixtures {
            guard let source = Fixtures.fixture(type) else { expect(false, "\(type.label): no fixture"); continue }
            let image = try ImageIOBridge.loadOriented(source)
            let marks = [AnnotationMark(kind: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)], text: "", color: RGBStop(r: 1, g: 0, b: 0), width: 6),
                         AnnotationMark(kind: .arrow, points: [CGPoint(x: 20, y: 60), CGPoint(x: 90, y: 60)], text: "", color: RGBStop(r: 0, g: 1, b: 0), width: 4),
                         AnnotationMark(kind: .text, points: [CGPoint(x: 10, y: 50)], text: "Hi", color: RGBStop(r: 0, g: 0, b: 0), width: 3)]
            let steps: [(String, () throws -> URL)] = [
                ("Edit", { try engine.saveKeepingFormat(ImageAdjust.render(image, brightness: 0.2, contrast: 1.1, saturation: 1.2, sharpness: 0.5)!, source: source, suffix: " Edited") }),
                ("Annotate", { try engine.saveKeepingFormat(AnnotationRenderer.render(base: image, marks: marks)!, source: source, suffix: " Annotated") }),
                ("Redact", { try engine.saveKeepingFormat(AnnotationRenderer.redact(base: image, boxes: [CGRect(x: 5, y: 5, width: 40, height: 30)])!, source: source, suffix: " Redacted") }),
                ("Add BG", { try engine.addBackground(ImageComposer.addBackground(image: image, padding: 48, cornerRadius: 24, shadowRadius: 24, background: .solid(1, 0.8, 0.6), aspect: .auto)!, source: source) }),
                ("Crop", { try engine.crop(image, source: source, to: PixelRect(x: 10, y: 10, width: 50, height: 40)) })
            ]
            for (tool, step) in steps {
                do {
                    let url = try step()
                    guard let info = Validate.image(url) else { expect(false, "\(type.label) \(tool): unreadable output"); continue }
                    expect(info.width > 0, "\(type.label) \(tool): empty")
                } catch {
                    expect(false, "\(type.label) \(tool): threw \(error)")
                }
            }
        }
    }

    func testEditorPixelsLandWhereTheEditorPutThem() throws {
        let out = Env.outputDir("tools/editor-pixels")
        let engine = Env.engine(output: out)
        let png = Fixtures.fixture(FileTypes.png)!
        let image = try ImageIOBridge.loadOriented(png)

        // Crop: PixelRect is top-left based (the crop canvas). The top-right quadrant is orange.
        let cropped = try engine.crop(image, source: png, to: PixelRect(x: 300, y: 10, width: 60, height: 40))
        let ci = try ImageIOBridge.loadOriented(cropped)
        expect(ci.width == 60 && ci.height == 40, "crop size \(ci.width)×\(ci.height)")
        let cp = Validate.pixel(ci, x: 30, y: 20)
        expect(cp.r > 200 && cp.g < 150 && cp.b < 80, "crop of the top-right came out (\(cp.r),\(cp.g),\(cp.b)), expected orange")

        // Redact: a top-left box turns black; elsewhere unchanged.
        let redacted = try engine.saveKeepingFormat(AnnotationRenderer.redact(base: image, boxes: [CGRect(x: 300, y: 10, width: 60, height: 40)])!, source: png, suffix: " Redacted")
        let ri = try ImageIOBridge.loadOriented(redacted)
        let rp = Validate.pixel(ri, x: 330, y: 30)
        expect(rp.r < 10 && rp.g < 10 && rp.b < 10 && rp.a > 250, "redacted pixel (\(rp.r),\(rp.g),\(rp.b),\(rp.a))")
        let untouched = Validate.pixel(ri, x: 20, y: 20)
        expect(untouched.b > 180, "redact touched other pixels")
        expect(Validate.image(redacted)?.type == FileTypes.png.uti, "redact changed the format")

        // Annotate: a pen stroke at top-left (10,10)→(60,10) is red.
        let marked = AnnotationRenderer.render(base: image, marks: [AnnotationMark(kind: .pen, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10)], text: "", color: RGBStop(r: 1, g: 0, b: 0), width: 6)])!
        let ap = Validate.pixel(try ImageIOBridge.loadOriented(try engine.saveKeepingFormat(marked, source: png, suffix: " Annotated")), x: 35, y: 10)
        expect(ap.r > 200 && ap.g < 60 && ap.b < 60, "annotation pixel (\(ap.r),\(ap.g),\(ap.b))")

        // Annotate text: the label is actually drawn, upright, at its top-left point.
        let texted = AnnotationRenderer.render(base: image, marks: [AnnotationMark(kind: .text, points: [CGPoint(x: 220, y: 40)], text: "WWW", color: RGBStop(r: 0, g: 0, b: 0), width: 4)])!
        let dark = Validate.countPixels(texted, in: CGRect(x: 220, y: 40, width: 120, height: 40)) { $0.r < 60 && $0.g < 60 && $0.b < 60 && $0.a > 200 }
        expect(dark > 50, "text annotation drew \(dark) dark pixels below its anchor")
        let above = Validate.countPixels(texted, in: CGRect(x: 220, y: 0, width: 120, height: 36)) { $0.r < 60 && $0.g < 60 && $0.b < 60 && $0.a > 200 }
        expect(above < 10, "text annotation spilled \(above) pixels above its anchor (drawn flipped?)")

        // Edit: brightness up makes the blue half lighter.
        let edited = ImageAdjust.render(image, brightness: 0.3, contrast: 1, saturation: 1, sharpness: 0)!
        let before = Validate.pixel(image, x: 20, y: 20)
        let after = Validate.pixel(edited, x: 20, y: 20)
        expect(after.r + after.g + after.b > before.r + before.g + before.b + 60, "brightness didn't brighten (\(before) → \(after))")
        expect(edited.width == image.width && edited.height == image.height, "edit changed size")

        // Add background: canvas grows by the padding; PNG keeps the alpha-free card.
        let composed = ImageComposer.addBackground(image: image, padding: 48, cornerRadius: 24, shadowRadius: 24, background: .solid(1, 0.8, 0.6), aspect: .auto)!
        let bg = try engine.addBackground(composed, source: png)
        let bi = Validate.image(bg)
        expect((bi?.width ?? 0) >= image.width + 96 && (bi?.height ?? 0) >= image.height + 96, "background canvas \(bi?.width ?? 0)×\(bi?.height ?? 0)")
        let corner = Validate.pixel(try ImageIOBridge.loadOriented(bg), x: 2, y: 2)
        expect(corner.r > 240 && corner.g > 190 && corner.g < 220, "background fill (\(corner.r),\(corner.g),\(corner.b))")
    }

    // MARK: Merge and split

    func testMergePDFsImagesAndMixed() throws {
        let out = Env.outputDir("tools/merge")
        let engine = Env.engine(output: out)
        let pdf = Fixtures.fixture(FileTypes.pdf)!
        let second = out.appendingPathComponent("second.pdf")
        try FileManager.default.copyItem(at: pdf, to: second)
        let images = imageFixtures.compactMap { Fixtures.fixture($0) }

        let pdfOnly = try engine.merge([pdf, second])
        expect(PDFDocument(url: pdfOnly[0])?.pageCount == 6, "PDF+PDF pages \(PDFDocument(url: pdfOnly[0])?.pageCount ?? 0)")
        expect(pdfOnly[0].lastPathComponent == "sample Merged.pdf", "merge name \(pdfOnly[0].lastPathComponent)")
        expect(PDFDocument(url: pdfOnly[0])?.page(at: 3)?.string?.contains("page 1") == true, "second PDF not appended in order")
        // Merging must not empty the sources.
        expect(PDFDocument(url: pdf)?.pageCount == 3, "source PDF changed")

        let imageOnly = try engine.merge(images)
        expect(PDFDocument(url: imageOnly[0])?.pageCount == images.count, "images-only pages \(PDFDocument(url: imageOnly[0])?.pageCount ?? 0), expected \(images.count)")

        let mixed = try engine.merge([Fixtures.fixture(FileTypes.png)!, pdf, Fixtures.fixture(FileTypes.heic)!])
        let mixedDoc = PDFDocument(url: mixed[0])
        expect(mixedDoc?.pageCount == 5, "mixed pages \(mixedDoc?.pageCount ?? 0)")
        expect(mixedDoc?.page(at: 1)?.string?.contains("page 1") == true, "mixed order wrong")
        // Named after the first file; earlier merges in this folder took "Merged" and "Merged 2".
        expect(mixed[0].lastPathComponent == "sample Merged 3.pdf", "mixed name \(mixed[0].lastPathComponent)")

        // Non-mergeable files are ignored; fewer than two candidates is an error.
        let withText = try engine.merge([pdf, Fixtures.fixture(FileTypes.text)!, second])
        expect(PDFDocument(url: withText[0])?.pageCount == 6, "text file not ignored")
        expect((try? engine.merge([pdf, Fixtures.fixture(FileTypes.text)!])) == nil, "merge of one PDF should fail")

        // The Tools wheel offers MERGE for exactly these drops.
        let offers = { (paths: [URL]) in WheelContents.build(kind: .tools, session: DragSession(changeCount: 1, filePaths: paths.map(\.path), hasFilePromise: false, promisedTypeIdentifiers: [], location: .zero), availability: Env.tools).segments }
        expect(offers([pdf, second]).contains { $0.title == "MERGE" && $0.enabled }, "PDF pair lacks MERGE")
        expect(offers(Array(images.prefix(2))).contains { $0.title == "MERGE" && $0.enabled }, "image pair lacks MERGE")
        expect(offers([pdf, images[0]]).contains { $0.title == "MERGE" && $0.enabled }, "mixed pair lacks MERGE")
        expect(!offers([pdf]).contains { $0.title == "MERGE" && $0.enabled }, "single PDF has MERGE enabled")
    }

    func testSplitPDF() throws {
        let out = Env.outputDir("tools/split")
        let engine = Env.engine(output: out)
        let pdf = Fixtures.fixture(FileTypes.pdf)!
        let pages = try engine.split(pdf)
        expect(pages.map(\.lastPathComponent) == ["sample page 1.pdf", "sample page 2.pdf", "sample page 3.pdf"], "split names \(pages.map(\.lastPathComponent))")
        for (index, url) in pages.enumerated() {
            let doc = PDFDocument(url: url)
            expect(doc?.pageCount == 1, "\(url.lastPathComponent): \(doc?.pageCount ?? 0) pages")
            expect(doc?.page(at: 0)?.string?.contains("page \(index + 1)") == true, "\(url.lastPathComponent) has the wrong page")
        }
        expect(PDFDocument(url: pages[1])?.page(at: 0)?.bounds(for: .mediaBox).width == 792, "landscape page lost its size")
        expect(PDFDocument(url: pdf)?.pageCount == 3, "split changed the source")
        // Splitting again doesn't overwrite.
        let again = try engine.split(pdf)
        expect(again[0].lastPathComponent == "sample page 1 2.pdf", "second split name \(again[0].lastPathComponent)")
    }

    func testPDFPagesRenderAtTheirOwnSize() async throws {
        let out = Env.outputDir("tools/pdf-render")
        var engine = Env.engine(output: out)
        engine.settings.pdfRenderDPI = 144
        let offer = ConverterRegistry.conversionOffers(for: FileTypes.pdf, tools: Env.tools).first { $0.label == "PNG" }!
        let pages = try await engine.convert(Fixtures.fixture(FileTypes.pdf)!, offer: offer, runner: ProcessRunner())
        expect(pages.map(\.lastPathComponent) == ["sample page 1.png", "sample page 2.png", "sample page 3.png"], "page names \(pages.map(\.lastPathComponent))")
        let first = Validate.image(pages[0]), second = Validate.image(pages[1])
        expect(first?.width == 1224 && first?.height == 1584, "page 1 at 144 DPI is \(first?.width ?? 0)×\(first?.height ?? 0)")
        expect(second?.width == 1584 && second?.height == 1224, "landscape page is \(second?.width ?? 0)×\(second?.height ?? 0)")
    }
}
