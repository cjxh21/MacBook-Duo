import Foundation
import QuartzCore

/// Explicit, local validation only. The normal app has no simulated input.
/// Motion collection must be disabled before enabling a synthetic scenario.
@MainActor
final class RuntimeValidation {
    enum Scenario: String { case clear, `static`, moving }
    let scenario: Scenario
    private let endpoint: Double
    private let start = CACurrentMediaTime()
    private var estimator = MotionEstimator()
    private var timer: Timer?
    var onChange: (() -> Void)?

    init?(arguments: [String], endpoint: Double, recording: Bool) {
        guard arguments.contains("--diagnostics"), !recording,
              let i = arguments.firstIndex(of: "--validation-state"), arguments.indices.contains(i + 1),
              let scenario = Scenario(rawValue: arguments[i + 1]) else { return nil }
        self.scenario = scenario
        self.endpoint = endpoint
        if scenario == .moving {
            tick()
            let timer = Timer(timeInterval: 1 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func snapshot(at time: Double) -> MotionSnapshot {
        if scenario == .moving { return estimator.snapshot }
        let angle = scenario == .clear ? endpoint : max(5, endpoint - 35)
        var snapshot = MotionSnapshot()
        snapshot.sample = MotionSample(time: time, raw: nil, angle: angle, readDuration: 0, valid: true)
        snapshot.lastValid = time
        return snapshot
    }
    private func tick() {
        let now = CACurrentMediaTime()
        let before = estimator.snapshot
        let angle = max(5, min(180, endpoint - 38 + 20 * sin((now - start) * .pi / 2))).rounded()
        estimator.ingest(MotionSample(time: now, raw: nil, angle: angle, readDuration: 0, valid: true))
        if before.sample.angle != angle || before.moving(at: now) != estimator.snapshot.moving(at: now) {
            onChange?()
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
}
