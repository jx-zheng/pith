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
        // Thresholds are ≥0.5% or ≥100ms. The samples sit clear of those edges:
        // 0.015 - 0.01 and 0.15 - 0.05 both fall short of 0.005 and 0.1 in Double.
        var gate = ProgressPublishGate()
        XCTAssertTrue(gate.shouldPublish(0.01, now: 0))
        XCTAssertFalse(gate.shouldPublish(0.012, now: 0.05), "under 0.5% and under 100ms")
        XCTAssertTrue(gate.shouldPublish(0.02, now: 0.05), "over 0.5% from the last publish")
        XCTAssertFalse(gate.shouldPublish(0.021, now: 0.12), "tiny move, under 100ms since the last publish")
        XCTAssertTrue(gate.shouldPublish(0.021, now: 0.16), "over 100ms since the last publish")
        XCTAssertTrue(gate.shouldPublish(0.0, now: 0.16), "a backwards jump over 0.5% still publishes")
    }
}
