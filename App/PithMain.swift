import AppKit
import os
import QuartzCore
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
    private var shownJobs: [UUID: HUDJob] = [:]
    private var editorWindows: [NSWindow] = []
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private static let dropGrace: TimeInterval = 0.4
    private var undoMonitors: [Any] = []
    private var ringDismiss = RingDismissMachine()
    private var lookupGeneration = 0
    private var readyClick: FinderSnapshot?
    private var pendingClick: PendingClick?
    private var dragLocateGeneration = 0
    private var closeToken = 0
    private var graceToken = 0
    private var buttonPoll: Timer?
    private var presentation = 0
    private var latencyAction: String?
    private var latencyKeyTime: Double?
    private var latencyOpenSignpost: OSSignpostID?
    private var latencySwitchSignpost: OSSignpostID?
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
        if CommandLine.arguments.contains("--placement-probe") {
            runPlacementProbe()
            return
        }
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
        wheel.prewarm()
        CompiledFinderScript.shared.prewarm()
        observeRingLifetime()
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
        drag.onShowWheel = { [weak self] kind, point, session, keyTime in
            self?.openDragWheel(kind: kind, at: point, session: session, keyTime: keyTime)
        }
        drag.onSwitchWheel = { [weak self] kind, session, keyTime in
            guard let self else { return }
            if case .closing = self.ringDismiss.presence {
                self.drag.machine.cancelArmedTap()
                self.apply(self.ringDismiss.handle(.shift(canCycle: false)))
                return
            }
            self.armLatency("switch", keyTime: keyTime)
            self.showWheel(kind: kind, at: nil, session: session, action: "switch")
        }
        drag.onDismissWheel = { [weak self] cause in
            self?.dismissFromGesture(cause)
        }
        drag.onDragBegan = { [weak self] session in
            self?.beginDragLocate(session)
        }
        drag.onWheelKey = { [weak self] key in
            guard let self, !self.wheel.isClosing else { return }
            self.handleWheelKey(key)
        }
        drag.onIdleTap = { [weak self] kind, keyTime in
            self?.handleIdleTap(kind, keyTime: keyTime)
        }
        drag.onPrefetchAnchor = { [weak self] in
            self?.prefetchOrReopen()
        }
        drag.onGlobalMouseDown = { [weak self] in
            guard let self else { return }
            if !self.wheel.isShowing {
                self.pendingClick = nil
                return
            }
            self.apply(self.ringDismiss.handle(.mouseDown(.left, onActionableWedge: false)))
        }
        drag.onUnguardedMouseUp = { [weak self] in
            guard let self, self.wheel.isShowing else { return }
            let onWedge = self.wheel.actionableWedge(atScreen: NSEvent.mouseLocation)
            self.apply(self.ringDismiss.handle(.mouseUp(.left, onActionableWedge: onWedge)))
        }
        drag.onRightMouse = { [weak self] down in
            guard let self, self.wheel.isShowing else { return }
            let event: RingDismissEvent = down
                ? .mouseDown(.right, onActionableWedge: false)
                : .mouseUp(.right, onActionableWedge: false)
            self.apply(self.ringDismiss.handle(event))
        }
        drag.onGlobalKeyDown = { [weak self] key in
            guard let self, self.wheel.isShowing else { return }
            if key == .escape {
                self.apply(self.ringDismiss.handle(.escape))
                return
            }
            guard self.clickMode, !self.wheel.isClosing else { return }
            self.handleWheelKey(key)
        }
        drag.onLocalKeyDown = { [weak self] key in
            guard let self, key == .escape, self.wheel.isShowing else { return }
            self.apply(self.ringDismiss.handle(.escape))
        }
    }

    private func observeRingLifetime() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.wheel.isShowing else { return }
            self.apply(self.ringDismiss.handle(.spaceChanged))
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.wheel.isShowing else { return }
            self.apply(self.ringDismiss.handle(.appDeactivated))
        }
    }

    /// Select a file in Finder (click and release), then tap Shift.
    /// Another Shift tap cycles Convert → Tools → Actions in place.
    /// Escape dismisses. So does any click that is not a wedge with an action. Shift does not.
    private func handleIdleTap(_ kind: WheelKind, keyTime: Double) {
        if wheel.isShowing {
            let decision = ringDismiss.handle(.shift(canCycle: canCycleRing()))
            switch decision {
            case .cycle:
                guard let session else {
                    apply(ringDismiss.handle(.shift(canCycle: false)))
                    return
                }
                armLatency("switch", keyTime: keyTime)
                showWheel(kind: self.kind.next, at: nil, session: session, action: "switch")
            case .reopen:
                apply(decision)
            default:
                apply(decision)
            }
            return
        }
        guard !drag.typedSinceClick,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        armLatency("open", keyTime: keyTime)
        if lookupGeneration == 0 {
            beginClickLookup()
        }
        if let ready = readyClick, readyClickMatchesCurrentLookup {
            showClick(ready, kind: kind)
            return
        }
        pendingClick = PendingClick(kind: kind, keyTime: keyTime, generation: lookupGeneration)
    }

    private func openDragWheel(kind: WheelKind, at point: Point, session: DragSession, keyTime: Double) {
        if case .closing = ringDismiss.presence {
            drag.machine.cancelArmedTap()
            apply(ringDismiss.handle(.shift(canCycle: false)))
            return
        }
        clickMode = false
        armLatency("open", keyTime: keyTime)
        showWheel(kind: kind, at: point, session: session, action: "open")
    }

    private func prefetchOrReopen() {
        if case .closing = ringDismiss.presence {
            drag.machine.cancelArmedTap()
            apply(ringDismiss.handle(.shift(canCycle: false)))
            return
        }
        beginClickLookup()
    }

    private func wireWheel() {
        wheel.onHoverIndex = { [weak self] index in
            self?.applyHighlight(index, fromPointer: true)
        }
        wheel.onDropIndex = { [weak self] index in
            self?.acceptDrop(index: index)
        }
        wheel.onClickIndex = { [weak self] index in
            guard let self, self.clickMode, !self.wheel.isClosing else { return }
            self.acceptDrop(index: index)
        }
        wheel.onMissClick = { [weak self] in
            guard let self, self.clickMode else { return }
            self.apply(self.ringDismiss.handle(.mouseDown(.left, onActionableWedge: false)))
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

    /// Kinds with no segments are skipped. Nil means every kind is empty.
    /// Disk probes stay off this path; a later pass fills size and folder type.
    private func nonEmptyKind(startingAt kind: WheelKind, session: DragSession) -> WheelKind? {
        WheelCycle.firstNonEmpty(startingAt: kind) { candidate in
            !WheelContents.build(kind: candidate, session: session, availability: model.tools, probeDisk: false).segments.isEmpty
        }
    }

    private func showWheel(kind: WheelKind, at point: Point?, session: DragSession, action: String) {
        if wheel.isShowing, point != nil {
            let decision = ringDismiss.handle(.openWhileVisible)
            switch decision {
            case .replace(let reason):
                RingLogger.write(RingDismissLog.line(reason: reason))
                invalidateClose()
            case .reopen:
                apply(.reopen)
            default:
                break
            }
        }
        pushSettings()
        guard let chosen = nonEmptyKind(startingAt: kind, session: session) else {
            drag.machine.adoptShownWheel(nil, session: session)
            if wheel.isShowing {
                hideImmediately(reason: "empty-wheel")
            }
            finishLatencyIfArmed()
            return
        }
        drag.machine.adoptShownWheel(chosen, session: session)
        self.kind = chosen
        self.session = session
        let built = WheelContents.build(kind: chosen, session: session, availability: model.tools, probeDisk: false)
        let cycling = point == nil && wheel.isShowing && !wheel.isClosing
        if cycling {
            withAnimation(PithTheme.wheelSwitchAnimation) {
                publish(built)
                wheel.model.generation += 1
            }
        } else {
            publish(built)
        }
        if latencyAction != nil {
            RingLogger.write(LatencyMark.show(action))
        }
        if let point {
            let screen = CGPoint(x: point.x, y: point.y)
            let origin = drag.fileDragOrigin.map { CGPoint(x: $0.x, y: $0.y) } ?? screen
            invalidateClose()
            wheel.present(at: screen, hiddenUntilAligned: !clickMode, dragOrigin: origin, paths: session.filePaths)
            notePresence()
        } else if !wheel.isShowing {
            let mouse = NSEvent.mouseLocation
            let origin = drag.fileDragOrigin.map { CGPoint(x: $0.x, y: $0.y) } ?? mouse
            invalidateClose()
            wheel.present(at: mouse, hiddenUntilAligned: !clickMode, dragOrigin: origin, paths: session.filePaths)
            notePresence()
        }
        wheel.commitFrame()
        finishLatencyIfArmed()
        presentation += 1
        refreshDiskFacts(session: session, id: presentation)
    }

    private struct PendingClick {
        var kind: WheelKind
        var keyTime: Double
        var generation: Int
    }

    private var readyClickMatchesCurrentLookup: Bool {
        readyClick != nil && lookupGeneration != 0
    }

    /// Shift went down. Accessibility runs now so it overlaps the tap. The ring
    /// stays hidden until this returns the same centre main would show.
    private func beginClickLookup() {
        lookupGeneration += 1
        let token = lookupGeneration
        readyClick = nil
        let context = finderContext()
        AnchorLookup.resolveClick(mouse: context.mouse, mainScreenMaxY: context.maxY, finderPIDs: context.pids) { [weak self] snap in
            guard let self, token == self.lookupGeneration else { return }
            self.readyClick = snap
            guard let pending = self.pendingClick, pending.generation == token else { return }
            self.pendingClick = nil
            self.showClick(snap, kind: pending.kind)
        }
    }

    private func showClick(_ snap: FinderSnapshot, kind: WheelKind) {
        guard !snap.paths.isEmpty else {
            cancelLatency()
            return
        }
        let mouse = NSEvent.mouseLocation
        let center = snap.located.center ?? mouse
        FinderIconLocator.log(snap.located, mode: "click", mouse: mouse, paths: snap.paths, center: center)
        let session = makeSession(paths: snap.paths, at: Point(x: center.x, y: center.y))
        clickMode = true
        showWheel(kind: kind, at: session.location, session: session, action: "open")
    }

    private func beginDragLocate(_ session: DragSession) {
        guard !session.filePaths.isEmpty else { return }
        dragLocateGeneration += 1
        let token = dragLocateGeneration
        wheel.preparedDragLocation = nil
        let origin = CGPoint(x: session.location.x, y: session.location.y)
        let context = finderContext(mouse: origin)
        AnchorLookup.resolveDrag(
            mouse: origin,
            paths: session.filePaths,
            mainScreenMaxY: context.maxY,
            finderPIDs: context.pids
        ) { [weak self] located in
            guard let self, token == self.dragLocateGeneration, located.center != nil else { return }
            self.wheel.preparedDragLocation = located
        }
    }

    private func finderContext(mouse: CGPoint? = nil) -> (mouse: CGPoint, maxY: Double, pids: Set<pid_t>) {
        let mouse = mouse ?? NSEvent.mouseLocation
        let maxY = NSScreen.screens.first.map { Double($0.frame.maxY) } ?? 0
        let pids = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").map(\.processIdentifier)
        )
        return (mouse, maxY, pids)
    }

    /// Same locate path as a Shift open, then exit. No window.
    private func runPlacementProbe() {
        let start = CACurrentMediaTime()
        let context = finderContext()
        var snap = FinderIconLocator.snapshot(
            near: context.mouse,
            knownPaths: [],
            mainScreenMaxY: context.maxY,
            finderPIDs: context.pids
        )
        if snap.paths.isEmpty || snap.located.center == nil {
            let paths = CompiledFinderScript.shared.execute()
            if !paths.isEmpty {
                snap = FinderIconLocator.snapshot(
                    near: context.mouse,
                    knownPaths: paths,
                    mainScreenMaxY: context.maxY,
                    finderPIDs: context.pids
                )
            }
        }
        let center = snap.located.center ?? context.mouse
        FinderIconLocator.log(snap.located, mode: "click", mouse: context.mouse, paths: snap.paths, center: center)
        let elapsed = (CACurrentMediaTime() - start) * 1000
        RingLogger.write(String(format: "placement-probe elapsed=%.1fms", elapsed))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(0)
        }
    }

    private func publish(_ built: WheelContents.Built) {
        self.built = built
        navigation = WheelNavigation(count: built.segments.count)
        wheel.model.segments = built.segments
        wheel.model.highlighted = nil
        wheel.model.centerText = built.centerFallback
    }

    private func makeSession(paths: [String], at center: Point) -> DragSession {
        DragSession(
            changeCount: -1,
            filePaths: paths,
            hasFilePromise: false,
            promisedTypeIdentifiers: [],
            location: center
        )
    }

    private func currentPointer() -> Point {
        let mouse = NSEvent.mouseLocation
        return Point(x: mouse.x, y: mouse.y)
    }

    private func canCycleRing() -> Bool {
        guard wheel.isShowing, session != nil, !wheel.isClosing else { return false }
        if case .closing = ringDismiss.presence { return false }
        if clickMode { return true }
        if case .wheel = drag.machine.phase { return true }
        return false
    }

    private func notePresence() {
        graceToken += 1
        if clickMode {
            ringDismiss.noteShown(.click)
            stopDragPoll()
        } else {
            let down = NSEvent.pressedMouseButtons & 1 != 0
            ringDismiss.noteShown(.drag(buttonDown: down))
            if down {
                startDragPoll()
            } else {
                // Finder often keeps the mouse-up inside its drag loop, so the button
                // can already be up by the time the ring is on screen.
                stopDragPoll()
                let inside = wheel.panelFrameContains(NSEvent.mouseLocation)
                apply(ringDismiss.handle(.buttonsReleased(pointerInsideRing: inside)))
            }
        }
    }

    private func refreshDiskFacts(session: DragSession, id: Int) {
        let paths = session.filePaths
        guard !paths.isEmpty else { return }
        let tools = model.tools
        let kind = self.kind
        DispatchQueue.global(qos: .utility).async {
            let probed = WheelContents.build(kind: kind, session: session, availability: tools, probeDisk: true)
            DispatchQueue.main.async {
                guard self.presentation == id, self.wheel.isShowing, !self.wheel.isClosing else { return }
                let sameSegments = probed.segments == self.wheel.model.segments
                let sameCenter = probed.centerFallback == self.wheel.model.centerText
                guard !sameSegments || !sameCenter else { return }
                self.built = probed
                self.navigation = WheelNavigation(count: probed.segments.count)
                self.wheel.model.segments = probed.segments
                if self.wheel.model.highlighted == nil {
                    self.wheel.model.centerText = probed.centerFallback
                }
            }
        }
    }

    private func armLatency(_ action: String, keyTime: Double) {
        if let id = latencyOpenSignpost { RingLogger.endOpen(id) }
        if let id = latencySwitchSignpost { RingLogger.endSwitch(id) }
        latencyAction = action
        latencyKeyTime = keyTime
        RingLogger.write(LatencyMark.key(action))
        if action == "switch" {
            latencySwitchSignpost = RingLogger.beginSwitch()
            latencyOpenSignpost = nil
        } else {
            latencyOpenSignpost = RingLogger.beginOpen()
            latencySwitchSignpost = nil
        }
    }

    private func finishLatencyIfArmed() {
        guard let action = latencyAction, let keyTime = latencyKeyTime else { return }
        let milliseconds = (CACurrentMediaTime() - keyTime) * 1000
        RingLogger.write(LatencyMark.frame(action, keyToFrameMilliseconds: milliseconds))
        if let id = latencyOpenSignpost {
            RingLogger.endOpen(id)
        }
        if let id = latencySwitchSignpost {
            RingLogger.endSwitch(id)
        }
        latencyAction = nil
        latencyKeyTime = nil
        latencyOpenSignpost = nil
        latencySwitchSignpost = nil
    }

    private func cancelLatency() {
        if let id = latencyOpenSignpost {
            RingLogger.endOpen(id)
        }
        if let id = latencySwitchSignpost {
            RingLogger.endSwitch(id)
        }
        latencyAction = nil
        latencyKeyTime = nil
        latencyOpenSignpost = nil
        latencySwitchSignpost = nil
    }

    private func dismissFromGesture(_ cause: GestureDismissCause) {
        let event: RingDismissEvent
        switch cause {
        case .escape:
            event = .escape
        case .mouseDown:
            event = .mouseDown(.left, onActionableWedge: false)
        case .mouseUp:
            let onWedge = wheel.actionableWedge(atScreen: NSEvent.mouseLocation)
            event = .mouseUp(.left, onActionableWedge: onWedge)
        case .dropAccepted:
            event = .dropAccepted
        }
        apply(ringDismiss.handle(event))
    }

    private func apply(_ decision: RingDismissDecision) {
        switch decision {
        case .ignore, .cycle:
            break
        case .beginClose(let reason):
            startClose(reason: reason)
        case .finishClose:
            orderOutClosed()
        case .reopen:
            cancelCloseAndRestore()
        case .dismiss(let reason):
            hideImmediately(reason: reason)
        case .dismissAfterDropGrace:
            scheduleDropGrace()
        case .replace(let reason):
            RingLogger.write(RingDismissLog.line(reason: reason))
            invalidateClose()
        }
    }

    private func startClose(reason: String) {
        guard wheel.isShowing else {
            ringDismiss.noteHidden()
            return
        }
        guard !wheel.isClosing else { return }
        RingLogger.write(RingDismissLog.line(reason: reason))
        stopDragPoll()
        closeToken += 1
        let token = closeToken
        wheel.beginCloseAnimation(duration: RingCloseTiming.duration) { [weak self] in
            self?.finishClose(token: token)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RingCloseTiming.fallback) { [weak self] in
            self?.finishClose(token: token)
        }
    }

    private func finishClose(token: Int) {
        guard token == closeToken else { return }
        closeToken += 1
        let decision = ringDismiss.handle(.closeFinished)
        guard case .finishClose = decision else { return }
        orderOutClosed()
    }

    private func orderOutClosed() {
        wheel.orderOutNow()
        built = nil
        navigation = WheelNavigation(count: 0)
        clickMode = false
        session = nil
        stopDragPoll()
        ringDismiss.noteHidden()
    }

    private func cancelCloseAndRestore() {
        invalidateClose()
        wheel.restoreInteractive()
        RingLogger.write(RingDismissLog.closeCancelledByReopen())
        if NSEvent.pressedMouseButtons & 1 == 0 {
            if case .drag = ringDismiss.presence {
                ringDismiss.noteShown(.click)
                clickMode = true
            }
            stopDragPoll()
        } else if case .drag(buttonDown: true) = ringDismiss.presence {
            clickMode = false
            startDragPoll()
        }
    }

    private func hideImmediately(reason: String) {
        guard wheel.isShowing || wheel.isClosing else {
            ringDismiss.noteHidden()
            return
        }
        invalidateClose()
        RingLogger.write(RingDismissLog.line(reason: reason))
        wheel.orderOutNow()
        built = nil
        navigation = WheelNavigation(count: 0)
        clickMode = false
        session = nil
        stopDragPoll()
        ringDismiss.noteHidden()
    }

    private func invalidateClose() {
        closeToken += 1
        wheel.restoreInteractive()
    }

    private func scheduleDropGrace() {
        graceToken += 1
        let token = graceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropGrace) { [weak self] in
            guard let self, token == self.graceToken else { return }
            self.apply(self.ringDismiss.handle(.dropGraceExpired))
        }
    }

    private func startDragPoll() {
        stopDragPoll()
        guard case .drag(buttonDown: true) = ringDismiss.presence else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollDragButton()
        }
        RunLoop.main.add(timer, forMode: .common)
        buttonPoll = timer
    }

    private func stopDragPoll() {
        buttonPoll?.invalidate()
        buttonPoll = nil
    }

    private func pollDragButton() {
        guard case .drag(buttonDown: true) = ringDismiss.presence else {
            stopDragPoll()
            return
        }
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let inside = wheel.panelFrameContains(NSEvent.mouseLocation)
        apply(ringDismiss.handle(.buttonsReleased(pointerInsideRing: inside)))
        if case .drag(buttonDown: true) = ringDismiss.presence {} else {
            stopDragPoll()
        }
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
        graceToken += 1
        let decision = ringDismiss.handle(.dropAccepted)
        if case .dismiss = decision {
            hideImmediately(reason: "drop")
        } else if wheel.isShowing {
            hideImmediately(reason: "drop")
        }
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
        let host = NSHostingController(rootView: SettingsView(model: model))
        let window = PithWindowFactory.makeSettings(contentController: host)
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
        let window = PithWindowFactory.makeOnboarding(content: PithHostingView(rootView: OnboardingView(
            onGrant: {
                _ = AccessibilityPermission.isTrusted(prompt: true)
                close()
            },
            onLater: close
        )))
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
