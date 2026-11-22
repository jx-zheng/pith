import XCTest
@testable import PithCore

final class RingOpenPositionTests: XCTestCase {
    private func cache(
        center: Point,
        grab: Point? = nil,
        paths: [String] = ["/tmp/a.png"]
    ) -> CachedAnchor {
        CachedAnchor(
            paths: paths,
            center: center,
            grab: grab,
            source: .selectedElement,
            filename: "a.png",
            icon: nil,
            cell: nil
        )
    }

    func testDragOpensOnTheCachedOffsetInsteadOfThePointer() {
        let request = RingOpenRequest(
            mode: .drag,
            pointer: Point(x: 500, y: 400),
            dragOrigin: Point(x: 110, y: 100),
            cache: cache(center: Point(x: 100, y: 80), grab: Point(x: 110, y: 100))
        )
        let first = RingOpenPosition.first(request)
        XCTAssertEqual(first.center, Point(x: 490, y: 380))
        XCTAssertEqual(first.source, .dragOffset)
        XCTAssertEqual(first.reason, "cached-offset")
        XCTAssertFalse(first.provisionalPointer)
    }

    func testDragWithoutACacheStaysOnThePointer() {
        let pointer = Point(x: 12, y: 40)
        let first = RingOpenPosition.first(RingOpenRequest(mode: .drag, pointer: pointer, dragOrigin: pointer, cache: nil))
        XCTAssertEqual(first.center, pointer)
        XCTAssertTrue(first.provisionalPointer)
        XCTAssertEqual(first.reason, "pointer-pending")
    }

    func testClickPrefersTheCachedSelectionOverThePointer() {
        let cached = Point(x: 40, y: 50)
        let first = RingOpenPosition.first(RingOpenRequest(
            mode: .click,
            pointer: Point(x: 400, y: 400),
            dragOrigin: nil,
            cache: cache(center: cached)
        ))
        XCTAssertEqual(first.center, cached)
        XCTAssertEqual(first.reason, "cached-selection")
        XCTAssertFalse(first.provisionalPointer)
    }

    func testClickWithoutACacheUsesThePointer() {
        let pointer = Point(x: 8, y: 9)
        let first = RingOpenPosition.first(RingOpenRequest(mode: .click, pointer: pointer, dragOrigin: nil, cache: nil))
        XCTAssertEqual(first.center, pointer)
        XCTAssertTrue(first.provisionalPointer)
    }

    func testRefineNudgeMovesAndAFarPointerCorrectionDoesNot() {
        let shown = Point(x: 0, y: 0)
        let near = RingOpenPosition.refine(
            shown: shown,
            provisionalPointer: true,
            proposed: Point(x: 40, y: 0),
            allowLongMove: false
        )
        XCTAssertEqual(near, .move(Point(x: 40, y: 0), "refine"))

        let far = RingOpenPosition.refine(
            shown: shown,
            provisionalPointer: true,
            proposed: Point(x: 800, y: 0),
            allowLongMove: false
        )
        XCTAssertEqual(far, .stay("keep-pointer"))

        let changed = RingOpenPosition.refine(
            shown: shown,
            provisionalPointer: false,
            proposed: Point(x: 800, y: 0),
            allowLongMove: true
        )
        XCTAssertEqual(changed, .move(Point(x: 800, y: 0), "reanchor"))

        let keep = RingOpenPosition.refine(
            shown: shown,
            provisionalPointer: false,
            proposed: Point(x: 800, y: 0),
            allowLongMove: false
        )
        XCTAssertEqual(keep, .stay("keep-anchor"))
    }

    func testLatencyLinesNameTheActionAndTheDelta() {
        XCTAssertEqual(LatencyMark.key("open"), "latency open key")
        XCTAssertEqual(LatencyMark.show("switch"), "latency switch show")
        XCTAssertEqual(LatencyMark.frame("open", keyToFrameMilliseconds: 12.34), "latency open key->frame=12.3ms")
        XCTAssertEqual(LatencyMark.frame("switch", keyToFrameMilliseconds: 4), "latency switch key->frame=4.0ms")
    }
}
