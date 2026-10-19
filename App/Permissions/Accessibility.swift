import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static func isTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let modern, NSWorkspace.shared.open(modern) { return }
        if let legacy { NSWorkspace.shared.open(legacy) }
    }
}
