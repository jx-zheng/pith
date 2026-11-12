import AppKit
import PithCore

/// The file icon inside a Finder drag image.
///
/// The drag image is the cell: icon bitmap plus the filename label (and the
/// padding around them). `NSDraggingImageComponent.Key.icon` is the bitmap.
/// Its frame is in the dragging item's bounds, origin at the bottom-left of
/// `draggingFrame` (AppKit, y up). If that piece is missing, the selected
/// file's icon is measured once at the grab and the ring is placed at
/// `pointer + (icon - grab)`. The pointer itself is last.
enum DraggedIconRing {
    static func placement(of sender: NSDraggingInfo, mouse: CGPoint, dragOrigin: CGPoint, paths: [String]) -> CGPoint {
        let pointer = Point(x: Double(mouse.x), y: Double(mouse.y))
        let grab = Point(x: Double(dragOrigin.x), y: Double(dragOrigin.y))
        if let image = iconPiece(of: sender, mouse: mouse) {
            let choice = IconRingGeometry.choose(dragImageCenter: image.center, offsetCenter: nil, pointer: pointer)
            write(
                source: choice.source,
                filename: "",
                icon: image.rect,
                cell: image.cell,
                pointer: pointer,
                center: choice.center,
                selectedCount: paths.count,
                reason: "drag-image"
            )
            return CGPoint(x: choice.center.x, y: choice.center.y)
        }

        let located = FinderIconLocator.locate(near: dragOrigin, paths: paths)
        let limit = Double(PithTheme.outerRadius) * 2
        if let found = located.center {
            let icon = Point(x: Double(found.x), y: Double(found.y))
            if let offset = DragGrab.offset(iconCenter: icon, grab: grab, limit: limit) {
                let center = DragGrab.center(pointer: pointer, offset: offset)
                write(
                    source: .dragOffset,
                    filename: located.filename,
                    icon: located.icon,
                    cell: located.cell,
                    pointer: pointer,
                    center: center,
                    selectedCount: paths.count,
                    reason: "drag-offset"
                )
                return CGPoint(x: center.x, y: center.y)
            }
            write(
                source: .pointer,
                filename: located.filename,
                icon: located.icon,
                cell: located.cell,
                pointer: pointer,
                center: pointer,
                selectedCount: paths.count,
                reason: "offset-too-large"
            )
            return mouse
        }

        write(
            source: .pointer,
            filename: "",
            icon: nil,
            cell: nil,
            pointer: pointer,
            center: pointer,
            selectedCount: paths.count,
            reason: located.reason
        )
        return mouse
    }

    private static func write(
        source: RingAnchorSource,
        filename: String,
        icon: RingRect?,
        cell: RingRect?,
        pointer: Point,
        center: Point,
        selectedCount: Int,
        reason: String
    ) {
        let line = RingLog(
            mode: "drag",
            source: source,
            filename: filename,
            icon: icon,
            cell: cell,
            pointer: pointer,
            center: center,
            selectedCount: selectedCount,
            reason: reason
        ).line
        RingLogger.write(line)
    }

    /// Screen center of a valid icon piece, or nil when the piece is missing,
    /// covers the whole drag frame, or is not on the pointer.
    private static func iconPiece(of sender: NSDraggingInfo, mouse: CGPoint) -> (center: Point, rect: RingRect, cell: RingRect)? {
        var found: (center: Point, rect: RingRect, cell: RingRect)?
        sender.enumerateDraggingItems(
            options: [],
            for: nil,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, stop in
            let frame = RingRect(item.draggingFrame)
            guard let icon = item.imageComponents?.first(where: { $0.key == .icon }) else { return }
            let piece = RingRect(icon.frame)
            guard let placed = IconRingGeometry.dragIcon(draggingFrame: frame, iconComponent: piece) else { return }
            let pointer = Point(x: Double(mouse.x), y: Double(mouse.y))
            guard IconRingGeometry.contains(frame, point: pointer) || IconRingGeometry.contains(placed, point: pointer) else { return }
            found = (IconRingGeometry.center(of: placed), placed, frame)
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
