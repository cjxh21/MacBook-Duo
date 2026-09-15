import AppKit

@main struct DuoWallpaperHost {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Duo Lab"
        let menu = NSMenu()
        let quit = NSMenuItem(title: "退出锁屏实验", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; menu.addItem(quit); status.menu = menu
        let worker = SensorWorker()
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/studio.prototype.DuoWallpaper.extension/Data/Documents")
        var bridge: AngleBridge?
        let defaults = UserDefaults(suiteName: "studio.prototype.HingeGlass.Global")!
        let timer = Timer.scheduledTimer(withTimeInterval: 1 / 30.0, repeats: true) { _ in
            if bridge == nil { bridge = try? AngleBridge(url: directory.appendingPathComponent("duo-state.bin"), create: false) }
            let now = CACurrentMediaTime()
            let snapshot = worker.snapshot()
            let endpoint = defaults.object(forKey: "calibratedOpenAngle") as? Double ?? 120
            let predictionEnabled = defaults.object(forKey: "predictionEnabled") as? Bool ?? true
            let frost = defaults.object(forKey: "frost") as? Double ?? 0.09
            let softness = defaults.object(forKey: "edgeSoftness") as? Double ?? 1
            let awake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
            bridge?.write(WallpaperAngle(time: snapshot.sample.time, angle: snapshot.sample.angle,
                predicted: snapshot.predicted(at: now, enabled: predictionEnabled), endpoint: endpoint,
                frost: frost, softness: softness, valid: snapshot.sample.valid, awake: awake))
        }
        worker.setRate(30)
        withExtendedLifetime((worker, timer, status)) { NSApp.run() }
        worker.shutdown()
    }
}
