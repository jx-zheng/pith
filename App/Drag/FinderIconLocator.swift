import AppKit
import ApplicationServices
import PithCore

/// Where a Shift tap or a drag grab should centre the ring.
///
/// The lookup is by identity, fresh every call, with no cache. Selected items
/// in the Finder window under the pointer are kept only when their URL or
/// filename positively names a selected path. The position hit-test is a
/// fallback, and an element that publishes neither name is not accepted.
struct LocatedIcon {
    var center: CGPoint?
    var source: RingAnchorSource
    var filename: String
    var icon: RingRect?
    var cell: RingRect?
    var reason: String
}

enum FinderIconLocator {
    /// The whole lookup, including every child query, stops after this.
    private static let budget: TimeInterval = 0.25

    static func locate(near mouse: CGPoint, paths: [String]) -> LocatedIcon {
        func miss(_ reason: String) -> LocatedIcon {
            LocatedIcon(center: nil, source: .pointer, filename: "", icon: nil, cell: nil, reason: reason)
        }
        guard AccessibilityPermission.isTrusted(prompt: false) else { return miss("accessibility-off") }
        guard let primary = NSScreen.screens.first else { return miss("no-screen") }
        let maxY = Double(primary.frame.maxY)
        let axY = IconRingGeometry.topLeftY(fromAppKitY: Double(mouse.y), mainScreenMaxY: maxY)
        let pointer = Point(x: Double(mouse.x), y: axY)
        let system = AXUIElementCreateSystemWide()
        let deadline = Date().addingTimeInterval(budget)
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(system, Float(mouse.x), Float(axY), &hit)
        guard status == .success, let hit else { return miss("no-hit") }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .contains(where: { $0.processIdentifier == pid }) else { return miss("not-finder") }
        let finder = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(finder, Float(budget))

        let root = window(above: hit, deadline: deadline) ?? hit
        if let located = selectedIcon(in: root, pointer: pointer, paths: paths, maxY: maxY, deadline: deadline) {
            return located
        }
        if let located = hitIcon(from: hit, pointer: pointer, paths: paths, maxY: maxY, deadline: deadline) {
            return located
        }
        return miss("no-positive-match")
    }

    static func log(_ located: LocatedIcon, mode: String, mouse: CGPoint, paths: [String], center: CGPoint) {
        let entry = RingLog(
            mode: mode,
            source: located.center == nil ? .pointer : located.source,
            filename: located.filename,
            icon: located.icon,
            cell: located.cell,
            pointer: Point(x: Double(mouse.x), y: Double(mouse.y)),
            center: Point(x: Double(center.x), y: Double(center.y)),
            selectedCount: paths.count,
            reason: located.reason
        )
        RingLogger.write(entry.line)
    }

    /// Selected rows and icons in icon view, list view, column view, and the Desktop.
    private static func selectedIcon(
        in root: AXUIElement,
        pointer: Point,
        paths: [String],
        maxY: Double,
        deadline: Date
    ) -> LocatedIcon? {
        var elements: [AXUIElement] = []
        collectSelected(in: root, into: &elements, depth: 0, deadline: deadline)
        let pairs: [(AXUIElement, FinderNamedItem)] = elements.compactMap { element in
            guard Date() < deadline, let item = namedItem(element) else { return nil }
            return (element, item)
        }
        let ranked = FinderIdentity.ranked(pairs.map(\.1), paths: paths, pointer: pointer)
        for item in ranked {
            guard Date() < deadline else { break }
            guard let element = pairs.first(where: { $0.1 == item })?.0 else { continue }
            guard let bounds = iconBounds(of: element, deadline: deadline) else { continue }
            return make(bounds, filename: displayName(item), source: .selectedElement, reason: "selected-element", maxY: maxY)
        }
        return nil
    }

    /// The element under the pointer, or an ancestor, and only with a positive name.
    private static func hitIcon(
        from hit: AXUIElement,
        pointer: Point,
        paths: [String],
        maxY: Double,
        deadline: Date
    ) -> LocatedIcon? {
        var current: AXUIElement? = hit
        for _ in 0..<10 {
            guard Date() < deadline, let node = current else { break }
            let kind = role(of: node) ?? ""
            if kind == windowRole || kind == applicationRole { break }
            if let item = namedItem(node),
               FinderIdentity.positivelyMatches(url: item.url, filename: item.filename, paths: paths),
               let bounds = iconBounds(of: node, deadline: deadline) {
                return make(bounds, filename: displayName(item), source: .hitTest, reason: "hit-test", maxY: maxY)
            }
            current = parent(of: node)
        }
        return nil
    }

    private static func make(
        _ bounds: (icon: RingRect, cell: RingRect),
        filename: String,
        source: RingAnchorSource,
        reason: String,
        maxY: Double
    ) -> LocatedIcon {
        let center = IconRingGeometry.center(of: bounds.icon)
        let appKitY = IconRingGeometry.appKitY(fromTopLeftY: center.y, mainScreenMaxY: maxY)
        return LocatedIcon(
            center: CGPoint(x: center.x, y: appKitY),
            source: source,
            filename: filename,
            icon: appKitRect(bounds.icon, maxY: maxY),
            cell: appKitRect(bounds.cell, maxY: maxY),
            reason: reason
        )
    }

