import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
import PithCore
@testable import PithEngine

/// Shared test environment: real external tools, a scratch root under .build, and fixtures
/// generated once per run with ImageIO, PDFKit, ffmpeg, pandoc, LibreOffice, ditto and tar.
enum Env {
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Outside the temporary directory on purpose, so outputs aren't redirected to Downloads.
    static let root = packageRoot.appendingPathComponent(".build/pith-tests", isDirectory: true)
    static let fixturesDir = root.appendingPathComponent("fixtures", isDirectory: true)

    static let tools: ToolAvailability = {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":" + ToolLocator.userBin
        return ToolLocator.availability(settings: .default, pathEnvironment: path) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    static func outputDir(_ name: String) -> URL {
        let url = root.appendingPathComponent("out/\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func engine(output: URL?, tools: ToolAvailability = Env.tools) -> ConversionEngine {
        var settings = PithSettings.default
        settings.pdfRenderDPI = 72
        settings.videoBitrateMbps = 1
        if let output { settings.outputLocation = .directory(output.path) }
        return ConversionEngine(settings: settings, tools: tools)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        let outFile = FileManager.default.temporaryDirectory.appendingPathComponent("pith-test-\(UUID().uuidString).out")
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("pith-test-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outFile)
            try? FileManager.default.removeItem(at: errFile)
        }
        process.standardOutput = try! FileHandle(forWritingTo: outFile)
        process.standardError = try! FileHandle(forWritingTo: errFile)
        do { try process.run() } catch { return (-1, "", "\(error)") }
        process.waitUntilExit()
        let out = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
        return (process.terminationStatus, out, err)
    }
}

// MARK: - Fixtures

/// One fixture per catalog type, keyed by `FileType.family`.
enum Fixtures {
    static let marker = "Pith fixture"

    static let all: [String: URL] = {
        let fm = FileManager.default
        try? fm.removeItem(at: Env.fixturesDir)
        try! fm.createDirectory(at: Env.fixturesDir, withIntermediateDirectories: true)
        var map: [String: URL] = [:]
        func url(_ name: String) -> URL { Env.fixturesDir.appendingPathComponent(name) }
        func add(_ family: String, _ u: URL) {
            if fm.fileExists(atPath: u.path) { map[family] = u } else { NSLog("Fixture missing: \(u.lastPathComponent)") }
        }

        // Images: 401×301 (odd on purpose), opaque left half, transparent bottom-right quadrant.
        let image = sampleImage(width: 401, height: 301)
        let png = url("sample.png"); writeImage(image, png, UTType.png.identifier); add("png", png)
        let jpg = url("sample.jpg"); writeImage(image, jpg, UTType.jpeg.identifier, properties: exifWithGPS(orientation: 1)); add("jpeg", jpg)
        let heic = url("sample.heic"); writeImage(image, heic, "public.heic"); add("heic", heic)
        let tiff = url("sample.tiff"); writeImage(image, tiff, UTType.tiff.identifier); add("tiff", tiff)
        let bmp = url("sample.bmp"); writeImage(image, bmp, UTType.bmp.identifier); add("bmp", bmp)
        let gif = url("sample.gif"); writeAnimatedGIF(gif, frames: 3); add("gif", gif)
        if let ffmpeg = Env.tools.ffmpeg {
            let webp = url("sample.webp"); Env.run(ffmpeg, ["-y", "-v", "error", "-i", png.path, webp.path]); add("webp", webp)
            let avif = url("sample.avif"); Env.run(ffmpeg, ["-y", "-v", "error", "-i", png.path, "-c:v", "libaom-av1", "-still-picture", "1", avif.path]); add("avif", avif)
        }

        // PDF: three pages, the second landscape, with real text on each.
        let pdf = url("sample.pdf"); writePDF(pdf, pages: [(612, 792), (792, 612), (612, 792)]); add("pdf", pdf)

        // Video and audio from lavfi test sources.
        if let ffmpeg = Env.tools.ffmpeg {
            let src = ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=2",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-shortest"]
            let videos: [(String, String, [String])] = [
                ("mp4", "sample.mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
                ("mov", "sample.mov", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
                ("mkv", "sample.mkv", ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
                ("webm", "sample.webm", ["-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus"]),
                ("avi", "sample.avi", ["-c:v", "mpeg4", "-c:a", "libmp3lame"])
            ]
            for (family, name, codec) in videos {
                let u = url(name); Env.run(ffmpeg, src + codec + [u.path]); add(family, u)
            }
            let tone = ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
            let audio: [(String, String, [String])] = [
                ("mp3", "sample.mp3", ["-c:a", "libmp3lame"]),
                ("m4a", "sample.m4a", ["-c:a", "aac"]),
                ("wav", "sample.wav", ["-c:a", "pcm_s16le"]),
                ("flac", "sample.flac", ["-c:a", "flac"]),
                ("ogg", "sample.ogg", ["-c:a", "libvorbis"]),
                ("opus", "sample.opus", ["-c:a", "libopus"]),
                ("aiff", "sample.aiff", ["-c:a", "pcm_s16be"])
            ]
            for (family, name, codec) in audio {
                let u = url(name); Env.run(ffmpeg, tone + codec + [u.path]); add(family, u)
            }
        }

        // Documents.
        let markdown = "# \(marker)\n\nA paragraph with *emphasis* and a [link](https://example.com).\n\n- one\n- two\n"
        let md = url("sample.md"); try! markdown.write(to: md, atomically: true, encoding: .utf8); add("markdown", md)
        let html = url("sample.html")
        try! "<!doctype html><html><head><meta charset=\"utf-8\"><title>t</title></head><body><h1>\(marker)</h1><p>Hello <b>bold</b> world.</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        add("html", html)
        let txt = url("sample.txt"); try! "\(marker)\n\nPlain text line two.\n* not a list *\n".write(to: txt, atomically: true, encoding: .utf8); add("text", txt)
        let rtf = url("sample.rtf")
        try! "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 \(marker)\\par Second line.\\par}".write(to: rtf, atomically: true, encoding: .utf8)
        add("rtf", rtf)
        if let pandoc = Env.tools.pandoc {
            let docx = url("sample.docx"); Env.run(pandoc, [md.path, "-o", docx.path]); add("docx", docx)
            let epub = url("sample.epub"); Env.run(pandoc, [md.path, "--metadata", "title=Sample", "-o", epub.path]); add("epub", epub)
        }

        // Spreadsheets and presentations.
        let csv = url("sample.csv"); try! "Name,Qty\n\(marker),3\n\"Pear, green\",5\n".write(to: csv, atomically: true, encoding: .utf8); add("csv", csv)
        let tsv = url("sample.tsv"); try! "Name\tQty\n\(marker)\t3\nPear\t5\n".write(to: tsv, atomically: true, encoding: .utf8); add("tsv", tsv)
        if let soffice = Env.tools.soffice {
            let work = Env.root.appendingPathComponent("soffice-work", isDirectory: true)
            try? fm.removeItem(at: work)
            try! fm.createDirectory(at: work, withIntermediateDirectories: true)
            for (family, format) in [("xlsx", "xlsx"), ("xls", "xls"), ("ods", "ods")] {
                Env.run(soffice, ["--headless", "--norestore", "--nolockcheck", "--convert-to", format, "--outdir", work.path, csv.path])
                let produced = work.appendingPathComponent("sample.\(format)")
                let target = url("sample.\(format)")
                try? fm.moveItem(at: produced, to: target)
                add(family, target)
            }
            for (family, format) in [("pptx", "pptx"), ("ppt", "ppt")] {
                Env.run(soffice, ["--headless", "--norestore", "--nolockcheck", "--infilter=impress_pdf_import", "--convert-to", format, "--outdir", work.path, pdf.path])
                let produced = work.appendingPathComponent("sample.\(format)")
                let target = url("sample.\(format)")
                try? fm.moveItem(at: produced, to: target)
                add(family, target)
            }
        }

        // Subtitles.
        let srt = url("sample.srt")
        try! "1\n00:00:01,000 --> 00:00:02,500\n\(marker)\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond cue\n".write(to: srt, atomically: true, encoding: .utf8)
        add("srt", srt)
        let vtt = url("sample.vtt")
        try! "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\n\(marker)\n\n00:00:03.000 --> 00:00:04.000\nSecond cue\n".write(to: vtt, atomically: true, encoding: .utf8)
        add("vtt", vtt)

        // Folder and archives.
        let folder = url("Sample Folder")
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! "\(marker) a\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try! "\(marker) b\n".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        add("folder", folder)
        let zip = url("sample.zip"); Env.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, zip.path]); add("zip", zip)
        let tar = url("sample.tar"); Env.run("/usr/bin/tar", ["-cf", tar.path, "-C", Env.fixturesDir.path, "Sample Folder"]); add("tar", tar)
        let tgz = url("sample.tar.gz"); Env.run("/usr/bin/tar", ["-czf", tgz.path, "-C", Env.fixturesDir.path, "Sample Folder"]); add("gzip", tgz)
        return map
    }()

    static func fixture(_ type: FileType) -> URL? { all[type.family] }

    static func sampleImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Opaque everywhere except the bottom-right quadrant (CG origin is bottom-left).
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: height / 2, width: width - width / 2, height: height - height / 2))
        return context.makeImage()!
    }

    static func exifWithGPS(orientation: Int) -> [CFString: Any] {
        [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PithCam", kCGImagePropertyTIFFModel: "Test 1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret comment", kCGImagePropertyExifDateTimeOriginal: "2026:10:19 12:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 43.65, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 79.38, kCGImagePropertyGPSLongitudeRef: "W"]
        ]
    }

    static func writeImage(_ image: CGImage, _ url: URL, _ uti: String, properties: [CFString: Any] = [:]) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    static func writeAnimatedGIF(_ url: URL, frames: Int) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            let context = CGContext(data: nil, width: 101, height: 75, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(frames), green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 101, height: 75))
            CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
    }

    static func writePDF(_ url: URL, pages: [(CGFloat, CGFloat)]) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for (index, size) in pages.enumerated() {
            var media = CGRect(x: 0, y: 0, width: size.0, height: size.1)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 120, height: 80))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("\(marker) page \(index + 1)" as NSString).draw(at: CGPoint(x: 72, y: size.1 - 120), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }
}

