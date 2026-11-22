import AppKit
import QuartzCore
import SwiftUI
import PithCore

/// Borderless, non-activating panel. The whole wheel is one drop destination;
/// `draggingUpdated` picks the segment from the pointer angle.
final class WheelPanelController: NSObject, NSDraggingDestination {
    let model = WheelModel()
    private let panel: NSPanel
    private let dropView: WheelDropView
    private(set) var isShowing = false
    /// True from the moment a non-action dismiss starts until the panel is ordered out or restored.
    private(set) var isClosing = false
    /// Set once the drag-image icon has been applied for this presentation.
    private var appliedDragImage = false
    /// The pointer where the wheel appeared. A drop waits until it moves, or until a later entry.
    private var hover = RingHoverGate()
    private var anchorMouse = Point.zero
    private var sawInitialDragEntry = false
    var onDropIndex: ((Int) -> Void)?
    var onHoverIndex: ((Int?) -> Void)?
    /// Click-select mode: a segment was clicked.
    var onClickIndex: ((Int) -> Void)?
    /// Click-select mode: the centre, a gap, a corner, or a wedge with no action.
    var onMissClick: (() -> Void)?
    /// Drag-image icon center, in screen coordinates. No accessibility lookup.
    var onDragImageCenter: ((CGPoint) -> Void)?

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

    /// Draws the ring at `screenPoint` on this turn. Full opacity, no intro animation.
    func present(at screenPoint: CGPoint, dragOrigin: CGPoint, paths: [String]) {
        _ = (dragOrigin, paths)
        appliedDragImage = false
        hover = RingHoverGate()
        sawInitialDragEntry = false
        anchorMouse = Point(x: Double(NSEvent.mouseLocation.x), y: Double(NSEvent.mouseLocation.y))
        model.highlighted = nil
        model.appeared = true
        restoreInteractive()
        moveRing(to: screenPoint)
        panel.orderFrontRegardless()
        isShowing = true
    }

    /// Orders the panel out. Alpha is restored only after it is off screen, so a fade
    /// cannot flash back to full opacity on the way out.
    func orderOutNow() {
        isClosing = false
        panel.ignoresMouseEvents = false
        isShowing = false
        model.highlighted = nil
        panel.orderOut(nil)
        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pith-close-fade")
            layer.removeAnimation(forKey: "pith-close-scale")
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        panel.alphaValue = 1
    }

    /// Stops taking clicks immediately, then fades and scales down.
    /// The opacity animation is on the content layer so cancelling it cannot
    /// leave `animator()` writing alpha 0 over a reopened ring.
    func beginCloseAnimation(duration: TimeInterval, completion: @escaping () -> Void) {
        guard isShowing, !isClosing else { return }
        isClosing = true
        panel.ignoresMouseEvents = true
        guard let layer = closeLayer() else {
            completion()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DIdentity
        scale.toValue = CATransform3DMakeScale(0.94, 0.94, 1)
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer.add(fade, forKey: "pith-close-fade")
        layer.add(scale, forKey: "pith-close-scale")
        // The model values stay at full opacity. `fillMode = .forwards` holds the
        // faded presentation, and removing the animations (a Shift reopen) snaps back.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            completion()
        }
    }

    /// Drops the fade. The panel is full opacity and accepts clicks again.
    func restoreInteractive() {
        isClosing = false
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        guard let layer = panel.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "pith-close-fade")
        layer.removeAnimation(forKey: "pith-close-scale")
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func closeLayer() -> CALayer? {
        panel.contentView?.wantsLayer = true
        panel.contentView?.subviews.forEach { $0.wantsLayer = true }
        return panel.contentView?.layer
    }

    func move(to screenPoint: CGPoint) {
        moveRing(to: screenPoint)
    }

    func commitFrame() {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
    }

    /// Warms the window server and the SwiftUI host without a visible flash.
    func prewarm() {
        model.appeared = true
        let saved = panel.frame.origin
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()
        panel.orderOut(nil)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.setFrameOrigin(saved)
        isShowing = false
        isClosing = false
    }

    func panelFrameContains(_ screenPoint: CGPoint) -> Bool {
        panel.frame.contains(screenPoint)
    }

    func actionableWedge(atScreen screenPoint: CGPoint) -> Bool {
        let windowPoint = dropView.convert(panel.convertPoint(fromScreen: screenPoint), from: nil)
        guard let index = highlight(at: windowPoint) else { return false }
        return model.segments.indices.contains(index) && model.segments[index].enabled
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

    /// Local drag-image icon only. Accessibility lookup stays off this path.
    private func alignRingToDraggedIcon(_ sender: NSDraggingInfo) {
        guard !appliedDragImage, !isClosing else { return }
        let mouse = NSEvent.mouseLocation
        guard let image = DraggedIconRing.iconPiece(of: sender, mouse: mouse) else { return }
        appliedDragImage = true
        onDragImageCenter?(CGPoint(x: image.center.x, y: image.center.y))
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

    /// Click mode. A wedge with an action runs. Every other point in the panel closes the wheel.
    func clickDown(at windowPoint: NSPoint) {
        guard !isClosing else { return }
        let index = highlight(at: windowPoint)
        let enabled = index.map { model.segments.indices.contains($0) && model.segments[$0].enabled } ?? false
        switch WheelClick.decide(index: index, enabled: enabled) {
        case .act(let index):
            onClickIndex?(index)
        case .close:
            onMissClick?()
        }
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        model.highlighted = nil
        onHoverIndex?(nil)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isClosing else { return false }
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

    override func mouseDown(with event: NSEvent) {
        controller?.clickDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {}

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
