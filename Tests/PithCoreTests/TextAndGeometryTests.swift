import XCTest
@testable import PithCore

final class TextAndGeometryTests: XCTestCase {
    func testCSVAndTSVRoundTripQuotes() {
        let csv = "name,note\nAda,\"hello, world\"\n"
        let rows = CSVTSV.parse(csv)
        XCTAssertEqual(rows, [["name", "note"], ["Ada", "hello, world"]])
        let tsv = CSVTSV.convert(text: csv, toTSV: true)
        XCTAssertTrue(tsv.contains("hello, world"))
        XCTAssertTrue(tsv.contains("\t"))
        let back = CSVTSV.parse(CSVTSV.convert(text: tsv, toTSV: false))
        XCTAssertEqual(back, rows)
    }

    func testSRTAndVTT() {
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nHello\n\n2\n00:00:05,000 --> 00:00:06,500\nAgain\n"
        let vtt = Subtitles.srtToVTT(srt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:04.000"))
        let back = Subtitles.vttToSRT(vtt)
        XCTAssertTrue(back.contains("00:00:01,000 --> 00:00:04,000"))
        XCTAssertTrue(back.contains("Hello"))
    }

    func testCropAspectLockAndClamp() {
        let locked = CropGeometry.applying(
            aspect: .square,
            to: PixelRect(x: 10, y: 20, width: 100, height: 40),
            imageWidth: 200,
            imageHeight: 200
        )
        XCTAssertEqual(locked.width, locked.height)
        XCTAssertEqual(locked.x, 10)
        let clamped = CropGeometry.clamped(
            PixelRect(x: -5, y: 180, width: 50, height: 80),
            imageWidth: 200,
            imageHeight: 200
        )
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertLessThanOrEqual(clamped.y + clamped.height, 200)
    }

    func testBackgroundCanvasRatio() {
        let canvas = BackgroundCanvas(imageWidth: 100, imageHeight: 100, padding: 10, aspect: .widescreen)
        let size = canvas.size
        XCTAssertEqual(size.height, 120)
        XCTAssertEqual(size.width, Int((120.0 * (16.0 / 9.0)).rounded()))
    }

    func testWheelHitTesting() {
        let geometry = WheelGeometry(outerRadius: 200, innerRadius: 80, gapRadians: 6.5 * .pi / 180, count: 4)
        XCTAssertEqual(geometry.index(at: Point(x: 0, y: -140), center: .zero), 0)
        XCTAssertEqual(geometry.index(at: Point(x: 140, y: 0), center: .zero), 1)
        XCTAssertEqual(geometry.index(at: Point(x: 0, y: 140), center: .zero), 2)
        XCTAssertEqual(geometry.index(at: Point(x: -140, y: 0), center: .zero), 3)
        XCTAssertNil(geometry.index(at: Point(x: 0, y: -20), center: .zero))
        XCTAssertNil(geometry.index(at: Point(x: 0, y: -260), center: .zero))
    }

    func testWheelNavigationWrapsAndConfirms() {
        var nav = WheelNavigation(count: 4)
        XCTAssertEqual(nav.handle(.right), .highlight(0))
        XCTAssertEqual(nav.handle(.number(3)), .highlight(2))
        XCTAssertEqual(nav.handle(.return), .confirm(2))
        _ = nav.handle(.number(1))
        XCTAssertEqual(nav.handle(.left), .highlight(3))
    }

    func testByteCount() {
        XCTAssertEqual(ByteCountFormat.string(bytes: 1_200_000), "1.1 MB")
    }

    func testCSVConverterWritesBesideDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("sheet.csv")
        let destination = directory.appendingPathComponent("sheet.tsv")
        try "a,b\n1,2\n".write(to: source, atomically: true, encoding: .utf8)
        let urls = try await CSVConverter().run(source: source, destination: destination, context: ConversionContext())
        XCTAssertEqual(urls, [destination])
        let text = try String(contentsOf: destination)
        XCTAssertTrue(text.contains("a\tb"))
        try? FileManager.default.removeItem(at: directory)
    }
}
