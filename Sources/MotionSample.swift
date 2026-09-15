import Foundation

struct MotionSample: Codable, Sendable {
    let time: Double
    let raw: UInt16?
    let angle: Double
    let readDuration: Double
    let valid: Bool
}

struct MotionSnapshot: Sendable {
    var sample = MotionSample(time: 0, raw: nil, angle: 105, readDuration: 0, valid: false)
    var velocity = 0.0
    var lastChange = -Double.infinity
    var lastValid = -Double.infinity
    var direction = 0.0
    var generation: UInt64 = 0
    func moving(at time: Double) -> Bool {
        sample.valid && time >= lastChange && time - lastChange < 0.15
    }
    func predicted(at time: Double, enabled: Bool) -> Double {
        guard enabled, sample.valid, time >= sample.time,
              time - lastValid < 0.1, time - lastChange < 0.1 else { return sample.angle }
        return min(180, max(0, sample.angle + min(2, max(-2, velocity * 0.020))))
    }
}

struct MotionEstimator {
    private var history: [MotionSample] = []
    private(set) var snapshot = MotionSnapshot()
    mutating func reset(invalidate: Bool = false) {
        history.removeAll(keepingCapacity: true)
        snapshot.direction = 0
        snapshot.velocity = 0
        snapshot.lastChange = -.infinity
        snapshot.generation &+= 1
        if invalidate {
            snapshot.sample = MotionSample(time: snapshot.sample.time, raw: nil,
                angle: snapshot.sample.angle, readDuration: 0, valid: false)
            snapshot.lastValid = -.infinity
        }
    }
    mutating func ingest(_ sample: MotionSample) {
        let previous = snapshot.sample
        guard sample.time.isFinite, sample.angle.isFinite, sample.readDuration.isFinite else {
            reset(invalidate: true)
            return
        }
        if !sample.valid || !(0...180).contains(sample.angle) {
            if snapshot.sample.valid { reset() }
            snapshot.sample = MotionSample(time: sample.time, raw: sample.raw, angle: sample.angle,
                readDuration: sample.readDuration, valid: false)
            return
        }
        if sample.time - snapshot.lastValid > 0.1 || sample.time <= snapshot.lastValid { reset() }
        // A calibration reset clears velocity history, but the first changed
        // reading must still wake capture and raise the sensor sampling rate.
        if previous.valid, sample.time > previous.time,
           sample.time - previous.time <= 0.1, sample.angle != previous.angle {
            let sign = sample.angle > previous.angle ? 1.0 : -1.0
            if snapshot.direction != 0 && sign != snapshot.direction { reset() }
            snapshot.direction = sign
            snapshot.lastChange = sample.time
        }
        history.append(sample)
        history.removeAll { sample.time - $0.time > 0.080 }
        snapshot.sample = sample
        snapshot.lastValid = sample.time
        // Least-squares over the time window; repeated integer readings carry time,
        // but don't generate a new motion event or reset lastChange.
        if history.count >= 2, sample.time - snapshot.lastChange < 0.1 {
            // Center timestamps relative to the current sample for long uptimes.
            let mt = history.reduce(0) { $0 + ($1.time - sample.time) } / Double(history.count)
            let ma = history.map(\.angle).reduce(0, +) / Double(history.count)
            let denominator = history.reduce(0) { $0 + pow(($1.time - sample.time) - mt, 2) }
            let numerator = history.reduce(0) { $0 + (($1.time - sample.time) - mt) * ($1.angle - ma) }
            snapshot.velocity = denominator > 1e-9 ? numerator / denominator : 0
        } else { snapshot.velocity = 0 }
    }
}

enum PerformanceMode: String, CaseIterable, Codable, Identifiable {
    case automatic, responsive, balanced, saver
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "自动"; case .responsive: return "流畅"; case .balanced: return "均衡"; case .saver: return "省电" }
    }
    func resolved(onAC: Bool, lowPower: Bool) -> PerformanceMode {
        if lowPower { return .saver }
        return self == .automatic ? (onAC ? .responsive : .saver) : self
    }
    var activeCaptureFPS: Int { self == .saver ? 30 : 60 }
    var idleSensorHz: Int { self == .responsive ? 120 : (self == .balanced ? 60 : 30) }
}

enum EffectState: String, Codable {
    case off, clearIdle, moving, staticEffect, suspended
}

struct CapturePolicy {
    static let clearIdleDelay = 2.0
    // A single integer HID jump just below the clear boundary must not start
    // ScreenCaptureKit.  Deeper motion starts immediately; only the narrow
    // handoff band gets this short confirmation window.
    static let effectEntryDelay = 0.12
    static func fps(mode: PerformanceMode, clearDuration: Double?, approaching: Bool) -> Int {
        if approaching { return mode.activeCaptureFPS }
        guard let duration = clearDuration else { return mode.activeCaptureFPS }
        if duration >= clearIdleDelay { return 0 }
        return mode.activeCaptureFPS
    }
}
