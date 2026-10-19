import AppKit
import Quartz

/// Menu-bar apps have no document window, so Quick Look needs a tiny key view
/// that adopts the preview panel. Confirm this responder chain in Xcode: a
/// click on a completion notification or a Recent item should open the panel.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()

    private var items: [NSURL] = []
    private var window: NSWindow?
    private var host: QuickLookHostView?

    func show(paths: [String]) {
        let urls = paths
            .map { NSURL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path ?? "") }
        guard !urls.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
            return
        }
        items = urls
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.isReleasedWhenClosed = false
        let host = QuickLookHostView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        host.presenter = self
        window.contentView = host
        window.setFrameOrigin(NSEvent.mouseLocation)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        self.window = window
        self.host = host
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items[index]
    }
}

final class QuickLookHostView: NSView {
    weak var presenter: QuickLookPresenter?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = presenter
        panel.delegate = presenter
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
