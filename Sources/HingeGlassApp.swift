import SwiftUI
import AppKit

#if !UI_VALIDATION
@main
struct HingeGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: DesktopWindow?
    private var model: AppModel?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var globalController: GlobalDesktopController?
    private var settingsFrame: NSRect?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // This is a menu-bar/background app with a live hinge sensor and an
        // optional wallpaper bridge. AppKit must not reap it while its setup
        // window is hidden; relaunching would reset the runtime state and can
        // briefly recreate a screen-capture session.
        ProcessInfo.processInfo.disableAutomaticTermination("MacBook Duo background services")
        ProcessInfo.processInfo.disableSuddenTermination()
        let model = AppModel()
        self.model = model
        model.globalStatus = "正在检查首次启动的屏幕录制权限…"
        Task { @MainActor in
            let message = await ScreenCapturePermissionPreparation.prepare()
            model.globalStatus = message ?? "实时桌面模式需要屏幕录制权限"
            model.globalNotice = message ?? (CGPreflightScreenCaptureAccess() ? "" : "启用效果需要屏幕录制权限。")
            model.permissionsPreparing = false
        }
        let window = DesktopWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = "MacBook Duo"
        if let iconURL = Bundle.main.url(forResource: "MacBookDuo", withExtension: "png") {
            NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
        }
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.contentMinSize = NSSize(width: 720, height: 540)
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone]
        window.center()
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: RootView(model: model))
        // Window geometry belongs to AppKit, not the intrinsic size of a transient page.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        self.window = window
        let globalController = GlobalDesktopController(model: model, setupWindow: window)
        self.globalController = globalController
        model.toggleGlobal = { [weak globalController] in globalController?.toggle() }
        model.pageChanged = { [weak self] page in self?.configureWindow(for: page) }
        model.startGlobal = { [weak globalController] in globalController?.start() }
        model.previewGlobal = { [weak globalController] in globalController?.preview() }
        model.calibrateGlobal = { [weak globalController] in globalController?.calibrate() }
        model.hideSettings = { [weak globalController] in globalController?.hideSetup() }
        NSApp.presentationOptions = []
        NSApp.setActivationPolicy(.accessory)
        keepWindowVisible()
        if CommandLine.arguments.contains("--background") {
            globalController.hideSetup()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if CommandLine.arguments.contains("--start-effects") {
            Task { @MainActor in
                while model.permissionsPreparing { try? await Task.sleep(for: .milliseconds(100)) }
                globalController.start(automatically: true)
            }
        }
        // Handle before AppKit's default Command-H (which hides the whole app).
        // Restricted to this window so file dialogs retain their own shortcuts.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow === self.window, let model = self.model else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "h" {
                if model.page == .test && !event.isARepeat { model.controlsHidden.toggle() }
                return nil
            }
            if modifiers == .command {
                if event.charactersIgnoringModifiers == "," { self.globalController?.showSetup(); return nil }
                if event.charactersIgnoringModifiers?.lowercased() == "q" { NSApp.terminate(nil); return nil }
                if event.charactersIgnoringModifiers?.lowercased() == "w", model.page == .setup {
                    self.globalController?.hideSetup(); return nil
                }
            }
            guard model.page == .test else { return event }
            if modifiers == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "k":
                    if !event.isARepeat { model.saveOpenAngle() }
                    return nil
                case "b":
                    if !event.isARepeat { model.showOriginal.toggle() }
                    return nil
                default: break
                }
            }
            if event.keyCode == 53 {
                model.controlsHidden = false
                return nil
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.globalController?.screenConfigurationChanged() }
            MainActor.assumeIsolated { self?.keepWindowVisible() }
        }
    }

    @MainActor private func configureWindow(for page: AppModel.Page) {
        guard let window else { return }
        switch page {
        case .test:
            settingsFrame = window.frame
            window.contentMinSize = .zero
            window.styleMask = [.borderless]
            window.hasShadow = false
            if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.frame, display: true) }
        case .setup:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "MacBook Duo"
            window.contentMinSize = NSSize(width: 720, height: 540)
            window.hasShadow = true
            if let settingsFrame { window.setFrame(settingsFrame, display: true) }
            keepWindowVisible()
        }
    }

    @MainActor private func keepWindowVisible() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if model?.page == .test {
            window.setFrame(screen.frame, display: true)
            return
        }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        globalController?.hideSetup()
        return false
    }

    @MainActor @objc private func openSettings() {
        globalController?.showSetup()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "打开设置", action: #selector(openSettings), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        globalController?.showSetup()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalController?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
