import Foundation

/// Desktop-only wake cycle. The animation clock starts on first GPU presentation.
struct DesktopWakeAnimation {
    static let durations = WakeAnimationTiming.durations
    static func validDuration(_ value: Double) -> Double {
        WakeAnimationTiming.validDuration(value)
    }
    private var sleepReasons = Set<String>()
    private var locked = false
    private var armed = false
    private var awaitingUnlockAt: Double?
    private var pendingAt: Double?
    private var startedAt: Double?
    private var duration = 0.9
    var isActive: Bool { pendingAt != nil || startedAt != nil }
    var deadline: Double? {
        if let start = startedAt { return start + duration }
        if let wake = awaitingUnlockAt { return wake + 1 }
        return pendingAt.map { $0 + 8 }
    }
    mutating func cancel() {
        sleepReasons.removeAll()
        armed = false
        awaitingUnlockAt = nil
        pendingAt = nil
        startedAt = nil
    }
    mutating func event(reason: String, pausing: Bool, eligible: Bool, at now: Double) {
        if reason == "lock" { locked = pausing }
        guard eligible else {
            cancel()
            return
        }
        if reason == "lock" {
            if pausing {
                // Idle display sleep can lock the session even inside the
                // password grace period. Keep a cycle armed by the desktop.
                if sleepReasons.isEmpty && awaitingUnlockAt == nil { cancel() }
            } else if let wake = awaitingUnlockAt {
                awaitingUnlockAt = nil
                if now - wake < 1 { pendingAt = now }
            }
            return
        }
        // Session activation notifications can bracket display sleep without
        // locking. They must not discard the observed sleep/wake cycle.
        guard reason == "display" || reason == "system" else { return }
        if pausing {
            if sleepReasons.isEmpty {
                pendingAt = nil; startedAt = nil; awaitingUnlockAt = nil
                armed = !locked
            }
            sleepReasons.insert(reason)
        } else if sleepReasons.remove(reason) != nil, sleepReasons.isEmpty {
            if armed {
                if locked { awaitingUnlockAt = now }
                else { pendingAt = now }
            }
            armed = false
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
        return WakeAnimationTiming.tilt(elapsed: now - start, duration: duration)
    }
}
