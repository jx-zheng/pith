import Foundation

public enum ByteCountFormat {
    public static func string(bytes: Int64) -> String {
        let value = Double(bytes < 0 ? 0 : bytes)
        if value < 1024 { return "\(Int(value)) B" }
        let kb = value / 1024
        if kb < 10 { return String(format: "%.1f KB", kb) }
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1f MB", mb) }
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}
