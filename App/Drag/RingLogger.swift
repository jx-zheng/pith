import os

/// Ring lines go out with `privacy: .public`. `NSLog` marks them `<private>`
/// in the unified log, which hid every placement on a signed-in Mac.
enum RingLogger {
    static let log = Logger(subsystem: "com.kevinzheng.pith", category: "ring")

    static func write(_ line: String) {
        log.notice("\(line, privacy: .public)")
    }
}
