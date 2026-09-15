import Foundation

@main
struct RuntimePolicyTests {
    static func main() {
        var policy = RuntimePolicy()
        func sample(_ time: Double, angle: Double = 120, change: Double = -.infinity, direction: Double = 0) -> MotionSnapshot {
            var s = MotionSnapshot()
            s.sample = MotionSample(time: time, raw: UInt16(angle), angle: angle, readDuration: 0.001, valid: true)
            s.lastValid = time; s.lastChange = change; s.direction = direction
            return s
        }
        var input = RuntimeInput(time: 0, enabled: false, suspended: false, settingsVisible: false,
            recording: false, snapshot: sample(0), endpoint: 120, mode: .automatic, onAC: false, lowPower: false)
        var d = policy.update(input)
        assert(d.state == .off && d.captureFPS == 0 && d.sensorHz == 0 && d.nextDeadline == nil)
        input.recording = true
        assert(policy.update(input).sensorHz == 30)
        input.recording = false; input.settingsVisible = true
        assert(policy.update(input).sensorHz == 30)
        input.settingsVisible = false; input.enabled = true
        d = policy.update(input)
        assert(d.state == .clearIdle && d.captureFPS == 0 && !d.showsEffect)
        var settingsPolicy = RuntimePolicy()
        var settingsInput = RuntimeInput(time: 0, enabled: true, suspended: false, settingsVisible: true,
            recording: false, snapshot: sample(0, angle: 100), endpoint: 120, mode: .automatic,
            onAC: false, lowPower: false)
        d = settingsPolicy.update(settingsInput)
        assert(d.captureFPS == 30 && d.sensorHz == 30 && d.showsEffect,
               "Settings keeps the hinge readout and effect alive")
        settingsInput.time = 1; settingsInput.settingsVisible = false
        settingsInput.snapshot = sample(1, angle: 100, change: 1, direction: -1)
        d = settingsPolicy.update(settingsInput)
        assert(d.captureFPS == 30 && d.showsEffect, "Closing settings resumes the effect")
        input.time = 1.999; input.snapshot = sample(input.time)
        assert(policy.update(input).captureFPS == 0)
        input.time = 2; input.snapshot = sample(input.time)
        d = policy.update(input)
        assert(d.captureFPS == 0 && !d.animates && !d.showsEffect)
        input.time = 3; input.snapshot = sample(3, angle: 117, change: 3, direction: -1)
        d = policy.update(input)
        assert(d.captureFPS == 0 && d.showsEffect, "A near-boundary crossing waits for confirmation")
        input.time = 3 + CapturePolicy.effectEntryDelay
        input.snapshot = sample(input.time, angle: 117, change: 3, direction: -1)
        d = policy.update(input)
        assert(d.captureFPS == 30 && d.showsEffect, "Capture resumes after a confirmed crossing")
        // A one-degree bounce above a lower calibrated endpoint must not
        // restart ScreenCaptureKit merely because the sensor reported motion.
        var bouncePolicy = RuntimePolicy()
        var bounceInput = input
        bounceInput.time = 10; bounceInput.endpoint = 111
        bounceInput.snapshot = sample(10, angle: 113)
        _ = bouncePolicy.update(bounceInput)
        bounceInput.time = 12.1
        bounceInput.snapshot = sample(12.1, angle: 113, change: 12.1, direction: -1)
        d = bouncePolicy.update(bounceInput)
        assert(d.captureFPS == 0 && !d.showsEffect, "Clear-zone motion above the endpoint must stay capture-free")
        // Crossing into the actual effect zone in the closing direction may prewarm.
        bounceInput.time = 12.2
        bounceInput.snapshot = sample(12.2, angle: 108, change: 12.2, direction: -1)
        d = bouncePolicy.update(bounceInput)
        assert(d.captureFPS == 0 && d.showsEffect, "A boundary jump should wait for confirmation")
        bounceInput.time = 12.2 + CapturePolicy.effectEntryDelay + 0.001
        bounceInput.snapshot = sample(bounceInput.time, angle: 108, change: 12.2, direction: -1)
        d = bouncePolicy.update(bounceInput)
        assert(d.captureFPS == 30 && d.showsEffect, "A confirmed boundary crossing should capture")
        var singleBounce = RuntimePolicy()
        var singleInput = bounceInput
        singleInput.time = 30; singleInput.snapshot = sample(30, angle: 113)
        _ = singleBounce.update(singleInput)
        singleInput.time = 31; singleInput.snapshot = sample(31, angle: 108, change: 31, direction: -1)
        d = singleBounce.update(singleInput)
        assert(d.captureFPS == 0, "A single boundary sample must not start capture")
        singleInput.time = 31.05; singleInput.snapshot = sample(31.05, angle: 110, change: 31.05, direction: 1)
        d = singleBounce.update(singleInput)
        assert(d.captureFPS == 0, "Returning clear before confirmation must stay capture-free")
        // A one-degree excursion below the endpoint but above the clear
        // boundary remains capture-free.
        bouncePolicy.reset()
        bounceInput.time = 20; bounceInput.snapshot = sample(20, angle: 110)
        d = bouncePolicy.update(bounceInput)
        assert(d.captureFPS == 0 && !d.showsEffect, "Endpoint-adjacent bounce must stay capture-free")
        input.time = 3.1; input.snapshot = sample(3.1, angle: 117, change: 3.1, direction: -1)
        d = policy.update(input)
        assert(d.state == .moving && d.animates && d.showsEffect)
        input.time = 3.3; input.snapshot = sample(3.3, angle: 117, change: 3.1, direction: -1)
        d = policy.update(input)
        assert(d.state == .staticEffect && !d.animates && d.captureFPS == 30)
        // Calibrating at the current angle always clears immediately.
        input.endpoint = 117
        assert(!policy.update(input).showsEffect)
        for mode in [PerformanceMode.responsive, .balanced, .saver] {
            policy.reset(); input.mode = mode; input.endpoint = 120; input.time = 10
            input.snapshot = sample(10, angle: 100, change: 10, direction: -1)
            _ = policy.update(input)
            input.time = 10.1; input.snapshot = sample(10.1, angle: 120)
            _ = policy.update(input)
            input.time = 11.9; input.snapshot = sample(11.9, angle: 120)
            d = policy.update(input)
            assert(d.captureFPS == mode.activeCaptureFPS && d.nextDeadline == 12.1)
            input.time = 12.1; input.snapshot = sample(12.1, angle: 120)
            d = policy.update(input)
            assert(d.captureFPS == 0 && !d.showsEffect && !d.animates)
            input.time = 13; input.snapshot = sample(13, angle: 115, change: 13, direction: -1)
            assert(policy.update(input).captureFPS == mode.activeCaptureFPS, "All modes resume on closing")
            assert(d.sensorHz == (mode == .responsive ? 120 : mode == .balanced ? 60 : 30))
            input.onAC.toggle()
            assert(policy.update(input).policy == mode, "AC changes must preserve a manual choice")
            input.lowPower = true
            assert(policy.update(input).policy == .saver)
            input.lowPower = false
        }
        input.mode = .automatic; input.onAC = true; input.screenFPS = 120
        assert(policy.update(input).renderFPS == 120)
        input.mode = .balanced
        assert(policy.update(input).renderFPS == 60)
        input.suspended = true
        d = policy.update(input)
        assert(d.state == .suspended && d.sensorHz == 0 && d.captureFPS == 0 && !d.showsEffect)
        input.suspended = false; input.freshAfter = 14
        assert(policy.update(input).state == .suspended, "Wake cannot reuse a pre-sleep sample")
        input.time = 14; input.snapshot = sample(14)
        assert(policy.update(input).state == .clearIdle)
        input.time = 14.6
        assert(policy.update(input).state == .suspended, "Stalled HID reads must hide the overlay")
        input.time = 15; input.snapshot = sample(15); input.preview = true
        d = policy.update(input)
        assert(d.showsEffect && d.captureFPS > 0 && !d.animates, "Fixed preview must not force continuous drawing")
        input.preview = false
        assert(!policy.update(input).showsEffect)
        print("PASS: off/recording/settings, stable deadlines, prewarm, movement/stop, calibration, all power modes, screen refresh, pause/wake/freshness and preview")
    }
}
