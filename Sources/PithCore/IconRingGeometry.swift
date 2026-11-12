import Foundation

/// A rectangle in a single coordinate space. `y` grows in whichever direction
/// that space uses; the ring math only needs midpoints and containment.
public struct RingRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
}

/// Where the ring around a file sits.
///
/// The ring is centered on the rendered icon image. A Finder icon-view cell and
/// a list row are larger than that image: they also hold the filename and the
/// padding around it. Using the cell midpoint pulls the ring toward the label,
/// and the pull changes with icon size, label length, and backing scale.
/// Callers resolve the image bounds first (`iconImage(inside:images:)` from
/// accessibility frames, or `placedIcon(draggingFrame:iconComponent:)` from a
/// drag image). This type does not add a constant nudge.
public enum IconRingGeometry {
    /// Midpoint of the rendered icon image.
    public static func center(of iconImage: RingRect) -> Point {
        iconImage.center
    }

    /// The icon image inside a cell or row.
    ///
    /// `images` are the image frames discovered in the cell (accessibility images,
    /// or any other measured icon bitmaps) in the same coordinate space as `cell`.
    /// A frame that is the cell itself is rejected: that is the label and padding
    /// too. Among the frames that are strictly smaller, a square bitmap wins over
    /// a wide label image, and the largest of those is the file icon rather than
    /// a badge. Returns nil when the icon image cannot be told from the cell, so
    /// the caller keeps its previous anchor instead of guessing a label height.
    public static func iconImage(inside cell: RingRect, images: [RingRect]) -> RingRect? {
        let distinct = images.filter { image in
            image.width > 1 && image.height > 1 &&
            contains(cell, image) &&
            (image.width < cell.width - 0.5 || image.height < cell.height - 0.5)
        }
        let squares = distinct.filter(isIconShaped)
        let pool = squares.isEmpty ? distinct : squares
        return pool.max { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height }
    }

    /// Icon-component bounds placed into the drag image's space.
    ///
    /// `iconComponent` is the icon piece of the drag image, origin at the
    /// bottom-left of `draggingFrame` (AppKit dragging-item bounds). The label
    /// component lives in the rest of `draggingFrame` and is not part of the result.
    public static func placedIcon(draggingFrame: RingRect, iconComponent: RingRect) -> RingRect {
        RingRect(
            x: draggingFrame.x + iconComponent.x,
            y: draggingFrame.y + iconComponent.y,
            width: iconComponent.width,
            height: iconComponent.height
        )
    }

    /// The drag image's icon piece, or nil when that piece is the whole frame
    /// or is not a roughly square bitmap.
    ///
    /// A piece the size of `draggingFrame` is the cell (icon, label, and padding).
    /// The same rule as `iconImage(inside:images:)` rejects it: strictly smaller
    /// than the frame, and square within 15%. The caller then uses the next anchor.
    public static func dragIcon(draggingFrame: RingRect, iconComponent: RingRect) -> RingRect? {
        let placed = placedIcon(draggingFrame: draggingFrame, iconComponent: iconComponent)
        guard let icon = iconImage(inside: draggingFrame, images: [placed]), isIconShaped(icon) else { return nil }
        return icon
    }

    /// The Finder icon center when it is within `radius` of the pointer.
    /// A center farther away is a different row, so the caller keeps the pointer.
    public static func accessibilityCenter(_ center: Point?, pointer: Point, radius: Double) -> Point? {
        guard let center, radius >= 0 else { return nil }
        let dx = center.x - pointer.x
        let dy = center.y - pointer.y
        guard dx * dx + dy * dy <= radius * radius else { return nil }
        return center
    }

    /// Which measurement produced the ring center. Drag-image bounds win, then the
    /// Finder icon under the drag origin, then the pointer.
    public static func choose(dragImageCenter: Point?, accessibilityCenter: Point?, pointer: Point) -> (center: Point, source: RingAnchorSource) {
        if let dragImageCenter { return (dragImageCenter, .dragImage) }
        if let accessibilityCenter { return (accessibilityCenter, .accessibility) }
        return (pointer, .pointer)
    }

    public static func logLine(source: RingAnchorSource, center: Point, pointer: Point) -> String {
        String(
            format: "Pith: drag ring source=%@ center=(%.1f,%.1f) pointer=(%.1f,%.1f)",
            source.rawValue, center.x, center.y, pointer.x, pointer.y
        )
    }

    /// Panel origin that puts the panel's center on `center`. The wheel is centered
    /// in the panel, so this is also the ring's origin.
    public static func panelOrigin(center: Point, panelWidth: Double, panelHeight: Double) -> Point {
        Point(x: center.x - panelWidth / 2, y: center.y - panelHeight / 2)
    }

    /// AppKit y (bottom-left of the main display, y up) to accessibility y
    /// (top-left of the main display, y down).
    public static func topLeftY(fromAppKitY y: Double, mainScreenMaxY: Double) -> Double {
        mainScreenMaxY - y
    }

    /// Accessibility y back to AppKit y. Inverse of `topLeftY(fromAppKitY:mainScreenMaxY:)`.
    public static func appKitY(fromTopLeftY y: Double, mainScreenMaxY: Double) -> Double {
        mainScreenMaxY - y
    }

    public static func contains(_ cell: RingRect, _ image: RingRect, slop: Double = 1) -> Bool {
        image.x >= cell.x - slop &&
        image.y >= cell.y - slop &&
        image.x + image.width <= cell.x + cell.width + slop &&
        image.y + image.height <= cell.y + cell.height + slop
    }

    public static func contains(_ rect: RingRect, point: Point, slop: Double = 1) -> Bool {
        point.x >= rect.x - slop &&
        point.y >= rect.y - slop &&
        point.x <= rect.x + rect.width + slop &&
        point.y <= rect.y + rect.height + slop
    }

    /// File icons are square bitmaps. A filename image is wide. 15% lets a
    /// slightly non-square icon through and rejects a label.
    private static func isIconShaped(_ rect: RingRect) -> Bool {
        let long = max(rect.width, rect.height)
        guard long > 0 else { return false }
        return abs(rect.width - rect.height) / long <= 0.15
    }
}

public enum RingAnchorSource: String, Equatable, Sendable {
    case dragImage = "drag-image"
    case accessibility = "accessibility"
    case pointer = "pointer"
}

/// A drop on the wheel counts only after the pointer moves, or after it leaves
/// and comes back. The position where the wheel appeared is not a choice:
/// recentering onto a list-row icon can leave the pointer already on a segment.
public struct RingHoverGate: Equatable, Sendable {
    public var armed = false
    /// Movement smaller than this is the pointer sitting still while the wheel appears.
    public static let movement: Double = 3

    public init() {}

    public mutating func pointerMoved(from anchor: Point, to pointer: Point) {
        guard !armed else { return }
        let dx = pointer.x - anchor.x
        let dy = pointer.y - anchor.y
        if dx * dx + dy * dy >= Self.movement * Self.movement {
            armed = true
        }
    }

    public mutating func freshEntry() {
        armed = true
    }

    /// `segment` is nil when the pointer is outside the ring. A stale highlight is not used.
    public func canCommit(segment: Int?) -> Int? {
        guard armed else { return nil }
        return segment
    }
}
