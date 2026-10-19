import AppKit
import PithCore

enum FileActions {
    static func perform(_ action: FileActionID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop:
            airDrop(urls)
        case .copy:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        case .move:
            move(urls)
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .openInTerminal:
            openInTerminal(urls)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private static func airDrop(_ urls: [URL]) {
        NSApp.activate()
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        if service.canPerform(withItems: urls) {
            service.perform(withItems: urls)
        } else {
            service.perform(withItems: urls)
        }
    }

    private static func move(_ urls: [URL]) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose where Pith should move the dropped items."
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            for url in urls {
                let target = destination.appendingPathComponent(url.lastPathComponent)
                let finalTarget = unique(target)
                try? FileManager.default.moveItem(at: url, to: finalTarget)
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private static func openInTerminal(_ urls: [URL]) {
        let folder = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent()
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: configuration)
    }

    private static func unique(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let directory = url.deletingLastPathComponent()
        var n = 2
        while n < 1000 {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
        return url
    }
}
