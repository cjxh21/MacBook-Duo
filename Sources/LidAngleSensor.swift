import Foundation
import Combine
import IOKit.hid
import QuartzCore

struct SensorStatistics: Codable, Sendable {
    var reads = 0
    var validReads = 0
    var angleChanges = 0
    var readSeconds = 0.0
    var maximumReadSeconds = 0.0
    var actualHz = 0
}

// Device discovery, feature reads, timers and close all belong to this queue.
// The UI and display link only copy a small, locked snapshot.
final class SensorWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "duo.hinge", qos: .userInteractive)
    private let lock = NSLock()
    private var value = MotionSnapshot()
    private var statisticsValue = SensorStatistics()
    private var estimator = MotionEstimator()
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private var hz = 0
    private var baseHz = 0
    private var wasMoving = false
    private var report = [UInt8](repeating: 0, count: 8)
    private var lastDiscovery = -Double.infinity
    // Install these before starting the worker; callbacks never touch SwiftUI.
    var onSample: (@Sendable (MotionSnapshot) -> Void)?
    var onStateChange: (@Sendable () -> Void)?

    func snapshot() -> MotionSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    func statistics() -> SensorStatistics { lock.lock(); defer { lock.unlock() }; return statisticsValue }
    func setRate(_ rate: Int) {
        queue.async { [self] in
            baseHz = max(0, min(120, rate))
            if baseHz == 0 {
                schedule(0)
                closeDevices()
                estimator.reset(invalidate: true)
                publish()
            } else {
                schedule(estimator.snapshot.moving(at: CACurrentMediaTime()) ? 120 : baseHz)
            }
        }
    }
    func reset(invalidate: Bool = false) {
        queue.async { [self] in
            estimator.reset(invalidate: invalidate)
            wasMoving = false
            publish()
            onStateChange?()
        }
    }
    func shutdown() {
        queue.sync {
            baseHz = 0
            schedule(0)
            closeDevices()
        }
    }
    private func closeDevices() {
        if let device { IOHIDDeviceClose(device, 0) }
        if let manager { IOHIDManagerClose(manager, 0) }
        device = nil
        manager = nil
        lastDiscovery = -.infinity
    }
    private func schedule(_ rate: Int) {
        guard rate != hz else { return }
        hz = rate
        lock.lock(); statisticsValue.actualHz = rate; lock.unlock()
        timer?.cancel(); timer = nil
        guard rate > 0 else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1 / Double(rate), leeway: .microseconds(300))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }
    private func discover() {
        lastDiscovery = CACurrentMediaTime()
        if manager == nil {
            let candidate = IOHIDManagerCreate(kCFAllocatorDefault, 0)
            IOHIDManagerSetDeviceMatching(candidate,
                [kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8A] as CFDictionary)
            guard IOHIDManagerOpen(candidate, 0) == kIOReturnSuccess else { return }
            manager = candidate
        }
        guard let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }
            var probe = [UInt8](repeating: 0, count: 8)
            var size = probe.count
            if IOHIDDeviceGetReport(candidate, kIOHIDReportTypeFeature, 1, &probe, &size) == kIOReturnSuccess && size >= 3 {
                device = candidate
                return
            }
            IOHIDDeviceClose(candidate, 0)
        }
    }
    private func publish() { lock.lock(); value = estimator.snapshot; lock.unlock() }
    private func poll() {
        if device == nil && CACurrentMediaTime() - lastDiscovery >= 2 { discover() }
        let previous = estimator.snapshot
        var length = report.count
        let start = CACurrentMediaTime()
        let result = device.map { IOHIDDeviceGetReport($0, kIOHIDReportTypeFeature, 1, &report, &length) }
        let now = CACurrentMediaTime()
        let raw: UInt16? = result == kIOReturnSuccess && length >= 3 ? UInt16(report[2]) << 8 | UInt16(report[1]) : nil
        var angle = raw.map(Double.init) ?? previous.sample.angle
        if angle > 360 { angle /= 100 }
        let valid = raw != nil && angle.isFinite && (0...180).contains(angle)
        let sample = MotionSample(time: now, raw: raw, angle: angle,
                                  readDuration: now - start, valid: valid)
        estimator.ingest(sample)
        let changed = valid && previous.sample.valid && angle != previous.sample.angle
        lock.lock()
        statisticsValue.reads += 1
        if valid { statisticsValue.validReads += 1 }
        if changed { statisticsValue.angleChanges += 1 }
        statisticsValue.readSeconds += sample.readDuration
        statisticsValue.maximumReadSeconds = max(statisticsValue.maximumReadSeconds, sample.readDuration)
        value = estimator.snapshot
        lock.unlock()
        onSample?(estimator.snapshot)
        let moving = estimator.snapshot.moving(at: now)
        if changed || valid != previous.sample.valid || moving != wasMoving {
            onStateChange?()
        }
        wasMoving = moving
        if !valid && now - estimator.snapshot.lastValid > 2, let device {
            IOHIDDeviceClose(device, 0)
            self.device = nil
        }
        schedule(baseHz == 0 ? 0 : (moving ? 120 : baseHz))
    }
}

@MainActor
final class LidAngleSensor: ObservableObject {
    @Published private(set) var angle = 105.0
    @Published private(set) var velocity = 0.0
    @Published private(set) var isAvailable = false
    @Published private(set) var statusText = "正在查找铰链传感器…"
    let worker = SensorWorker()
    let motionEvents = PassthroughSubject<Void, Never>()
    private let notifications = DispatchSource.makeUserDataAddSource(queue: .main)
    private var uiTimer: Timer?
    private var lastUIUpdate = -Double.infinity
    var snapshot: MotionSnapshot { worker.snapshot() }
    var lastSuccessfulUpdate: Date {
        Date().addingTimeInterval(-(CACurrentMediaTime() - snapshot.lastValid))
    }
    init() {
        let notifications = self.notifications
        worker.onStateChange = { notifications.add(data: 1) }
        notifications.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.motionEvents.send()
                if self.uiTimer != nil { self.refresh() }
            }
        }
        notifications.resume()
    }
    func start() { worker.setRate(30); setUIVisible(true) }
    func setUIVisible(_ visible: Bool) {
        if !visible { uiTimer?.invalidate(); uiTimer = nil; return }
        guard uiTimer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        uiTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func setRate(_ rate: Int) { worker.setRate(rate) }
    func reset(invalidate: Bool = false) { worker.reset(invalidate: invalidate) }
    func shutdown() { uiTimer?.invalidate(); uiTimer = nil; worker.shutdown() }
    private func refresh() {
        let now = CACurrentMediaTime()
        guard now - lastUIUpdate >= 0.1 - 0.00001 else { return }
        lastUIUpdate = now
        let s = snapshot
        let available = s.sample.valid && now - s.lastValid < 0.5
        if available, angle != s.sample.angle { angle = s.sample.angle }
        if velocity != s.velocity { velocity = s.velocity }
        if isAvailable != available { isAvailable = available }
        let text = available ? "您的设备支持铰链传感器" : "等待有效铰链数据 · 可使用截图模拟"
        if statusText != text { statusText = text }
    }
}
