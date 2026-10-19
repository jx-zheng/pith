import XCTest
@testable import PithCore

final class GestureTests: XCTestCase {
    func testShortShiftTapOpensConvertWheel() {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 4, location: .zero))
        let began = machine.handle(.mouseDragged(
            time: 0.05, changeCount: 5, location: Point(x: 12, y: 40),
            filePaths: ["/tmp/Page 001.pdf"], hasFilePromise: false, promisedTypeIdentifiers: []
        ))
        XCTAssertEqual(began.count, 1)
        _ = machine.handle(.flagsChanged(time: 1.0, flags: .shift))
        let effects = machine.handle(.flagsChanged(time: 1.12, flags: []))
        XCTAssertEqual(effects, [.showWheel(.convert, Point(x: 12, y: 40), DragSession(
            changeCount: 5,
            filePaths: ["/tmp/Page 001.pdf"],
            hasFilePromise: false,
            promisedTypeIdentifiers: [],
            location: Point(x: 12, y: 40)
        ))])
        if case .wheel(_, .convert) = machine.phase {} else {
            XCTFail("expected convert wheel, got \(machine.phase)")
        }
    }

    func testStaleDragPasteboardIsIgnored() {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 9, location: .zero))
        let effects = machine.handle(.mouseDragged(
            time: 0.2, changeCount: 9, location: Point(x: 8, y: 8),
            filePaths: ["/tmp/old.pdf"], hasFilePromise: false, promisedTypeIdentifiers: []
        ))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(machine.phase, .pressed(baselineChangeCount: 9))
        _ = machine.handle(.flagsChanged(time: 0.4, flags: .shift))
        let tap = machine.handle(.flagsChanged(time: 0.5, flags: []))
        XCTAssertEqual(tap, [])
    }

    func testLongHoldIsNotATap() {
        var machine = armed()
        _ = machine.handle(.flagsChanged(time: 2, flags: .shift))
        let effects = machine.handle(.flagsChanged(time: 2.45, flags: []))
        XCTAssertEqual(effects, [])
        if case .dragging = machine.phase {} else { XCTFail("wheel should stay closed") }
    }

    func testOtherModifierContaminatesTap() {
        var machine = armed()
        _ = machine.handle(.flagsChanged(time: 1, flags: .shift))
        _ = machine.handle(.flagsChanged(time: 1.05, flags: [.shift, .command]))
        let effects = machine.handle(.flagsChanged(time: 1.1, flags: []))
        XCTAssertEqual(effects, [])
    }

    func testOtherKeyContaminatesTap() {
        var machine = armed()
        _ = machine.handle(.flagsChanged(time: 1, flags: .shift))
        _ = machine.handle(.keyDown(time: 1.05, key: .other))
        let effects = machine.handle(.flagsChanged(time: 1.1, flags: []))
        XCTAssertEqual(effects, [])
    }

    func testCommandAndControlSelectTheirWheels() {
        var machine = armed()
        _ = machine.handle(.flagsChanged(time: 1, flags: .command))
        let tools = machine.handle(.flagsChanged(time: 1.1, flags: []))
        XCTAssertEqual(tools.first, .showWheel(.tools, Point(x: 3, y: 4), session(at: Point(x: 3, y: 4))))
        _ = machine.handle(.flagsChanged(time: 2, flags: .control))
        let actions = machine.handle(.flagsChanged(time: 2.1, flags: []))
        guard case let .switchWheel(kind, _) = actions.first else {
            return XCTFail("expected switch, got \(actions)")
        }
        XCTAssertEqual(kind, .actions)
    }

    func testSameKeyDoesNotDismissWheel() {
        var machine = armed()
        _ = machine.handle(.flagsChanged(time: 1, flags: .shift))
        _ = machine.handle(.flagsChanged(time: 1.1, flags: []))
        _ = machine.handle(.flagsChanged(time: 1.4, flags: .shift))
        let again = machine.handle(.flagsChanged(time: 1.5, flags: []))
        XCTAssertEqual(again, [.repeatTap(.convert)])
        if case .wheel = machine.phase {} else { XCTFail("wheel should stay open") }
    }

    func testEscapeDismissesWheelButDragContinues() {
        var machine = openWheel()
        let effects = machine.handle(.keyDown(time: 3, key: .escape))
        XCTAssertEqual(effects, [.dismissWheel])
        if case .dragging = machine.phase {} else { XCTFail("drag should continue") }
    }

    func testMouseUpEndsDragAndDismissesWheel() {
        var machine = openWheel()
        let effects = machine.handle(.mouseUp(time: 4, location: Point(x: 1, y: 1)))
        XCTAssertEqual(effects, [.dismissWheel, .dragEnded])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testWheelStaysOpenWhileDragging() {
        var machine = openWheel()
        let effects = machine.handle(.mouseDragged(
            time: 3, changeCount: 8, location: Point(x: 90, y: 10),
            filePaths: ["/tmp/a.png"], hasFilePromise: false, promisedTypeIdentifiers: []
        ))
        XCTAssertEqual(effects, [])
        if case .wheel = machine.phase {} else { XCTFail("wheel closed early") }
    }

    func testNonFileDragDoesNotArm() {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 1, location: .zero))
        let effects = machine.handle(.mouseDragged(
            time: 0.1, changeCount: 2, location: Point(x: 4, y: 4),
            filePaths: [], hasFilePromise: false, promisedTypeIdentifiers: []
        ))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(machine.phase, .nonFileDrag)
    }

    func testFilePromiseCountsAsFileDrag() {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 1, location: .zero))
        let effects = machine.handle(.mouseDragged(
            time: 0.1, changeCount: 2, location: Point(x: 4, y: 4),
            filePaths: [], hasFilePromise: true, promisedTypeIdentifiers: ["public.jpeg"]
        ))
        XCTAssertEqual(effects.count, 1)
    }

    func testArrowKeyWhileWheelEmitsWheelKey() {
        var machine = openWheel()
        let effects = machine.handle(.keyDown(time: 3, key: .right))
        XCTAssertEqual(effects, [.wheelKey(.right)])
    }

    private func session(at point: Point) -> DragSession {
        DragSession(
            changeCount: 8,
            filePaths: ["/tmp/a.png"],
            hasFilePromise: false,
            promisedTypeIdentifiers: [],
            location: point
        )
    }

    private func armed() -> DragGestureMachine {
        var machine = DragGestureMachine()
        _ = machine.handle(.mouseDown(time: 0, changeCount: 7, location: .zero))
        _ = machine.handle(.mouseDragged(
            time: 0.1, changeCount: 8, location: Point(x: 3, y: 4),
            filePaths: ["/tmp/a.png"], hasFilePromise: false, promisedTypeIdentifiers: []
        ))
        return machine
    }

    private func openWheel() -> DragGestureMachine {
        var machine = armed()
        _ = machine.handle(.flagsChanged(time: 1, flags: .shift))
        _ = machine.handle(.flagsChanged(time: 1.1, flags: []))
        return machine
    }
}
