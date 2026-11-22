import Foundation

/// Log lines the owner filters with `subsystem == "com.kevinzheng.pith"`.
public enum LatencyMark {
    public static func key(_ action: String) -> String {
        "latency \(action) key"
    }

    public static func show(_ action: String) -> String {
        "latency \(action) show"
    }

    public static func frame(_ action: String, keyToFrameMilliseconds: Double) -> String {
        String(format: "latency %@ key->frame=%.1fms", action, keyToFrameMilliseconds)
    }
}
