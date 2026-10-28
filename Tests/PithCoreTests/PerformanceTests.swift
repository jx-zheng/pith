import XCTest
@testable import PithCore

final class PerformanceTests: XCTestCase {
    func testPreviewLongEdgeIsTwiceTheWindowInsideTheCap() {
        XCTAssertEqual(PreviewDecode.maxPixelSize(windowLongEdge: 860), 1720)
        XCTAssertEqual(PreviewDecode.maxPixelSize(windowLongEdge: 820), 1640)
        XCTAssertEqual(PreviewDecode.maxPixelSize(windowLongEdge: 780), 1600, "below 1600 clamps up")
        XCTAssertEqual(PreviewDecode.maxPixelSize(windowLongEdge: 400), 1600)
        XCTAssertEqual(PreviewDecode.maxPixelSize(windowLongEdge: 2000), 2048, "above 2048 clamps down")
        XCTAssertEqual(PreviewDecode.lowerBound, 1600)
        XCTAssertEqual(PreviewDecode.upperBound, 2048)
    }

    func testProgressGatePublishesOnDeltaOrInterval() {
        var gate = ProgressPublishGate()
        XCTAssertTrue(gate.shouldPublish(0.01, now: 0))
        XCTAssertFalse(gate.shouldPublish(0.012, now: 0.05), "under 0.5% and under 100ms")
        XCTAssertTrue(gate.shouldPublish(0.015, now: 0.05), "0.5% from the last publish")
        XCTAssertFalse(gate.shouldPublish(0.016, now: 0.12))
        XCTAssertTrue(gate.shouldPublish(0.016, now: 0.15), "100ms since the last publish")
        XCTAssertTrue(gate.shouldPublish(0.0, now: 0.15), "a backwards jump of 0.5% still publishes")
    }
}
