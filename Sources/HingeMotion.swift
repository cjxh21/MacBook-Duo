import Foundation

enum HingeMotion {
    static let handoffDegrees = 6.0
    static func clearAngle(endpoint: Double) -> Double {
        max(1, endpoint - min(2, endpoint * 0.1))
    }
    // Leave a small clear zone for sensor quantization and normal lid movement.
    static func remaining(angle: Double, endpoint: Double) -> Double {
        guard angle.isFinite, endpoint.isFinite, endpoint >= 1 else { return 0 }
        let clearAngle = clearAngle(endpoint: endpoint)
        return min(1, max(0, 1 - angle / clearAngle))
    }

    // The endpoint handoff is driven by angle, not an exit animation. A zero
    // slope at either end makes integer readings and threshold jitter subtle.
    static func effectOpacity(angle: Double, endpoint: Double) -> Double {
        guard angle.isFinite, endpoint.isFinite, endpoint >= 1 else { return 0 }
        let boundary = clearAngle(endpoint: endpoint)
        let u = min(1, max(0, (boundary - angle) / min(handoffDegrees, boundary)))
        return u * u * (3 - 2 * u)
    }
    static func tilt(angle: Double, endpoint: Double, strength: Double = 1) -> Double {
        let remaining = remaining(angle: angle, endpoint: endpoint)
        let linear = 80 * (1 - pow(1 - remaining, 1 / max(0.01, strength)))
        return linear * effectOpacity(angle: angle, endpoint: endpoint)
    }

    static func blend(deltaTime: Double) -> Double {
        guard deltaTime.isFinite else { return 1 }
        return 1 - exp(-max(deltaTime, 0) / 0.025)
    }
}

/// Shared by desktop and wallpaper so settings, validation and easing agree.
enum WakeAnimationTiming {
    static let durations: [Double] = [0.3, 0.6, 0.9, 1.5, 2, 3]
    static let closedAngle = 90.0
    // Retain the existing preference key to preserve the user's selection.
    static let defaultsKey = "desktopWakeDuration"
    static func validDuration(_ value: Double) -> Double {
        durations.contains(value) ? value : 0.9
    }
    static func openingTilt(lidAngle: Double) -> Double {
        guard lidAngle.isFinite else { return 60 }
        return min(closedAngle, max(0, 180 - lidAngle))
    }
    static func handoffDuration(_ duration: Double) -> Double {
        min(0.25, validDuration(duration) * 0.25)
    }
    static func overlayOpacity(elapsed: Double, duration: Double) -> Double {
        let total = validDuration(duration), handoff = handoffDuration(duration)
        let t = min(1, max(0, (elapsed - (total - handoff)) / handoff))
        return 1 - t * t * (3 - 2 * t)
    }
    static func tilt(elapsed: Double, duration: Double, initialTilt: Double = closedAngle) -> Double {
        // Finish geometry first. Reserve a short, perfectly aligned clear hold
        // for the desktop crossfade (and the wallpaper's pipeline handoff).
        let openingDuration = validDuration(duration) - handoffDuration(duration)
        let progress = min(1, max(0, elapsed / openingDuration))
        // Front-load the opening, then settle gently into the clear frame.
        // The time warp and quintic both retain zero endpoint velocity.
        let t = 1 - (1 - progress) * (1 - progress)
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        return min(closedAngle, max(0, initialTilt)) * (1 - eased)
    }
}
