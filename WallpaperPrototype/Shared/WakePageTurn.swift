import Foundation

/// One animation per observed display sleep/wake cycle. Waiting for a fresh
/// hinge sample avoids playing against stale data immediately after wake.
struct WakePageTurn {
    private(set) var awake = true
    private var pendingAt: Double?
    private var startedAt: Double?
    private var slept = false

    mutating func setAwake(_ value: Bool, at now: Double) {
        guard value != awake else { return }
        awake = value
        if !value {
            slept = true
            pendingAt = nil
            startedAt = nil
        } else if slept {
            pendingAt = now
            slept = false
        }
    }

    mutating func tilt(at now: Double, locked: Bool, sample: WallpaperAngle?) -> Double? {
        guard awake else { return nil }
        if let pending = pendingAt {
            if now - pending > 2 {
                pendingAt = nil
            } else if locked, let sample, sample.fresh(at: now) {
                pendingAt = nil
                // A lid still opening should keep following the real sensor.
                if sample.angle >= HingeMotion.clearAngle(endpoint: sample.endpoint) {
                    startedAt = now
                }
            }
        }
        guard let start = startedAt else { return nil }
        guard locked, let sample, sample.fresh(at: now),
              sample.angle >= HingeMotion.clearAngle(endpoint: sample.endpoint),
              now - start < 0.9 else {
            startedAt = nil
            return nil
        }
        let progress = min(1, max(0, (now - start) / 0.9))
        return 65 * pow(1 - progress, 3)
    }
}
