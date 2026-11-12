import XCTest
@testable import PithCore

final class IconRingGeometryTests: XCTestCase {
    private func evidence(_ name: String, icon: RingRect, cell: RingRect) {
        let center = IconRingGeometry.center(of: icon)
        let cellCenter = cell.center
        print(String(
            format: "PITH_RING name=%@ iconCenter=(%.2f,%.2f) cellCenter=(%.2f,%.2f) delta=(%.2f,%.2f) icon=%gx%g cell=%gx%g",
            name,
            center.x, center.y,
            cellCenter.x, cellCenter.y,
            center.x - cellCenter.x, center.y - cellCenter.y,
            icon.width, icon.height,
            cell.width, cell.height
        ))
        XCTAssertEqual(center.x, icon.x + icon.width / 2, accuracy: 0.0001)
        XCTAssertEqual(center.y, icon.y + icon.height / 2, accuracy: 0.0001)
        if cell != icon {
            let same = abs(center.x - cellCenter.x) < 0.001 && abs(center.y - cellCenter.y) < 0.001
            XCTAssertFalse(same, "\(name): ring landed on the cell, which includes the label")
        }
    }

    func testRingCenterIsTheIconNotTheCell() {
        // Icon view, y down: 64 pt icon centered in an 80 pt cell, label below.
        let icon = RingRect(x: 108, y: 40, width: 64, height: 64)
        let shortLabel = RingRect(x: 100, y: 32, width: 80, height: 120)
        let longLabel = RingRect(x: 90, y: 32, width: 140, height: 168)
        evidence("icon-view-short-label", icon: icon, cell: shortLabel)
        evidence("icon-view-long-label", icon: icon, cell: longLabel)

        let shortCenter = IconRingGeometry.center(of: icon)
        XCTAssertEqual(IconRingGeometry.center(of: icon), shortCenter)
        XCTAssertNotEqual(shortLabel.center, longLabel.center, "a longer label moves the cell center")
        XCTAssertEqual(IconRingGeometry.center(of: icon).y, 72, accuracy: 0.0001)
        XCTAssertNotEqual(shortLabel.center.y, longLabel.center.y)
    }

    func testIconSizesDoNotUseTheCellCenter() {
        let sizes: [Double] = [16, 32, 48, 64, 128, 256]
        for size in sizes {
            let cell = RingRect(x: 0, y: 0, width: size + 40, height: size + 36 + 28)
            let icon = RingRect(x: 20, y: 8, width: size, height: size)
            let resolved = IconRingGeometry.iconImage(inside: cell, images: [icon])
            XCTAssertEqual(resolved, icon, "icon size \(size)")
            evidence("icon-size-\(Int(size))", icon: icon, cell: cell)
            let center = IconRingGeometry.center(of: resolved!)
            XCTAssertEqual(center.x, 20 + size / 2, accuracy: 0.0001)
            XCTAssertEqual(center.y, 8 + size / 2, accuracy: 0.0001)
            XCTAssertNotEqual(center, cell.center)
        }
    }

    func testListRowCenterStaysOnTheIconWhenTheLabelGrows() {
        let icon = RingRect(x: 18, y: 42, width: 16, height: 16)
        let shortRow = RingRect(x: 0, y: 40, width: 220, height: 20)
        let longRow = RingRect(x: 0, y: 40, width: 640, height: 20)
        XCTAssertEqual(IconRingGeometry.iconImage(inside: shortRow, images: [icon]), icon)
        XCTAssertEqual(IconRingGeometry.iconImage(inside: longRow, images: [icon]), icon)
        evidence("list-row-short", icon: icon, cell: shortRow)
        evidence("list-row-long", icon: icon, cell: longRow)
        XCTAssertEqual(IconRingGeometry.center(of: icon), Point(x: 26, y: 50))
        XCTAssertNotEqual(shortRow.center.x, longRow.center.x)
    }

    func testWideLabelImageIsNotTheIcon() {
        let cell = RingRect(x: 0, y: 0, width: 240, height: 120)
        let icon = RingRect(x: 88, y: 8, width: 64, height: 64)
        let label = RingRect(x: 20, y: 78, width: 200, height: 32)
        let resolved = IconRingGeometry.iconImage(inside: cell, images: [label, icon])
        XCTAssertEqual(resolved, icon)
        evidence("label-image-rejected", icon: icon, cell: cell)
    }

    func testBadgeLosesToTheLargerIcon() {
        let cell = RingRect(x: 0, y: 0, width: 96, height: 140)
        let icon = RingRect(x: 16, y: 10, width: 64, height: 64)
        let badge = RingRect(x: 64, y: 58, width: 16, height: 16)
        XCTAssertEqual(IconRingGeometry.iconImage(inside: cell, images: [badge, icon]), icon)
    }

    func testCellSizedImageIsNotTreatedAsTheIcon() {
        let cell = RingRect(x: 10, y: 10, width: 80, height: 110)
        XCTAssertNil(IconRingGeometry.iconImage(inside: cell, images: [cell]))
        XCTAssertNil(IconRingGeometry.iconImage(inside: cell, images: []))
    }

