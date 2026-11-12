import AppKit
import PithCore

/// The file icon inside a Finder drag image.
///
/// The drag image is the cell: icon bitmap plus the filename label (and the
/// padding around them). `NSDraggingImageComponent.Key.icon` is the bitmap.
/// Its frame is in the dragging item's bounds, origin at the bottom-left of
/// `draggingFrame` (AppKit, y up). If that piece is missing, the Finder icon
/// under the drag origin is next. The pointer is last, and the log says which
/// one was used.
enum DraggedIconRing {
    static func placement(of sender: NSDraggingInfo, mouse: CGPoint, dragOrigin: CGPoint, paths: [String]) -> (center: CGPoint, source: RingAnchorSource) {
        let dragImage = iconCenter(of: sender, mouse: mouse)
        let accessibility = dragImage == nil
            ? FinderIconLocator.iconCenter(near: dragOrigin, paths: paths)
            : nil
        let choice = IconRingGeometry.choose(
            dragImageCenter: dragImage.map { Point(x: Double($0.x), y: Double($0.y)) },
            accessibilityCenter: accessibility.map { Point(x: Double($0.x), y: Double($0.y)) },
            pointer: Point(x: Double(mouse.x), y: Double(mouse.y))
        )
        let line = IconRingGeometry.logLine(
            source: choice.source,
            center: choice.center,
            pointer: Point(x: Double(mouse.x), y: Double(mouse.y))
        )
        NSLog("%@", line as NSString)
        return (CGPoint(x: choice.center.x, y: choice.center.y), choice.source)
    }

    /// Screen center of the icon component, or nil when the drag image has no icon piece
    /// or the pointer is not on that drag image.
    private static func iconCenter(of sender: NSDraggingInfo, mouse: CGPoint) -> CGPoint? {
        var found: CGPoint?
        sender.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, stop in
            let frame = RingRect(item.draggingFrame)
            guard let icon = item.imageComponents?.first(where: { $0.key == .icon }) else { return }
            let piece = RingRect(icon.frame)
            guard piece.width > 1, piece.height > 1 else { return }
            let placed = IconRingGeometry.placedIcon(draggingFrame: frame, iconComponent: piece)
            let pointer = Point(x: Double(mouse.x), y: Double(mouse.y))
            guard IconRingGeometry.contains(frame, point: pointer) || IconRingGeometry.contains(placed, point: pointer) else { return }
            let center = IconRingGeometry.center(of: placed)
            found = CGPoint(x: center.x, y: center.y)
            stop.pointee = true
        }
        return found
    }
}

extension RingRect {
    init(_ rect: CGRect) {
        self.init(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }
}
