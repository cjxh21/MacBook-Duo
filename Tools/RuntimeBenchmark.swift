import AppKit
import MetalKit
@preconcurrency import CoreVideo
import QuartzCore
import Carbon

@MainActor private final class BenchmarkStop {
    var aborted = false
    weak var window: NSWindow?
}

/// Controlled component benchmark: real HID and Metal, synthetic input content.
/// Saved baseline algorithms are unchanged; only measurement callbacks are added.
@main
struct RuntimeBenchmark {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        func option(_ key: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return fallback }
            return args[i + 1]
        }
        let legacy = args.contains("--legacy"), scene = option("--state", "moving")
        let mode = PerformanceMode(rawValue: option("--mode", "saver")) ?? .saver
        let duration = max(1, Double(option("--duration", "60")) ?? 60), warmup = 3.0
        let dynamic = args.contains("--dynamic-content"), recording = args.contains("--record")
        let output = URL(fileURLWithPath: option("--output", "Validation/benchmark-runtime.json"))
        guard ["off", "clear", "static", "moving"].contains(scene) else { fatalError("Unknown state") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = NSScreen.screens.first {
            let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main!
        let oldSensor = legacy ? LegacyLidAngleSensor() : nil
        let sensor = legacy ? nil : SensorWorker()
        oldSensor?.start()
        let suite = "duo.benchmark.\(UUID().uuidString)", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        let recorder = recording && !legacy ? MotionRecorder(
            directory: output.deletingLastPathComponent().appendingPathComponent("motion"), defaults: defaults) : nil
        if let recorder { sensor?.onSample = { recorder.ingest($0) } }
        sensor?.setRate(scene == "off" ? (recording ? 30 : 0) : (scene == "moving" ? 120 : mode.idleSensorHz))
        defer { sensor?.shutdown(); oldSensor?.stop(); recorder?.close(); defaults.removePersistentDomain(forName: suite) }
        var old: LegacyGlassMetalView?, new: GlassMetalView?, window: NSWindow?
        var buffer: CVPixelBuffer?, timers: [Timer] = []
        var delivered = 0, renders = 0, uploads = 0, gpu = 0.0, encode = 0.0, intervals: [Double] = []
        var previousFrame: Double?, sensorStart = 0, buildsStart = 0, schedulerCalls = 0
        var measuring = false
        let start = CACurrentMediaTime()
        var measureStart = start + warmup, cpuStart = 0.0
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let stop = BenchmarkStop()
        var handler: EventHandlerRef?, hotKey: EventHotKeyRef?
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let stop = Unmanaged<BenchmarkStop>.fromOpaque(pointer).takeUnretainedValue()
            stop.aborted = true; stop.window?.orderOut(nil)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(stop).toOpaque(), &handler)
        let keyResult = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: 0x44554F42, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard keyResult == noErr else { throw NSError(domain: "Benchmark", code: Int(keyResult),
            userInfo: [NSLocalizedDescriptionKey: "Close the running app before benchmarking; emergency shortcut is occupied."]) }
        defer { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) } }
        var firstReadyWait: Double?
        var estimator = MotionEstimator(), runtime = RuntimePolicy()
        var requestedFPS = scene == "off" ? 0 : (legacy ? 60 : mode.activeCaptureFPS)
        var currentAngle = scene == "clear" || scene == "off" ? 120.0 : 78.7
        func updateSample() {
            let now = CACurrentMediaTime()
            if scene == "moving" { currentAngle = (78 + 24 * sin((now - start) * 1.8)).rounded() }
            estimator.ingest(MotionSample(time: now, raw: UInt16(currentAngle), angle: currentAngle, readDuration: 0, valid: true))
        }
        func tilt() -> Double {
            let now = CACurrentMediaTime(), s = estimator.snapshot
            guard HingeMotion.remaining(angle: s.sample.angle, endpoint: 120) > 0 else { return 0 }
            return HingeMotion.tilt(angle: s.predicted(at: now, enabled: true), endpoint: 120)
        }
        func didRender(_ time: Double, _ duration: Double) {
            guard measuring else { return }
            renders += 1; gpu += duration
            if scene == "moving", let previousFrame { intervals.append(time - previousFrame) }
            previousFrame = time
        }
        func updateOld() {
            if measuring { schedulerCalls += 1 }
            old?.setLiveAngle(scene == "clear" ? 0 : 80 * HingeMotion.remaining(angle: currentAngle, endpoint: 120))
            old?.continuousRendering = scene == "static" || scene == "moving"
        }
        func updateNew() {
            if measuring { schedulerCalls += 1 }
            let d = runtime.update(RuntimeInput(time: CACurrentMediaTime(), enabled: scene != "off", suspended: false,
                settingsVisible: false, recording: recording, snapshot: estimator.snapshot, endpoint: 120,
                mode: mode, onAC: true, lowPower: false, screenFPS: screen.maximumFramesPerSecond))
            requestedFPS = d.captureFPS
            new?.continuousRendering = d.animates
            new?.setLiveAngle(tilt())
        }
        updateSample()
        if scene != "off" {
            let w = Int(screen.frame.width), h = Int(screen.frame.height)
            let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                  let buffer else { fatalError("No pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for y in stride(from: 0, to: h, by: 48) { for x in stride(from: 0, to: w, by: 48) where (x / 48 + y / 48) % 2 == 0 {
                context.setFillColor(CGColor(red: 0.2, green: 0.27, blue: 0.4, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 48, height: 48))
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let panel = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.ignoresMouseEvents = true
            panel.backgroundColor = .black; panel.alphaValue = scene == "clear" ? 0 : 1
            window = panel
            stop.window = panel
            if legacy {
                let view = LegacyGlassMetalView()
                old = view; panel.contentView = view
                view.preferredFramesPerSecond = screen.maximumFramesPerSecond
                view.beforeDraw = updateOld
                view.onFrame = didRender
                view.onUpload = { duration in if measuring { uploads += 1; gpu += duration } }
                view.receive(buffer); updateOld()
            } else {
                let view = GlassMetalView()
                new = view; panel.contentView = view
                view.preferredFramesPerSecond = mode == .responsive ? screen.maximumFramesPerSecond : 60
                view.angleProvider = tilt
                view.onFrame = { timing in
                    didRender(timing.submitted, timing.gpuDuration)
                    if measuring { encode += timing.submitted - timing.encodeStart }
                }
                view.onReady = { firstReadyWait = firstReadyWait ?? CACurrentMediaTime() - start }
                view.receive(buffer); view.renderingEnabled = scene != "clear"; updateNew()
            }
            if scene != "clear" { panel.orderFrontRegardless(); new?.draw() }
            // One first frame for a static desktop. The optional dynamic case
            // supplies content at the requested rate, including idle rate changes.
            if dynamic {
                var lastDelivery = 0.0
                let deliver: @MainActor () -> Void = {
                    if legacy { old?.receive(buffer) } else { new?.receive(buffer) }
                }
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = CACurrentMediaTime()
                        guard requestedFPS > 0, now - lastDelivery >= 1 / Double(requestedFPS) - 0.001 else { return }
                        lastDelivery = now
                        if measuring { delivered += 1 }
                        deliver()
                    }
                }
                timers.append(timer); RunLoop.main.add(timer, forMode: .common)
            }
            if legacy {
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { updateOld() } }
                timers.append(timer); RunLoop.main.add(timer, forMode: .common)
            }
        }
        if scene != "off" {
            let movement = Timer(timeInterval: scene == "moving" ? 1.0 / 120 : 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let previous = estimator.snapshot.sample.angle
                    updateSample()
                    if !legacy && (scene != "moving" || previous != currentAngle) { updateNew() }
                }
            }
            timers.append(movement); RunLoop.main.add(movement, forMode: .common)
        }
        let begin = Timer(timeInterval: warmup, repeats: false) { _ in
            MainActor.assumeIsolated {
                measuring = true
                measureStart = CACurrentMediaTime(); cpuStart = cpuTime()
                sensorStart = oldSensor?.readCount ?? sensor?.statistics().reads ?? 0
                buildsStart = new?.pyramidBuildCount ?? 0
            }
        }
        timers.append(begin); RunLoop.main.add(begin, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(warmup + duration + 0.05))
        measuring = false
        let elapsed = CACurrentMediaTime() - measureStart
        let cpuElapsed = cpuTime() - cpuStart
        for timer in timers { timer.invalidate() }
        new?.renderingEnabled = false; old?.isPaused = true; window?.orderOut(nil)
        let sorted = intervals.sorted()
        let info: [String: Any] = [
            "schema": 2, "variant": legacy ? "legacy" : "new", "state": scene, "mode": legacy ? "legacy60" : mode.rawValue,
            "duration": elapsed, "warmup": warmup, "recording": recorder != nil, "aborted": stop.aborted,
            "measurement_start": measureStart, "measurement_end": measureStart + elapsed,
            "process_cpu_seconds": cpuElapsed, "process_cpu_mean_percent": cpuElapsed / elapsed * 100,
            "capture": false, "real_capture_frames": 0, "synthetic_content_frames": delivered, "dynamic_content": dynamic,
            "capture_fps_policy": requestedFPS, "render_frames": renders, "gpu_uploads": uploads,
            "pyramid_builds": (new?.pyramidBuildCount ?? 0) - buildsStart, "gpu_seconds": gpu, "cpu_encode_seconds": encode,
            "frame_interval_p95_ms": sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000,
            "motion_frame_intervals": intervals, "sensor_reads": (oldSensor?.readCount ?? sensor?.statistics().reads ?? 0) - sensorStart,
            "scheduler_calls": schedulerCalls, "first_ready_wait": firstReadyWait as Any? ?? NSNull(),
            "display_hz": screen.maximumFramesPerSecond, "source_size": ["width": screen.frame.width, "height": screen.frame.height],
            "drawable_size": ["width": old?.drawableSize.width ?? new?.drawableSize.width ?? 0, "height": old?.drawableSize.height ?? new?.drawableSize.height ?? 0],
            "device": MTLCreateSystemDefaultDevice()?.name ?? "unknown",
            "scope": "Actual HID and Metal component benchmark with synthetic content/angles; excludes ScreenCaptureKit and SwiftUI settings.",
            "absolute_physical_latency_measured": false]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print("Completed \(legacy ? "legacy" : "new") \(scene), \(renders) frames over \(String(format: "%.2f", elapsed))s")
    }
}
