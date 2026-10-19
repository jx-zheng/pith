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
        dropView.controller = self
        panel.contentView = dropView
        let host = NSHostingView(rootView: WheelContainer(model: model))
        host.frame = dropView.bounds
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
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

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

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

    func draggingExited(_ sender: NSDraggingInfo?) {
        model.highlighted = nil
        onHoverIndex?(nil)
    }

    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
