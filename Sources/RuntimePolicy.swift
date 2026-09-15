import Foundation

struct RuntimeInput {
    var time: Double
    var enabled: Bool
    var suspended: Bool
    var settingsVisible: Bool
    var recording: Bool
    var snapshot: MotionSnapshot
    var endpoint: Double
    var mode: PerformanceMode
    var onAC: Bool
    var lowPower: Bool
    var preview: Bool = false
    var screenFPS: Int = 60
    var freshAfter: Double = -.infinity
}

struct RuntimeDecision: Equatable {
    var state: EffectState = .off
    var policy: PerformanceMode = .saver
    var captureFPS = 0
    var sensorHz = 0
    var renderFPS = 60
    var showsEffect = false
    var animates = false
    var nextDeadline: Double?
}

/// The only owner of runtime policy. Call on motion, content, settings, power,
/// system events and the returned deadline; rendering never calls this reducer.
struct RuntimePolicy {
    private(set) var clearSince: Double?
    private var inClearZone = false
    private var effectSince: Double?
    private var hasSeenEffect = false
    mutating func reset() {
        clearSince = nil
        inClearZone = false
        effectSince = nil
        hasSeenEffect = false
    }

    mutating func update(_ input: RuntimeInput) -> RuntimeDecision {
        let mode = input.mode.resolved(onAC: input.onAC, lowPower: input.lowPower)
        var result = RuntimeDecision(policy: mode,
            renderFPS: mode == .responsive ? max(1, input.screenFPS) : min(60, max(1, input.screenFPS)))
        let s = input.snapshot
        let moving = s.moving(at: input.time)
        result.sensorHz = input.suspended ? 0 : (input.enabled ? mode.idleSensorHz :
            ((input.recording || input.settingsVisible) ? 30 : 0))
        guard input.enabled else {
            clearSince = nil
            inClearZone = false
            effectSince = nil
            hasSeenEffect = false
            return result
        }
        let fresh = s.sample.valid && s.sample.time >= input.freshAfter &&
            input.time >= s.lastValid && input.time - s.lastValid < 0.5
        guard !input.suspended, fresh else {
            clearSince = nil
            inClearZone = false
            effectSince = nil
            hasSeenEffect = false
            result.state = .suspended
            return result
        }
        let clear = HingeMotion.remaining(angle: s.sample.angle, endpoint: input.endpoint) == 0 && !input.preview
        let wasInClearZone = inClearZone
        if clear {
            // Keep the clear-zone timer across quantized one-degree readings.
            // A lid resting just above the calibrated endpoint can otherwise
            // reset the timer on every tiny sensor change and repeatedly
            // restart ScreenCaptureKit.
            if !wasInClearZone, hasSeenEffect { clearSince = input.time }
            inClearZone = true
            effectSince = nil
        } else {
            inClearZone = false
            clearSince = nil
            if effectSince == nil { effectSince = input.time }
            // The first degree below the clear boundary is a noisy handoff
            // band.  Confirm it briefly before asking ScreenCaptureKit to
            // start; deeper motion remains immediate for responsiveness.
            let boundary = HingeMotion.clearAngle(endpoint: input.endpoint)
            let deepEffect = s.sample.angle <= boundary - 2
            if input.preview || deepEffect || input.time - (effectSince ?? input.time) >= CapturePolicy.effectEntryDelay {
                hasSeenEffect = true
            }
        }
        result.showsEffect = !clear
        result.animates = !clear && moving
        result.state = clear ? .clearIdle : (moving ? .moving : .staticEffect)
        if clear {
            // A fresh app or a wake-up can begin above the endpoint. Keep that
            // clear zone capture-free. After a real effect has been shown, the
            // normal two-second grace period still applies when returning to
            // clear, and a preview is always allowed to capture.
            result.captureFPS = input.preview ? mode.activeCaptureFPS :
                (clearSince.map { CapturePolicy.fps(mode: mode,
                    clearDuration: input.time - $0, approaching: false) } ?? 0)
        } else {
            // Start immediately for substantive motion.  Near the boundary,
            // wait for the short confirmation above so a one-sample jump does
            // not flash the system's screen-monitoring indicator.
            let boundary = HingeMotion.clearAngle(endpoint: input.endpoint)
            let deepEffect = s.sample.angle <= boundary - 2
            let confirmed = input.preview || deepEffect ||
                (effectSince.map { input.time - $0 >= CapturePolicy.effectEntryDelay } ?? false)
            result.captureFPS = confirmed ? mode.activeCaptureFPS : 0
        }
        var deadlines = [s.lastValid + 0.5] // watchdog if the HID read itself stalls
        if moving { deadlines.append(s.lastChange + 0.15) }
        if let effectSince, !clear,
           s.sample.angle > HingeMotion.clearAngle(endpoint: input.endpoint) - 2,
           input.time - effectSince < CapturePolicy.effectEntryDelay {
            deadlines.append(effectSince + CapturePolicy.effectEntryDelay)
        }
        if let clearSince {
            let transition = clearSince + CapturePolicy.clearIdleDelay
            if transition > input.time { deadlines.append(transition) }
        }
        result.nextDeadline = deadlines.filter { $0 > input.time + 0.0001 }.min()
        return result
    }
}
