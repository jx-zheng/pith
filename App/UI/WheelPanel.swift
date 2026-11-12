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
    /// Set once the ring has been placed for this presentation.
    private var alignedToIcon = false
    /// The pointer where the wheel appeared. A drop waits until it moves, or until a later entry.
    private var hover = RingHoverGate()
    private var anchorMouse = Point.zero
    private var sawInitialDragEntry = false
    private var dragOrigin = CGPoint.zero
    private var dragPaths: [String] = []
    var onDropIndex: ((Int) -> Void)?
    var onHoverIndex: ((Int?) -> Void)?
    /// Click-select mode: a segment was clicked.
    var onClickIndex: ((Int) -> Void)?

    override init() {
        let side = PithTheme.wheelDiameter + PithTheme.panelPadding
        panel = PithWindowFactory.makeWheelPanel(side: side)
        dropView = WheelDropView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        super.init()
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

    /// `hiddenUntilAligned` keeps a drag wheel invisible until the icon center is known,
    /// so it does not appear on the pointer and then jump.
    func present(at screenPoint: CGPoint, hiddenUntilAligned: Bool, dragOrigin: CGPoint, paths: [String]) {
        alignedToIcon = false
        hover = RingHoverGate()
        sawInitialDragEntry = false
        anchorMouse = Point(x: Double(NSEvent.mouseLocation.x), y: Double(NSEvent.mouseLocation.y))
        self.dragOrigin = dragOrigin
        dragPaths = paths
        model.highlighted = nil
        panel.alphaValue = hiddenUntilAligned ? 0 : 1
        moveRing(to: screenPoint)
        if !isShowing {
            model.appeared = false
            model.replay += 1
        }
        panel.orderFrontRegardless()
        isShowing = true
        if hiddenUntilAligned {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.alphaValue = 1
            }
        }
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
        alignRingToDraggedIcon(sender)
        // The entry that happens because the wheel just appeared is not a choice.
        // Leaving and coming back is.
        if sawInitialDragEntry {
            hover.freshEntry()
        } else {
            sawInitialDragEntry = true
        }
        return draggingUpdated(sender)
    }

    /// Places the ring, then reveals it. Drag-image icon, then the Finder icon
    /// under the drag origin, then the pointer. The log names the source.
    private func alignRingToDraggedIcon(_ sender: NSDraggingInfo) {
        guard !alignedToIcon else { return }
        alignedToIcon = true
        let mouse = NSEvent.mouseLocation
        let placement = DraggedIconRing.placement(of: sender, mouse: mouse, dragOrigin: dragOrigin, paths: dragPaths)
        moveRing(to: placement.center)
        panel.alphaValue = 1
    }

    private func moveRing(to screenPoint: CGPoint) {
        let size = panel.frame.size
        let origin = IconRingGeometry.panelOrigin(
            center: Point(x: Double(screenPoint.x), y: Double(screenPoint.y)),
            panelWidth: Double(size.width),
            panelHeight: Double(size.height)
        )
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        alignRingToDraggedIcon(sender)
        notePointer()
        let index = highlight(at: sender.draggingLocation)
        publishHover(index)
        guard hover.canCommit(segment: index) != nil,
              let index, model.segments.indices.contains(index), model.segments[index].enabled else {
            return []
        }
        return .copy
    }

    func pointerMoved(to windowPoint: NSPoint) {
        notePointer()
        publishHover(highlight(at: windowPoint))
    }

    private func notePointer() {
        let mouse = NSEvent.mouseLocation
        hover.pointerMoved(from: anchorMouse, to: Point(x: Double(mouse.x), y: Double(mouse.y)))
    }

    /// Outside the ring, `index` is nil and any previous highlight is cleared.
    private func publishHover(_ index: Int?) {
        guard hover.armed else {
            if model.highlighted != nil {
                model.highlighted = nil
                onHoverIndex?(nil)
            }
            return
        }
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
        let index = highlight(at: sender.draggingLocation)
        guard let index = hover.canCommit(segment: index),
              model.segments.indices.contains(index),
              model.segments[index].enabled else {
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
