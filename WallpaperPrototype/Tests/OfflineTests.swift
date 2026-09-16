import AppKit
import CoreVideo

@main struct OfflineTests {
    static func main() throws {
        let migrationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        let legacy = migrationRoot.appendingPathComponent("legacy")
        let shared = migrationRoot.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let oldFile = legacy.appendingPathComponent(DuoWallpaperPaths.customWallpaperName)
        let newFile = shared.appendingPathComponent(DuoWallpaperPaths.customWallpaperName)
        try Data("old".utf8).write(to: oldFile)
        try DuoWallpaperPaths.migrateWallpaper(from: legacy, to: shared)
        let migrated = try Data(contentsOf: newFile)
        precondition(migrated == Data("old".utf8))
        try Data("new".utf8).write(to: newFile)
        try DuoWallpaperPaths.migrateWallpaper(from: legacy, to: shared)
        let retained = try Data(contentsOf: newFile)
        precondition(retained == Data("new".utf8))
        precondition(FileManager.default.fileExists(atPath: oldFile.path))
        print("PASS: legacy wallpaper migration preserves new imports and original file")
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
        precondition(wake.tilt(at: 3.1, locked: true, sample: opened(1)) == 90)
        precondition(wake.tilt(at: 3.2, locked: true, sample: opened(3.2)) == 65)
        wake.setAwake(true, at: 3.4) // Duplicate notifications must not restart.
        let middle = wake.tilt(at: 3.65, locked: true, sample: opened(3.65))!
        precondition(abs(middle - WakeAnimationTiming.tilt(elapsed: 0.45, duration: 0.9, initialTilt: 65)) < 0.001)
        precondition(wake.tilt(at: 4.2, locked: true, sample: opened(4.2)) == nil)
        wake.setAwake(false, at: 5)
        wake.setAwake(true, at: 6)
        precondition(wake.tilt(at: 6, locked: true, sample: opened(6, angle: 60)) == nil)
        precondition(wake.tilt(at: 6.2, locked: true, sample: opened(6.2)) == nil, "Opening the physical lid must not start a timed wake later")
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
        precondition(reader.read() == nil)
        let sample = WallpaperAngle(time: 10, angle: 90, predicted: 89, endpoint: 115, frost: 0.09, softness: 1, valid: true, awake: true)
        precondition(writer.write(sample))
        precondition(reader.read()?.fresh(at: 10.2) == true)
        precondition(reader.read()?.fresh(at: 10.5) == false)
        precondition(reader.read()?.fresh(at: 9) == false)
        for duration in WakeAnimationTiming.durations {
            var configured = opened(100)
            configured.wakeDuration = duration
            precondition(writer.write(configured))
            precondition(reader.read()?.wakeDuration == duration)
            var cycle = WakePageTurn()
            cycle.setAwake(false, at: 99)
            cycle.setAwake(true, at: 100)
            precondition(cycle.tilt(at: 100, locked: true, sample: reader.read()) == 65)
            configured.time = 100 + duration / 2
            precondition(writer.write(configured))
            let middle = cycle.tilt(at: configured.time, locked: true, sample: reader.read())!
            precondition(abs(middle - WakeAnimationTiming.tilt(elapsed: duration / 2, duration: duration, initialTilt: 65)) < 0.001, "Both renderers must share the same duration and curve")
            configured.time = 100 + duration + 0.001
            precondition(writer.write(configured))
            precondition(cycle.tilt(at: configured.time, locked: true, sample: reader.read()) == nil)
        }
        print("PASS: all shared wake durations survive bridge transport and control lock-screen timing")
        func image(_ buffer: CVPixelBuffer) -> CGImage {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: stride * height)
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        // High-frequency stripes distinguish actual blur from geometry/dimming.
        let stripe = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
            bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<512 {
            stripe.setFillColor(CGColor(gray: (x / 4) % 2 == 0 ? 0 : 1, alpha: 1))
            stripe.fill(CGRect(x: x, y: 0, width: 1, height: 512))
        }
        let stripes = try WallpaperFrameRenderer(width: 512, height: 512, sourceImage: stripe.makeImage()!)
        var contrasts: [Int] = []
        for angle in [60.0, 30.0, 0.0] {
            let cg = image(try stripes.render(tilt: 0, opacity: 1, wakeAngle: angle))
            let bytes = cg.dataProvider!.data! as Data
            let values = (180..<332).map { Int(bytes[480 * cg.bytesPerRow + $0 * 4]) }
            contrasts.append(values.max()! - values.min()!)
        }
        precondition(contrasts[0] < contrasts[1] && contrasts[1] < contrasts[2],
                     "Opening must progressively restore image detail: \(contrasts)")
        print("PASS: wake blur progressively clears, stripe contrast \(contrasts)")
        stripe.setFillColor(CGColor(gray: 1, alpha: 1))
        stripe.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let white = try WallpaperFrameRenderer(width: 512, height: 512, sourceImage: stripe.makeImage()!)
        let feathered = image(try white.render(tilt: 0, opacity: 1, wakeAngle: 45))
        let featherBytes = feathered.dataProvider!.data! as Data
        let edgeY = Int((1 - 2.4 * cos(Double.pi / 4) / (2.4 + sin(Double.pi / 4))) * 512)
        let outside = Int(featherBytes[(edgeY - 4) * feathered.bytesPerRow + 256 * 4])
        let inside = Int(featherBytes[(edgeY + 4) * feathered.bytesPerRow + 256 * 4])
        precondition(outside > 10 && outside < inside && inside < 245,
                     "Glass edge must feather on both sides instead of hard clipping")
        print("PASS: Gaussian glass silhouette, outside/inside intensities \(outside)/\(inside)")
        let settled = image(try white.render(tilt: 0, opacity: 1, wakeAngle: 0))
        let settledBytes = settled.dataProvider!.data! as Data
        for nearZero in [0.1, 0.01, 0.001] {
            let near = image(try white.render(tilt: 0, opacity: 1, wakeAngle: nearZero))
            let bytes = near.dataProvider!.data! as Data
            var maximumDifference = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                maximumDifference = max(maximumDifference, abs(Int(bytes[i]) - Int(settledBytes[i])))
            }
            precondition(maximumDifference <= 2,
                         "Last wake frames must converge without a disappearing dark border: \(maximumDifference)")
        }
        print("PASS: near-zero wake frames converge to clear frame without edge pop")
        let opening = try WallpaperFrameRenderer(width: 960, height: 600)
        var previousVisible = 0
        var finalOpening: Data?
        for angle in [90.0, 75, 55, 35, 15, 0] {
            let frame = try opening.render(tilt: 0, opacity: 1, wakeAngle: angle)
            let cg = image(frame)
            let data = cg.dataProvider!.data! as Data
            var visible = 0, firstVisibleRow = opening.height
            for y in 0..<opening.height {
                for x in 0..<opening.width {
                    let offset = y * cg.bytesPerRow + x * 4
                    if data[offset] != 0 || data[offset + 1] != 0 || data[offset + 2] != 0 {
                        visible += 1; firstVisibleRow = min(firstVisibleRow, y)
                    }
                }
            }
            if angle == 90 { precondition(visible == 0, "The closed wake frame must be solid black") }
            if angle == 55 {
                precondition(firstVisibleRow > opening.height / 2, "The image must rise from the bottom hinge")
            }
            precondition(visible >= previousVisible, "Opening must reveal the image monotonically")
            previousVisible = visible
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("wake-\(Int(angle)).png"))
            if angle == 0 { finalOpening = data }
        }
        precondition(opening.pyramidBuilds == 1, "Wake rendering must reuse its blur pyramid across angles")
        let normal = image(try opening.render(tilt: 0, opacity: 1))
        precondition(finalOpening == normal.dataProvider!.data! as Data, "The final wake frame must exactly match the normal image")
        print("PASS: black first frame, bottom-anchored perspective opening, monotonic reveal, exact final handoff, cached wake blur")
        let renderer = try WallpaperFrameRenderer(width: 1200, height: 780)
        for angle in [115.0, 100, 65] {
            let buffer = try renderer.render(tilt: HingeMotion.tilt(angle: angle, endpoint: 115),
                opacity: HingeMotion.effectOpacity(angle: angle, endpoint: 115))
            precondition(CVPixelBufferGetIOSurface(buffer) != nil)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let bytes = CVPixelBufferGetBytesPerRow(buffer)
            let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: bytes * renderer.height)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            let cg = CGImage(width: renderer.width, height: renderer.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytes, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("angle-\(Int(angle)).png"))
        }
        precondition(renderer.pyramidBuilds == 1 && renderer.frameCount == 3)
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
