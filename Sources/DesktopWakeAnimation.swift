import Foundation

/// Desktop-only wake cycle. The animation clock starts on first GPU presentation.
struct DesktopWakeAnimation {
    static let durations: [Double] = [0.3, 0.6, 0.9, 1.5, 2, 3]
    static func validDuration(_ value: Double) -> Double {
        durations.contains(value) ? value : 0.9
    }
    private var slept = false
    private var pendingAt: Double?
    private var startedAt: Double?
    private var duration = 0.9
    var isActive: Bool { pendingAt != nil || startedAt != nil }
    var deadline: Double? {
        if let start = startedAt { return start + duration }
        return pendingAt.map { $0 + 8 }
    }
    mutating func cancel() {
        slept = false
        pendingAt = nil
        startedAt = nil
    }
    mutating func event(reason: String, pausing: Bool, eligible: Bool, at now: Double) {
        if !eligible || ((reason == "lock" || reason == "session") && pausing) {
            cancel()
            return
        }
        guard reason == "display" else { return }
        if pausing {
            cancel()
            slept = true
        } else if slept {
            slept = false
            pendingAt = now
        }
    }
    mutating func advance(at now: Double, allowed: Bool) {
        if !allowed || deadline.map({ now >= $0 }) == true { cancel() }
    }
    mutating func present(at now: Double, duration: Double) {
        guard pendingAt != nil else { return }
        pendingAt = nil
        startedAt = now
        self.duration = Self.validDuration(duration)
    }
    func tilt(at now: Double) -> Double? {
        if pendingAt != nil { return 65 }
        guard let start = startedAt else { return nil }
        let progress = min(1, max(0, (now - start) / duration))
        return 65 * pow(1 - progress, 3)
    }
}
