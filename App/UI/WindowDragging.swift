import AppKit
import SwiftUI

/// Title-bar drag shared by every secondary window.
///
/// Glass editors use a hidden, transparent title bar (`fullSizeContentView`) and
/// the SwiftUI content covers it, so AppKit never sees a title-bar drag. The
/// progress card is borderless. This view is the title region: `mouseDown`
/// tracks the pointer and moves the window by that delta. Canvas clicks stay
/// on the views above it, because `isMovableByWindowBackground` stays off.
final class TitleBarDragView: NSView {
    static let identifier = "pith.titleDrag"

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, window.isMovable else { return }
        window.performDrag(with: event)
    }
}

/// SwiftUI's hosting view otherwise returns itself from `hitTest`, so a click on the
/// title strip never reaches `TitleBarDragView`.
final class PithHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The close control sits in front of the strip. SwiftUI handles that click.
        if marker(in: self, point: point, identifier: "pith.close") != nil {
            return super.hitTest(point)
        }
        if let drag = dragView(in: self, point: point) {
            return drag
        }
        return super.hitTest(point)
    }

    private func dragView(in view: NSView, point: NSPoint) -> NSView? {
        for subview in view.subviews.reversed() {
            guard !subview.isHidden else { continue }
            let local = view.convert(point, to: subview)
            if let nested = dragView(in: subview, point: local) {
                return nested
            }
            if subview is TitleBarDragView, subview.bounds.contains(local) {
                return subview
            }
        }
        return nil
    }

    private func marker(in view: NSView, point: NSPoint, identifier: String) -> NSView? {
        for subview in view.subviews.reversed() {
            guard !subview.isHidden else { continue }
            let local = view.convert(point, to: subview)
            if let nested = marker(in: subview, point: local, identifier: identifier) {
                return nested
            }
            if subview.accessibilityIdentifier() == identifier, subview.bounds.contains(local) {
                return subview
            }
        }
        return nil
    }
}

/// Marks a control so tests can find its frame. The view sits behind the control.
struct AccessibilityMarker: NSViewRepresentable {
    var identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Invisible title strip. Put it behind a window's own buttons so those still click.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarDragView {
        let view = TitleBarDragView()
        view.setAccessibilityIdentifier(TitleBarDragView.identifier)
        return view
    }

    func updateNSView(_ nsView: TitleBarDragView, context: Context) {}

    /// Take the size proposed by the header or title strip. Asking for more
    /// would stretch the strip over the editor canvas.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleBarDragView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

extension View {
    /// Covers the transparent system title bar (about 32 pt) without taking the
    /// controls drawn under it.
    func pithTitleBarDrag() -> some View {
        overlay(alignment: .top) {
            // The leading gap is the traffic-light area, so the system close
            // button still receives the click.
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 78)
                    .allowsHitTesting(false)
                WindowDragRegion()
            }
            .frame(height: 32)
            .frame(maxWidth: .infinity)
        }
    }
}

enum PithWindowFactory {
    static func configureEditor(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovable = true
        // `close()` must not release the window out from under ARC. Tests and
        // the app both keep the NSWindow, and a second release crashes.
        window.isReleasedWhenClosed = false
        // Canvas tools (crop, redact, annotate) drag inside the view. Only the
        // title strip moves the window.
        window.isMovableByWindowBackground = false
        window.level = .floating
    }

    static func makeOnboarding(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pith"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.62, alpha: 1)
        window.contentView = content
        window.center()
        return window
    }

    static func makeSettings(contentController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Pith Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        return window
    }

    /// Folder choosers come back with `isMovable == false`. The titled panel the
    /// user sees should still move by its title bar.
    static func configureChooser(_ panel: NSOpenPanel) {
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
    }

    static func makeHUDPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 78),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Borderless radial menu. It stays on the file icon. A title bar would steal
    /// segment clicks and the drop, so this panel is not movable.
    static func makeWheelPanel(side: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    /// Invisible anchor for the system Quick Look panel. The panel the user sees
    /// is `QLPreviewPanel`, which has its own title bar. This host is not a window
    /// anyone drags.
    static func makeQuickLookHost() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.isReleasedWhenClosed = false
        window.isMovable = false
        return window
    }
}
