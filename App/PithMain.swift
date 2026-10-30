import AppKit
import SwiftUI
import PithCore

private let appDelegate = AppDelegate()

@main
struct PithMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let center = ConversionCenter()
    private let drag: DragController
    private let wheel = WheelPanelController()
    private let hud = HUDPanelController()
    private let menu = MenuBarController()

    private var session: DragSession?
    private var kind: WheelKind = .convert
    private var built: WheelContents.Built?
    private var navigation = WheelNavigation(count: 0)
    private var dropAccepted = false
    private var shownJobs: [UUID: HUDJob] = [:]
    private var editorWindows: [NSWindow] = []
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private static let dropGrace: TimeInterval = 0.4
    private var undoMonitors: [Any] = []
    private let undoTap = UndoKeyTap()
    private var undoTapRetry: Timer?
    /// Wheel opened from a Finder selection (no drag); segments are clicked, not dropped on.
    private var clickMode = false

    override init() {
        drag = DragController(bindings: .default)
        super.init()
    }

    /// Set when macOS started Pith as a login item; such launches never pop Settings open.
    private var launchedAsLoginItem = false
    private static let showSettingsNotification = Notification.Name("com.kevinzheng.pith.showSettings")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The open-application Apple Event is only readable while it's being handled.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    /// `open -a Pith` or a double-click while Pith is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningInstance() { return }
        model.refreshTools()
        pushSettings()
        Notifier.shared.requestAuthorization()
        Notifier.shared.onOpen = { paths in
            DispatchQueue.main.async {
                QuickLookPresenter.shared.show(paths: paths)
            }
        }
        center.presentEditor = { [weak self] request in
            DispatchQueue.main.async { self?.present(request) }
        }
        center.onJobsChanged = { [weak self] jobs in
            if Thread.isMainThread {
                self?.syncHUD(jobs)
            } else {
                DispatchQueue.main.async { self?.syncHUD(jobs) }
            }
        }
        hud.onCancel = { [weak self] id in
            self?.center.cancel(id)
        }
        wireDrag()
        wireWheel()
        wireMenu()
        drag.start()
        if !AccessibilityPermission.isTrusted(prompt: false) {
            showOnboarding()
        } else if !MenuBarPreference.isVisible && !launchedAsLoginItem {
            // No icon to click, so a manual launch is how the user gets back to Settings.
            showSettings()
        }
    }

    /// A second copy (e.g. `open -n`, or another build) tells the running one to show
    /// Settings and quits, so two instances never watch the same drags.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        other.activate()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        drag.stop()
        hud.removeAll()
    }

    private func pushSettings() {
        center.settings = model.settings
        center.tools = model.tools
        drag.updateBindings(model.settings.bindings)
    }

    private func wireMenu() {
        menu.recentProvider = { [weak self] in self?.center.recent ?? [] }
        menu.hasJobsProvider = { [weak self] in self?.center.jobs.isEmpty == false }
        menu.onRevealRecent = { item in
            QuickLookPresenter.shared.show(paths: item.outputPaths.isEmpty ? (item.replaced ?? []).map(\.original) : item.outputPaths)
        }
        menu.onCancelJobs = { [weak self] in self?.center.cancelAll() }
        menu.onUndo = { [weak self] in self?.undoLastConversion() }
        center.onUndoWindow = { [weak self] date in
            self?.undoTap.arm(entryDate: date)
        }
        installUndoHotKey()
        installUndoTap()
        menu.onSettings = { [weak self] in self?.showSettings() }
        menu.onQuit = { NSApp.terminate(nil) }
        menu.onPromptAccessibility = { [weak self] in
            _ = AccessibilityPermission.isTrusted(prompt: true)
            self?.onboardingWindow?.close()
        }
        menu.install()
        // The Settings toggle writes through @AppStorage; follow it live.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.menu.isVisible != MenuBarPreference.isVisible else { return }
            self.menu.setVisible(MenuBarPreference.isVisible)
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }
    }

    private func wireDrag() {
        drag.onShowWheel = { [weak self] kind, point, session in
            self?.showWheel(kind: kind, at: point, session: session)
        }
        drag.onSwitchWheel = { [weak self] kind, session in
            self?.showWheel(kind: kind, at: nil, session: session)
        }
        drag.onDismissWheel = { [weak self] in
            // On mouse-up the global monitor can fire before AppKit delivers
            // performDragOperation to the wheel. Dismissing right away orders the
            // panel out from under the drop, so give the drop a moment to land.
            if NSEvent.pressedMouseButtons & 1 == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropGrace) {
                    guard let self, !self.dropAccepted else { return }
                    self.dismissWheel()
                }
            } else {
                self?.dismissWheel()
            }
        }
        drag.onDragEnded = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropGrace + 0.05) {
                guard let self else { return }
                if !self.dropAccepted {
                    self.dismissWheel()
                }
                self.dropAccepted = false
                self.session = nil
            }
        }
        drag.onWheelKey = { [weak self] key in
            self?.handleWheelKey(key)
        }
        drag.onIdleTap = { [weak self] kind in
            DispatchQueue.main.async { self?.handleIdleTap(kind) }
        }
        drag.onGlobalMouseDown = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.clickMode else { return }
                self.endClickMode()
            }
        }
        drag.onGlobalKeyDown = { [weak self] key in
            DispatchQueue.main.async {
                guard let self, self.clickMode, self.wheel.isShowing else { return }
                if key == .escape {
                    self.endClickMode()
                } else {
                    self.handleWheelKey(key)
                }
            }
        }
    }

    /// Select a file in Finder (click and release), then tap Shift.
    /// Another Shift tap cycles Convert → Tools → Actions in place.
    /// Escape and a click outside still dismiss; Shift does not.
    private func handleIdleTap(_ kind: WheelKind) {
        if clickMode, wheel.isShowing, let session {
            showWheel(kind: self.kind.next, at: nil, session: session)
            return
        }
        guard !drag.typedSinceClick,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let paths = FinderSelection.paths()
        guard !paths.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let point = Point(x: mouse.x, y: mouse.y)
        let session = DragSession(
            changeCount: -1,
            filePaths: paths,
            hasFilePromise: false,
            promisedTypeIdentifiers: [],
            location: point
        )
        clickMode = true
        showWheel(kind: kind, at: point, session: session)
    }

    private func endClickMode() {
        clickMode = false
        session = nil
        dismissWheel()
    }

    private func wireWheel() {
        wheel.onHoverIndex = { [weak self] index in
            self?.applyHighlight(index, fromPointer: true)
        }
        wheel.onDropIndex = { [weak self] index in
            self?.acceptDrop(index: index)
        }
        wheel.onClickIndex = { [weak self] index in
            guard let self, self.clickMode else { return }
            self.acceptDrop(index: index)
            self.clickMode = false
            self.session = nil
        }
    }

    private func undoLastConversion() {
        let entryDate = RecentLog.nextUndoable(center.recent)?.date
        if let message = center.undoLast() {
            // Whatever route undid it, ⌘Z in Finder must not undo the next-older entry as well.
            undoTap.noteUndone(entryDate: entryDate)
            center.flash(title: "Undone", subtitle: message)
        } else {
            NSSound.beep()
        }
    }

    /// Plain ⌘Z in Finder within `UndoShortcut.window` of a Pith entry. Needs Accessibility,
    /// which may arrive after launch, so keep trying until macOS grants the tap.
    private func installUndoTap() {
        undoTap.newestEntryDate = { [weak self] in
            self.flatMap { RecentLog.nextUndoable($0.center.recent)?.date }
        }
        undoTap.onUndo = { [weak self] in self?.undoLastConversion() }
        guard !undoTap.install() else { return }
        undoTapRetry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.undoTap.install() { timer.invalidate(); self.undoTapRetry = nil }
        }
    }

    private func installUndoHotKey() {
        // ⌃⌥⌘Z, system-wide. Global monitors observe only, so nothing else loses the key.
        let matches: (NSEvent) -> Bool = { event in
            event.keyCode == 6 &&
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.control, .option, .command]) &&
            !event.modifierFlags.contains(.shift)
        }
        undoMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if matches(event) { DispatchQueue.main.async { self?.undoLastConversion() } }
        } as Any)
        undoMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if matches(event) { self?.undoLastConversion(); return nil }
            return event
        } as Any)
    }

    private func showWheel(kind: WheelKind, at point: Point?, session: DragSession) {
        model.refreshTools()
        pushSettings()
        self.kind = kind
        self.session = session
        let built = WheelContents.build(kind: kind, session: session, availability: model.tools)
        self.built = built
        navigation = WheelNavigation(count: built.segments.count)
        let apply = { [wheel] in
            wheel.model.segments = built.segments
            wheel.model.highlighted = nil
            wheel.model.centerText = built.segments.isEmpty ? "NOTHING" : built.centerFallback
        }
        if wheel.isShowing {
            // Cycling wheels in place: the old ring spins out and the next one settles in.
            withAnimation(PithTheme.wheelSwitchAnimation) {
                apply()
                wheel.model.generation += 1
            }
        } else {
            apply()
        }
        if let point {
            wheel.present(at: CGPoint(x: point.x, y: point.y))
        } else if !wheel.isShowing {
            let mouse = NSEvent.mouseLocation
            wheel.present(at: mouse)
        }
    }

    private func dismissWheel() {
        wheel.dismiss()
        built = nil
        navigation = WheelNavigation(count: 0)
    }

    private func applyHighlight(_ index: Int?, fromPointer: Bool) {
        if fromPointer {
            navigation.index = index
        }
        wheel.model.highlighted = index
        guard let built else { return }
        guard let index, built.segments.indices.contains(index) else {
            wheel.model.centerText = built.centerFallback
            return
        }
        let segment = built.segments[index]
        if segment.enabled {
            wheel.model.centerText = segment.title
        } else {
            wheel.model.centerText = segment.help ?? built.centerFallback
        }
    }

    private func handleWheelKey(_ key: MonitorKey) {
        let action = navigation.handle(key)
        switch action {
        case .none:
            break
        case let .highlight(index):
            applyHighlight(index, fromPointer: false)
        case let .confirm(index):
            guard let built, built.segments.indices.contains(index), built.segments[index].enabled else { return }
            acceptDrop(index: index)
        }
    }

    private func acceptDrop(index: Int) {
        NSLog("Pith: acceptDrop index=%d kind=%@ paths=%@", index, String(describing: kind), String(describing: session?.filePaths ?? []))
        dropAccepted = true
        let paths = session?.filePaths ?? []
        let receivers = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
        let anchor = NSEvent.mouseLocation
        // A click on the wheel (Finder selection, no drag) says nothing about where the file
        // should go, so those outputs sit next to the source's icon instead.
        let drop: CGPoint? = clickMode ? nil : anchor
        let kind = self.kind
        let built = self.built
        drag.noteDropAccepted()
        dismissWheel()
        if !paths.isEmpty {
            perform(kind: kind, built: built, index: index, urls: paths.map { URL(fileURLWithPath: $0) }, anchor: anchor, drop: drop)
            return
        }
        DragPasteboardReader.beginReceive(receivers) { [weak self] urls in
            self?.perform(kind: kind, built: built, index: index, urls: urls, anchor: anchor, drop: drop)
        }
    }

    private func perform(kind: WheelKind, built: WheelContents.Built?, index: Int, urls: [URL], anchor: CGPoint, drop: CGPoint?) {
        guard let built else { return }
        guard !urls.isEmpty else {
            Notifier.shared.post(title: "Nothing to convert", body: "The drag did not include a file Pith could read.", paths: [])
            return
        }
        pushSettings()
        NSLog("Pith: perform kind=%@ index=%d urls=%@", String(describing: kind), index, urls.map(\.path).joined(separator: ", "))
        switch kind {
        case .convert:
            guard built.offers.indices.contains(index) else { return }
            center.convert(urls: urls, offer: built.offers[index], anchor: anchor, drop: drop)
        case .tools:
            guard built.tools.indices.contains(index) else { return }
            center.runTool(built.tools[index].tool, urls: urls, drop: drop)
        case .actions:
            guard built.actions.indices.contains(index) else { return }
            FileActions.perform(built.actions[index], urls: urls)
        }
    }

    private func syncHUD(_ jobs: [HUDJob]) {
        let incomingIDs = Set(jobs.map(\.id))
        let removedAny = shownJobs.keys.contains(where: { !incomingIDs.contains($0) })
        for id in shownJobs.keys where !incomingIDs.contains(id) {
            hud.remove(id)
        }
        for job in jobs {
            if shownJobs[job.id] != job {
                hud.upsert(job)
            } else if removedAny {
                hud.place(job)
            }
        }
        shownJobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    }

    private func showSettings() {
        NSApp.activate()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        // The window takes the SwiftUI form's own size, so there's no dead margin around it.
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Pith Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    private func showOnboarding() {
        let box = WindowBox()
        let close: () -> Void = { [weak self] in
            box.window?.close()
            box.window = nil
            self?.onboardingWindow = nil
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pith"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.62, alpha: 1)
        window.contentView = NSHostingView(rootView: OnboardingView(
            onGrant: {
                _ = AccessibilityPermission.isTrusted(prompt: true)
                close()
            },
            onLater: close
        ))
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        box.window = window
        onboardingWindow = window
    }

    private func present(_ request: EditorRequest) {
        switch request {
        case let .crop(url):
            openImageEditor(url: url, size: NSSize(width: 760, height: 860)) { source, close in
                CropEditor(image: source.preview, pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, onClose: close, onApply: { rect in
                    self.save(source: url) { engine in
                        let (full, mapped) = try source.cropSource(for: rect)
                        return try engine.crop(full, source: url, to: mapped)
                    }
                    close()
                }, onReplace: { rect in
                    self.replace(source: url) { engine in
                        let (full, mapped) = try source.cropSource(for: rect)
                        return try engine.cropReplacing(full, source: url, to: mapped)
                    }
                    close()
                }, replaceBlocker: ReplaceStore.blocker(for: url))
            }
        case let .addBackground(url):
            openImageEditor(url: url, size: NSSize(width: 760, height: 860)) { source, close in
                AddBackgroundEditor(image: source.preview, pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, onClose: close) { edit in
                    self.save(source: url) { engine in
                        try engine.addBackground(try source.backed(edit), source: url)
                    }
                    close()
                }
            }
        case let .annotate(url):
            openImageEditor(url: url, size: NSSize(width: 760, height: 820)) { source, close in
                AnnotateEditor(image: source.preview, pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, onClose: close, onApply: { marks in
                    self.save(source: url) { engine in
                        try engine.saveKeepingFormat(try source.annotated(marks), source: url, suffix: " Annotated")
                    }
                    close()
                }, onReplace: { marks in
                    self.replace(source: url) { engine in
                        try engine.replaceOriginal(try source.annotated(marks), source: url)
                    }
                    close()
                }, replaceBlocker: ReplaceStore.blocker(for: url))
            }
        case let .redact(url):
            openImageEditor(url: url, size: NSSize(width: 760, height: 820)) { source, close in
                RedactEditor(image: source.preview, pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, onClose: close, onApply: { boxes in
                    self.save(source: url) { engine in
                        try engine.saveKeepingFormat(try source.redacted(boxes), source: url, suffix: " Redacted")
                    }
                    close()
                }, onReplace: { boxes in
                    self.replace(source: url) { engine in
                        try engine.replaceOriginal(try source.redacted(boxes), source: url)
                    }
                    close()
                }, replaceBlocker: ReplaceStore.blocker(for: url))
            }
        case let .adjust(url):
            openImageEditor(url: url, size: NSSize(width: 720, height: 780)) { source, close in
                AdjustEditor(image: source.preview, onClose: close, onApply: { edit in
                    self.save(source: url) { engine in
                        try engine.saveKeepingFormat(try source.adjusted(edit), source: url, suffix: " Edited")
                    }
                    close()
                }, onReplace: { edit in
                    self.replace(source: url) { engine in
                        try engine.replaceOriginal(try source.adjusted(edit), source: url)
                    }
                    close()
                }, replaceBlocker: ReplaceStore.blocker(for: url))
            }
        case let .metadata(url):
            Task { @MainActor in
                let rows = await Task.detached { ImageIOBridge.properties(of: url) }.value
                self.presentWindow(size: NSSize(width: 560, height: 640)) { close in
                    MetadataEditor(source: url, rows: rows, onClose: close, onStrip: {
                        self.save(source: url) { try $0.stripMetadata(url) }
                        close()
                    }, onStripReplacing: {
                        self.replace(source: url) { try $0.stripMetadataReplacing(url) }
                        close()
                    }, replaceBlocker: ReplaceStore.blocker(for: url))
                }
            }
        case let .compress(urls):
            guard let url = urls.first else { return }
            let size = NSSize(width: 640, height: 720)
            Task { @MainActor in
                let payload = await Task.detached { () -> (Bool, Int64, EditorImage?) in
                    let matched = FileTypes.matching(path: url.path)
                    let isVideo = matched?.kind == .video
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let image = isVideo ? nil : EditorImage.load(url: url, windowLongEdge: max(size.width, size.height))
                    return (isVideo, bytes, image)
                }.value
                self.presentWindow(size: size) { close in
                    CompressEditor(
                        image: payload.2?.preview,
                        originalBytes: payload.1,
                        isVideo: payload.0,
                        onClose: close,
                        onApplyImage: { quality, maxEdge in
                            self.save(source: url) { engine in
                                guard let loaded = payload.2 else {
                                    throw ConversionFailure.unreadable("Couldn't read \(url.lastPathComponent).")
                                }
                                return try engine.compressImage(try loaded.fullImage(), source: url, quality: quality, maxEdge: maxEdge)
                            }
                            close()
                        },
                        onApplyVideo: { bitrate in
                            self.pushSettings()
                            self.center.exportVideo(source: url, trim: nil, bitrate: bitrate, anchor: NSEvent.mouseLocation)
                            close()
                        }
                    )
                }
            }
        case let .trim(urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                let duration = await self.probeDuration(url)
                self.presentWindow(size: NSSize(width: 520, height: 360)) { close in
                    TrimEditor(filename: url.lastPathComponent, duration: duration, onClose: close) { range in
                        self.pushSettings()
                        self.center.exportVideo(source: url, trim: range, bitrate: nil, anchor: NSEvent.mouseLocation)
                        close()
                    }
                }
            }
        }
    }

    /// Decodes a display preview off the main thread, then opens the editor.
    private func openImageEditor<Content: View>(
        url: URL,
        size: NSSize,
        @ViewBuilder content: @escaping (EditorImage, @escaping () -> Void) -> Content
    ) {
        let longEdge = max(size.width, size.height)
        Task { @MainActor in
            let loaded = await Task.detached {
                EditorImage.load(url: url, windowLongEdge: longEdge)
            }.value
            self.presentWindow(size: size) { close in
                if let loaded {
                    content(loaded, close)
                } else {
                    MissingImageNote(name: url.lastPathComponent, onClose: close)
                }
            }
        }
    }

    private func presentWindow<Content: View>(size: NSSize, @ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        let box = WindowBox()
        let close: () -> Void = { [weak self] in
            let window = box.window
            box.window = nil
            window?.close()
            self?.editorWindows.removeAll { $0 === window }
        }
        let window = EditorWindow.present(size: size) {
            content(close)
        }
        window.isReleasedWhenClosed = false
        box.window = window
        editorWindows.append(window)
    }

    /// Runs an editor save off the main thread, then records it for Recent and Undo.
    private func save(source: URL, _ work: @escaping (ConversionEngine) throws -> URL) {
        pushSettings()
        let engine = center.engine
        Task.detached {
            do {
                let saved = try work(engine)
                await MainActor.run {
                    self.center.recordSaved(saved, source: source)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    Notifier.shared.post(title: "Couldn't save", body: message, paths: [])
                }
            }
        }
    }

    /// Save and Replace: overwrite the source in place (backed up for undo).
    private func replace(source: URL, _ work: @escaping (ConversionEngine) throws -> ReplacedFile) {
        pushSettings()
        let engine = center.engine
        let name = source.lastPathComponent
        Task.detached {
            do {
                let entry = try work(engine)
                await MainActor.run {
                    self.center.recordReplaced(entry, source: source)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    Notifier.shared.post(title: "Couldn't replace \(name)", body: message, paths: [])
                }
            }
        }
    }

    private func probeDuration(_ url: URL) async -> Double {
        guard let ffprobe = model.tools.ffprobe else { return 0 }
        let spec = FFmpegScripts.probe(ffprobe: ffprobe, input: url.path)
        var text = ""
        let status = try? await ProcessRunner().run(spec) { line in
            text += line
        }
        guard status == 0 else { return 0 }
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private final class WindowBox {
    var window: NSWindow?
}

private struct MissingImageNote: View {
    var name: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Couldn't open \(name)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PithTheme.ink)
            Button("Close", action: onClose)
                .buttonStyle(PithPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PithTheme.windowWash.opacity(0.35))
    }
}

struct OnboardingView: View {
    var onGrant: () -> Void
    var onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pith watches the drag")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PithTheme.ink)
            Text("Drag a file from Finder, then tap Shift. A wheel appears under the pointer. Tap Shift again to cycle through Tools and Actions, then back to Convert. Drop on a segment and the converted file lands next to the source. Escape dismisses the wheel.")
                .font(.system(size: 13))
                .foregroundStyle(PithTheme.ink.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS has to list Pith under Privacy & Security → Accessibility. Finder owns the drag; Pith only sees the tap and the drag pasteboard once that permission is on.")
                .font(.system(size: 13))
                .foregroundStyle(PithTheme.ink.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later", action: onLater)
                    .buttonStyle(PithQuietButtonStyle())
                Spacer()
                Button("Grant Access", action: onGrant)
                    .buttonStyle(PithPrimaryButtonStyle())
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 460)
    }
}
