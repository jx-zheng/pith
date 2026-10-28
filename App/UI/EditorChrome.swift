import AppKit
import SwiftUI
import PithCore

struct EditorChrome<Content: View>: View {
    var title: String
    var primaryTitle: String
    var onClose: () -> Void
    var onReset: () -> Void
    var onPrimary: () -> Void
    /// When set, a "Save and Replace" button sits next to the primary (which should read "Save as New").
    var replace: ReplaceButton? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PithTheme.ink)
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(PithTheme.ink.opacity(0.75))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button("Reset", action: onReset)
                    .buttonStyle(PithQuietButtonStyle())
                Spacer()
                if let replace {
                    Button("Save and Replace", action: replace.action)
                        .buttonStyle(PithQuietButtonStyle())
                        .disabled(replace.blocker != nil)
                        .opacity(replace.blocker == nil ? 1 : 0.45)
                        .help(replace.blocker ?? "Overwrite the original in place. Undo with ⌃⌥⌘Z, or ⌘Z in Finder within 5 seconds.")
                }
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(PithPrimaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background {
            DesktopBlur(material: .popover)
            Color.white.opacity(0.22)
            PithTheme.windowWash.opacity(0.18)
        }
    }
}

/// The secondary editor action that overwrites the source file.
struct ReplaceButton {
    /// Why replacing isn't possible for this file (shown as the tooltip), or nil when it is.
    var blocker: String?
    var action: () -> Void
}

struct PithPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(configuration.isPressed ? PithTheme.highlightDeep : PithTheme.highlight))
    }
}

struct PithQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PithTheme.ink.opacity(0.8))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.35 : 0.55)))
    }
}

struct AspectChips: View {
    var presets: [AspectPreset]
    @Binding var selection: AspectPreset

    var body: some View {
        HStack(spacing: 8) {
            Text("Aspect ratio")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PithTheme.ink.opacity(0.7))
            ForEach(presets, id: \.self) { preset in
                Button(preset.label) { selection = preset }
                    .buttonStyle(ChipStyle(selected: selection == preset))
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? Color.white : PithTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? PithTheme.highlight : Color.white.opacity(0.001))
            )
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var display: String
    var onEditingChanged: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PithTheme.ink)
                .frame(width: 72, alignment: .leading)
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
            }
                .tint(PithTheme.highlight)
            Text(display)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(PithTheme.ink.opacity(0.75))
                .frame(width: 64, alignment: .trailing)
        }
    }
}

enum EditorWindow {
    @discardableResult
    static func present<Content: View>(size: NSSize, @ViewBuilder content: () -> Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // Editors use click-drag on their canvas (redact, crop, annotate), so only the
        // title-bar strip moves the window.
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.center()
        let host = NSHostingView(rootView: content())
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.cornerRadius = 22
        host.layer?.masksToBounds = true
        window.contentView = host
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
