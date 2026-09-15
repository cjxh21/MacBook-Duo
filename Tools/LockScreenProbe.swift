import AppKit
import ScreenCaptureKit
import CoreMedia

// Standalone feasibility probe. Never draws captured pixels or saves images.
final class Probe: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var panel: NSPanel?
    var timer: Timer?
    var locked = false
    var frames = 0
    var completeFrames = 0
    var observers: [NSObjectProtocol] = []
    let started = ProcessInfo.processInfo.systemUptime
    func log(_ event: String) {
        print(String(format: "%.2f %@", ProcessInfo.processInfo.systemUptime - started, event))
        fflush(stdout)
    }
    func begin(preview: Bool = false, windowOnly: Bool = false) {
        let rect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let p = NSPanel(contentRect: NSRect(x: rect.minX + 24, y: rect.maxY - 90, width: 300, height: 46),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.backgroundColor = .systemTeal
        // Same public window level as the app; no shielding-level tricks.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let label = NSTextField(labelWithString: windowOnly ? "Duo 锁屏探针 · 5 分钟自动退出" : "Duo 锁屏探针 · 120 秒自动退出")
        label.frame = NSRect(x: 10, y: 12, width: 285, height: 24)
        p.contentView?.addSubview(label)
        panel = p
        if preview {
            p.orderFrontRegardless()
            if let view = p.contentView {
                view.wantsLayer = true
                view.layer?.backgroundColor = p.backgroundColor?.cgColor
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: "Validation/lock-screen-marker.png"))
                    }
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
                p.orderOut(nil)
                NSApp.terminate(nil)
            }
            log("marker preview only; no capture; exits in 30 seconds")
            return
        }
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.locked = value
                self.log("locked=\(value)")
                if value { self.panel?.orderFrontRegardless() } else { self.panel?.orderOut(nil) }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.log("locked=\(self.locked) callbacks=\(self.frames) complete=\(self.completeFrames) windowOrdered=\(self.panel?.isVisible == true) [ordered does not prove visible on lock screen]")
            if ProcessInfo.processInfo.systemUptime - self.started >= (windowOnly ? 300 : 120) {
                self.panel?.orderOut(nil)
                NSApp.terminate(nil)
            }
        }
        if windowOnly {
            log("window-only lock test armed; no capture; exits in 300 seconds")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            log("capture permission unavailable for probe; no prompt requested; window-only check")
            return
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
                    self.log("no built-in display"); return
                }
                let config = SCStreamConfiguration()
                config.width = 160; config.height = 100
                config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
                config.capturesAudio = false; config.showsCursor = false
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
                self.stream = s
                try await s.startCapture()
                self.log("capture started; buffers discarded, no image persistence")
            } catch { self.log("capture failed: \(error.localizedDescription)") }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        frames += 1
        if let a = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = a.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue { completeFrames += 1 }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.log("stream stopped: \(error.localizedDescription)") }
    }
}

@main struct LockScreenProbe {
    static func main() {
        let preview = CommandLine.arguments.contains("--preview-marker")
        guard preview || CommandLine.arguments.contains("--allow-lock-screen-test") else {
            print("Not started. When user is ready, pass --allow-lock-screen-test. User locks manually; marker only appears after lock. Auto-exit after 120 seconds.")
            return
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let probe = Probe()
        probe.begin(preview: preview, windowOnly: CommandLine.arguments.contains("--window-only"))
        withExtendedLifetime(probe) { NSApp.run() }
    }
}
