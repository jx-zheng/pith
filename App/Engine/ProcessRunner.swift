import Foundation
import PithCore

final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    func run(_ spec: CommandSpec, onStdout: @escaping (String) -> Void) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: spec.executable)
            process.arguments = spec.arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            // Nobody reads stderr here; an undrained pipe blocks the tool once it fills (64 KB).
            process.standardError = FileHandle.nullDevice
            let buffer = LineBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data).forEach(onStdout)
            }
            let once = ResumeOnce(continuation)
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                // Whatever was still in the pipe at exit.
                buffer.append(stdout.fileHandleForReading.readDataToEndOfFile()).forEach(onStdout)
                buffer.flush().forEach(onStdout)
                once.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
                self.lock.lock()
                if self.cancelled {
                    process.terminate()
                } else {
                    self.process = process
                }
                self.lock.unlock()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                once.resume(throwing: error)
            }
        }
    }

    func runWithError(_ spec: CommandSpec, onStdout: @escaping (String) -> Void = { _ in }) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: spec.executable)
            process.arguments = spec.arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let outBuffer = LineBuffer()
            let errBuffer = TailBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outBuffer.append(data).forEach(onStdout)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                errBuffer.append(data)
            }
            let once = ResumeOnce(continuation)
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Drain what the handlers hadn't read yet, or the last lines (often the error) are lost.
                outBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile()).forEach(onStdout)
                errBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                outBuffer.flush().forEach(onStdout)
                let err = errBuffer.text
                once.resume(returning: (proc.terminationStatus, err))
            }
            do {
                try process.run()
                self.lock.lock()
                if self.cancelled {
                    process.terminate()
                } else {
                    self.process = process
                }
                self.lock.unlock()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                once.resume(throwing: error)
            }
        }
    }
}

/// Keeps the last `limit` bytes of stderr. (A LineBuffer here handed back each completed
/// line and kept only the unterminated remainder, so error text was almost always empty.)
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 64 * 1024

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > limit { data.removeFirst(data.count - limit) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        pending.append(data)
        let lines = drain(flushAll: false)
        lock.unlock()
        return lines
    }

    func flush() -> [String] {
        lock.lock()
        let lines = drain(flushAll: true)
        lock.unlock()
        return lines
    }

    private func drain(flushAll: Bool) -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let chunk = pending.subdata(in: 0..<newline)
            pending.removeSubrange(0...newline)
            if let text = String(data: chunk, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r")) {
                if !text.isEmpty { lines.append(text) }
            }
        }
        if flushAll && !pending.isEmpty {
            if let text = String(data: pending, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lines.append(text)
            }
            pending.removeAll()
        }
        return lines
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}
