import Foundation
import AppKit
import QuartzCore

/// Publishes the same motion snapshot used by the desktop renderer to the
/// bundled wallpaper extension. The file is created by the sandboxed extension;
/// the main app only opens it after it exists.
final class WallpaperBridgeWriter {
    private let worker: SensorWorker
    private let defaults: UserDefaults
    private var bridge: AngleBridge?
    private var timer: Timer?
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var locked: Bool
    private var lastSensorLease = -Double.infinity
    private var lastSessionCheck = -Double.infinity

    init(worker: SensorWorker,
         defaults: UserDefaults = .standard) {
        self.worker = worker
        self.defaults = defaults
        self.locked = Self.sessionIsLocked()
        let center = DistributedNotificationCenter.default()
        lockObserver = center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setLocked(true)
        }
        unlockObserver = center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setLocked(false)
        }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        if let lockObserver { center.removeObserver(lockObserver) }
        if let unlockObserver { center.removeObserver(unlockObserver) }
    }

    func start() {
        guard timer == nil else { return }
        if locked { worker.setRate(30) }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.publish() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        publish()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        bridge = nil
    }

    private func publish() {
        let now = CACurrentMediaTime()
        if now - lastSessionCheck >= 0.25 {
            lastSessionCheck = now
            let currentLocked = Self.sessionIsLocked()
            if currentLocked != locked {
                locked = currentLocked
                lastSensorLease = -.infinity
            }
        }
        if locked, now - lastSensorLease >= 0.25 {
            // GlobalDesktopController deliberately suspends its sensor while
            // the session is locked. The wallpaper still needs fresh hinge
            // samples, so briefly renew the same worker's 30 Hz lease.
            worker.setRate(30)
            lastSensorLease = now
        }
        if bridge == nil {
            bridge = try? AngleBridge(url: DuoWallpaperPaths.angleBridgeURL, create: false)
        }
        let snapshot = worker.snapshot()
        let endpoint = defaults.object(forKey: "calibratedOpenAngle") as? Double ?? 120
        let predictionEnabled = defaults.object(forKey: "predictionEnabled") as? Bool ?? true
        let frost = defaults.object(forKey: "frost") as? Double ?? 0.09
        let softness = defaults.object(forKey: "edgeSoftness") as? Double ?? 1
        let awake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        _ = bridge?.write(WallpaperAngle(time: snapshot.sample.time, angle: snapshot.sample.angle,
            predicted: snapshot.predicted(at: now, enabled: predictionEnabled), endpoint: endpoint,
            frost: frost, softness: softness, valid: snapshot.sample.valid, awake: awake,
            wakeDuration: WakeAnimationTiming.validDuration(defaults.double(forKey: WakeAnimationTiming.defaultsKey))))
    }

    private func setLocked(_ value: Bool) {
        guard value != locked else { return }
        locked = value
        lastSessionCheck = CACurrentMediaTime()
        lastSensorLease = -.infinity
        publish()
    }

    private static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true ||
            session[kCGSessionOnConsoleKey as String] as? Bool == false
    }
}
