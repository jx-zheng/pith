import XCTest
@testable import PithCore

final class CommandTests: XCTestCase {
    func testH264VideoToolboxCommandAndSoftwareFallback() {
        let hardware = FFmpegScripts.videoEncoders(output: FileTypes.mp4, preference: .h264)
        XCTAssertEqual(hardware, [.h264VideoToolbox, .libx264])
        let hevc = FFmpegScripts.videoEncoders(output: FileTypes.mov, preference: .hevc)
        XCTAssertEqual(hevc, [.hevcVideoToolbox, .libx265])
        XCTAssertEqual(FFmpegScripts.videoEncoders(output: FileTypes.webm, preference: .h264), [.vp9])

        let spec = FFmpegScripts.transcode(
            ffmpeg: "/opt/homebrew/bin/ffmpeg",
            input: "/tmp/in.mov",
            output: "/tmp/out.mp4",
            outputType: FileTypes.mp4,
            encoder: .h264VideoToolbox,
            bitrate: "8.0M"
        )
        XCTAssertTrue(spec.arguments.contains("h264_videotoolbox"))
        XCTAssertTrue(spec.arguments.contains("pipe:1"))
        XCTAssertTrue(spec.arguments.contains("+faststart"))
        XCTAssertEqual(spec.progressOnStdout, true)

        let software = FFmpegScripts.transcode(
            ffmpeg: "ffmpeg",
            input: "in.mkv",
            output: "out.mp4",
            outputType: FileTypes.mp4,
            encoder: .libx264,
            bitrate: "8.0M"
        )
        XCTAssertTrue(software.arguments.contains("libx264"))
        XCTAssertFalse(software.arguments.contains("h264_videotoolbox"))
    }

    func testGIFTwoPassUsesPalettegen() {
        let passes = FFmpegScripts.gif(
            ffmpeg: "ffmpeg",
            input: "/tmp/clip.mp4",
            output: "/tmp/clip.gif",
            palettePath: "/tmp/palette.png",
            fps: 12,
            maxWidth: 480
        )
        XCTAssertEqual(passes.count, 2)
        XCTAssertTrue(passes[0].arguments.contains { $0.contains("palettegen") })
        XCTAssertTrue(passes[1].arguments.contains { $0.contains("paletteuse") })
        XCTAssertEqual(passes[1].progressOnStdout, true)
    }

    func testAudioExtractionDropsVideo() {
        let spec = FFmpegScripts.transcode(
            ffmpeg: "ffmpeg",
            input: "/tmp/a.mp4",
            output: "/tmp/a.mp3",
            outputType: FileTypes.mp3,
            encoder: .libx264,
            bitrate: "1M",
            audioOnly: true
        )
        XCTAssertTrue(spec.arguments.contains("-vn"))
        XCTAssertTrue(spec.arguments.contains("libmp3lame"))
    }

    func testTrimArguments() {
        let spec = FFmpegScripts.transcode(
            ffmpeg: "ffmpeg",
            input: "in.mp4",
            output: "out.mp4",
            outputType: FileTypes.mp4,
            encoder: .h264VideoToolbox,
            bitrate: "4.0M",
            trim: TrimRange(startSeconds: 1.5, endSeconds: 9)
        )
        XCTAssertTrue(spec.arguments.contains("-ss"))
        XCTAssertTrue(spec.arguments.contains("1.500"))
        XCTAssertTrue(spec.arguments.contains("-to"))
        XCTAssertTrue(spec.arguments.contains("9.000"))
    }

    func testProgressParser() {
        var parser = FFmpegProgressParser(duration: 10)
        XCTAssertEqual(parser.ingest(line: "out_time_us=5000000"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(parser.ingest(line: "out_time=00:00:02.500000"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(parser.ingest(line: "progress=end"), 1, accuracy: 0.0001)
        XCTAssertEqual(FFmpegProgressParser.parseTimestamp("01:02:03.5"), 3723.5)
    }

    func testPandocAndSofficeArguments() {
        let spec = PandocScripts.convert(
            pandoc: "/opt/homebrew/bin/pandoc",
            input: "/tmp/Notes.docx",
            output: "/tmp/Notes.md",
            from: FileTypes.docx,
            to: FileTypes.markdown
        )
        XCTAssertEqual(spec?.arguments, ["--from", "docx", "--to", "markdown", "--output", "/tmp/Notes.md", "/tmp/Notes.docx"])
        let office = SofficeScripts.convert(
            soffice: "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            input: "/tmp/Deck.pptx",
            outputDirectory: "/tmp/out",
            format: "pdf"
        )
        XCTAssertTrue(office.arguments.contains("--headless"))
        XCTAssertTrue(office.arguments.contains("--convert-to"))
        XCTAssertEqual(
            SofficeScripts.expectedOutput(input: "/tmp/Deck.pptx", outputDirectory: "/tmp/out", format: "pdf"),
            "/tmp/out/Deck.pdf"
        )
    }

    func testArchiveArguments() {
        let zip = ArchiveScripts.zip(source: "/tmp/Folder", destinationZip: "/tmp/Folder.zip")
        XCTAssertEqual(zip.arguments, ["-c", "-k", "--keepParent", "/tmp/Folder", "/tmp/Folder.zip"])
        let tar = ArchiveScripts.tarGzip(source: "/tmp/Folder", destination: "/tmp/Folder.tar.gz")
        XCTAssertEqual(tar.arguments, ["-czf", "/tmp/Folder.tar.gz", "-C", "/tmp", "Folder"])
        let untar = ArchiveScripts.untar(archive: "/tmp/Folder.tar.gz", destinationDirectory: "/tmp/out")
        XCTAssertEqual(untar.arguments.first, "-xzf")
    }

    func testToolLocatorOrder() {
        let found = ToolLocator.resolve(
            tool: .ffmpeg,
            override: "",
            pathEnvironment: "/usr/bin:/opt/homebrew/bin",
            exists: { $0 == "/opt/homebrew/bin/ffmpeg" }
        )
        XCTAssertEqual(found, "/opt/homebrew/bin/ffmpeg")
        let override = ToolLocator.resolve(
            tool: .ffmpeg,
            override: "/custom/ffmpeg",
            pathEnvironment: "",
            exists: { $0 == "/custom/ffmpeg" }
        )
        XCTAssertEqual(override, "/custom/ffmpeg")
        let fromPath = ToolLocator.resolve(
            tool: .pandoc,
            override: nil,
            pathEnvironment: "/opt/bin:/usr/bin",
            exists: { $0 == "/usr/bin/pandoc" }
        )
        XCTAssertEqual(fromPath, "/usr/bin/pandoc")
        XCTAssertNil(ToolLocator.resolve(tool: .soffice, override: " ", pathEnvironment: "", exists: { _ in false }))
    }
}
