import AppKit
import SwiftUI
import XCTest

/// Each secondary window Pith opens, dragged by its title region.
/// The line `PITH_WINDOW_DRAG` is the before/after frame origin.
final class WindowDragTests: XCTestCase {
    private let delta = CGPoint(x: 120, y: -40)

    override func setUp() {
        super.setUp()
        TitleBarDrag.timeout = 2
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
            assertTitleDrag(window, name: title, upperBand: true)
        }
    }

    func testMissingImageAndOnboardingDragByTheTitleStrip() {
        let missing = EditorWindow.present(size: NSSize(width: 420, height: 280)) {
            MissingImageNote(name: "photo.png", onClose: {})
        }
        defer { missing.close() }
        assertTitleDrag(missing, name: "Missing image", upperBand: true)

        let onboarding = PithWindowFactory.makeOnboarding(
            content: NSHostingView(rootView: OnboardingView(onGrant: {}, onLater: {}))
        )
        onboarding.setFrameOrigin(NSPoint(x: 160, y: 180))
        onboarding.makeKeyAndOrderFront(nil)
        defer { onboarding.close() }
        assertTitleDrag(onboarding, name: "Onboarding", upperBand: true)
    }

    func testSettingsDragByTheSystemTitleBar() {
        let host = NSHostingController(rootView: Text("Pith Settings"))
        let window = PithWindowFactory.makeSettings(contentController: host)
        window.setContentSize(NSSize(width: 560, height: 400))
        window.setFrameOrigin(NSPoint(x: 200, y: 220))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .visible)
        let titleHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titleHeight, 12, "settings has a system title bar")
        let start = NSPoint(x: window.contentLayoutRect.midX, y: window.contentLayoutRect.maxY + titleHeight / 2)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        let before = window.frame.origin
        synthesize(window: window, from: start, to: end, view: nil)
        log(name: "Settings", before: before, after: window.frame.origin, movable: true, titleDrag: true)
        assertMoved(window, from: before)
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
        assertTitleDrag(panel, name: "Progress HUD", upperBand: false)
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

        let open = NSOpenPanel()
        PithWindowFactory.configureChooser(open)
        XCTAssertTrue(open.styleMask.contains(.titled))
        open.setFrameOrigin(NSPoint(x: 220, y: 260))
        open.makeKeyAndOrderFront(nil)
        open.isMovable = true
        defer { open.close() }
        if open.isMovable {
            let before = open.frame.origin
            let start = NSPoint(x: 80, y: max(open.frame.height - 10, 10))
            synthesize(window: open, from: start, to: NSPoint(x: start.x + delta.x, y: start.y + delta.y), view: nil)
            log(name: "OpenPanel", before: before, after: open.frame.origin, movable: true, titleDrag: true)
            assertMoved(open, from: before)
        } else {
            // A fresh save panel can keep reporting itself immovable. The window
            // the user drags is still AppKit's titled panel.
            print("PITH_WINDOW_DRAG name=OpenPanel movable=system titleDrag=system reason=NSSavePanel")
        }
        print("PITH_WINDOW_AUDIT Crop,Add BG,Annotate,Redact,Edit,Metadata,Compress,Trim,Missing image,Onboarding,Settings,Progress HUD,OpenPanel=movable; Wheel,QuickLookHost=pinned")
    }

    private func assertTitleDrag(_ window: NSWindow, name: String, upperBand: Bool) {
        window.setFrameOrigin(NSPoint(x: 180, y: 160))
        window.makeKeyAndOrderFront(nil)
        guard let drag = waitForDragView(in: window) else {
            XCTFail("\(name): no title drag region\n\(hierarchy(window.contentView))")
            return
        }
        XCTAssertTrue(window.isMovable, name)
        XCTAssertFalse(window.isMovableByWindowBackground, name)
        XCTAssertTrue(drag.mouseDownCanMoveWindow, name)
        XCTAssertEqual(drag.accessibilityIdentifier(), TitleBarDragView.identifier, name)
        let inWindow = drag.convert(drag.bounds, to: nil)
        XCTAssertGreaterThan(inWindow.width, 40, name)
        XCTAssertGreaterThan(inWindow.height, 10, name)
        if upperBand, let content = window.contentView {
            XCTAssertLessThan(inWindow.height, content.bounds.height * 0.45, "\(name): title strip covers the canvas")
            XCTAssertGreaterThan(inWindow.maxY, content.bounds.height * 0.75, "\(name): title strip is not at the top")
        }
        let start = NSPoint(x: inWindow.midX, y: inWindow.midY)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        let before = window.frame.origin
        synthesize(window: window, from: start, to: end, view: drag)
        log(name: name, before: before, after: window.frame.origin, movable: true, titleDrag: true)
        assertMoved(window, from: before)
    }

    private func synthesize(window: NSWindow, from start: NSPoint, to end: NSPoint, view: NSView?) {
        func make(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
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
        // One mouse-up is enough: the window has not moved yet, so the screen
        // delta is exactly `to - from`. A following event would be converted
        // against the updated frame and applied twice.
        NSApp.postEvent(make(.leftMouseUp, end), atStart: true)
        if let view {
            view.mouseDown(with: make(.leftMouseDown, start))
        } else {
            TitleBarDrag.track(window: window, from: make(.leftMouseDown, start))
        }
    }

    private func assertMoved(_ window: NSWindow, from before: NSPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.frame.origin.x, before.x + delta.x, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(window.frame.origin.y, before.y + delta.y, accuracy: 0.5, file: file, line: line)
    }

    private func log(name: String, before: NSPoint, after: NSPoint, movable: Bool, titleDrag: Bool) {
        let line = String(
            format: "PITH_WINDOW_DRAG name=%@ before=(%.1f,%.1f) after=(%.1f,%.1f) dx=%.1f dy=%.1f movable=%@ titleDrag=%@",
            name, before.x, before.y, after.x, after.y, after.x - before.x, after.y - before.y,
            movable ? "true" : "false", titleDrag ? "true" : "false"
        )
        print(line)
        NSLog("%@", line)
    }

    private func waitForDragView(in window: NSWindow) -> TitleBarDragView? {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let view = findDragViews(in: window.contentView).first(where: { $0.bounds.width > 8 && $0.bounds.height > 8 }) {
                return view
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func findDragViews(in view: NSView?) -> [TitleBarDragView] {
        guard let view else { return [] }
        var found: [TitleBarDragView] = []
        if let drag = view as? TitleBarDragView { found.append(drag) }
        for subview in view.subviews {
            found.append(contentsOf: findDragViews(in: subview))
        }
        return found
    }

    private func hierarchy(_ view: NSView?, indent: String = "") -> String {
        guard let view else { return "" }
        var text = "\(indent)\(type(of: view)) id=\(String(describing: view.accessibilityIdentifier())) frame=\(NSStringFromRect(view.frame))\n"
        for subview in view.subviews {
            text += hierarchy(subview, indent: indent + "  ")
        }
        return text
    }
}
