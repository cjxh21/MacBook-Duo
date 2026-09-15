import Foundation

@main
struct DesktopWakeAnimationTests {
    static func main() {
        var animation = DesktopWakeAnimation()
        animation.event(reason: "display", pausing: false, eligible: true, at: 0)
        assert(!animation.isActive, "A wake without sleep must not animate")
        animation.event(reason: "display", pausing: true, eligible: true, at: 1)
        assert(animation.needsCover && !animation.isActive, "Prepare black coverage before wake")
        animation.event(reason: "display", pausing: false, eligible: true, at: 2)
        assert(animation.tilt(at: 3) == 90, "Wait for the fresh GPU frame")
        assert(animation.needsCover, "Keep black coverage until the first GPU frame")
        animation.present(at: 3, duration: 2)
        assert(!animation.needsCover, "A GPU-ready animation takes over from the cover")
        assert(abs(animation.tilt(at: 4)! - 45) < 0.0001)
        animation.event(reason: "display", pausing: false, eligible: true, at: 4)
        assert(animation.deadline == 5, "Duplicate wake must not restart")
        animation.advance(at: 5, allowed: true)
        assert(!animation.isActive)
        for duration in DesktopWakeAnimation.durations {
            var previousAngle = 90.0
            for step in 0...100 {
                let angle = WakeAnimationTiming.tilt(elapsed: duration * Double(step) / 100, duration: duration)
                assert(angle <= previousAngle + 0.000001 && angle >= 0)
                previousAngle = angle
            }
            assert(abs(WakeAnimationTiming.tilt(elapsed: duration / 2, duration: duration) - 45) < 0.00001)
            animation.event(reason: "display", pausing: true, eligible: true, at: 10)
            animation.event(reason: "display", pausing: false, eligible: true, at: 11)
            animation.present(at: 12, duration: duration)
            assert(animation.deadline == 12 + duration)
            animation.advance(at: 12 + duration, allowed: true)
            assert(!animation.isActive)
        }
        animation.event(reason: "display", pausing: true, eligible: true, at: 20)
        animation.event(reason: "lock", pausing: true, eligible: true, at: 21)
        animation.event(reason: "display", pausing: false, eligible: false, at: 22)
        animation.event(reason: "lock", pausing: false, eligible: true, at: 23)
        assert(!animation.isActive, "Lock/unlock must not replay the desktop effect")
        animation.event(reason: "display", pausing: true, eligible: true, at: 30)
        animation.event(reason: "display", pausing: false, eligible: true, at: 31)
        animation.advance(at: 33, allowed: true)
        assert(!animation.isActive, "Missing fresh content must expire")
        assert(!animation.needsCover, "A late capture must release the cover and skip replay")
        animation.event(reason: "display", pausing: true, eligible: true, at: 35)
        animation.event(reason: "display", pausing: false, eligible: true, at: 36)
        animation.present(at: 38.1, duration: 3)
        assert(!animation.isActive && !animation.needsCover,
               "A late GPU callback must not restart the animation before the timeout timer runs")
        assert(DesktopWakeAnimation.validDuration(.nan) == 0.9)
        // Idle sleep followed by missing resume notifications: OS state repairs
        // stale pause flags, which must also release the pending animation.
        animation.event(reason: "display", pausing: true, eligible: true, at: 40)
        animation.event(reason: "session", pausing: true, eligible: true, at: 40.1)
        let repairs = SystemResumeState.changes(paused: ["display", "session"],
            displayAsleep: false, locked: false, onConsole: true)
        assert(repairs == [.init(reason: "session", pausing: false), .init(reason: "display", pausing: false)])
        for repair in repairs {
            animation.event(reason: repair.reason, pausing: repair.pausing, eligible: true, at: 41)
        }
        assert(animation.isActive, "Session transitions must not erase display sleep")
        animation.present(at: 41, duration: 3)
        assert(animation.deadline == 44)
        assert(SystemResumeState.changes(paused: [], displayAsleep: false,
            locked: false, onConsole: true).isEmpty, "Steady desktop must not restart capture")
        let locked = SystemResumeState.changes(paused: ["display"], displayAsleep: false,
            locked: true, onConsole: true)
        assert(locked.first == .init(reason: "lock", pausing: true))
        animation.cancel()
        animation.event(reason: "system", pausing: true, eligible: true, at: 50)
        animation.event(reason: "display", pausing: true, eligible: true, at: 50.1)
        animation.event(reason: "system", pausing: false, eligible: true, at: 51)
        assert(!animation.isActive)
        animation.event(reason: "display", pausing: false, eligible: true, at: 51.1)
        assert(animation.isActive)
        animation.present(at: 52, duration: 3)
        animation.event(reason: "system", pausing: false, eligible: true, at: 52.1)
        assert(animation.deadline == 55)

        // Neither display notification arrives: actual OS state must arm and
        // release a cycle, and polling an unchanged state must leave it alone.
        var recovered = DesktopWakeAnimation()
        var paused = Set<String>()
        func reconcile(asleep: Bool, locked: Bool, at now: Double) {
            for change in SystemResumeState.changes(paused: paused, displayAsleep: asleep,
                                                    locked: locked, onConsole: true) {
                recovered.event(reason: change.reason, pausing: change.pausing,
                                eligible: true, at: now)
                if change.pausing { paused.insert(change.reason) }
                else { paused.remove(change.reason) }
            }
            recovered.advance(at: now, allowed: true)
        }
        reconcile(asleep: true, locked: false, at: 60)
        assert(paused == ["display"] && !recovered.isActive)
        reconcile(asleep: false, locked: false, at: 61)
        assert(paused.isEmpty && recovered.tilt(at: 61) == 90)
        recovered.present(at: 61.5, duration: 3)
        reconcile(asleep: false, locked: false, at: 62)
        assert(recovered.deadline == 64.5)
        reconcile(asleep: true, locked: false, at: 63)
        assert(!recovered.isActive, "Sleeping again must cancel the current presentation")
        reconcile(asleep: false, locked: true, at: 64)
        assert(paused == ["lock"] && !recovered.isActive)
        reconcile(asleep: false, locked: false, at: 65)
        assert(paused.isEmpty && !recovered.isActive, "A delayed authenticated unlock must not replay a wake")

        // The display and temporary lock can both change between polling
        // ticks. A password-free unlock immediately after wake still animates.
        reconcile(asleep: true, locked: true, at: 70)
        assert(paused == ["display", "lock"] && !recovered.isActive)
        reconcile(asleep: false, locked: true, at: 71)
        assert(!recovered.isActive, "Never begin presentation over a locked session")
        reconcile(asleep: false, locked: false, at: 71.2)
        assert(recovered.tilt(at: 71.2) == 90, "Idle sleep's temporary lock must not discard the desktop wake")
        recovered.present(at: 71.3, duration: 3)
        assert(recovered.deadline == 74.3)
        reconcile(asleep: false, locked: false, at: 75)

        // An explicit lock while the display is still awake belongs to the
        // wallpaper path, even if the subsequent unlock is quick.
        reconcile(asleep: false, locked: true, at: 80)
        reconcile(asleep: true, locked: true, at: 81)
        reconcile(asleep: false, locked: true, at: 82)
        reconcile(asleep: false, locked: false, at: 82.2)
        assert(!recovered.isActive)

        let systemRepairs = SystemResumeState.changes(paused: ["system", "display", "session"],
            displayAsleep: false, locked: false, onConsole: true)
        assert(systemRepairs == [.init(reason: "session", pausing: false),
                                  .init(reason: "display", pausing: false),
                                  .init(reason: "system", pausing: false)])
        print("Desktop wake animation tests passed: missed sleep/wake notifications, idle recovery, session ordering, lock cancellation, system/display deduplication")
    }
}
