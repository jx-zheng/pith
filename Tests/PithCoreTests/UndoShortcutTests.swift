import XCTest
@testable import PithCore

final class UndoShortcutTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let cmd = UndoShortcut.commandMask

    private func consume(
        key: Int64 = 6, flags: UInt64? = nil, repeat isRepeat: Bool = false,
        app: String? = "com.apple.finder", age: TimeInterval? = 1, undone: TimeInterval? = nil
    ) -> Bool {
        UndoShortcut.shouldConsume(
            keyCode: key, flags: flags ?? cmd, isAutoRepeat: isRepeat, frontmostBundleID: app,
            entryDate: age.map { now.addingTimeInterval(-$0) },
            lastUndoneEntryDate: undone.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    func testConsumesPlainCommandZInFinderRightAfterAnEntry() {
        XCTAssertTrue(consume())
        XCTAssertTrue(consume(age: 0))
        XCTAssertTrue(consume(age: 5))
    }

    func testWindowIsFiveSeconds() {
        XCTAssertEqual(UndoShortcut.window, 5)
        XCTAssertTrue(consume(age: 4.9))
        XCTAssertFalse(consume(age: 5.01))
        XCTAssertFalse(consume(age: 60))
        XCTAssertFalse(consume(age: -1), "entry from the future (clock change)")
        XCTAssertFalse(consume(age: nil), "nothing to undo")
    }

    func testOnlyFinder() {
        XCTAssertFalse(consume(app: "com.apple.TextEdit"))
        XCTAssertFalse(consume(app: "com.apple.finder.helper"))
        XCTAssertFalse(consume(app: nil))
    }

    func testModifiersMustBeExactlyCommand() {
        let capsLock: UInt64 = 0x0001_0000, fn: UInt64 = 0x0080_0000, deviceBits: UInt64 = 0x8
        XCTAssertTrue(consume(flags: cmd | capsLock))
        XCTAssertTrue(consume(flags: cmd | fn | deviceBits))
        XCTAssertFalse(consume(flags: cmd | UndoShortcut.shiftMask), "⇧⌘Z is redo")
        XCTAssertFalse(consume(flags: cmd | UndoShortcut.optionMask))
        XCTAssertFalse(consume(flags: cmd | UndoShortcut.controlMask))
        XCTAssertFalse(consume(flags: cmd | UndoShortcut.controlMask | UndoShortcut.optionMask), "⌃⌥⌘Z has its own handler")
        XCTAssertFalse(consume(flags: 0))
        XCTAssertFalse(consume(key: 7), "⌘X")
        XCTAssertFalse(consume(repeat: true))
    }

    func testEachEntryOnlyOnce() {
        XCTAssertFalse(consume(age: 1, undone: 1), "this entry was already undone")
        XCTAssertFalse(consume(age: 2, undone: 1), "older entry after an undo goes to Finder")
        XCTAssertTrue(consume(age: 1, undone: 3), "a newer entry is fair game")
    }
}
