import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuartzCore

@MainActor
final class AppModel: ObservableObject {
    enum Page {
        case setup
        case test
    }

    enum SettingsPage: String, CaseIterable, Identifiable {
        case effect = "效果", appearance = "外观", wallpaper = "壁纸", advanced = "高级"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .effect: return "rectangle.on.rectangle"
            case .appearance: return "slider.horizontal.3"
            case .wallpaper: return "photo"
            case .advanced: return "gearshape"
            }
        }
    }
    @Published var settingsPage: SettingsPage = .effect
    @Published var effectSummary = "已关闭"
    @Published var wallpaperImage: NSImage?
    @Published var screenshotMessage = ""
    @Published var recordingMessage = ""
    var pageChanged: ((Page) -> Void)?
    @Published var page: Page = .setup { didSet { if oldValue != page { pageChanged?(page) } } }
    @Published var desktopImage: NSImage?
    @Published var importedFileName = ""
    @Published var wallpaperFileName = ""
    @Published var wallpaperStatus = "使用 Duo 默认背景"
    @Published var useSensor = true
    @Published var simulatedAngle = 105.0
    @Published var controlsHidden = false
    @Published var showOriginal = false
    @Published var calibrationMessage = ""
    @Published var openAngle = 120.0 { didSet { runtimeSettingsChanged?() } }
    @Published var globalNotice = ""
    @Published var globalStatus = "实时桌面模式需要屏幕录制权限"
    @Published var globalRunning = false
    @Published var permissionsPreparing = true
    @Published var performanceMode = PerformanceMode(rawValue: UserDefaults.standard.string(forKey: "performanceMode") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(performanceMode.rawValue, forKey: "performanceMode"); runtimeSettingsChanged?() }
    }
    @Published var desktopWakeDuration = DesktopWakeAnimation.validDuration(
        UserDefaults.standard.double(forKey: "desktopWakeDuration")) {
        didSet {
            UserDefaults.standard.set(desktopWakeDuration, forKey: "desktopWakeDuration")
            runtimeSettingsChanged?()
        }
    }
    @Published var effectivePolicy = "正在检测电源…"
    @Published var effectiveRenderFPS = 60
    @Published var predictionEnabled = UserDefaults.standard.object(forKey: "predictionEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(predictionEnabled, forKey: "predictionEnabled"); runtimeSettingsChanged?() }
    }
    @Published var frost = UserDefaults.standard.object(forKey: "frost") as? Double ?? 0.09 {
        didSet { UserDefaults.standard.set(frost, forKey: "frost"); runtimeSettingsChanged?() }
    }
    @Published var edgeSoftness = UserDefaults.standard.object(forKey: "edgeSoftness") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(edgeSoftness, forKey: "edgeSoftness"); runtimeSettingsChanged?() }
    }
    @Published var recordingEnabled = false
    @Published var recordingStatus = "正在准备本地采集…"
    @Published var runtimeStatus = "已关闭"
    @Published var settingsVisible = true {
        didSet { sensor.setUIVisible(settingsVisible); runtimeSettingsChanged?() }
    }
    var runtimeSettingsChanged: (() -> Void)?
    let power = PowerMonitor()
    let recorder: MotionRecorder
    var toggleGlobal: (() -> Void)?
    var startGlobal: (() -> Void)?
    var previewGlobal: (() -> Void)?
    var calibrateGlobal: (() -> Void)?
    var hideSettings: (() -> Void)?
    private var wallpaperBridgeWriter: WallpaperBridgeWriter?

    var currentAngle: Double { useSensor && sensor.isAvailable ? sensor.angle : simulatedAngle }

    func saveOpenAngle() {
        let snapshot = sensor.snapshot
        let value = useSensor && snapshot.sample.valid ? snapshot.sample.angle : simulatedAngle
        guard value.isFinite, value >= 1, value <= 180 else {
            calibrationMessage = "请先打开屏幕，再保存展开终点"
            controlsHidden = false
            return
        }
        sensor.reset()
        recorder.breakSegment(reason: "calibration")
        openAngle = value
        UserDefaults.standard.set(value, forKey: "calibratedOpenAngle")
        calibrationMessage = "已保存展开位置：\(Int(value.rounded()))°"
    }

    @discardableResult
    func savePhysicalOpenAngle() -> Bool {
        let snapshot = sensor.snapshot
        guard snapshot.sample.valid,
              CACurrentMediaTime() - snapshot.lastValid < 0.5 else {
            calibrationMessage = "暂时没有有效的屏幕角度，请稍后重试"
            return false
        }
        guard sensor.snapshot.sample.angle >= 1, sensor.snapshot.sample.angle <= 180 else {
            calibrationMessage = "请先打开屏幕，再保存完全展开位置"
            return false
        }
        useSensor = true
        saveOpenAngle()
        return true
    }

    let sensor = LidAngleSensor()

    init(startServices: Bool = true, recorder: MotionRecorder? = nil) {
        self.recorder = recorder ?? MotionRecorder()
        let saved = UserDefaults.standard.object(forKey: "calibratedOpenAngle") as? Double
            ?? UserDefaults(suiteName: "studio.prototype.HingeGlass")?.double(forKey: "calibratedOpenAngle") ?? 120
        if saved >= 1 && saved <= 180 { openAngle = saved }
        let recorder = self.recorder
        recorder.setContext(RecordingContext(endpoint: openAngle, mode: performanceMode.rawValue,
            policy: performanceMode.resolved(onAC: power.onAC, lowPower: power.lowPower).rawValue,
            onAC: power.onAC, prediction: predictionEnabled, state: EffectState.off.rawValue,
            lowPower: power.lowPower))
        sensor.worker.onSample = { snapshot in recorder.ingest(snapshot) }
        recorder.onStatusChange = { [weak self] in
            Task { @MainActor in
                self?.refreshRecordingStatus()
                self?.runtimeSettingsChanged?()
            }
        }
        guard startServices else { return }
        sensor.start()
        wallpaperBridgeWriter = WallpaperBridgeWriter(worker: sensor.worker)
        wallpaperBridgeWriter?.start()
        refreshWallpaperStatus()
        refreshRecordingStatus()
    }

    func refreshRecordingStatus() {
        recorder.tick()
        let s = recorder.status()
        if recordingEnabled != s.enabled { recordingEnabled = s.enabled }
        let days = max(0, Int(ceil((s.deadline?.timeIntervalSinceNow ?? 0) / 86400)))
        let message = "\(s.enabled ? "采集中" : "已停止") · 剩余 \(days) 天 · \(s.actions) 次动作 · \(String(format: "%.1f", Double(s.bytes)/1_000_000)) MB"
        let text = [s.error ?? s.stopReason, message].compactMap { $0 }.joined(separator: "\n")
        if recordingStatus != text { recordingStatus = text }
    }
    func toggleRecording() { recorder.setEnabled(!recorder.status().enabled); refreshRecordingStatus() }
    func beginRecording() { recorder.setEnabled(true, newPeriod: true); refreshRecordingStatus() }
    func exportRecording() {
        let panel = NSOpenPanel()
        panel.title = "选择导出位置"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = url.appendingPathComponent("MacBook-Duo-Motion-\(Int(Date().timeIntervalSince1970))")
        recorder.export(to: destination) { [weak self] error in
            Task { @MainActor in self?.recordingMessage = error.map { "导出失败：\($0)" } ?? "已导出到 \(destination.path)" }
        }
    }
    func clearRecording() {
        let alert = NSAlert()
        alert.messageText = "清空全部开合记录？"; alert.informativeText = "将停止采集并删除本地角度数据。请先导出需要保留的记录。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空记录")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        recorder.clear { [weak self] error in
            Task { @MainActor in self?.refreshRecordingStatus(); self?.recordingMessage = error ?? "已清空记录" }
        }
    }
    func resetAppearance() { frost = 0.09; edgeSoftness = 1 }

    func refreshWallpaperStatus() {
        let url = DuoWallpaperPaths.customWallpaperURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            wallpaperFileName = ""
            wallpaperStatus = "使用 Duo 默认背景"
            wallpaperImage = nil
            return
        }
        wallpaperFileName = UserDefaults.standard.string(forKey: "wallpaper.fileName") ?? url.lastPathComponent
        wallpaperStatus = "已设置自定义壁纸"
        wallpaperImage = NSImage(contentsOf: url)
    }

    func importWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "选择锁屏壁纸"
        panel.message = "选择一张图片，作为系统墙纸中 Duo · 随开合变化的背景。"
        panel.prompt = "导入壁纸"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url), let data = wallpaperPNGData(image) else {
            wallpaperStatus = "导入失败：无法读取这张图片"
            return
        }
        do {
            try FileManager.default.createDirectory(at: DuoWallpaperPaths.documentsDirectory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: DuoWallpaperPaths.customWallpaperURL, options: .atomic)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "wallpaper.fileName")
            wallpaperFileName = url.lastPathComponent
            wallpaperStatus = "壁纸已更新"
            wallpaperImage = NSImage(data: data)
        } catch {
            wallpaperStatus = "导入失败：\(error.localizedDescription)"
        }
    }

    private func wallpaperPNGData(_ image: NSImage) -> Data? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let original = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              original.width > 0, original.height > 0 else { return nil }
        let maxDimension = 2560.0
        let scale = min(1.0, maxDimension / Double(max(original.width, original.height)))
        let width = max(1, Int((Double(original.width) * scale).rounded()))
        let height = max(1, Int((Double(original.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    func importScreenshot() {
        let panel = NSOpenPanel()
        panel.title = "选择桌面截图"
        panel.message = "请选择一张完整的桌面截图，用作玻璃层下方的内容。"
        panel.prompt = "导入截图"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            screenshotMessage = "导入失败：无法读取这张图片"
            return
        }
        screenshotMessage = ""
        desktopImage = image
        importedFileName = url.lastPathComponent
    }

    func startTest() {
        guard desktopImage != nil else { return }
        controlsHidden = false
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
            page = .test
        }
    }

    func returnToSetup() {
        controlsHidden = false
        withAnimation(.easeInOut(duration: 0.3)) {
            page = .setup
        }
    }

    func toggleFullScreen() {
        guard let window = NSApp.keyWindow, let screen = window.screen else { return }
        window.setFrame(screen.frame, display: true)
    }
}
