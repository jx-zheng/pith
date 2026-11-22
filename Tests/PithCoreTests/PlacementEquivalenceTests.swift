import XCTest
@testable import PithCore

final class PlacementEquivalenceTests: XCTestCase {
    /// Owner's log on main: `icon=462,563 64x64`, `pointer=(550.4,598.5)`,
    /// `center=(494.0,595.0)`, `source=selected-element`.
    func testSelectedElementCentreMatchesMain() {
        let icon = RingRect(x: 462, y: 563, width: 64, height: 64)
        let pointer = Point(x: 550.4, y: 598.5)
        let center = IconRingGeometry.placedCenter(icon: icon, pointer: pointer)
        XCTAssertEqual(center.x, 494, accuracy: 0.001)
        XCTAssertEqual(center.y, 595, accuracy: 0.001)
        XCTAssertNotEqual(center, pointer, "the ring sits on the icon, not the pointer")
    }
}
