import AppKit
import CoreVideo

@main struct OfflineTests {
    static func main() throws {
        var wake = WakePageTurn()
        func opened(_ time: Double, angle: Double = 115) -> WallpaperAngle {
            WallpaperAngle(time: time, angle: angle, predicted: angle, endpoint: 115,
                           frost: 0.09, softness: 1, valid: true, awake: true)
        }
        precondition(wake.tilt(at: 0, locked: true, sample: opened(0)) == nil)
        wake.setAwake(false, at: 1)
        precondition(wake.tilt(at: 2, locked: true, sample: opened(2)) == nil)
        wake.setAwake(true, at: 3)
        precondition(wake.tilt(at: 3, locked: false, sample: opened(3)) == nil)
        precondition(wake.tilt(at: 3.1, locked: true, sample: opened(1)) == nil)
        precondition(wake.tilt(at: 3.2, locked: true, sample: opened(3.2)) == 65)
        wake.setAwake(true, at: 3.4) // Duplicate notifications must not restart.
        let middle = wake.tilt(at: 3.65, locked: true, sample: opened(3.65))!
        precondition(abs(middle - 8.125) < 0.001)
        precondition(wake.tilt(at: 4.2, locked: true, sample: opened(4.2)) == nil)
        wake.setAwake(false, at: 5)
        wake.setAwake(true, at: 6)
        precondition(wake.tilt(at: 6, locked: true, sample: opened(6, angle: 60)) == nil)
        precondition(wake.tilt(at: 6.2, locked: true, sample: opened(6.2)) == nil)
        wake.setAwake(false, at: 7)
        wake.setAwake(true, at: 8)
        precondition(wake.tilt(at: 10.1, locked: true, sample: opened(10.1)) == nil)
        wake.setAwake(false, at: 11)
        wake.setAwake(true, at: 12)
        precondition(wake.tilt(at: 12, locked: true, sample: opened(12)) == 65)
        precondition(wake.tilt(at: 12.1, locked: false, sample: opened(12.1)) == nil)
        precondition(wake.tilt(at: 12.2, locked: true, sample: opened(12.2)) == nil)
        print("PASS: wake page turn, duplicate wake, stale data, moving lid, timeout, unlock cancellation")
        let folder = URL(fileURLWithPath: "WallpaperPrototype/build/validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try AngleBridge(url: file, create: true)
        let reader = try AngleBridge(url: file, create: false)
        assert(reader.read() == nil)
        let sample = WallpaperAngle(time: 10, angle: 90, predicted: 89, endpoint: 115, frost: 0.09, softness: 1, valid: true, awake: true)
        assert(writer.write(sample))
        assert(reader.read()?.fresh(at: 10.2) == true)
        assert(reader.read()?.fresh(at: 10.5) == false)
        assert(reader.read()?.fresh(at: 9) == false)
        let renderer = try WallpaperFrameRenderer(width: 1200, height: 780)
        for angle in [115.0, 100, 65] {
            let buffer = try renderer.render(tilt: HingeMotion.tilt(angle: angle, endpoint: 115),
                opacity: HingeMotion.effectOpacity(angle: angle, endpoint: 115))
            assert(CVPixelBufferGetIOSurface(buffer) != nil)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = CVPixelBufferGetBytesPerRow(buffer)
            let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: bytes * renderer.height)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let cg = CGImage(width: renderer.width, height: renderer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("angle-\(Int(angle)).png"))
        }
        assert(renderer.pyramidBuilds == 1 && renderer.frameCount == 3)
        let benchmark = try WallpaperFrameRenderer(width: 1470, height: 956)
        var durations: [Double] = []
        var previous = CACurrentMediaTime()
        for angle in stride(from: 110.0, through: 25.0, by: -3.0) {
            _ = try benchmark.render(tilt: HingeMotion.tilt(angle: angle, endpoint: 115),
                opacity: HingeMotion.effectOpacity(angle: angle, endpoint: 115))
            let now = CACurrentMediaTime()
            durations.append(now - previous)
            previous = now
        }
        let sorted = durations.sorted()
        let p50 = sorted[sorted.count / 2] * 1000
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))] * 1000
        print(String(format: "PASS: shared angle transport, stale/future fallback, IOSurface GPU rendering, angle-only pyramid reuse; 1470x956 render p50 %.1fms p95 %.1fms", p50, p95))
    }
}
