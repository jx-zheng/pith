import XCTest
@testable import PithCore

final class RingDismissTests: XCTestCase {
    func testDragEndedOutsideTheRingClosesWithoutWaitingForADrop() {
        var machine = RingDismissMachine(presence: .drag(buttonDown: true))
        let up = machine.handle(.mouseUp(.left, onActionableWedge: false))
        XCTAssertEqual(up, .beginClose(reason: "drag-ended-outside"))
        guard case .closing = machine.presence else { return XCTFail("\(machine.presence)") }

        var polled = RingDismissMachine(presence: .drag(buttonDown: true))
        let released = polled.handle(.buttonsReleased(pointerInsideRing: false))
        XCTAssertEqual(released, .beginClose(reason: "drag-ended-outside"))
        XCTAssertEqual(RingDismissLog.line(reason: "drag-ended-outside"), "Pith: dismiss reason=drag-ended-outside")
    }

    func testDragReleaseOnAWedgeWaitsForTheDrop() {
        var machine = RingDismissMachine(presence: .drag(buttonDown: true))
        XCTAssertEqual(
            machine.handle(.mouseUp(.left, onActionableWedge: true)),
            .dismissAfterDropGrace(reason: "mouse-up-on-wedge")
        )
        XCTAssertEqual(machine.presence, .drag(buttonDown: false))
        XCTAssertEqual(machine.handle(.mouseUp(.left, onActionableWedge: true)), .ignore)
        XCTAssertEqual(machine.handle(.dropGraceExpired), .beginClose(reason: "drop-grace"))
        XCTAssertEqual(machine.handle(.closeFinished), .finishClose)
        XCTAssertEqual(machine.presence, .hidden)
    }

    func testButtonsReleasedInsideTheRingWaitsForTheDrop() {
        var machine = RingDismissMachine(presence: .drag(buttonDown: true))
        XCTAssertEqual(
            machine.handle(.buttonsReleased(pointerInsideRing: true)),
            .dismissAfterDropGrace(reason: "buttons-released")
        )
        XCTAssertEqual(machine.handle(.dropAccepted), .dismiss(reason: "drop"))
        XCTAssertEqual(machine.presence, .hidden)
    }

    func testASecondOpenWhileVisibleReplacesTheRing() {
        var machine = RingDismissMachine(presence: .drag(buttonDown: false))
        XCTAssertEqual(machine.handle(.openWhileVisible), .replace(reason: "second-open"))
        XCTAssertEqual(machine.presence, .hidden)

        machine.noteShown(.click)
        XCTAssertEqual(machine.handle(.openWhileVisible), .replace(reason: "second-open"))
        XCTAssertEqual(machine.handle(.openWhileVisible), .ignore, "hidden, so there is nothing to replace")
    }

    func testShiftCyclesOnlyWhenTheRingCanCycle() {
        var machine = RingDismissMachine(presence: .click)
        XCTAssertEqual(machine.handle(.shift(canCycle: true)), .cycle)
        XCTAssertEqual(machine.presence, .click)
        XCTAssertEqual(machine.handle(.shift(canCycle: false)), .beginClose(reason: "shift-stuck"))
        guard case .closing(resume: .click) = machine.presence else { return XCTFail("\(machine.presence)") }
    }

    func testEscapeRightClickDeactivateAndSpaceDismiss() {
        func check(_ event: RingDismissEvent, _ reason: String) {
            var machine = RingDismissMachine(presence: .drag(buttonDown: true))
            XCTAssertEqual(machine.handle(event), .beginClose(reason: reason))
            guard case .closing = machine.presence else { return XCTFail("\(machine.presence)") }
        }
        check(.escape, "escape")
        check(.mouseDown(.right, onActionableWedge: false), "right-click")
        check(.mouseUp(.right, onActionableWedge: false), "right-mouse-up")
        check(.appDeactivated, "deactivate")
        check(.spaceChanged, "space-change")
    }

