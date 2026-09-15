import AppKit
import ScreenCaptureKit
import Carbon
import CoreMedia
import QuartzCore
import Combine

@MainActor
final class GlobalDesktopController: NSObject, @preconcurrency SCStreamOutput, SCStreamDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let model: AppModel
    private weak var setupWindow: NSWindow?
    private let power: PowerMonitor
    private let validation: RuntimeValidation?
    private var policy = RuntimePolicy()
    private var desktopWake = DesktopWakeAnimation()
    private var wakeDurationItems: [Double: NSMenuItem] = [:]
    private var decision = RuntimeDecision()
    private var motionSubscription: AnyCancellable?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var policyItems: [PerformanceMode: NSMenuItem] = [:]
    private var toggleItem: NSMenuItem!
    private var hotKeys: [EventHotKeyRef] = []
    private var emergencyKeyRegistered = false
    private var eventHandler: EventHandlerRef?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var deadlineTimer: Timer?
    private var maintenanceTimer: Timer?
    private var resumeTimer: Timer?
    private var maintenanceInterval: Double?
    private var menuOpen = false
    private var overlay: NSPanel?
    private var renderer: GlassMetalView?
    private var stream: SCStream?
    private var ownApplication: SCRunningApplication?
    private var displayID: CGDirectDisplayID?
    private var captureSize = CGSize.zero
    private var enabled = false
    private var shuttingDown = false
    private var desiredFPS = 0
    private var appliedFPS = 0
    private var revision = 0
    private var requestedGeneration = 0
    private var streamGeneration = -1
    private var reconciling = false
    private var allowPermissionPrompt = false
    private var pauseReasons = Set<String>()
    private var freshAfter = -Double.infinity
    private var previewUntil = -Double.infinity
    private var previewPending = false
    private var receivedFrame = false
    private var captureStartedAt = 0.0
    private var presentationStartedAt: Double?
    private var lastStatus = -Double.infinity
    private var failures = 0
    private var retryAt = 0.0
    private var configuredRate = -1
    private var lastRecordingContext: RecordingContext?
    private var lastMotionSubmit: Double?
    private var frameIntervals: [Double] = []
    private var firstFrameWaits: [Double] = []
    private var firstPresentationWaits: [Double] = []
    private let diagnosticPath: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diagnostics"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }()
    private(set) var state = EffectState.off
    private(set) var captureFrames = 0
    private(set) var contentFrames = 0
    private(set) var renderFrames = 0
    private(set) var gpuSeconds = 0.0
    private(set) var encodeSeconds = 0.0
    private(set) var firstFrameWait = 0.0
    private(set) var schedulerUpdates = 0
    private(set) var configurationUpdates = 0

    init(model: AppModel, setupWindow: NSWindow, startServices: Bool = true) {
        self.model = model
        self.power = model.power
        self.validation = RuntimeValidation(arguments: CommandLine.arguments,
            endpoint: model.openAngle, recording: model.recorder.status().enabled)
        self.setupWindow = setupWindow
        super.init()
        makeMenu()
        guard startServices else { return }
        registerKeys()
        power.onChange = { [weak self] in self?.update() }
        validation?.onChange = { [weak self] in self?.update() }
        model.runtimeSettingsChanged = { [weak self] in self?.update() }
        motionSubscription = model.sensor.motionEvents.sink { [weak self] in self?.update() }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, reason, pausing) in [
            (NSWorkspace.willSleepNotification, "system", true),
            (NSWorkspace.screensDidSleepNotification, "display", true),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (NSWorkspace.didWakeNotification, "system", false),
            (NSWorkspace.screensDidWakeNotification, "display", false),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemEvent(reason: reason, pausing: pausing) }
            }
            observers.append((workspace, observer))
        }
        let spaceObserver = workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateCapture()
                self?.update()
            }
        }
        observers.append((workspace, spaceObserver))
        // Session-resign notifications alone do not cover every lock-screen path.
        for (name, pausing) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemEvent(reason: "lock", pausing: pausing) }
            }
            distributedObservers.append(observer)
        }
        if Self.sessionLocked {
            pauseReasons.insert("lock")
            desktopWake.event(reason: "lock", pausing: true, eligible: false, at: CACurrentMediaTime())
        }
        // A lost workspace wake/session notification must not leave the app
        // suspended forever. This also detects idle display power transitions.
        let resumeTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemState() }
        }
        self.resumeTimer = resumeTimer
        RunLoop.main.add(resumeTimer, forMode: .common)
        refreshSystemState()
        update()
    }

    #if UI_VALIDATION
    var validationMenu: NSMenu { statusItem.menu! }
    func refreshValidationMenu() { refreshStatus(force: true) }
    #endif

    private func makeMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "MacBook Duo")
        statusItem.button?.setAccessibilityLabel("MacBook Duo")
        let menu = NSMenu()
        menu.delegate = self
        statusLine = NSMenuItem(title: "MacBook Duo", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem = item("启用效果", #selector(toggle))
        toggleItem.keyEquivalent = "g"
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleItem)
        menu.addItem(item("预览 8 秒", #selector(preview)))
        let calibration = item("设为展开位置", #selector(calibrate))
        calibration.keyEquivalent = "k"
        calibration.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(calibration)
        menu.addItem(.separator())
        let performance = NSMenuItem(title: "性能模式", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "性能模式")
        for mode in PerformanceMode.allCases {
            let option = item(mode.title, #selector(selectPolicy(_:)))
            option.representedObject = mode.rawValue
            submenu.addItem(option)
            policyItems[mode] = option
        }
        performance.submenu = submenu
        menu.addItem(performance)
        let wakeMenu = NSMenuItem(title: "息屏唤醒动画耗时", action: nil, keyEquivalent: "")
        let wakeOptions = NSMenu(title: wakeMenu.title)
        for duration in DesktopWakeAnimation.durations {
            let option = item(String(format: "%.1f 秒", duration), #selector(selectWakeDuration(_:)))
            option.representedObject = duration
            wakeOptions.addItem(option)
            wakeDurationItems[duration] = option
        }
        wakeMenu.submenu = wakeOptions
        menu.addItem(wakeMenu)
        let settings = item("设置…", #selector(showSetup))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        let emergency = item("紧急停止", #selector(emergencyStop))
        emergency.keyEquivalent = "\u{1b}"
        emergency.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(emergency)
        let quitItem = item("退出 MacBook Duo", #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
        statusItem.menu = menu
    }
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggle): return enabled || !model.permissionsPreparing
        case #selector(preview): return !model.permissionsPreparing
        case #selector(calibrate): return model.sensor.isAvailable
        default: return true
        }
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; refreshStatus(force: true); configureMaintenance() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; configureMaintenance() }
    @objc private func selectPolicy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PerformanceMode(rawValue: raw) {
            model.performanceMode = mode
        }
    }
    @objc private func selectWakeDuration(_ sender: NSMenuItem) {
        if let duration = sender.representedObject as? Double {
            model.wakeAnimationDuration = duration
            refreshStatus(force: true)
        }
    }
    @objc private func togglePrediction() { model.predictionEnabled.toggle() }
    @objc private func toggleRecording() { model.toggleRecording() }
    @objc private func beginRecording() { model.beginRecording() }
    @objc private func exportRecording() { model.exportRecording() }
    @objc private func clearRecording() { model.clearRecording() }
    @objc func toggle() { enabled ? stop(reason: "全局效果已停止") : start() }
    @objc func preview() {
        previewPending = true
        previewUntil = -.infinity
        // Start the eight seconds only after a fresh effect frame is ready.
        if enabled { hideEffect(); update() } else { start() }
    }
    func previewWakeAnimation() {
        guard !model.permissionsPreparing, !Self.sessionLocked else { return }
        refreshSystemState()
        if !enabled { start() }
        guard enabled, pauseReasons.isEmpty else { return }
        previewPending = false; previewUntil = -.infinity
        let now = CACurrentMediaTime()
        desktopWake.event(reason: "display", pausing: true, eligible: true, at: now)
        desktopWake.event(reason: "display", pausing: false, eligible: true, at: now)
        invalidateCapture()
        update()
    }
    @objc func calibrate() {
        guard model.savePhysicalOpenAngle() else { refreshStatus(force: true); return }
        previewPending = false; previewUntil = -.infinity
        policy.reset()
        model.sensor.reset()
        renderer?.resetLiveAngle()
        hideEffect()
        update()
        statusItem.button?.toolTip = model.calibrationMessage
    }
    func hideSetup() {
        model.settingsVisible = false
        // The live panel may be above ordinary windows while the effect is
        // running, but the settings window must not retain a top level after
        // it is closed.
        setupWindow?.level = .normal
        setupWindow?.orderOut(nil)
        NSApp.presentationOptions = []
        pauseReasons.remove("settings")
        update()
    }
    @objc func showSetup() {
        model.returnToSetup()
        // Settings are an ordinary application window, including while the
        // background effect is enabled.
        pauseReasons.remove("settings")
        model.settingsVisible = true
        setupWindow?.level = .normal
        if setupWindow?.isMiniaturized == true { setupWindow?.deminiaturize(nil) }
        setupWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        update()
    }
    @objc private func emergencyStop() {
        stop(reason: "全局效果已停止")
        showSetup()
    }
    @objc private func quit() { shutdown(); NSApp.terminate(nil) }
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        enabled = false
        desiredFPS = 0; revision += 1
        hideEffect(invalidate: true)
        if let stream { Task { try? await stream.stopCapture() } }
        deadlineTimer?.invalidate(); maintenanceTimer?.invalidate(); resumeTimer?.invalidate()
        motionSubscription?.cancel()
        model.runtimeSettingsChanged = nil
        power.onChange = nil
        validation?.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        for key in hotKeys { UnregisterEventHotKey(key) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        model.sensor.shutdown()
        model.recorder.close()
    }
    func start(automatically: Bool = false) {
        guard !enabled, !shuttingDown, !model.permissionsPreparing else { return }
        guard emergencyKeyRegistered else {
            model.globalStatus = "紧急停止快捷键注册失败，未启用覆盖层"
            model.globalNotice = model.globalStatus
            return
        }
        enabled = true
        model.globalRunning = true
        failures = 0; retryAt = 0
        allowPermissionPrompt = !automatically
        let resumedFromSettings = pauseReasons.remove("settings") != nil
        policy.reset()
        model.globalStatus = "正在准备实时效果"
        model.globalNotice = ""
        if model.settingsVisible {
            setupWindow?.level = .normal
        } else {
            setupWindow?.level = .normal
            setupWindow?.orderOut(nil)
        }
        if resumedFromSettings {
            freshAfter = CACurrentMediaTime()
            model.sensor.reset(invalidate: true)
            invalidateCapture()
        }
        update()
    }
    func stop(reason: String) {
        enabled = false
        desktopWake.cancel()
        model.globalRunning = false
        previewPending = false; previewUntil = -.infinity
        policy.reset()
        allowPermissionPrompt = false
        model.sensor.reset()
        hideEffect(invalidate: true)
        setCaptureFPS(0)
        model.globalStatus = reason
        update()
    }
    private static var sessionLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool == true ||
            session[kCGSessionOnConsoleKey as String] as? Bool == false
    }
    private static var sessionOnConsole: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
    }
    private func systemEvent(reason: String, pausing: Bool) {
        if reason == "lock", pausing, !pauseReasons.contains("display"),
           CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            systemEvent(reason: "display", pausing: true)
        }
        // A polling repair can precede the corresponding notification. Do not
        // invalidate a fresh frame or its sensor sample twice for one change.
        guard pauseReasons.contains(reason) != pausing else { return }
        desktopWake.event(reason: reason, pausing: pausing,
            eligible: enabled && Self.sessionOnConsole,
            at: CACurrentMediaTime())
        if pausing { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        freshAfter = CACurrentMediaTime()
        model.sensor.reset(invalidate: true)
        model.recorder.breakSegment(reason: pausing ? "systemPause" : "systemResume")
        policy.reset()
        previewPending = false; previewUntil = -.infinity
        invalidateCapture()
        NSLog("Duo wake event: %@ paused=%d remaining=%@ animation=%d", reason, pausing,
              pauseReasons.sorted().joined(separator: ","), desktopWake.isActive)
        update()
    }
    private func refreshSystemState() {
        guard !shuttingDown,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool == true
        let locked = session["CGSSessionScreenIsLocked"] as? Bool == true
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        for change in SystemResumeState.changes(paused: pauseReasons, displayAsleep: asleep,
                                                 locked: locked, onConsole: onConsole) {
            systemEvent(reason: change.reason, pausing: change.pausing)
        }
        // Fresh HID samples may resume with an unchanged angle. Re-evaluate
        // freshness even if the motion-event stream does not deliver a change.
        if enabled && (state == .suspended || desktopWake.isActive) { update() }
    }
    private func invalidateCapture() {
        requestedGeneration += 1; revision += 1
        hideEffect(invalidate: true)
    }
    private func hideEffect(invalidate: Bool = false) {
        overlay?.orderOut(nil)
        overlay?.alphaValue = 0
        renderer?.renderingEnabled = false
        presentationStartedAt = nil
        lastMotionSubmit = nil
        if invalidate {
            receivedFrame = false
            renderer?.invalidateContent()
        }
    }
    private func targetAngle(at now: Double) -> Double {
        if let tilt = desktopWake.tilt(at: now) { return tilt }
        if previewPending || now < previewUntil { return 28 }
        let snapshot = motionSnapshot(at: now)
        guard snapshot.sample.valid, now - snapshot.lastValid < 0.5,
              HingeMotion.remaining(angle: snapshot.sample.angle, endpoint: model.openAngle) > 0 else { return 0 }
        return HingeMotion.tilt(
            angle: snapshot.predicted(at: now, enabled: model.predictionEnabled), endpoint: model.openAngle)
    }

    private func effectOpacity(at now: Double) -> Double {
        if desktopWake.isActive { return 1 }
        if previewPending || now < previewUntil { return 1 }
        let snapshot = motionSnapshot(at: now)
        guard snapshot.sample.valid, now - snapshot.lastValid < 0.5 else { return 0 }
        return HingeMotion.effectOpacity(angle: snapshot.sample.angle, endpoint: model.openAngle)
    }

    private func motionSnapshot(at now: Double) -> MotionSnapshot {
        validation?.snapshot(at: now) ?? model.sensor.snapshot
    }

    private func update() {
        guard !shuttingDown else { return }
        schedulerUpdates += 1
        let now = CACurrentMediaTime()
        desktopWake.advance(at: now, allowed: enabled && Self.sessionOnConsole)
        let screenFPS = overlay?.screen?.maximumFramesPerSecond ??
            NSScreen.screens.first(where: { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return CGDisplayIsBuiltin(id.uint32Value) != 0
            })?.maximumFramesPerSecond ?? 60
        let input = RuntimeInput(time: now, enabled: enabled, suspended: !pauseReasons.isEmpty,
            settingsVisible: model.settingsVisible, recording: model.recorder.status().enabled,
            snapshot: motionSnapshot(at: now), endpoint: model.openAngle, mode: model.performanceMode,
            onAC: power.onAC, lowPower: power.lowPower, preview: desktopWake.isActive || previewPending || now < previewUntil,
            screenFPS: screenFPS, freshAfter: freshAfter)
        let previousState = state
        decision = policy.update(input)
        if desktopWake.isActive && decision.showsEffect {
            decision.animates = true
            decision.state = .moving
        }
        state = decision.state
        let sensorRate = validation?.scenario == .moving && enabled && pauseReasons.isEmpty ? 120 : decision.sensorHz
        if configuredRate != sensorRate {
            configuredRate = sensorRate
            model.sensor.setRate(configuredRate)
        }
        model.sensor.setUIVisible(model.settingsVisible && pauseReasons.isEmpty)
        if model.effectiveRenderFPS != decision.renderFPS { model.effectiveRenderFPS = decision.renderFPS }
        setCaptureFPS(now < retryAt ? 0 : decision.captureFPS)
        if state == .suspended {
            hideEffect(invalidate: true)
            model.globalStatus = pauseReasons.isEmpty ? "等待有效铰链数据，恢复后继续" : "系统已暂停，唤醒并取得新画面后继续"
        } else if !decision.showsEffect || !receivedFrame {
            hideEffect()
        } else if let renderer, let overlay {
            renderer.preferredFramesPerSecond = decision.renderFPS
            renderer.setAppearance(frost: model.frost, softness: model.edgeSoftness)
            renderer.continuousRendering = decision.animates
            renderer.setLiveAngle(targetAngle(at: now))
            if !renderer.renderingEnabled {
                presentationStartedAt = now
                // An explicit first draw also runs when a zero-alpha window is
                // occluded. The panel becomes opaque only on GPU completion.
                overlay.alphaValue = 0
                overlay.orderFrontRegardless()
                renderer.renderingEnabled = true
                renderer.draw()
            } else if renderer.readyForDisplay {
                overlay.alphaValue = effectOpacity(at: now)
            }
        }
        if previousState != state { lastMotionSubmit = nil }
        let context = RecordingContext(endpoint: model.openAngle, mode: model.performanceMode.rawValue,
            policy: decision.policy.rawValue, onAC: power.onAC, prediction: model.predictionEnabled,
            state: state.rawValue, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7",
            lowPower: power.lowPower, build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "7")
        if lastRecordingContext != context {
            lastRecordingContext = context
            model.recorder.setContext(context)
        }
        var deadlines = [decision.nextDeadline]
        if let deadline = desktopWake.deadline { deadlines.append(deadline) }
        if enabled && retryAt > now { deadlines.append(retryAt) }
        if previewUntil > now { deadlines.append(previewUntil) }
        if stream != nil && desiredFPS > 0 && !receivedFrame {
            if now - captureStartedAt >= 8 { captureFailed("等待有效首帧超时"); return }
            deadlines.append(captureStartedAt + 8)
        }
        if let start = presentationStartedAt, renderer?.readyForDisplay == false {
            if now - start >= 3 { captureFailed("首帧 GPU 准备超时"); return }
            deadlines.append(start + 3)
        }
        scheduleDeadline(deadlines.compactMap { $0 }.filter { $0 > now }.min())
        configureMaintenance()
        refreshStatus(force: previousState != state)
    }
    private func scheduleDeadline(_ time: Double?) {
        deadlineTimer?.invalidate(); deadlineTimer = nil
        guard let time else { return }
        let timer = Timer(timeInterval: max(0.001, time - CACurrentMediaTime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func configureMaintenance() {
        let interval: Double? = diagnosticPath != nil || menuOpen || model.settingsVisible ? 1 :
            (model.recorder.status().enabled ? 30 : (enabled ? 10 : nil))
        guard interval != maintenanceInterval else { return }
        maintenanceInterval = interval
        maintenanceTimer?.invalidate(); maintenanceTimer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.recorder.tick()
                if self.model.settingsVisible { self.model.refreshRecordingStatus() }
                self.refreshStatus(force: true)
                self.writeDiagnostics()
            }
        }
        maintenanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func refreshStatus(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastStatus >= 1 else { return }
        lastStatus = now
        let description = "\(power.onAC ? "插电" : "电池") · 实际\(decision.policy.title)\(power.lowPower ? " · 系统低电量" : "")"
        if model.effectivePolicy != description { model.effectivePolicy = description }
        let name: String
        switch state {
        case .off: name = "已关闭"
        case .clearIdle: name = "清晰待机"
        case .moving: name = "运动中"
        case .staticEffect: name = "静止显示效果"
        case .suspended: name = "系统／传感器暂停"
        }
        let validationLabel = validation == nil ? "" : "测试动作 · "
        let status = "\(validationLabel)\(name) · 捕获上限 \(appliedFPS)fps · 已绘制 \(renderFrames) 帧"
        if model.runtimeStatus != status { model.runtimeStatus = status }
        // Keep the product state separate from diagnostic prose.
        let summary = !enabled ? "已关闭" : (previewPending || previewUntil > now ? "预览中" : name)
        if model.effectSummary != summary { model.effectSummary = summary }
        statusLine.title = summary
        toggleItem.title = enabled ? "停止效果" : "启用效果"
        toggleItem.isEnabled = !model.permissionsPreparing || enabled
        statusItem.button?.toolTip = "MacBook Duo · \(statusLine.title)"
        for (duration, item) in wakeDurationItems { item.state = duration == model.wakeAnimationDuration ? .on : .off }
        for (mode, item) in policyItems { item.state = mode == model.performanceMode ? .on : .off }
    }

    private func setCaptureFPS(_ fps: Int) {
        guard !shuttingDown else { return }
        if desiredFPS != fps { desiredFPS = fps; revision += 1 }
        let needsWork = desiredFPS != appliedFPS || (desiredFPS > 0 && (stream == nil || streamGeneration != requestedGeneration)) ||
            (desiredFPS == 0 && stream != nil)
        guard !reconciling, needsWork else { return }
        reconciling = true
        Task { @MainActor in
            await reconcile()
            reconciling = false
            setCaptureFPS(desiredFPS)
            update()
        }
    }
    private func tearDownStream() async {
        let old = stream
        stream = nil; appliedFPS = 0; streamGeneration = -1
        hideEffect(invalidate: true)
        if let old {
            try? await old.stopCapture()
            try? old.removeStreamOutput(self, type: .screen)
        }
    }
    private func configuration(fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(captureSize.width); config.height = Int(captureSize.height)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3; config.showsCursor = false; config.capturesAudio = false
        return config
    }
    // A single MainActor task owns every awaited start/update/stop. Both rate
    // revisions and resource generations are checked after asynchronous calls.
    private func reconcile() async {
        while !shuttingDown {
            let token = revision, fps = desiredFPS, generation = requestedGeneration
            do {
                if fps == 0 {
                    await tearDownStream()
                } else {
                    if stream != nil && streamGeneration != generation { await tearDownStream() }
                    if token != revision { continue }
                    if let stream {
                        try await stream.updateConfiguration(configuration(fps: fps))
                        appliedFPS = fps
                        configurationUpdates += 1
                    } else {
                        guard allowPermissionPrompt || CGPreflightScreenCaptureAccess() else {
                            enabled = false; model.globalRunning = false
                            desiredFPS = 0; revision += 1
                            model.globalStatus = "请手动启用实时效果，并在系统设置允许屏幕录制"
                            model.globalNotice = model.globalStatus
                            model.settingsVisible = true; setupWindow?.makeKeyAndOrderFront(nil)
                            return
                        }
                        allowPermissionPrompt = false
                        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                        guard token == revision, enabled, pauseReasons.isEmpty else { continue }
                        guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }),
                              let screen = NSScreen.screens.first(where: {
                                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                              }) else { throw GlobalError.noInternalDisplay }
                        let pid = ProcessInfo.processInfo.processIdentifier
                        if let own = content.applications.first(where: { $0.processID == pid }) { ownApplication = own }
                        guard let ownApplication, ownApplication.processID == pid else { throw GlobalError.cannotExcludeSelf }
                        try prepareRenderer(screen: screen)
                        displayID = display.displayID
                        captureSize = screen.frame.size
                        let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
                        let candidate = SCStream(filter: filter, configuration: configuration(fps: fps), delegate: self)
                        try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                        stream = candidate; streamGeneration = generation
                        receivedFrame = false; captureStartedAt = CACurrentMediaTime()
                        try await candidate.startCapture()
                        guard token == revision, enabled, pauseReasons.isEmpty else {
                            await tearDownStream()
                            continue
                        }
                        appliedFPS = fps; configurationUpdates += 1
                        model.globalStatus = "实时效果已启用 · ⌘⇧Esc 紧急停止"
                        model.globalNotice = ""
                    }
                }
            } catch {
                await tearDownStream()
                if token == revision { captureFailed(error.localizedDescription); return }
            }
            if token == revision { break }
        }
    }
    private func prepareRenderer(screen: NSScreen) throws {
        let view = renderer ?? GlassMetalView()
        guard view.isOperational else { throw GlobalError.noGPU }
        view.invalidateContent()
        view.angleProvider = { [weak self] in self?.targetAngle(at: CACurrentMediaTime()) ?? 0 }
        view.sensorTimeProvider = { [weak self] in self?.motionSnapshot(at: CACurrentMediaTime()).sample.time ?? 0 }
        view.movingProvider = { [weak self] in
            guard let self else { return false }
            let now = CACurrentMediaTime()
            return self.desktopWake.isActive || self.motionSnapshot(at: now).moving(at: now)
        }
        view.onFrame = { [weak self] timing in self?.didRender(timing) }
        view.onReady = { [weak self] in self?.presentFreshFrame() }
        view.onFailure = { [weak self] in self?.captureFailed("Metal 绘制失败") }
        let panel = overlay ?? NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view; panel.setFrame(screen.frame, display: false)
        renderer = view; overlay = panel
    }
    private func presentFreshFrame() {
        guard enabled, pauseReasons.isEmpty, receivedFrame, decision.showsEffect,
              renderer?.readyForDisplay == true, !Self.sessionLocked else { hideEffect(); return }
        let now = CACurrentMediaTime()
        let sample = motionSnapshot(at: now)
        guard sample.sample.valid, sample.sample.time >= freshAfter, now - sample.lastValid < 0.5,
              desktopWake.isActive || previewPending || now < previewUntil || HingeMotion.remaining(angle: sample.sample.angle, endpoint: model.openAngle) > 0 else {
            hideEffect(); return
        }
        if let start = presentationStartedAt {
            firstPresentationWaits.append(now - start)
            if firstPresentationWaits.count > 100 { firstPresentationWaits.removeFirst() }
        }
        presentationStartedAt = nil
        desktopWake.present(at: now, duration: model.wakeAnimationDuration)
        if desktopWake.isActive {
            NSLog("Duo wake presented: duration=%.1f", model.wakeAnimationDuration)
        }
        overlay?.alphaValue = effectOpacity(at: now)
        if previewPending { previewPending = false; previewUntil = now + 8 }
        update()
    }
    private func didRender(_ timing: RenderTiming) {
        renderFrames += 1
        gpuSeconds += timing.gpuDuration
        encodeSeconds += timing.submitted - timing.encodeStart
        if timing.moving && timing.succeeded && renderer?.renderingEnabled == true && state == .moving {
            if let previous = lastMotionSubmit { frameIntervals.append(timing.submitted - previous) }
            lastMotionSubmit = timing.submitted
        } else { lastMotionSubmit = nil }
        if frameIntervals.count > 20_000 { frameIntervals.removeFirst(frameIntervals.count - 20_000) }
        model.recorder.event("gpuSubmit", time: timing.submitted, duration: timing.submitted - timing.encodeStart,
            frameID: timing.frameID, sourceTime: timing.sensorTime)
        model.recorder.event("gpuStart", time: timing.gpuStart, duration: max(0, timing.gpuStart - timing.submitted),
            frameID: timing.frameID, sourceTime: timing.captureArrival)
        model.recorder.event("gpuComplete", time: timing.completed, duration: timing.gpuDuration,
            frameID: timing.frameID, sourceTime: timing.gpuEnd)
    }
    private func captureFailed(_ reason: String) {
        failures += 1
        retryAt = CACurrentMediaTime() + Double(min(failures, 3))
        invalidateCapture()
        desiredFPS = 0; revision += 1
        model.globalStatus = "捕获暂不可用：\(reason)"
        model.globalNotice = model.globalStatus
        if failures >= 3 {
            enabled = false; model.globalRunning = false
            model.settingsVisible = true; setupWindow?.makeKeyAndOrderFront(nil)
        }
        setCaptureFPS(0)
        update()
    }
    func screenConfigurationChanged() {
        guard let id = displayID else { update(); return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if screen == nil || screen?.frame != overlay?.frame ||
            screen.map({ $0.frame.size != captureSize }) == true {
            invalidateCapture()
            policy.reset()
        }
        update()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, desiredFPS > 0, streamGeneration == requestedGeneration,
              enabled, pauseReasons.isEmpty, type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        failures = 0
        captureFrames += 1
        model.recorder.event("captureArrival", time: now)
        if receivedFrame, let dirty = info[.dirtyRects] as? [Any], dirty.isEmpty { return }
        contentFrames += 1
        renderer?.receive(buffer, arrivalTime: now)
        if !receivedFrame {
            firstFrameWait = now - captureStartedAt
            firstFrameWaits.append(firstFrameWait)
            if firstFrameWaits.count > 100 { firstFrameWaits.removeFirst() }
            receivedFrame = true
            model.recorder.event("captureFirstFrame", time: now, duration: firstFrameWait)
            update()
        }
        // Subsequent content goes directly to the renderer's latest-frame mailbox.
        // No scheduler work is duplicated on every capture or display callback.
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.captureFailed(error.localizedDescription)
        }
    }
    private func writeDiagnostics() {
        guard let diagnosticPath else { return }
        let snapshot = model.sensor.snapshot, stats = model.sensor.worker.statistics()
        let intervals = frameIntervals.sorted()
        let info: [String: Any] = [
            "schema": 2, "time": CACurrentMediaTime(), "state": state.rawValue, "policy": decision.policy.rawValue,
            "requestedMode": model.performanceMode.rawValue, "onAC": power.onAC, "lowPower": power.lowPower,
            "captureFPS": appliedFPS, "captureFrames": captureFrames, "contentFrames": contentFrames,
            "renderFrames": renderFrames, "pyramidBuilds": renderer?.pyramidBuildCount ?? 0,
            "gpuSeconds": gpuSeconds, "encodeSeconds": encodeSeconds,
            "firstFrameWaits": firstFrameWaits, "firstPresentationWaits": firstPresentationWaits,
            "motionFrameIntervals": frameIntervals,
            "frameIntervalP95ms": intervals.isEmpty ? 0 : intervals[Int(Double(intervals.count - 1) * 0.95)] * 1000,
            "sensorBaseHz": configuredRate, "sensorActualHz": stats.actualHz,
            "sensorReads": stats.reads, "sensorValidReads": stats.validReads, "sensorChanges": stats.angleChanges,
            "sensorReadSeconds": stats.readSeconds, "sensorMaxReadSeconds": stats.maximumReadSeconds,
            "recording": model.recorder.status().enabled, "actualAngle": snapshot.sample.angle,
            "schedulerUpdates": schedulerUpdates, "configurationUpdates": configurationUpdates,
            "screenCaptureAllowed": CGPreflightScreenCaptureAccess(), "settingsVisible": model.settingsVisible,
            "pauseReasons": pauseReasons.sorted(), "wakeAnimationActive": desktopWake.isActive,
            "wakeAnimationDuration": model.wakeAnimationDuration,
            "wakeAnimationTilt": desktopWake.tilt(at: CACurrentMediaTime()) ?? 0,
            "overlayVisible": overlay?.isVisible == true && (overlay?.alphaValue ?? 0) > 0,
            "overlayOpacity": overlay?.alphaValue ?? 0,
            "continuousDrawing": renderer.map { !$0.isPaused && $0.renderingEnabled } ?? false,
            "captureSize": ["width": captureSize.width, "height": captureSize.height],
            "renderSize": ["width": renderer?.drawableSize.width ?? 0, "height": renderer?.drawableSize.height ?? 0],
            "absolutePhysicalLatencyMeasured": false
            , "validationScenario": validation?.scenario.rawValue ?? "none"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: diagnosticPath), options: .atomic)
        }
    }
    private func registerKeys() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let controller = Unmanaged<GlobalDesktopController>.fromOpaque(pointer).takeUnretainedValue()
            switch id.id {
            case 1: controller.emergencyStop()
            case 2: controller.toggle()
            case 3: controller.calibrate()
            default: break
            }
            return noErr
        }, 1, &event, pointer, &eventHandler)
        guard installed == noErr else { return }
        for (id, code) in [(UInt32(1), UInt32(kVK_Escape)), (2, UInt32(kVK_ANSI_G)), (3, UInt32(kVK_ANSI_K))] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(cmdKey | shiftKey),
                EventHotKeyID(signature: 0x48474C53, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                hotKeys.append(ref)
                if id == 1 { emergencyKeyRegistered = true }
            } else if id == 1 { break }
        }
    }
    enum GlobalError: LocalizedError {
        case noInternalDisplay, cannotExcludeSelf, noGPU
        var errorDescription: String? {
            switch self {
            case .noInternalDisplay: return "未找到内建屏幕"
            case .cannotExcludeSelf: return "无法排除自身捕获"
            case .noGPU: return "Metal 不可用"
            }
        }
    }
}
