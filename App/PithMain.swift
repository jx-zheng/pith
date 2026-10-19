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
    private var shownJobs: Set<UUID> = []
    private var editorWindows: [NSWindow] = []
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private static let dropGrace: TimeInterval = 0.4
    private static let doubleTapWindow: TimeInterval = 0.45
    private var wheelShownAt = Date.distantPast
    private var undoMonitors: [Any] = []
    /// Wheel opened from a Finder selection (no drag); segments are clicked, not dropped on.
    private var clickMode = false

    override init() {
        drag = DragController(bindings: .default)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        }
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
            QuickLookPresenter.shared.show(paths: item.outputPaths)
        }
        menu.onCancelJobs = { [weak self] in self?.center.cancelAll() }
        menu.onUndo = { [weak self] in self?.undoLastConversion() }
        installUndoHotKey()
        menu.onSettings = { [weak self] in self?.showSettings() }
        menu.onQuit = { NSApp.terminate(nil) }
        menu.onPromptAccessibility = { [weak self] in
            _ = AccessibilityPermission.isTrusted(prompt: true)
            self?.onboardingWindow?.close()
        }
        menu.install()
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
        drag.onRepeatTap = { [weak self] kind in
            DispatchQueue.main.async { _ = self?.runFavouriteIfDoubleTap(kind) }
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

    /// Select a file in Finder (click and release), then tap a trigger key.
    /// Tapping another trigger key while the wheel is open switches wheels in place.
    private func handleIdleTap(_ kind: WheelKind) {
        if clickMode, wheel.isShowing, let session {
            if kind == self.kind {
                if runFavouriteIfDoubleTap(kind) { return }
                endClickMode()
            } else {
                showWheel(kind: kind, at: nil, session: session)
            }
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

    /// Second tap of the same key shortly after the wheel opened runs that wheel's favourite.
    private func runFavouriteIfDoubleTap(_ kind: WheelKind) -> Bool {
        guard wheel.isShowing, kind == self.kind,
              Date().timeIntervalSince(wheelShownAt) < Self.doubleTapWindow,
              let built, let index = Favourites.index(for: kind, in: built.segments) else { return false }
        acceptDrop(index: index)
        if clickMode {
            clickMode = false
            session = nil
        }
        return true
    }

    private func undoLastConversion() {
        if let message = center.undoLast() {
            center.flash(title: "Undid last conversion", subtitle: message)
        } else {
            NSSound.beep()
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
        if !wheel.isShowing || kind != self.kind { wheelShownAt = Date() }
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
            // Switching wheels in place: cross-fade the old ring out and spin the new one in.
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
        let kind = self.kind
        let built = self.built
        drag.noteDropAccepted()
        dismissWheel()
        if !paths.isEmpty {
            perform(kind: kind, built: built, index: index, urls: paths.map { URL(fileURLWithPath: $0) }, anchor: anchor)
            return
        }
        DragPasteboardReader.beginReceive(receivers) { [weak self] urls in
            self?.perform(kind: kind, built: built, index: index, urls: urls, anchor: anchor)
        }
    }

    private func perform(kind: WheelKind, built: WheelContents.Built?, index: Int, urls: [URL], anchor: CGPoint) {
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
            center.convert(urls: urls, offer: built.offers[index], anchor: anchor)
        case .tools:
            guard built.tools.indices.contains(index) else { return }
            center.runTool(built.tools[index].tool, urls: urls)
        case .actions:
            guard built.actions.indices.contains(index) else { return }
            FileActions.perform(built.actions[index], urls: urls)
        }
    }

    private func syncHUD(_ jobs: [HUDJob]) {
        let ids = Set(jobs.map(\.id))
        for job in jobs {
            hud.upsert(job)
        }
        for id in shownJobs.subtracting(ids) {
            hud.remove(id)
        }
        shownJobs = ids
    }

    private func showSettings() {
        NSApp.activate()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pith Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
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
            presentWindow(size: NSSize(width: 760, height: 860)) { close in
                self.imageEditor(url, close: close) { image, close in
                    CropEditor(image: image, onClose: close) { cropped in
                        self.saveImage(cropped, source: url, suffix: " Cropped", ext: "jpg", uti: FileTypes.jpeg.uti, quality: self.model.settings.clampedJPEGQuality)
                        close()
                    }
                }
            }
        case let .addBackground(url):
            presentWindow(size: NSSize(width: 760, height: 860)) { close in
                self.imageEditor(url, close: close) { image, close in
                    AddBackgroundEditor(image: image, onClose: close) { composed in
                        self.saveImage(composed, source: url, suffix: " Background", ext: "png", uti: FileTypes.png.uti, quality: nil)
                        close()
                    }
                }
            }
        case let .annotate(url):
            presentWindow(size: NSSize(width: 760, height: 820)) { close in
                self.imageEditor(url, close: close) { image, close in
                    AnnotateEditor(image: image, onClose: close) { marked in
                        self.saveKeepingFormat(marked, source: url, suffix: " Annotated")
                        close()
                    }
                }
            }
        case let .redact(url):
            presentWindow(size: NSSize(width: 760, height: 820)) { close in
                self.imageEditor(url, close: close) { image, close in
                    RedactEditor(image: image, onClose: close) { marked in
                        self.saveKeepingFormat(marked, source: url, suffix: " Redacted")
                        close()
                    }
                }
            }
        case let .adjust(url):
            presentWindow(size: NSSize(width: 720, height: 780)) { close in
                self.imageEditor(url, close: close) { image, close in
                    AdjustEditor(image: image, onClose: close) { edited in
                        self.saveKeepingFormat(edited, source: url, suffix: " Edited")
                        close()
                    }
                }
            }
        case let .metadata(url):
            let rows = ImageIOBridge.properties(of: url)
            presentWindow(size: NSSize(width: 560, height: 640)) { close in
                MetadataEditor(source: url, rows: rows, onClose: close) {
                    if let image = try? ImageIOBridge.loadOriented(url) {
                        self.saveKeepingFormat(image, source: url, suffix: " Clean")
                    }
                    close()
                }
            }
        case let .compress(urls):
            guard let url = urls.first else { return }
            let matched = FileTypes.matching(path: url.path)
            let isVideo = matched?.kind == .video
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            let image = isVideo ? nil : (try? ImageIOBridge.loadOriented(url))
            presentWindow(size: NSSize(width: 640, height: 720)) { close in
                CompressEditor(
                    image: image,
                    originalBytes: bytes,
                    isVideo: isVideo,
                    onClose: close,
                    onApplyImage: { rendered, quality, maxEdge in
                        let scaled = ImageIOBridge.scaled(rendered, maxEdge: maxEdge)
                        self.saveImage(scaled, source: url, suffix: " Compressed", ext: "jpg", uti: FileTypes.jpeg.uti, quality: quality)
                        close()
                    },
                    onApplyVideo: { bitrate in
                        self.pushSettings()
                        self.center.exportVideo(source: url, trim: nil, bitrate: bitrate, anchor: NSEvent.mouseLocation)
                        close()
                    }
                )
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

    @ViewBuilder
    private func imageEditor<Content: View>(_ url: URL, close: @escaping () -> Void, @ViewBuilder content: (CGImage, @escaping () -> Void) -> Content) -> some View {
        if let image = try? ImageIOBridge.loadOriented(url) {
            content(image, close)
        } else {
            MissingImageNote(name: url.lastPathComponent, onClose: close)
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

    private func saveImage(_ image: CGImage, source: URL, suffix: String, ext: String, uti: String, quality: Double?) {
        pushSettings()
        do {
            _ = try center.saveEditedImage(image, source: source, suffix: suffix, fileExtension: ext, uti: uti, quality: quality)
        } catch {
            Notifier.shared.post(title: "Couldn't save", body: error.localizedDescription, paths: [])
        }
    }

    private func saveKeepingFormat(_ image: CGImage, source: URL, suffix: String) {
        let matched = FileTypes.matching(path: source.path)
        let ext = matched?.primaryExtension ?? "png"
        let uti = matched?.uti ?? FileTypes.png.uti
        let quality: Double?
        switch matched?.family {
        case "jpeg": quality = model.settings.clampedJPEGQuality
        case "heic": quality = model.settings.clampedHEICQuality
        default: quality = nil
        }
        saveImage(image, source: source, suffix: suffix, ext: ext, uti: uti, quality: quality)
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
            Text("Drag a file from Finder, then tap Shift. A wheel appears under the pointer. Drop on a segment and the converted file lands next to the source. Command opens tools. Control opens actions.")
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
