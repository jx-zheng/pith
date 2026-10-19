import XCTest
@testable import PithCore

final class RegistryTests: XCTestCase {
    func testJPEGWheelMatchesReferenceOrder() {
        let offers = ConverterRegistry.conversionOffers(for: FileTypes.jpeg, tools: ffmpeg)
        XCTAssertEqual(offers.map(\.label), ["PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "GIF"])
        XCTAssertFalse(offers.contains { $0.output.family == "jpeg" })
        XCTAssertEqual(offers.first { $0.label == "PNG" }?.backend, .imageIO)
        XCTAssertEqual(offers.first { $0.label == "WEBP" }?.backend, .ffmpeg)
        XCTAssertTrue(offers.first { $0.label == "WEBP" }?.isEnabled == true)
    }

    func testWebPDisabledWithoutFFmpeg() {
        let offers = ConverterRegistry.conversionOffers(for: FileTypes.png, tools: .none)
        let webp = offers.first { $0.label == "WEBP" }
        XCTAssertEqual(webp?.isEnabled, false)
        XCTAssertEqual(webp?.unavailableReason, "brew install ffmpeg")
    }

    func testPDFWheelMatchesReferenceOrder() {
        let offers = ConverterRegistry.conversionOffers(for: FileTypes.pdf, tools: soffice)
        XCTAssertEqual(offers.map(\.label), ["DOCX", "JPG", "PNG", "TXT"])
        XCTAssertEqual(offers.first { $0.label == "JPG" }?.backend, .pdfKit)
        XCTAssertEqual(offers.first { $0.label == "DOCX" }?.isEnabled, true)
    }

    func testPDFDocxGreyedOutWithoutTools() {
        let offers = ConverterRegistry.conversionOffers(for: FileTypes.pdf, tools: .none)
        XCTAssertEqual(offers.map(\.label), ["DOCX", "JPG", "PNG", "TXT"])
        XCTAssertEqual(offers.first { $0.label == "DOCX" }?.isEnabled, false)
    }

    func testVideoTargetsAndNativeRoute() {
        let offers = ConverterRegistry.conversionOffers(for: FileTypes.mp4, tools: ffmpeg)
        XCTAssertEqual(offers.map(\.label), ["MOV", "MKV", "WEBM", "AVI", "GIF", "MP3", "M4A"])
        XCTAssertEqual(offers.first { $0.label == "MOV" }?.backend, .avFoundation)
        XCTAssertEqual(offers.first { $0.label == "MKV" }?.backend, .ffmpeg)
        XCTAssertEqual(offers.first { $0.label == "M4A" }?.backend, .avFoundation)
        let missing = ConverterRegistry.conversionOffers(for: FileTypes.mkv, tools: .none)
        XCTAssertTrue(missing.allSatisfy { $0.isEnabled == false })
    }

    func testAudioTargets() {
        let offers = ConverterRegistry.conversionOffers(for: FileTypes.wav, tools: ffmpeg)
        XCTAssertEqual(offers.map(\.label), ["MP3", "M4A", "FLAC", "OGG", "OPUS", "AIFF"])
        XCTAssertTrue(offers.allSatisfy { $0.backend == .ffmpeg })
    }

    func testPandocDocumentsAndNativeFallback() {
        let withPandoc = ConverterRegistry.conversionOffers(for: FileTypes.docx, tools: pandoc)
        XCTAssertTrue(withPandoc.contains { $0.label == "MD" && $0.backend == .pandoc && $0.isEnabled })
        let native = ConverterRegistry.conversionOffers(for: FileTypes.rtf, tools: .none)
        XCTAssertEqual(native.first { $0.label == "TXT" }?.backend, .attributedString)
        XCTAssertEqual(native.first { $0.label == "TXT" }?.isEnabled, true)
        XCTAssertEqual(native.first { $0.label == "EPUB" }?.isEnabled, false)
    }

    func testSpreadsheetsSubtitlesArchives() {
        XCTAssertEqual(ConverterRegistry.conversionOffers(for: FileTypes.csv).map(\.label), ["TSV", "ZIP", "GZIP"])
        XCTAssertEqual(ConverterRegistry.conversionOffers(for: FileTypes.srt).map(\.label), ["VTT", "ZIP", "GZIP"])
        XCTAssertEqual(ConverterRegistry.conversionOffers(for: FileTypes.folder).map(\.label), ["ZIP", "GZIP"])
        XCTAssertEqual(ConverterRegistry.conversionOffers(for: FileTypes.zip).map(\.label), ["UNZIP"])
        let xlsx = ConverterRegistry.conversionOffers(for: FileTypes.xlsx, tools: soffice)
        XCTAssertTrue(xlsx.contains { $0.label == "PDF" && $0.backend == .libreOffice && $0.isEnabled })
        XCTAssertTrue(xlsx.contains { $0.label == "CSV" && $0.isEnabled })
    }

    func testExtensionAndUTILookup() {
        XCTAssertEqual(FileTypes.matching(pathExtension: "JPEG")?.label, "JPG")
        XCTAssertEqual(FileTypes.matching(path: "/tmp/notes.tar.gz")?.label, "GZIP")
        XCTAssertEqual(FileTypes.matching(uti: "public.png")?.label, "PNG")
    }

    func testImageToolsMatchReferenceOrder() {
        let tools = ToolRegistry.tools(for: [FileTypes.jpeg], tools: .none, fileCount: 1)
        XCTAssertEqual(tools.map(\.tool.label), ["COMPRESS", "METADATA", "EDIT", "ANNOTATE", "ADD BG", "CROP", "REDACT"])
    }

    func testVideoToolsRequireFFmpegAndPDFMergeNeedsTwoFiles() {
        let missing = ToolRegistry.tools(for: [FileTypes.mp4], tools: .none, fileCount: 1)
        XCTAssertTrue(missing.allSatisfy { $0.isEnabled == false })
        let one = ToolRegistry.tools(for: [FileTypes.pdf], tools: .none, fileCount: 1)
        XCTAssertEqual(one.first { $0.tool == .mergePDF }?.isEnabled, false)
        XCTAssertEqual(one.first { $0.tool == .splitPDF }?.isEnabled, true)
        let two = ToolRegistry.tools(for: [FileTypes.pdf, FileTypes.pdf], tools: .none, fileCount: 2)
        XCTAssertEqual(two.first { $0.tool == .mergePDF }?.isEnabled, true)
        let images = ToolRegistry.tools(for: [FileTypes.jpeg, FileTypes.jpeg], tools: .none, fileCount: 2)
        XCTAssertEqual(images.last?.tool, .mergePDF)
        let mixed = ToolRegistry.tools(for: [FileTypes.jpeg, FileTypes.pdf], tools: .none, fileCount: 2)
        XCTAssertEqual(mixed.map(\.tool), [.mergePDF])
    }

    private var ffmpeg: ToolAvailability {
        ToolAvailability(ffmpeg: "/opt/homebrew/bin/ffmpeg", ffprobe: "/opt/homebrew/bin/ffprobe")
    }

    private var pandoc: ToolAvailability {
        ToolAvailability(pandoc: "/opt/homebrew/bin/pandoc")
    }

    private var soffice: ToolAvailability {
        ToolAvailability(soffice: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
    }
}
