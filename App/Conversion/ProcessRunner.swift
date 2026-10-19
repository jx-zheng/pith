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
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let buffer = LineBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data).forEach(onStdout)
            }
            let once = ResumeOnce(continuation)
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                let trailing = buffer.flush()
                trailing.forEach(onStdout)
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
            let errBuffer = LineBuffer()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outBuffer.append(data).forEach(onStdout)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                _ = errBuffer.append(data)
            }
            let once = ResumeOnce(continuation)
            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                outBuffer.flush().forEach(onStdout)
                let err = errBuffer.flush().joined(separator: "\n")
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
                once.resume(throwing: error)
            }
        }
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
