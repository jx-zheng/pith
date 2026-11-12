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
            // Header background is the drag region, including the padding under the
            // transparent title bar. The close button stays in front and still clicks.
            VStack(spacing: 0) {
                ZStack {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PithTheme.ink)
                        .allowsHitTesting(false)
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(PithTheme.ink.opacity(0.75))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                        .background(AccessibilityMarker(identifier: "pith.close"))
                        Spacer()
                            .allowsHitTesting(false)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .background(WindowDragRegion())

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
        PithWindowFactory.configureEditor(window)
        window.isReleasedWhenClosed = false
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

struct MissingImageNote: View {
    var name: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Couldn't open \(name)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PithTheme.ink)
            Button("Close", action: onClose)
                .buttonStyle(PithPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PithTheme.windowWash.opacity(0.35))
        .pithTitleBarDrag()
    }
}

struct OnboardingView: View {
    var onGrant: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pith watches the drag")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PithTheme.ink)
            Text("Drag a file from Finder, then tap Shift. A wheel appears under the pointer. Tap Shift again to cycle through Tools and Actions, then back to Convert. Drop on a segment and the converted file lands next to the source. Escape dismisses the wheel.")
                .font(.system(size: 13))
                .foregroundStyle(PithTheme.ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS has to list Pith under Privacy & Security → Accessibility. Finder owns the drag; Pith only sees the tap and the drag pasteboard once that permission is on.")
                .font(.system(size: 13))
                .foregroundStyle(PithTheme.ink.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later", action: onLater)
                    .buttonStyle(PithQuietButtonStyle())
                Spacer()
                Button("Grant Access", action: onGrant)
                    .buttonStyle(PithPrimaryButtonStyle())
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 460)
        .pithTitleBarDrag()
    }
}
