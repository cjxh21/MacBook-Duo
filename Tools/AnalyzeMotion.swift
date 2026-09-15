import Foundation

struct ReplayPoint: Codable {
    var time: Double
    var raw: Double
    var prediction: Double
    var off: Double
    var on: Double
    var tiltOff: Double
    var tiltOn: Double
    var opacity: Double
    var valid: Bool
}
struct ReplayAction: Codable {
    var id: String
    var complete: Bool
    var points: [ReplayPoint]
    var metrics: [String: Double]
}

@main
struct AnalyzeMotion {
    static let scenarios = ["slow", "fast", "stop", "reverse", "endpoint", "repeated", "gap"]
    static func syntheticAngle(_ name: String, _ t: Double) -> Double {
        switch name {
        case "fast": return t < 1.6 ? 120 - min(45, max(0, t - 0.5) * 90) : min(120, 75 + (t - 1.6) * 90)
        case "stop": return t < 2.3 ? 120 - min(32, max(0, t - 0.5) * 40) : min(120, 88 + (t - 2.3) * 30)
        case "reverse": return t < 1.25 ? 120 - max(0, t - 0.5) * 45 : min(120, 86.25 + (t - 1.25) * 90)
        case "endpoint": return t < 4 ? 119 + sin(t * .pi * 6) * 0.8 : 119
        case "repeated": return 120 - min(5, floor(max(0, t - 0.5) * 2))
        default: return 120 - min(40, max(0, t - 0.5) * 12)
        }
    }
    static func stats(_ values: [Double], scale: Double = 1000) -> [String: Double] {
        guard !values.isEmpty else { return [:] }
        let v = values.sorted()
        return ["count": Double(v.count), "mean": v.reduce(0, +) / Double(v.count) * scale,
                "p50": v[(v.count - 1) / 2] * scale, "p95": v[Int(Double(v.count - 1) * 0.95)] * scale,
                "max": v.last! * scale]
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("Usage: analyze-motion <JSONL file|directory|--synthetic> <output-directory> [--fps 60|120]\n", stderr)
            exit(2)
        }
        let fps: Double
        if let index = args.firstIndex(of: "--fps"), args.indices.contains(index + 1),
           let value = Double(args[index + 1]), [30, 60, 120].contains(value) { fps = value } else { fps = 60 }
        let output = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records: [MotionRecord] = [], warnings: [String] = []
        let synthetic = args[1] == "--synthetic"
        if synthetic {
            for scenario in scenarios {
                records.append(MotionRecord(kind: "actionStart", time: 0, action: scenario, reason: "syntheticFixture"))
                var estimator = MotionEstimator()
                for i in 0...720 {
                    let t = Double(i) / 120
                    if scenario == "gap" && t > 1.25 && t < 1.45 { continue }
                    let a = syntheticAngle(scenario, t).rounded()
                    let valid = !(scenario == "gap" && t > 1 && t <= 1.25)
                    let sample = MotionSample(time: t, raw: valid ? UInt16(a) : nil, angle: a,
                        readDuration: 0.0001, valid: valid)
                    estimator.ingest(sample)
                    records.append(MotionRecord(kind: "sample", time: t, action: scenario, sample: sample,
                        predicted: estimator.snapshot.predicted(at: t, enabled: true), context: RecordingContext()))
                }
                records.append(MotionRecord(kind: "actionEnd", time: 6, action: scenario, reason: "fixtureEnd"))
            }
            let encoder = JSONEncoder()
            let data = try records.reduce(into: Data()) { data, record in
                data.append(try encoder.encode(record)); data.append(10)
            }
            try data.write(to: output.appendingPathComponent("synthetic.jsonl"))
        } else {
            let input = URL(fileURLWithPath: args[1])
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let files = isDirectory.boolValue ?
                try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent } : [input]
            let decoder = JSONDecoder()
            for file in files {
                let content = try String(contentsOf: file, encoding: .utf8)
                let lines = content.components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where !line.isEmpty {
                    do {
                        let record = try decoder.decode(MotionRecord.self, from: Data(line.utf8))
                        guard (1...2).contains(record.schema), record.time.isFinite else {
                            throw NSError(domain: "Replay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported schema or non-finite timestamp"])
                        }
                        records.append(record)
                    } catch {
                        if index == lines.count - 1 && !content.hasSuffix("\n") {
                            warnings.append("Truncated final line: \(file.lastPathComponent):\(index + 1)")
                        } else {
                            throw NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                "\(file.lastPathComponent):\(index + 1): \(error.localizedDescription)"])
                        }
                    }
                }
            }
        }
        let groups = Dictionary(grouping: records.filter { $0.action != nil }, by: { $0.action! })
        var actions: [ReplayAction] = []
        var csv = ["action,time,raw_angle,prediction_candidate,display_off,display_on,projected_tilt_off,projected_tilt_on,effect_opacity,valid"]
        var repeated = 0, validSamples = 0, changes = 0
        var readDurations: [Double] = [], processingWaits: [Double] = [], changeIntervals: [Double] = [], replayErrors: [Double] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let samples = group.filter { $0.sample != nil }.sorted { $0.sample!.time < $1.sample!.time }
            guard let first = samples.first?.sample, let last = samples.last?.sample else { continue }
            let complete = group.contains { $0.kind == "actionStart" } && group.contains { $0.kind == "actionEnd" }
            if !complete { warnings.append("Incomplete action: \(key)") }
            var verifier = MotionEstimator(), previous: MotionSample?, lastChangedTime: Double?
            var maxCompensation = 0.0
            for record in samples {
                let s = record.sample!
                verifier.ingest(s)
                if s.valid {
                    validSamples += 1
                    readDurations.append(s.readDuration)
                    if let wait = record.processingWait { processingWaits.append(wait) }
                    if let previous, previous.valid {
                        if previous.angle == s.angle { repeated += 1 }
                        else {
                            changes += 1
                            if let t = lastChangedTime, s.time - t <= 0.15 { changeIntervals.append(s.time - t) }
                            lastChangedTime = s.time
                        }
                    }
                    let candidate = verifier.snapshot.predicted(at: s.time, enabled: true)
                    maxCompensation = max(maxCompensation, abs(candidate - s.angle))
                    if let recorded = record.predicted, record.schema >= 2 || record.context?.prediction != false {
                        replayErrors.append(abs(candidate - recorded))
                    }
                }
                previous = s
            }
            var estimator = MotionEstimator(), index = 0, points: [ReplayPoint] = []
            var off = first.angle, on = first.angle, tiltOff = 0.0, tiltOn = 0.0
            var previousValid = false, lastFrameTime = first.time
            let endpoint = samples.first?.context?.endpoint ?? 120
            for frame in 0...Int(ceil((last.time - first.time) * fps)) {
                let t = min(last.time, first.time + Double(frame) / fps)
                while index < samples.count && samples[index].sample!.time <= t + 1e-8 {
                    estimator.ingest(samples[index].sample!); index += 1
                }
                let snapshot = estimator.snapshot
                let valid = snapshot.sample.valid && t - snapshot.lastValid < 0.5
                let raw = snapshot.sample.angle
                let prediction = snapshot.predicted(at: max(t, snapshot.sample.time), enabled: true)
                let blend = HingeMotion.blend(deltaTime: t - lastFrameTime)
                let actualClear = HingeMotion.remaining(angle: raw, endpoint: endpoint) == 0
                let targetOff = valid && !actualClear ? HingeMotion.tilt(angle: raw, endpoint: endpoint) : 0
                let targetOn = valid && !actualClear ? HingeMotion.tilt(angle: prediction, endpoint: endpoint) : 0
                if frame == 0 || !previousValid || !valid {
                    off = raw; on = raw; tiltOff = targetOff; tiltOn = targetOn
                } else {
                    off += (raw - off) * blend; on += (prediction - on) * blend
                    tiltOff += (targetOff - tiltOff) * blend; tiltOn += (targetOn - tiltOn) * blend
                }
                if abs(off - raw) < 0.001 { off = raw }
                if abs(on - prediction) < 0.001 { on = prediction }
                // The display is removed immediately at the actual clear boundary.
                if actualClear || !valid { tiltOff = 0; tiltOn = 0 }
                if targetOff == 0 { tiltOff = 0 }
                if targetOn == 0 { tiltOn = 0 }
                let p = ReplayPoint(time: t - first.time, raw: raw, prediction: prediction,
                    off: off, on: on, tiltOff: tiltOff, tiltOn: tiltOn,
                    opacity: valid ? HingeMotion.effectOpacity(angle: raw, endpoint: endpoint) : 0, valid: valid)
                points.append(p)
                csv.append("\"\(key.replacingOccurrences(of: "\"", with: "\"\""))\",\(p.time),\(raw),\(prediction),\(off),\(on),\(tiltOff),\(tiltOn),\(p.opacity),\(valid)")
                lastFrameTime = t; previousValid = valid
            }
            let eligible = points.filter { $0.valid }
            let moving = points.enumerated().filter { i, p in
                i > 0 && p.valid && points[i - 1].raw != p.raw
            }.map(\.element)
            let meanOff = moving.isEmpty ? 0 : moving.reduce(0) { $0 + abs($1.off - $1.raw) } / Double(moving.count)
            let meanOn = moving.isEmpty ? 0 : moving.reduce(0) { $0 + abs($1.on - $1.raw) } / Double(moving.count)
            // Overshoot is defined at observed extrema/stops, not against an
            // unmeasured physical lid trajectory.
            var overshootOn = 0.0, overshootOff = 0.0, midpointAdvances: [Double] = []
            var strokeStart = 0, direction = 0.0
            func finishStroke(_ end: Int) {
                guard end > strokeStart, direction != 0 else { return }
                let startValue = points[strokeStart].raw, endValue = points[end].raw
                if abs(endValue - startValue) >= 3 {
                    let midpoint = (startValue + endValue) / 2
                    let tail = points[strokeStart...min(points.count - 1, end + Int(fps / 4))]
                    let tOff = tail.first { ($0.off - midpoint) * direction >= 0 }?.time
                    let tOn = tail.first { ($0.on - midpoint) * direction >= 0 }?.time
                    if let tOff, let tOn { midpointAdvances.append((tOff - tOn) * 1000) }
                }
                let until = min(points.count - 1, end + Int(fps * 0.15))
                for p in points[end...until] where p.valid {
                    overshootOn = max(overshootOn, (p.on - endValue) * direction)
                    overshootOff = max(overshootOff, (p.off - endValue) * direction)
                }
            }
            var lastChange = 0
            for i in 1..<points.count where points[i].valid && points[i - 1].valid {
                let delta = points[i].raw - points[i - 1].raw
                if delta != 0 {
                    let sign = delta > 0 ? 1.0 : -1.0
                    if direction != 0 && sign != direction {
                        finishStroke(i - 1); strokeStart = i - 1
                    } else if direction == 0 { strokeStart = i - 1 }
                    direction = sign; lastChange = i
                } else if direction != 0 && points[i].time - points[lastChange].time >= 0.15 {
                    finishStroke(lastChange); direction = 0
                }
            }
            if direction != 0 { finishStroke(points.count - 1) }
            let final = eligible.last ?? points.last!
            var metrics: [String: Double] = [
                "duration_s": last.time - first.time, "samples": Double(samples.count),
                "max_compensation_deg": maxCompensation,
                "motion_mean_abs_error_off_deg": meanOff, "motion_mean_abs_error_on_deg": meanOn,
                "observed_stop_reverse_overshoot_off_deg": max(0, overshootOff),
                "observed_stop_reverse_overshoot_on_deg": max(0, overshootOn),
                "final_return_error_off_deg": abs(final.off - final.raw), "final_return_error_on_deg": abs(final.on - final.raw),
                "midpoint_advance_mean_ms": midpointAdvances.isEmpty ? 0 : midpointAdvances.reduce(0, +) / Double(midpointAdvances.count),
                "midpoint_comparisons": Double(midpointAdvances.count)]
            if synthetic {
                metrics["synthetic_truth_mae_off_deg"] = eligible.reduce(0) { $0 + abs($1.off - syntheticAngle(key, $1.time)) } / Double(max(1, eligible.count))
                metrics["synthetic_truth_mae_on_deg"] = eligible.reduce(0) { $0 + abs($1.on - syntheticAngle(key, $1.time)) } / Double(max(1, eligible.count))
            }
            actions.append(ReplayAction(id: key, complete: complete, points: points, metrics: metrics))
        }
        try csv.joined(separator: "\n").write(to: output.appendingPathComponent("replay.csv"), atomically: true, encoding: .utf8)
        let summary: [String: Any] = [
            "schema": 2, "synthetic": synthetic, "actions": actions.count, "valid_samples": validSamples,
            "repeated_readings": repeated, "observed_angle_changes": changes, "display_simulation_fps": fps,
            "prediction_lookahead_ms": 20, "compensation_limit_deg": 2, "velocity_window_ms": 80,
            "extrapolation_expiry_ms": 100, "smoothing_time_constant_ms": 25,
            "read_duration_ms": stats(readDurations), "processing_wait_ms": stats(processingWaits),
            "moving_angle_change_interval_ms": stats(changeIntervals),
            "gpu_duration_ms": stats(records.filter { $0.kind == "gpuComplete" }.compactMap(\.duration)),
            "cpu_encode_ms": stats(records.filter { $0.kind == "gpuSubmit" }.compactMap(\.duration)),
            "gpu_queue_wait_ms": stats(records.filter { $0.kind == "gpuStart" }.compactMap(\.duration)),
            "replay_max_difference_degrees": replayErrors.max() ?? 0,
            "absolute_physical_latency_measured": false, "training_performed": false,
            "warnings": warnings, "per_action": actions.map { ["id": $0.id, "complete": $0.complete, "metrics": $0.metrics] as [String: Any] },
            "interpretation": "Angle-domain smoothing and 60/120 Hz render simulation. Midpoint advance is a software-output comparison. Stop/reverse overshoot uses observed sample extrema. No external physical latency measurement."
        ]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: output.appendingPathComponent("summary.json"))
        let data = try JSONEncoder().encode(actions)
        let payload = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let template = try String(contentsOf: root.appendingPathComponent("Tools/replay-template.html"), encoding: .utf8)
        let html = template.replacingOccurrences(of: "__REPLAY_DATA__", with: payload)
            .replacingOccurrences(of: "__SOURCE__", with: synthetic ? "合成测试动作" : "本地开合记录")
        try html.write(to: output.appendingPathComponent("replay.html"), atomically: true, encoding: .utf8)
        print(String(data: json, encoding: .utf8)!)
    }
}
