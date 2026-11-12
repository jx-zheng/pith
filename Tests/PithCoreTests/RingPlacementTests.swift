import XCTest
@testable import PithCore

final class RingPlacementTests: XCTestCase {
    private let oldFile = "/Users/kevin/Desktop/notes.txt"
    private let newFile = "/Users/kevin/Desktop/notes 2.txt"

    private func item(_ path: String, frame: RingRect, filename: String? = nil) -> FinderNamedItem {
        FinderNamedItem(url: path, filename: filename ?? URL(fileURLWithPath: path).lastPathComponent, frame: frame)
    }

    func testUnnamedElementIsNotAMatch() {
        XCTAssertFalse(FinderIdentity.positivelyMatches(url: nil, filename: nil, paths: [oldFile]))
        XCTAssertFalse(FinderIdentity.positivelyMatches(url: nil, filename: "  ", paths: [oldFile]))
        XCTAssertFalse(FinderIdentity.positivelyMatches(url: "", filename: "", paths: [oldFile]))
        XCTAssertFalse(FinderIdentity.positivelyMatches(url: newFile, filename: "notes.txt", paths: [oldFile]))
        XCTAssertTrue(FinderIdentity.positivelyMatches(url: oldFile, filename: nil, paths: [oldFile]))
        XCTAssertTrue(FinderIdentity.positivelyMatches(url: nil, filename: "notes.txt", paths: [oldFile]))
        XCTAssertTrue(FinderIdentity.positivelyMatches(url: "file:///Users/kevin/Desktop/notes.txt", filename: nil, paths: [oldFile]))
    }

    func testChooseTheItemUnderThePointerOtherwiseTheNearest() {
        let old = item(oldFile, frame: RingRect(x: 0, y: 0, width: 80, height: 80))
        let shifted = item(newFile, frame: RingRect(x: 200, y: 0, width: 80, height: 80))
        let unnamed = FinderNamedItem(url: nil, filename: nil, frame: RingRect(x: 10, y: 10, width: 40, height: 40))
        let pointerOnNew = Point(x: 220, y: 40)
        let chosen = FinderIdentity.choose([old, shifted, unnamed], paths: [oldFile, newFile], pointer: pointerOnNew)
        XCTAssertEqual(chosen, shifted)

        let between = Point(x: 90, y: 200)
        let nearest = FinderIdentity.choose([old, shifted], paths: [oldFile, newFile], pointer: between)
        XCTAssertEqual(nearest, old, "neither frame contains the pointer, so the nearer center wins")

        let onlyOldSelected = FinderIdentity.choose([old, shifted], paths: [oldFile], pointer: pointerOnNew)
        XCTAssertEqual(onlyOldSelected, old, "the neighbour is selected in Finder's view but not in the path list")
    }

    func testDragOffsetStaysOnTheIconAfterThePointerMovesFar() {
        let icon = Point(x: 100, y: 80)
        let grab = Point(x: 110, y: 100)
        let limit = 400.0
        let offset = DragGrab.offset(iconCenter: icon, grab: grab, limit: limit)
        XCTAssertEqual(offset, Point(x: -10, y: -20))
        let far = Point(x: 900, y: 700)
        let center = DragGrab.center(pointer: far, offset: offset!)
        XCTAssertEqual(center, Point(x: 890, y: 680))
        XCTAssertNil(DragGrab.offset(iconCenter: Point(x: 0, y: 0), grab: Point(x: 500, y: 0), limit: limit))
    }

    func testClickModeCentreGapAndCornerCloseAndAWedgeActs() {
        let geometry = WheelGeometry(outerRadius: 200, innerRadius: 80, gapRadians: 6.5 * .pi / 180, count: 4)
        func decide(_ point: Point, enabled: Bool = true) -> WheelClickDecision {
            let index = geometry.index(at: point, center: .zero)
            return WheelClick.decide(index: index, enabled: enabled && index != nil)
        }
        XCTAssertEqual(decide(Point(x: 0, y: -20)), .close, "centre hole")
        let gap = Point(x: 140 * cos(-.pi / 4), y: 140 * sin(-.pi / 4))
        XCTAssertEqual(decide(gap), .close, "gap between wedges")
        XCTAssertEqual(decide(Point(x: 300, y: 300)), .close, "transparent corner")
        XCTAssertEqual(decide(Point(x: 0, y: -140)), .act(0))
        XCTAssertEqual(decide(Point(x: 0, y: -140), enabled: false), .close, "disabled wedge")
    }
}
