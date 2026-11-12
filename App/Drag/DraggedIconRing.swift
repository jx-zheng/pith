import AppKit
import PithCore

/// The file icon inside a Finder drag image.
///
/// The drag image is the cell: icon bitmap plus the filename label (and the
/// padding around them). `NSDraggingImageComponent.Key.icon` is the bitmap.
/// Its frame is in the dragging item's bounds, origin at the bottom-left of
/// `draggingFrame` (AppKit, y up). The ring uses that image, not the cell.
enum DraggedIconRing {
    static func center(of sender: NSDraggingInfo, mouse: CGPoint) -> CGPoint? {
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
            // The pointer is on the icon or on its label, so it is inside the drag image.
            // A frame that doesn't contain it belongs to some other item.
            guard IconRingGeometry.contains(frame, point: pointer) || IconRingGeometry.contains(placed, point: pointer) else { return }
            let center = IconRingGeometry.center(of: placed)
            NSLog(
                "Pith: drag ring icon=(%.1f,%.1f) cell=(%.1f,%.1f) pointer=(%.1f,%.1f)",
                center.x, center.y, frame.center.x, frame.center.y, pointer.x, pointer.y
            )
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
