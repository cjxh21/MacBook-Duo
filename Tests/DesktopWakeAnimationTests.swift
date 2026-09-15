import Foundation

@main
struct DesktopWakeAnimationTests {
    static func main() {
        var animation = DesktopWakeAnimation()
        animation.event(reason: "display", pausing: false, eligible: true, at: 0)
        assert(!animation.isActive, "A wake without sleep must not animate")
        animation.event(reason: "display", pausing: true, eligible: true, at: 1)
        animation.event(reason: "display", pausing: false, eligible: true, at: 2)
        assert(animation.tilt(at: 3) == 65, "Wait for the fresh GPU frame")
        animation.present(at: 3, duration: 2)
        assert(abs(animation.tilt(at: 4)! - 8.125) < 0.0001)
        animation.event(reason: "display", pausing: false, eligible: true, at: 4)
        assert(animation.deadline == 5, "Duplicate wake must not restart")
        animation.advance(at: 5, allowed: true)
        assert(!animation.isActive)
        for duration in DesktopWakeAnimation.durations {
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
        animation.advance(at: 39, allowed: true)
        assert(!animation.isActive, "Missing fresh content must expire")
        assert(DesktopWakeAnimation.validDuration(.nan) == 0.9)
        print("Desktop wake animation tests passed")
    }
}