    func testRingLogNamesEveryAnchorSource() {
        let pointer = Point(x: 200, y: 300)
        let icon = Point(x: 200, y: 340)
        let shifted = Point(x: 188, y: 320)
        let fromImage = IconRingGeometry.choose(dragImageCenter: icon, offsetCenter: shifted, pointer: pointer)
        let fromOffset = IconRingGeometry.choose(dragImageCenter: nil, offsetCenter: shifted, pointer: pointer)
        let fromPointer = IconRingGeometry.choose(dragImageCenter: nil, offsetCenter: nil, pointer: pointer)
        XCTAssertEqual(fromImage.source, .dragImage)
        XCTAssertEqual(fromImage.center, icon)
        XCTAssertEqual(fromOffset.source, .dragOffset)
        XCTAssertEqual(fromOffset.center, shifted)
        XCTAssertEqual(fromPointer.source, .pointer)
        XCTAssertEqual(fromPointer.center, pointer)
        for choice in [fromImage, fromOffset, fromPointer] {
            let line = RingLog(
                mode: "drag",
                source: choice.source,
                filename: "notes.txt",
                icon: nil,
                cell: nil,
                pointer: pointer,
                center: choice.center,
                selectedCount: 1,
                reason: choice.source.rawValue
            ).line
            XCTAssertTrue(line.hasPrefix("Pith: ring mode=drag source=\(choice.source.rawValue)"))
            print(line)
        }
    }

    func testDropWaitsForPointerMovementOrAFreshEntry() {
        var gate = RingHoverGate()
        let anchor = Point(x: 10, y: 10)
        gate.pointerMoved(from: anchor, to: Point(x: 11, y: 10))
        XCTAssertNil(gate.canCommit(segment: 2), "the pointer is still where the wheel appeared")
        gate.pointerMoved(from: anchor, to: Point(x: 14, y: 10))
        XCTAssertEqual(gate.canCommit(segment: 2), 2)
        XCTAssertNil(gate.canCommit(segment: nil), "outside the ring is not a segment")
        var fresh = RingHoverGate()
        fresh.freshEntry()
        XCTAssertEqual(fresh.canCommit(segment: 0), 0)
    }

    func testIconPieceCoveringTheWholeDragFrameIsRejected() {
        let frame = RingRect(x: 400, y: 500, width: 96, height: 120)
        let covering = RingRect(x: 0, y: 0, width: 96, height: 120)
        XCTAssertNil(IconRingGeometry.dragIcon(draggingFrame: frame, iconComponent: covering))
        let wide = RingRect(x: 4, y: 4, width: 88, height: 24)
        XCTAssertNil(IconRingGeometry.dragIcon(draggingFrame: frame, iconComponent: wide), "a label-shaped piece is not the icon")
        let piece = RingRect(x: 16, y: 48, width: 64, height: 64)
        XCTAssertEqual(
            IconRingGeometry.dragIcon(draggingFrame: frame, iconComponent: piece),
            RingRect(x: 416, y: 548, width: 64, height: 64)
        )
        // The rejected piece is not a center, so the next anchor is logged.
        let pointer = Point(x: 430, y: 520)
        let choice = IconRingGeometry.choose(dragImageCenter: nil, offsetCenter: nil, pointer: pointer)
        XCTAssertEqual(choice.source, .pointer)
        XCTAssertEqual(choice.center, pointer)
    }

    func testDragImageIconIsNotTheDragImageCenter() {
        // Drag image is the cell (icon + label). Label hangs below the icon in y-up space,
        // so the icon component sits in the upper part of the dragging frame.
        // A longer label grows the frame downward and changes the cell center, not the icon.
        let shortFrame = RingRect(x: 400, y: 500, width: 96, height: 120)
        let longFrame = RingRect(x: 380, y: 460, width: 160, height: 180)
        let iconPiece = RingRect(x: 16, y: 48, width: 64, height: 64)
        let shortIcon = IconRingGeometry.placedIcon(draggingFrame: shortFrame, iconComponent: iconPiece)
        let longIcon = IconRingGeometry.placedIcon(draggingFrame: longFrame, iconComponent: iconPiece)
        XCTAssertEqual(shortIcon, RingRect(x: 416, y: 548, width: 64, height: 64))
        evidence("drag-image-short-label", icon: shortIcon, cell: shortFrame)
        evidence("drag-image-long-label", icon: longIcon, cell: longFrame)
        XCTAssertNotEqual(shortFrame.center, IconRingGeometry.center(of: shortIcon))
        XCTAssertEqual(IconRingGeometry.center(of: shortIcon), Point(x: 448, y: 580))
        // Pointer on the label, inside the cell, outside the icon.
        let pointer = Point(x: 448, y: 520)
        XCTAssertTrue(IconRingGeometry.contains(shortFrame, point: pointer))
        XCTAssertFalse(IconRingGeometry.contains(shortIcon, point: pointer))
        XCTAssertNotEqual(pointer, IconRingGeometry.center(of: shortIcon))
    }

    func testPanelOriginPutsTheRingOnTheIconCenter() {
        let center = Point(x: 448.5, y: 580.25)
        let side = 436.0
        let origin = IconRingGeometry.panelOrigin(center: center, panelWidth: side, panelHeight: side)
        XCTAssertEqual(origin.x + side / 2, center.x, accuracy: 0.0001)
        XCTAssertEqual(origin.y + side / 2, center.y, accuracy: 0.0001)
    }

    func testAccessibilityYIsTheInverseOfAppKitY() {
        let maxY = 900.0
        XCTAssertEqual(IconRingGeometry.topLeftY(fromAppKitY: 100, mainScreenMaxY: maxY), 800)
        XCTAssertEqual(IconRingGeometry.appKitY(fromTopLeftY: 800, mainScreenMaxY: maxY), 100)
        // A center measured from the top of the screen converts without depending on label height.
        let axCenterY = 240.0
        let appKit = IconRingGeometry.appKitY(fromTopLeftY: axCenterY, mainScreenMaxY: maxY)
        XCTAssertEqual(IconRingGeometry.topLeftY(fromAppKitY: appKit, mainScreenMaxY: maxY), axCenterY)
        // Secondary display above the main display: accessibility y is negative.
        XCTAssertEqual(IconRingGeometry.appKitY(fromTopLeftY: -100, mainScreenMaxY: maxY), 1000)
    }
}