// MARK: - Validation

struct MediaInfo {
    var streams: [String]   // codec_type list
    var codecs: [String]
    var duration: Double
    var formatName: String
    var bitRate: Double
    var width: Int
    var height: Int
}

enum Validate {
    static func probe(_ url: URL) -> MediaInfo? {
        guard let ffprobe = Env.tools.ffprobe else { return nil }
        let result = Env.run(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height:format=duration,format_name,bit_rate", "-of", "json", url.path])
        guard result.status == 0, let data = result.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        let video = streams.first { $0["codec_type"] as? String == "video" }
        return MediaInfo(
            streams: streams.compactMap { $0["codec_type"] as? String },
            codecs: streams.compactMap { $0["codec_name"] as? String },
            duration: Double(format["duration"] as? String ?? "") ?? 0,
            formatName: format["format_name"] as? String ?? "",
            bitRate: Double(format["bit_rate"] as? String ?? "") ?? 0,
            width: video?["width"] as? Int ?? 0,
            height: video?["height"] as? Int ?? 0
        )
    }

    static func image(_ url: URL) -> (type: String, width: Int, height: Int, frames: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (type, image.width, image.height, CGImageSourceGetCount(source))
    }

    static func zipEntries(_ url: URL) -> [String]? {
        let result = Env.run("/usr/bin/zipinfo", ["-1", url.path])
        guard result.status == 0 else { return nil }
        return result.out.split(separator: "\n").map(String.init)
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    static func head(_ url: URL, _ count: Int) -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        return [UInt8](handle.readData(ofLength: count))
    }

    /// Returns nil when `url` is a valid file of `type`, otherwise the reason it isn't.
    static func check(_ url: URL, as type: FileType, sourceDuration: Double = 0) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "missing \(url.lastPathComponent)" }
        if type.kind == .folder {
            guard isDir.boolValue else { return "not a folder" }
            let items = (try? fm.subpathsOfDirectory(atPath: url.path)) ?? []
            return items.contains { $0.hasSuffix("a.txt") } ? nil : "extracted folder lacks a.txt: \(items)"
        }
        guard size(url) > 0 else { return "empty \(url.lastPathComponent)" }
        switch type.kind {
        case .image:
            guard let info = image(url) else { return "ImageIO can't decode" }
            guard info.type == type.uti || (type.family == "heic" && info.type.contains("hei")) else { return "type \(info.type), expected \(type.uti)" }
            return info.width > 0 && info.height > 0 ? nil : "zero size"
        case .pdf:
            guard let doc = PDFDocument(url: url) else { return "PDFKit can't open" }
            return doc.pageCount > 0 ? nil : "no pages"
        case .video, .audio:
            guard let info = probe(url) else { return "ffprobe failed" }
            if type.kind == .video, !info.streams.contains("video") { return "no video stream (\(info.streams))" }
            if type.kind == .audio, !info.streams.contains("audio") { return "no audio stream (\(info.streams))" }
            if type.kind == .audio, info.streams.contains("video") { return "audio file has a video stream" }
            if sourceDuration > 0, abs(info.duration - sourceDuration) > 0.6, type.family != "gif" { return "duration \(info.duration) vs \(sourceDuration)" }
            return nil
        case .document, .presentation, .spreadsheet, .subtitle, .archive, .other, .folder:
            return checkText(url, as: type)
        }
    }

    static func checkText(_ url: URL, as type: FileType) -> String? {
        switch type.family {
        case "docx", "epub", "xlsx", "ods", "pptx", "zip":
            guard let entries = zipEntries(url) else { return "not a zip container" }
            let needle: String
            switch type.family {
            case "docx": needle = "word/document.xml"
            case "epub": needle = "mimetype"
            case "xlsx": needle = "xl/workbook.xml"
            case "ods": needle = "content.xml"
            case "pptx": needle = "ppt/presentation.xml"
            default: needle = ""
            }
            return needle.isEmpty || entries.contains(needle) ? nil : "missing \(needle) in \(entries.prefix(6))"
        case "xls", "ppt":
            return head(url, 4) == [0xD0, 0xCF, 0x11, 0xE0] ? nil : "not an OLE2 file"
        case "gzip":
            guard head(url, 2) == [0x1F, 0x8B] else { return "not gzip" }
            let listing = Env.run("/usr/bin/tar", ["-tzf", url.path])
            return listing.status == 0 && !listing.out.isEmpty ? nil : "tar can't list it"
        case "rtf":
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard text.hasPrefix("{\\rtf") else { return "RTF lacks {\\rtf header: \(text.prefix(30))" }
            return text.contains("Pith") ? nil : "RTF lacks fixture text"
        case "html":
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.lowercased().contains("<html") && text.contains("Pith") ? nil : "HTML not a full document: \(text.prefix(60))"
        default:
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard !text.isEmpty else { return "not UTF-8 text" }
            if type.family == "vtt", !text.hasPrefix("WEBVTT") { return "VTT header missing" }
            if type.family == "srt", !text.contains("-->") { return "SRT has no cues" }
            if type.family == "tsv", !text.contains("\t") { return "TSV has no tabs" }
            return text.contains("Pith") ? nil : "missing fixture text: \(text.prefix(80))"
        }
    }

    /// Pixels in a top-left based rect that satisfy `predicate`.
    static func countPixels(_ image: CGImage, in rect: CGRect, where predicate: ((r: Int, g: Int, b: Int, a: Int)) -> Bool) -> Int {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        // Bitmap memory rows run top to bottom.
        for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                let i = (y * width + x) * 4
                if predicate((Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))) { count += 1 }
            }
        }
        return count
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left based coordinates.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }
}

// MARK: - Matrix reporting

final class Matrix {
    static let shared = Matrix()
    private let lock = NSLock()
    private(set) var rows: [(category: String, passed: Int, failed: Int)] = []

    func report(_ category: String, passed: Int, failed: [String]) {
        lock.lock(); rows.append((category, passed, failed.count)); lock.unlock()
        print("MATRIX \(category): \(passed) passed, \(failed.count) failed")
        for failure in failed { print("  FAIL \(failure)") }
    }
}