    func testClickOnAWedgeStaysAndCentreOrOutsideCloses() {
        var machine = RingDismissMachine(presence: .click)
        XCTAssertEqual(machine.handle(.mouseDown(.left, onActionableWedge: true)), .ignore)
        XCTAssertEqual(machine.handle(.mouseDown(.left, onActionableWedge: false)), .beginClose(reason: "click-outside"))

        var up = RingDismissMachine(presence: .click)
        XCTAssertEqual(up.handle(.mouseUp(.left, onActionableWedge: true)), .ignore)
        XCTAssertEqual(up.handle(.mouseUp(.left, onActionableWedge: false)), .beginClose(reason: "mouse-up"))
    }

    func testHiddenIgnoresDismissalsAndANewMouseDownClearsADragRing() {
        var hidden = RingDismissMachine()
        XCTAssertEqual(hidden.handle(.escape), .ignore)
        XCTAssertEqual(hidden.handle(.buttonsReleased(pointerInsideRing: false)), .ignore)

        var drag = RingDismissMachine(presence: .drag(buttonDown: true))
        XCTAssertEqual(drag.handle(.mouseDown(.left, onActionableWedge: false)), .beginClose(reason: "mouse-down"))
    }

    func testClickRingIgnoresButtonPolling() {
        var machine = RingDismissMachine(presence: .click)
        XCTAssertEqual(machine.handle(.buttonsReleased(pointerInsideRing: false)), .ignore)
        XCTAssertEqual(machine.presence, .click)
    }

    func testShiftDuringClosingReopens() {
        var machine = RingDismissMachine(presence: .click)
        XCTAssertEqual(machine.handle(.escape), .beginClose(reason: "escape"))
        XCTAssertEqual(machine.handle(.shift(canCycle: true)), .reopen)
        XCTAssertEqual(machine.presence, .click)
        XCTAssertEqual(machine.handle(.closeFinished), .ignore, "a late completion must not hide the reopened ring")
        XCTAssertEqual(machine.presence, .click)
        XCTAssertEqual(RingDismissLog.closeCancelledByReopen(), "Pith: close cancelled by reopen")

        var drag = RingDismissMachine(presence: .drag(buttonDown: true))
        _ = drag.handle(.escape)
        XCTAssertEqual(drag.handle(.shift(canCycle: false)), .reopen)
        XCTAssertEqual(drag.presence, .drag(buttonDown: true))
    }

    func testClickDuringClosingIsIgnoredByTheRing() {
        var machine = RingDismissMachine(presence: .click)
        XCTAssertEqual(machine.handle(.mouseDown(.left, onActionableWedge: false)), .beginClose(reason: "click-outside"))
        XCTAssertEqual(machine.handle(.mouseDown(.left, onActionableWedge: true)), .ignore)
        XCTAssertEqual(machine.handle(.mouseUp(.left, onActionableWedge: true)), .ignore)
        XCTAssertEqual(machine.handle(.mouseUp(.left, onActionableWedge: false)), .ignore)
        XCTAssertEqual(machine.handle(.mouseDown(.right, onActionableWedge: false)), .ignore)
        guard case .closing(resume: .click) = machine.presence else { return XCTFail("\(machine.presence)") }
    }

    func testClosingAlwaysEndsHidden() {
        var machine = RingDismissMachine(presence: .drag(buttonDown: true))
        XCTAssertEqual(machine.handle(.escape), .beginClose(reason: "escape"))
        XCTAssertEqual(machine.handle(.closeFinished), .finishClose)
        XCTAssertEqual(machine.presence, .hidden)
        XCTAssertEqual(machine.handle(.closeFinished), .ignore, "the fallback and the completion both end here")
        XCTAssertEqual(machine.presence, .hidden)

        machine.noteShown(.click)
        XCTAssertEqual(machine.handle(.dropAccepted), .dismiss(reason: "drop"))
        XCTAssertEqual(machine.presence, .hidden, "a wedge action is hidden immediately, with no closing state left behind")
    }

    func testCloseAnimationFitsInTheShortWindow() {
        XCTAssertGreaterThanOrEqual(RingCloseTiming.duration, 0.10)
        XCTAssertLessThanOrEqual(RingCloseTiming.duration, 0.15)
        XCTAssertGreaterThan(RingCloseTiming.fallback, RingCloseTiming.duration)
        XCTAssertLessThanOrEqual(RingCloseTiming.fallback, 0.15)
    }
}