    private static func displayName(_ item: FinderNamedItem) -> String {
        if let filename = item.filename, !filename.isEmpty { return filename }
        if let url = item.url { return URL(fileURLWithPath: FinderIdentity.normalizedPath(url)).lastPathComponent }
        return ""
    }

    private static func namedItem(_ element: AXUIElement) -> FinderNamedItem? {
        guard let frame = frame(of: element) else { return nil }
        let url = string(element, kAXURLAttribute as String)
        let filename = string(element, "AXFilename") ?? string(element, kAXTitleAttribute as String)
        let hasURL = url.map { !FinderIdentity.normalizedPath($0).isEmpty } ?? false
        let hasName = filename.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        guard hasURL || hasName else { return nil }
        return FinderNamedItem(url: url, filename: filename, frame: frame)
    }

    private static func collectSelected(in node: AXUIElement, into found: inout [AXUIElement], depth: Int, deadline: Date) {
        guard depth < 8, Date() < deadline else { return }
        let kind = role(of: node) ?? ""
        if kind == browserRole {
            found.append(contentsOf: lastColumnSelection(node, deadline: deadline))
            return
        }
        if kind == outlineRole {
            found.append(contentsOf: elements(node, kAXSelectedRowsAttribute as String))
            return
        }
        if kind == listRole {
            found.append(contentsOf: elements(node, kAXSelectedChildrenAttribute as String))
            return
        }
        if kind == groupRole || kind == scrollRole {
            let selected = elements(node, kAXSelectedChildrenAttribute as String)
            if !selected.isEmpty {
                found.append(contentsOf: selected)
                return
            }
        }
        guard Date() < deadline else { return }
        for child in children(of: node) {
            guard Date() < deadline else { return }
            collectSelected(in: child, into: &found, depth: depth + 1, deadline: deadline)
        }
    }

    /// Column view: the selection that matters is in the last list.
    private static func lastColumnSelection(_ browser: AXUIElement, deadline: Date) -> [AXUIElement] {
        var lists: [AXUIElement] = []
        for child in children(of: browser) {
            guard Date() < deadline else { break }
            let kind = role(of: child) ?? ""
            if kind == listRole || kind == outlineRole {
                lists.append(child)
                continue
            }
            for grand in children(of: child) {
                guard Date() < deadline else { break }
                if role(of: grand) == listRole || role(of: grand) == outlineRole {
                    lists.append(grand)
                }
            }
        }
        guard let last = lists.last else { return elements(browser, kAXSelectedChildrenAttribute as String) }
        let selected = elements(last, kAXSelectedChildrenAttribute as String)
        if !selected.isEmpty { return selected }
        return elements(last, kAXSelectedRowsAttribute as String)
    }

    private static func window(above element: AXUIElement, deadline: Date) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard Date() < deadline, let node = current else { break }
            if role(of: node) == windowRole { return node }
            current = parent(of: node)
        }
        return nil
    }

    private static func iconBounds(of element: AXUIElement, deadline: Date) -> (icon: RingRect, cell: RingRect)? {
        guard Date() < deadline, let cell = frame(of: element) else { return nil }
        var images: [RingRect] = []
        if role(of: element) == imageRole { images.append(cell) }
        if Date() < deadline {
            for child in children(of: element) {
                guard Date() < deadline else { break }
                collectImages(child, into: &images, depth: 0, deadline: deadline)
            }
        }
        if let icon = IconRingGeometry.iconImage(inside: cell, images: images) {
            return (icon, cell)
        }
        if role(of: element) == imageRole, cell.width > 1, cell.height > 1 {
            return (cell, cell)
        }
        return nil
    }

    private static func collectImages(_ element: AXUIElement, into images: inout [RingRect], depth: Int, deadline: Date) {
        guard depth < 4, Date() < deadline else { return }
        if role(of: element) == imageRole, let rect = frame(of: element) {
            images.append(rect)
        }
        guard Date() < deadline else { return }
        for child in children(of: element) {
            guard Date() < deadline else { return }
            collectImages(child, into: &images, depth: depth + 1, deadline: deadline)
        }
    }

    private static let imageRole = kAXImageRole as String
    private static let listRole = kAXListRole as String
    private static let outlineRole = kAXOutlineRole as String
    private static let groupRole = kAXGroupRole as String
    private static let scrollRole = kAXScrollAreaRole as String
    private static let windowRole = kAXWindowRole as String
    private static let applicationRole = kAXApplicationRole as String
    private static let browserRole = "AXBrowser"

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = copy(element, attribute), let array = value as? NSArray else { return [] }
        return (0..<array.count).compactMap { axElement(array[$0]) }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute as String)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = copy(element, kAXParentAttribute as String) else { return nil }
        return axElement(value)
    }

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
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func appKitRect(_ rect: RingRect, maxY: Double) -> RingRect {
        let bottom = IconRingGeometry.appKitY(fromTopLeftY: rect.y + rect.height, mainScreenMaxY: maxY)
        return RingRect(x: rect.x, y: bottom, width: rect.width, height: rect.height)
    }
}
