import AppKit
import ApplicationServices
import PithCore

/// Screen point (AppKit, y up) at the center of a Finder file's icon image.
///
/// The element under the pointer is often the filename or the whole cell. The
/// icon bitmap is the square image inside that cell. List rows and icon-view
/// cells both go through `IconRingGeometry`, so a longer label does not move
/// the result. Returns nil when Accessibility is off or the icon image cannot
/// be separated from the cell; the caller then keeps the pointer.
enum FinderIconLocator {
    static func iconCenter(near mouse: CGPoint, paths: [String]) -> CGPoint? {
        guard AccessibilityPermission.isTrusted(prompt: false) else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let maxY = Double(primary.frame.maxY)
        let axY = IconRingGeometry.topLeftY(fromAppKitY: Double(mouse.y), mainScreenMaxY: maxY)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(mouse.x), Float(axY), &hit)
        guard status == .success, let hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .contains(where: { $0.processIdentifier == pid }) else { return nil }

        let pointer = Point(x: Double(mouse.x), y: axY)
        guard let match = resolve(startingAt: hit, pointer: pointer, paths: paths) else { return nil }
        let center = IconRingGeometry.center(of: match.icon)
        let appKitY = IconRingGeometry.appKitY(fromTopLeftY: center.y, mainScreenMaxY: maxY)
        NSLog(
            "Pith: click ring icon=(%.1f,%.1f) cell=(%.1f,%.1f) pointer=(%.1f,%.1f)",
            center.x, appKitY, match.cell.center.x,
            IconRingGeometry.appKitY(fromTopLeftY: match.cell.center.y, mainScreenMaxY: maxY),
            mouse.x, mouse.y
        )
        return CGPoint(x: center.x, y: appKitY)
    }

    private static func resolve(startingAt element: AXUIElement, pointer: Point, paths: [String]) -> (icon: RingRect, cell: RingRect)? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let node = current else { break }
            if let role = role(of: node), stopRoles.contains(role) { break }
            if let cell = frame(of: node), IconRingGeometry.contains(cell, point: pointer) {
                var images: [RingRect] = []
                if role(of: node) == imageRole, let own = frame(of: node) {
                    images.append(own)
                }
                for child in children(of: node) {
                    collectImages(child, into: &images, depth: 0)
                }
                if let icon = IconRingGeometry.iconImage(inside: cell, images: images),
                   accepts(node, paths: paths) {
                    return (icon, cell)
                }
            }
            current = parent(of: node)
        }
        return nil
    }

    /// A URL or filename that names some other file is the wrong cell.
    /// Elements that don't publish either are kept: Finder often omits them on the label.
    private static func accepts(_ element: AXUIElement, paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let url = string(element, kAXURLAttribute as String) {
            let path = URL(string: url)?.path ?? url
            let name = URL(fileURLWithPath: path).lastPathComponent
            if paths.contains(path) || names.contains(name) { return true }
            if !name.isEmpty && !names.contains(name) && path.hasPrefix("/") { return false }
        }
        if let name = string(element, "AXFilename") ?? string(element, kAXTitleAttribute as String) {
            if names.contains(name) { return true }
            if !name.isEmpty && name.contains(".") && !names.contains(name) { return false }
        }
        return true
    }

    private static let imageRole = kAXImageRole as String
    private static let stopRoles: Set<String> = [
        kAXScrollAreaRole as String,
        kAXListRole as String,
        kAXWindowRole as String,
        kAXApplicationRole as String,
        "AXOutline",
        "AXTable",
        "AXBrowser"
    ]

    private static func collectImages(_ element: AXUIElement, into images: inout [RingRect], depth: Int) {
        guard depth < 4 else { return }
        if role(of: element) == imageRole, let rect = frame(of: element) {
            images.append(rect)
        }
        for child in children(of: element) {
            collectImages(child, into: &images, depth: depth + 1)
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copy(element, kAXChildrenAttribute as String),
              let array = value as? NSArray else { return [] }
        return (0..<array.count).compactMap { axElement(array[$0]) }
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = copy(element, kAXParentAttribute as String) else { return nil }
        return axElement(value)
    }

    /// `as? AXUIElement` does not check the CoreFoundation type, so compare type IDs.
    private static func axElement(_ value: Any) -> AXUIElement? {
        guard let object = value as AnyObject?, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(object, to: AXUIElement.self)
    }

    private static func role(of element: AXUIElement) -> String? {
        copy(element, kAXRoleAttribute as String) as? String
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private static func frame(of element: AXUIElement) -> RingRect? {
        guard let origin = point(element, kAXPositionAttribute as String),
              let size = size(element, kAXSizeAttribute as String) else { return nil }
        return RingRect(x: Double(origin.x), y: Double(origin.y), width: Double(size.width), height: Double(size.height))
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute), AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute), AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
