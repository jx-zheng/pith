import AppKit
import SwiftUI
import PithCore

/// Borderless, non-activating panel. The whole wheel is one drop destination;
/// `draggingUpdated` picks the segment from the pointer angle.
final class WheelPanelController: NSObject, NSDraggingDestination {
    let model = WheelModel()
    private let panel: NSPanel
    private let dropView: WheelDropView
    private(set) var isShowing = false
    var onDropIndex: ((Int) -> Void)?
    var onHoverIndex: ((Int?) -> Void)?
    /// Click-select mode: a segment was clicked.
    var onClickIndex: ((Int) -> Void)?

    override init() {
        let side = PithTheme.wheelDiameter + PithTheme.panelPadding
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        dropView = WheelDropView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        super.init()
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
        dropView.controller = self
        // The SwiftUI hosting view registers its own drag types and would swallow the
        // drop if it sat above the destination view. Keep it underneath, and put the
        // transparent drop view on top so AppKit routes dragging callbacks to us.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = container
        let host = NSHostingView(rootView: WheelContainer(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        host.unregisterDraggedTypes()
        container.addSubview(host)
        dropView.frame = container.bounds
        dropView.autoresizingMask = [.width, .height]
        container.addSubview(dropView, positioned: .above, relativeTo: host)
    }

    func present(at screenPoint: CGPoint) {
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: screenPoint.x - size.width / 2, y: screenPoint.y - size.height / 2))
        if !isShowing {
            model.appeared = false
            model.replay += 1
        }
        panel.orderFrontRegardless()
        isShowing = true
    }

    func dismiss() {
        guard isShowing else { return }
        isShowing = false
        model.highlighted = nil
        panel.orderOut(nil)
    }

    func highlight(at windowPoint: NSPoint) -> Int? {
        let bounds = dropView.bounds
        guard bounds.width > 0 else { return nil }
        // Window points are y-up. Wheel geometry is y-down, matching SwiftUI.
        let yDown = NSPoint(x: windowPoint.x, y: bounds.height - windowPoint.y)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let geometry = WheelGeometry(
            outerRadius: Double(PithTheme.outerRadius),
            innerRadius: Double(PithTheme.innerRadius),
            gapRadians: PithTheme.gapRadians,
            count: max(model.segments.count, 1)
        )
        let local = Point(x: Double(yDown.x - center.x), y: Double(yDown.y - center.y))
        return geometry.index(at: local, center: .zero)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NSLog("Pith: draggingEntered wheel")
        return draggingUpdated(sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let index = highlight(at: sender.draggingLocation)
        if model.highlighted != index {
            model.highlighted = index
            onHoverIndex?(index)
        }
        guard let index, model.segments.indices.contains(index), model.segments[index].enabled else {
            return []
        }
        return .copy
    }

    func pointerMoved(to windowPoint: NSPoint) {
        let index = highlight(at: windowPoint)
        if model.highlighted != index {
            model.highlighted = index
            onHoverIndex?(index)
        }
    }

    func clicked(at windowPoint: NSPoint) {
        guard let index = highlight(at: windowPoint),
              model.segments.indices.contains(index),
              model.segments[index].enabled else { return }
        onClickIndex?(index)
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        model.highlighted = nil
        onHoverIndex?(nil)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        NSLog("Pith: performDragOperation at %@", NSStringFromPoint(sender.draggingLocation))
        let index = highlight(at: sender.draggingLocation) ?? model.highlighted
        guard let index, model.segments.indices.contains(index), model.segments[index].enabled else {
            return false
        }
        onDropIndex?(index)
        return true
    }
}

final class WheelDropView: NSView {
    weak var controller: WheelPanelController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerDragTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerDragTypes()
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pointerMoved(to: NSPoint(x: -10_000, y: -10_000))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        controller?.clicked(at: convert(event.locationInWindow, from: nil))
    }

    private func registerDragTypes() {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        registerForDraggedTypes(types)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.performDragOperation(sender) ?? false
    }
}
