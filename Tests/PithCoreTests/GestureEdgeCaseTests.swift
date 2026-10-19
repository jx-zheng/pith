import XCTest
@testable import PithCore

final class GestureEdgeCaseTests: XCTestCase {
    private let files = ["/tmp/a.png"]

    private func dragging(_ bindings: KeyBindings = .default) -> DragGestureMachine {
        var machine = DragGestureMachine(bindings: bindings)
        _ = machine.handle(.mouseDown(time: 0, changeCount: 1, location: .zero))
        _ = machine.handle(.mouseDragged(time: 0.1, changeCount: 2, location: Point(x: 5, y: 5), filePaths: files, hasFilePromise: false, promisedTypeIdentifiers: []))
        return machine
    }

    private func tap(_ machine: inout DragGestureMachine, _ flags: ModifierFlags, at time: Double) -> [GestureEffect] {
        _ = machine.handle(.flagsChanged(time: time, flags: flags))
        return machine.handle(.flagsChanged(time: time + 0.1, flags: []))
    }

    func testRepeatTapOnOpenWheelIsADoubleTap() {
        var machine = dragging()
        XCTAssertEqual(tap(&machine, .shift, at: 1).count, 1)
        XCTAssertEqual(tap(&machine, .shift, at: 1.3), [.repeatTap(.convert)])
        if case .wheel(_, .convert) = machine.phase {} else { XCTFail("wheel should stay open, got \(machine.phase)") }
    }

    func testSwitchingWheelsThenEscapeThenReopen() {
        var machine = dragging()
        _ = tap(&machine, .shift, at: 1)
        let switched = tap(&machine, .command, at: 1.5)
        guard case .switchWheel(.tools, _)? = switched.first else { return XCTFail("\(switched)") }
        XCTAssertEqual(machine.handle(.keyDown(time: 2, key: .escape)), [.dismissWheel])
        if case .dragging = machine.phase {} else { XCTFail("escape should keep the drag") }
        _ = machine.handle(.mouseDragged(time: 2.2, changeCount: 2, location: Point(x: 40, y: 50), filePaths: files, hasFilePromise: false, promisedTypeIdentifiers: []))
        let reopened = tap(&machine, .control, at: 3)
        guard case let .showWheel(.actions, point, _)? = reopened.first else { return XCTFail("\(reopened)") }
        XCTAssertEqual(point, Point(x: 40, y: 50), "reopens under the pointer, not where the drag began")
    }

    func testDropAcceptedThenMouseUpIsANoOp() {
        var machine = dragging()
        _ = tap(&machine, .shift, at: 1)
        XCTAssertEqual(machine.handle(.dropAccepted), [.dismissWheel, .dragEnded])
        XCTAssertEqual(machine.handle(.mouseUp(time: 2, location: .zero)), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testTapWhileMouseIsDownWithoutADragDoesNothingButAfterReleaseIsAnIdleTap() {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 1, location: .zero))
        XCTAssertEqual(tap(&machine, .shift, at: 0.2), [])
        XCTAssertEqual(machine.handle(.mouseUp(time: 0.5, location: .zero)), [])
        XCTAssertEqual(tap(&machine, .shift, at: 1), [.idleTap(.convert)])
    }

    func testPasteboardSwappedToNonFileMidDragKeepsTheFiles() {
        var machine = dragging()
        _ = machine.handle(.mouseDragged(time: 0.3, changeCount: 3, location: Point(x: 9, y: 9), filePaths: [], hasFilePromise: false, promisedTypeIdentifiers: []))
        guard case let .dragging(session) = machine.phase else { return XCTFail("\(machine.phase)") }
        XCTAssertEqual(session.filePaths, files)
        XCTAssertEqual(session.location, Point(x: 9, y: 9))
    }

    func testNonFileDragNeverOpensAWheel() {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 1, location: .zero))
        _ = machine.handle(.mouseDragged(time: 0.1, changeCount: 2, location: .zero, filePaths: [], hasFilePromise: false, promisedTypeIdentifiers: []))
        XCTAssertEqual(machine.phase, .nonFileDrag)
        XCTAssertEqual(tap(&machine, .shift, at: 1), [])
        XCTAssertEqual(machine.handle(.mouseUp(time: 2, location: .zero)), [.dragEnded])
    }

    func testDragWithoutMouseDownIsIgnored() {
        var machine = DragGestureMachine()
        XCTAssertEqual(machine.handle(.mouseDragged(time: 0.1, changeCount: 2, location: .zero, filePaths: files, hasFilePromise: false, promisedTypeIdentifiers: [])), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testUnboundAndRebindedKeys() {
        var machine = dragging()
        XCTAssertEqual(tap(&machine, .option, at: 1), [], "option isn't bound by default")
        var bindings = KeyBindings.default
        bindings.tools = .option
        machine.updateBindings(bindings)
        guard case .showWheel(.tools, _, _)? = tap(&machine, .option, at: 2).first else { return XCTFail("rebinding ignored") }
    }

    func testChordedModifiersAreNotATap() {
        var machine = dragging()
        _ = machine.handle(.flagsChanged(time: 1, flags: [.shift, .command]))
        XCTAssertEqual(machine.handle(.flagsChanged(time: 1.05, flags: .command)), [])
        XCTAssertEqual(machine.handle(.flagsChanged(time: 1.1, flags: [])), [])
    }

    func testMouseDownResetsAHalfFinishedTap() {
        var machine = dragging()
        _ = machine.handle(.flagsChanged(time: 1, flags: .shift))
        _ = machine.handle(.mouseUp(time: 1.05, location: .zero))
        _ = machine.handle(.mouseDown(time: 1.1, changeCount: 5, location: .zero))
        XCTAssertEqual(machine.handle(.flagsChanged(time: 1.15, flags: [])), [], "release after a new press isn't a tap")
    }
}
