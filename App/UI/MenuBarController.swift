import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPromptAccessibility: (() -> Void)?
    var onCancelJobs: (() -> Void)?
    var recentProvider: (() -> [RecentConversion])?
    var hasJobsProvider: (() -> Bool)?
    var onRevealRecent: ((RecentConversion) -> Void)?
    var onUndo: (() -> Void)?

    func install() {
        statusItem.button?.image = MenuBarIcon.image()
        statusItem.button?.imagePosition = .imageOnly
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = AccessibilityPermission.isTrusted(prompt: false)
        let access = NSMenuItem(
            title: trusted ? "Accessibility: granted" : "Accessibility: not granted",
            action: trusted ? nil : #selector(promptAccess),
            keyEquivalent: ""
        )
        access.target = self
        menu.addItem(access)
        if !trusted {
            let open = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccess), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }
        menu.addItem(.separator())
        let recentMenu = NSMenu()
        let recent = recentProvider?() ?? []
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No conversions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for item in recent {
                let entry = NSMenuItem(title: item.title, action: #selector(revealRecent(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.id.uuidString
                entry.toolTip = item.subtitle
                recentMenu.addItem(entry)
            }
        }
        let undo = NSMenuItem(title: "Undo Last Conversion", action: #selector(undoLast), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.control, .option, .command]
        undo.target = self
        undo.isEnabled = recent.contains { $0.succeeded && !$0.outputPaths.isEmpty }
        menu.autoenablesItems = false
        menu.addItem(undo)
        let recentItem = NSMenuItem(title: "Recent conversions", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        if hasJobsProvider?() == true {
            let cancel = NSMenuItem(title: "Cancel conversions", action: #selector(cancelJobs), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Pith", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func promptAccess() { onPromptAccessibility?() }
    @objc private func undoLast() { onUndo?() }
    @objc private func openAccess() { AccessibilityPermission.openSystemSettings() }
    @objc private func openSettings() { onSettings?() }
    @objc private func quit() { onQuit?() }
    @objc private func cancelJobs() { onCancelJobs?() }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = recentProvider?().first(where: { $0.id.uuidString == id }) else { return }
        onRevealRecent?(item)
    }
}

enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 1.2, dy: 1.2))
            outer.lineWidth = 1.6
            outer.stroke()
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 5.3, dy: 5.3))
            inner.lineWidth = 1.4
            inner.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
