import AppKit
import SwiftUI

// Build with UI_VALIDATION. Isolated recording storage; no sensor, capture,
// wallpaper bridge, permission preparation, or global hot-key registration.
@main
struct UIValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "duo.ui.validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let recorder = MotionRecorder(directory: temporary, defaults: defaults)
        let model = AppModel(startServices: false, recorder: recorder)
        model.permissionsPreparing = false
        model.globalNotice = ""
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MacBook Duo · UI Validation"
        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        let controller = GlobalDesktopController(model: model, setupWindow: window, startServices: false)
        defer {
            controller.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        if CommandLine.arguments.contains("--interactive") {
            window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if CommandLine.arguments.contains("--menu") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    controller.refreshValidationMenu()
                    controller.validationMenu.popUp(positioning: nil, at: NSPoint(x: 30, y: 400), in: host)
                }
            }
            NSApp.run()
            return
        }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func capture(_ name: String) throws {
            settle()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 820, height: 620), NSSize(width: 720, height: 540)] {
                window.setContentSize(size)
                for page in AppModel.SettingsPage.allCases {
                    model.settingsPage = page
                    try capture("fixture-\(name)-\(Int(size.width))-\(page.id)")
                    precondition(host.bounds.size == size, "Page must not resize its window")
                }
            }
        }
        model.settingsPage = .effect
        model.permissionsPreparing = true
        try capture("fixture-permissions-preparing")
        model.permissionsPreparing = false
        model.globalNotice = "捕获暂不可用：屏幕录制权限未授予，请在系统设置中允许 MacBook Duo。"
        try capture("fixture-permission-error")
        model.settingsPage = .wallpaper
        model.wallpaperFileName = String(repeating: "很长的壁纸文件名", count: 12) + ".png"
        model.wallpaperStatus = "导入失败：无法读取这张图片"
        try capture("fixture-wallpaper-error-long-name")
        model.settingsPage = .advanced
        model.screenshotMessage = "导入失败：无法读取这张图片"
        model.recordingMessage = "导出失败：所选目录不可写入"
        try capture("fixture-operation-errors")
        let menu = controller.validationMenu
        controller.refreshValidationMenu()
        let visible = menu.items.filter { !$0.isSeparatorItem }
        precondition(visible.count == 9)
        precondition(visible[1].title == "启用效果")
        precondition(visible[1].keyEquivalent == "g")
        precondition(visible[1].keyEquivalentModifierMask == [.command, .shift])
        precondition(visible[4].submenu?.items.count == 4)
        precondition(visible[4].submenu?.items.filter { $0.state == .on }.count == 1)
        precondition(visible[5].title == "息屏唤醒动画耗时")
        precondition(visible[5].submenu?.items.count == DesktopWakeAnimation.durations.count)
        precondition(visible[5].submenu?.items.filter { $0.state == .on }.count == 1)
        precondition(visible[6].keyEquivalent == ",")
        precondition(visible[7].keyEquivalent == "\u{1b}")
        model.permissionsPreparing = true
        precondition(!controller.validateMenuItem(visible[1]))
        precondition(!controller.validateMenuItem(visible[2]))
        precondition(!controller.validateMenuItem(visible[3]))
        controller.refreshValidationMenu()
        precondition(!visible[1].isEnabled)
        model.permissionsPreparing = false
        recorder.setEnabled(true, newPeriod: true)
        settle()
        model.refreshRecordingStatus()
        precondition(model.recordingEnabled)
        recorder.setEnabled(false)
        settle()
        model.refreshRecordingStatus()
        precondition(!model.recordingEnabled)
        try menu.items.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: "\n")
            .write(to: output.appendingPathComponent("menu.txt"), atomically: true, encoding: .utf8)
        print("PASS: 16 page/appearance/size renders, four error fixtures, fixed geometry, native menu structure/shortcuts/checkmarks, isolated recording toggles")
    }
}
