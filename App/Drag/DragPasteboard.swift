import AppKit

struct DragPasteboardSnapshot {
    var changeCount: Int
    var filePaths: [String]
    var hasFilePromise: Bool
    var promisedTypeIdentifiers: [String]
}

enum DragPasteboardReader {
    static func snapshot(readPromiseTypes: Bool) -> DragPasteboardSnapshot {
        let pasteboard = NSPasteboard(name: .drag)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let canPromise = pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        var promised: [String] = []
        if readPromiseTypes && canPromise {
            let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
            promised = receivers.flatMap(\.fileTypes)
        }
        return DragPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            filePaths: urls.map(\.path),
            hasFilePromise: canPromise,
            promisedTypeIdentifiers: promised
        )
    }

    /// Fulfills file promises into a fresh temporary directory. The drag pasteboard
    /// must still be the active drag when this is called.
    static func receivePromises(from pasteboard: NSPasteboard = NSPasteboard(name: .drag)) async -> [URL] {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        return await receive(receivers)
    }

    static func receive(_ receivers: [NSFilePromiseReceiver]) async -> [URL] {
        await withCheckedContinuation { continuation in
            beginReceive(receivers) { urls in
                continuation.resume(returning: urls)
            }
        }
    }

    /// Starts `receivePromisedFiles` before returning. Call this on the drag-operation
    /// stack; a later `Task` runs after the drag pasteboard has already gone stale.
    static func beginReceive(_ receivers: [NSFilePromiseReceiver], completion: @escaping ([URL]) -> Void) {
        guard !receivers.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pith-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let group = DispatchGroup()
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let lock = NSLock()
        var urls: [URL] = []
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { url, error in
                if error == nil {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(urls)
        }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        if let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return names.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
