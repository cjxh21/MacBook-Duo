import Foundation

@main
struct HingeMotionTests {
    static func main() {
        for endpoint in [1.0, 45, 90, 109, 120, 180] {
            assert(HingeMotion.remaining(angle: endpoint, endpoint: endpoint) == 0)
            assert(HingeMotion.remaining(angle: endpoint + 1, endpoint: endpoint) == 0)
            assert(HingeMotion.remaining(angle: 0, endpoint: endpoint) == 1)
            var previous = 1.0
            for step in 0...1800 {
                let value = HingeMotion.remaining(angle: Double(step) / 10, endpoint: endpoint)
                assert(value >= 0 && value <= 1 && value <= previous)
                previous = value
            }
        }
        assert(HingeMotion.remaining(angle: 107, endpoint: 109) == 0)
        assert(HingeMotion.remaining(angle: 106, endpoint: 109) > 0)
        assert(HingeMotion.remaining(angle: .nan, endpoint: 109) == 0)
        assert(HingeMotion.remaining(angle: 90, endpoint: 0) == 0)
        let endpoint = 115.0, boundary = HingeMotion.clearAngle(endpoint: 115)
        assert(boundary == 113)
        assert(HingeMotion.effectOpacity(angle: boundary, endpoint: endpoint) == 0)
        assert(HingeMotion.tilt(angle: boundary, endpoint: endpoint) == 0)
        assert(HingeMotion.effectOpacity(angle: boundary - 6, endpoint: endpoint) == 1)
        assert(abs(HingeMotion.tilt(angle: boundary - 6, endpoint: endpoint) - 80 * HingeMotion.remaining(angle: boundary - 6, endpoint: endpoint)) < 1e-9)
        var previousOpacity = 1.0, previousTilt = 80.0
        for step in 0...600 {
            let angle = boundary - 6 + Double(step) / 100
            let opacity = HingeMotion.effectOpacity(angle: angle, endpoint: endpoint)
            let tilt = HingeMotion.tilt(angle: angle, endpoint: endpoint)
            assert(opacity <= previousOpacity + 1e-12 && tilt <= previousTilt + 1e-12)
            previousOpacity = opacity; previousTilt = tilt
        }
        // The angle-times-opacity proxy tends to zero near the clear boundary.
        // Actual pixel differences are measured by the GPU handoff fixture.
        let lastOpacity = HingeMotion.effectOpacity(angle: boundary - 1, endpoint: endpoint)
        let lastTilt = HingeMotion.tilt(angle: boundary - 1, endpoint: endpoint)
        assert(lastOpacity * lastTilt < 0.004)
        var results: [Double] = []
        for fps in [60.0, 120.0] {
            var angle = 0.0
            for _ in 0..<Int(fps / 10) {
                angle += (40 - angle) * HingeMotion.blend(deltaTime: 1 / fps)
            }
            results.append(angle)
        }
        assert(abs(results[0] - results[1]) < 0.00001)
        print("PASS: calibration endpoints, clear margin, monotonic motion, frame-rate independent smoothing")
    }
}
