import AppKit

final class FixtureView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
        bounds.fill()
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .semibold),
                                                      .foregroundColor: NSColor.black]
        ("MacBook Duo · 当前新版性能验证" as NSString).draw(at: NSPoint(x: 70, y: bounds.height - 110), withAttributes: heading)
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
                                                 .foregroundColor: NSColor.darkGray]
        ("固定测试桌面 / 真实 ScreenCaptureKit / 模拟开合 / 每项 60 秒" as NSString)
            .draw(at: NSPoint(x: 70, y: bounds.height - 154), withAttributes: text)
        ("⌘⇧Esc 紧急停止效果。此画面没有旧版着色器。" as NSString)
            .draw(at: NSPoint(x: 70, y: bounds.height - 190), withAttributes: text)
        for y in stride(from: 40, to: Int(bounds.height) - 240, by: 48) {
            for x in stride(from: 40, to: Int(bounds.width) - 40, by: 48) {
                ((x / 48 + y / 48) % 2 == 0 ? NSColor(calibratedRed: 0.2, green: 0.28, blue: 0.41, alpha: 1) : .white).setFill()
                NSRect(x: x, y: y, width: 48, height: 48).fill()
            }
        }
    }
}

@main struct DesktopFixture {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first(where: {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) != 0
        }) else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .white
        window.contentView = FixtureView(frame: screen.frame)
        window.orderFrontRegardless()
        NSApp.run()
    }
}
