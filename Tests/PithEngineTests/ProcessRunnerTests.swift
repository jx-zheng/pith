import Foundation
import XCTest
import PithCore
@testable import PithEngine

/// ProcessRunner drives every ffmpeg, pandoc, soffice, ditto and tar call.
final class ProcessRunnerTests: XCTestCase {
    private func sh(_ script: String) -> CommandSpec {
        CommandSpec(executable: "/bin/sh", arguments: ["-c", script], progressOnStdout: true)
    }

    /// A tool that writes more than a pipe buffer (64 KB) to stderr must not hang `run`.
    func testRunDoesNotDeadlockOnChattyStderr() async throws {
        let status = try await withTimeout(15) { runner in
            try await runner.run(self.sh("head -c 400000 /dev/zero >&2; echo done")) { _ in }
        }
        XCTAssertEqual(status, 0)
    }

    /// Every stdout line arrives, including the ones still in the pipe at exit.
    func testNoStdoutLinesAreLost() async throws {
        for _ in 0..<5 {
            let lines = LineCounter()
            let (status, _) = try await withTimeout(15) { runner in
                try await runner.runWithError(self.sh("seq 1 20000")) { lines.add($0) }
            }
            XCTAssertEqual(status, 0)
            XCTAssertEqual(lines.count, 20000)
            XCTAssertEqual(lines.last, "20000")
        }
    }

    /// The tail of stderr is what the HUD shows when a tool fails.
    func testStderrTailIsCaptured() async throws {
        let (status, error) = try await ProcessRunner().runWithError(sh("seq 1 30000 >&2; echo 'fatal: the real reason' >&2; exit 3"))
        XCTAssertEqual(status, 3)
        XCTAssertTrue(error.hasSuffix("fatal: the real reason"), String(error.suffix(80)))
    }

    func testCancelTerminatesAndLaterRunsStopImmediately() async throws {
        let runner = ProcessRunner()
        let started = Date()
        Task { try await Task.sleep(nanoseconds: 300_000_000); runner.cancel() }
        let (status, _) = try await runner.runWithError(sh("sleep 20"))
        XCTAssertNotEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let (again, _) = try await runner.runWithError(sh("sleep 20"))
        XCTAssertNotEqual(again, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testMissingExecutableThrows() async {
        do {
            _ = try await ProcessRunner().runWithError(CommandSpec(executable: "/nonexistent/tool", arguments: [], progressOnStdout: false))
            XCTFail("expected a throw")
        } catch {}
    }
}

private final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last: String?
    func add(_ line: String) { lock.lock(); count += 1; last = line; lock.unlock() }
}
