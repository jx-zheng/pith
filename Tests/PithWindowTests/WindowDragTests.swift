import AppKit
import SwiftUI
import XCTest

/// Title-bar drags go through `window.sendEvent`, so the test shows the header
/// strip is the view that receives the click. `performDrag` tracks that event.
final class WindowDragTests: XCTestCase {
    private let delta = CGPoint(x: 120, y: -40)

    override func setUp() {
        super.setUp()
        TitleBarDragView.followsQueuedEventsForTesting = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
    }

    override func tearDown() {
        TitleBarDragView.followsQueuedEventsForTesting = false
        super.tearDown()
    }

    func testEditorWindowsDragByTheTitleStrip() {
        let titles = ["Crop Image", "Add BG", "Annotate", "Redact", "Edit", "Metadata", "Compress", "Trim"]
        for title in titles {
            let window = EditorWindow.present(size: NSSize(width: 640, height: 480)) {
                EditorChrome(title: title, primaryTitle: "Save", onClose: {}, onReset: {}, onPrimary: {}) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            defer { window.close() }
            assertTitleDrag(window, name: title)
        }
    }

    func testCloseButtonReceivesClicksAndCanvasGesturesDoNotMoveTheWindow() {
        var closed = false
        let editor = EditorWindow.present(size: NSSize(width: 640, height: 480)) {
            EditorChrome(title: "Edit", primaryTitle: "Save", onClose: { closed = true }, onReset: {}, onPrimary: {}) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        defer { editor.close() }
        let close = waitForIdentifier("pith.close", in: editor)
        XCTAssertNotNil(close, "editor close button\n\(hierarchy(editor.contentView))")
        if let close {
            let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
            let hit = editor.contentView?.hitTest(editor.contentView!.convert(point, from: nil))
            if isDragStrip(hit) {
                XCTFail("close button is covered by the drag strip")
                return
            }
            editor.sendEvent(mouse(.leftMouseDown, at: point, window: editor))
            editor.sendEvent(mouse(.leftMouseUp, at: point, window: editor))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertTrue(closed, "clicking the X should close the editor")
        }

        assertCanvasDoesNotMove(name: "Crop") { image in
            CropEditor(image: image, pixelWidth: 80, pixelHeight: 60, onClose: {}, onApply: { _ in })
        }
        assertCanvasDoesNotMove(name: "Annotate") { image in
            AnnotateEditor(image: image, pixelWidth: 80, pixelHeight: 60, onClose: {}, onApply: { _ in })
        }
    }

    func testOnboardingCloseButtonStillWorks() {
        let window = PithWindowFactory.makeOnboarding(
            content: PithHostingView(rootView: OnboardingView(onGrant: {}, onLater: {}))
        )
        window.setFrameOrigin(NSPoint(x: 160, y: 180))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        guard let close = window.standardWindowButton(.closeButton) else {
            XCTFail("onboarding has no close button")
            return
        }
        XCTAssertFalse(close.isHidden)
        if let root = window.contentView?.superview {
            let point = root.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
            let hit = root.hitTest(point)
            XCTAssertTrue(hit === close || (hit != nil && close.isDescendant(of: hit!)), "drag strip covers the close button, hit \(String(describing: hit.map { type(of: $0) }))")
        }
        let closing = expectation(forNotification: NSWindow.willCloseNotification, object: window)
        close.performClick(nil)
        wait(for: [closing], timeout: 2)
    }

    func testMissingImageAndOnboardingDragByTheTitleStrip() {
        let missing = EditorWindow.present(size: NSSize(width: 420, height: 280)) {
            MissingImageNote(name: "photo.png", onClose: {})
        }
        defer { missing.close() }
        assertTitleDrag(missing, name: "Missing image")

        let onboarding = PithWindowFactory.makeOnboarding(
            content: PithHostingView(rootView: OnboardingView(onGrant: {}, onLater: {}))
        )
        onboarding.setFrameOrigin(NSPoint(x: 160, y: 180))
        onboarding.makeKeyAndOrderFront(nil)
        defer { onboarding.close() }
        assertTitleDrag(onboarding, name: "Onboarding")
    }

    func testProgressCardDragsByItsTitleAndDoesNotSnapBack() {
        let hud = HUDPanelController()
        let id = UUID()
        let job = HUDJob(id: id, title: "Converting to JPG", subtitle: "photo.png", progress: 0.4, anchor: CGPoint(x: 300, y: 500))
        hud.upsert(job)
        guard let panel = hud.panel(id: id) else {
            XCTFail("HUD panel was not created")
            return
        }
        defer { hud.removeAll() }
        XCTAssertTrue(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        let before = panel.frame.origin
        assertTitleDrag(panel, name: "Progress HUD")
        let dragged = panel.frame.origin
        XCTAssertNotEqual(dragged, before)
        hud.upsert(HUDJob(id: id, title: "Converting to JPG", subtitle: "photo.png", progress: 0.8, anchor: job.anchor))
        XCTAssertEqual(panel.frame.origin.x, dragged.x, accuracy: 0.5)
        XCTAssertEqual(panel.frame.origin.y, dragged.y, accuracy: 0.5, "a progress tick must not snap a dragged card back to the anchor")
    }

    func testWheelStaysPinnedAndQuickLookHostIsNotAWindowYouDrag() {
        let wheel = PithWindowFactory.makeWheelPanel(side: 436)
        XCTAssertFalse(wheel.isMovable)
        XCTAssertTrue(wheel.styleMask.contains(.borderless))
        XCTAssertFalse(wheel.styleMask.contains(.titled))
        print("PITH_WINDOW_DRAG name=Wheel movable=false pinned=true titleDrag=false reason=radial-menu")

        let host = PithWindowFactory.makeQuickLookHost()
        XCTAssertFalse(host.isMovable)
        XCTAssertTrue(host.styleMask.contains(.borderless))
        XCTAssertEqual(host.frame.width, 8)
        XCTAssertEqual(host.frame.height, 8)
        print("PITH_WINDOW_DRAG name=QuickLookHost movable=false titleDrag=false reason=invisible-anchor-for-system-panel")
    }

    private func assertCanvasDoesNotMove<Content: View>(name: String, @ViewBuilder content: (CGImage) -> Content) {
        let window = EditorWindow.present(size: NSSize(width: 760, height: 640), content: { content(sampleImage()) })
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: 180, y: 160))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let contentView = window.contentView else {
            XCTFail(name)
            return
        }
        // Below the title strip: the crop canvas and the annotate canvas live here.
        let local = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.height * 0.45)
        let hit = contentView.hitTest(local)
        if isDragStrip(hit) {
            XCTFail("\(name) canvas hit the title strip")
            return
        }
        let point = contentView.convert(local, to: nil)
        let before = window.frame.origin
        let end = NSPoint(x: point.x + 36, y: point.y - 24)
        window.sendEvent(mouse(.leftMouseDown, at: point, window: window))
        window.sendEvent(mouse(.leftMouseDragged, at: end, window: window))
        window.sendEvent(mouse(.leftMouseUp, at: end, window: window))
        XCTAssertEqual(window.frame.origin.x, before.x, accuracy: 0.5, "\(name) gesture moved the window")
        XCTAssertEqual(window.frame.origin.y, before.y, accuracy: 0.5, "\(name) gesture moved the window")
        print(String(format: "PITH_WINDOW_DRAG name=%@Canvas before=(%.1f,%.1f) after=(%.1f,%.1f) moved=false", name, before.x, before.y, window.frame.origin.x, window.frame.origin.y))
    }

