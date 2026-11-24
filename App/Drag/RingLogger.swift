import os

/// Ring lines go out with `privacy: .public`. `NSLog` marks them `<private>`
/// in the unified log, which hid every placement on a signed-in Mac.
enum RingLogger {
    static let log = Logger(subsystem: "com.kevinzheng.pith", category: "ring")
    private static let points = OSLog(subsystem: "com.kevinzheng.pith", category: "latency")

    static func write(_ line: String) {
        log.notice("\(line, privacy: .public)")
    }

    static func beginOpen() -> OSSignpostID {
        let id = OSSignpostID(log: points)
        os_signpost(.begin, log: points, name: "ring-open", signpostID: id)
        return id
    }

    static func endOpen(_ id: OSSignpostID) {
        os_signpost(.end, log: points, name: "ring-open", signpostID: id)
    }

    static func beginSwitch() -> OSSignpostID {
        let id = OSSignpostID(log: points)
        os_signpost(.begin, log: points, name: "ring-switch", signpostID: id)
        return id
    }

    static func endSwitch(_ id: OSSignpostID) {
        os_signpost(.end, log: points, name: "ring-switch", signpostID: id)
    }
}