    private func assertTitleDrag(_ window: NSWindow, name: String) {
        window.setFrameOrigin(NSPoint(x: 180, y: 160))
        window.makeKeyAndOrderFront(nil)
        guard let drag = waitForDragView(in: window) else {
            XCTFail("\(name): no title drag region\n\(hierarchy(window.contentView))")
            return
        }
        XCTAssertTrue(window.isMovable, name)
        XCTAssertFalse(window.isMovableByWindowBackground, name)
        XCTAssertTrue(drag.mouseDownCanMoveWindow, name)
        let inWindow = drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: nil)
        let hit = window.contentView?.hitTest(window.contentView!.convert(inWindow, from: nil))
        XCTAssertTrue(isDragStrip(hit), "\(name): header point hit \(String(describing: hit.map { type(of: $0) }))")
        let end = NSPoint(x: inWindow.x + delta.x, y: inWindow.y + delta.y)
        let before = window.frame.origin
        sendHeaderDrag(window: window, from: inWindow, to: end)
        let after = window.frame.origin
        log(name: name, before: before, after: after)
        XCTAssertEqual(after.x - before.x, delta.x, accuracy: 0.5, "\(name): dx")
        XCTAssertEqual(after.y - before.y, delta.y, accuracy: 0.5, "\(name): dy")
    }

    /// `sendEvent` hit-tests to the strip. The drag and mouse-up are already queued.
    /// The strip follows them only when no left button is down.
    private func sendHeaderDrag(window: NSWindow, from start: NSPoint, to end: NSPoint) {
        TitleBarDragView.followsQueuedEventsForTesting = true
        // The click itself is not queued, so its window location does not share
        // the shift a titled or borderless window applies to posted events.
        // The first drag is that same point, posted, and the second is the end.
        NSApp.postEvent(mouse(.leftMouseDragged, at: start, window: window), atStart: false)
        NSApp.postEvent(mouse(.leftMouseDragged, at: end, window: window), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, at: end, window: window), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, at: start, window: window))
    }

    private func isDragStrip(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is TitleBarDragView
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func log(name: String, before: NSPoint, after: NSPoint) {
        let line = String(
            format: "PITH_WINDOW_DRAG name=%@ before=(%.1f,%.1f) after=(%.1f,%.1f) dx=%.1f dy=%.1f movable=true titleDrag=true routed=hitTest",
            name, before.x, before.y, after.x, after.y, after.x - before.x, after.y - before.y
        )
        print(line)
        NSLog("%@", line as NSString)
    }

    private func waitForDragView(in window: NSWindow) -> TitleBarDragView? {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let view = find(in: window.contentView, where: { $0 is TitleBarDragView && $0.bounds.width > 8 && $0.bounds.height > 8 }) as? TitleBarDragView {
                return view
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func waitForIdentifier(_ identifier: String, in window: NSWindow) -> NSView? {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let view = find(in: window.contentView, where: { $0.accessibilityIdentifier() == identifier && $0.bounds.width > 4 }) {
                return view
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func find(in view: NSView?, where match: (NSView) -> Bool) -> NSView? {
        guard let view else { return nil }
        if match(view) { return view }
        for subview in view.subviews {
            if let found = find(in: subview, where: match) { return found }
        }
        return nil
    }

    private func hierarchy(_ view: NSView?, indent: String = "") -> String {
        guard let view else { return "" }
        var text = "\(indent)\(type(of: view)) id=\(String(describing: view.accessibilityIdentifier())) frame=\(NSStringFromRect(view.frame))\n"
        for subview in view.subviews {
            text += hierarchy(subview, indent: indent + "  ")
        }
        return text
    }

    private func sampleImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        return context.makeImage()!
    }
}

private final class DragFinished: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var done: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
