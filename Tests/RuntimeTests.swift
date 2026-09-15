import Foundation
import QuartzCore

@main
struct RuntimeTests {
    static func sample(_ t: Double, _ a: Double, valid: Bool = true) -> MotionSample {
        MotionSample(time: t, raw: valid ? UInt16(max(0,a)) : nil, angle: a, readDuration: 0.0001, valid: valid)
    }
    static func main() throws {
        var e = MotionEstimator()
        for i in 0...20 { e.ingest(sample(Double(i)/120, 120-Double(i)/2)) }
        let t = 20.0/120
        assert(e.snapshot.velocity < 0)
        assert(e.snapshot.predicted(at: t, enabled: true) < e.snapshot.sample.angle)
        assert(abs(e.snapshot.predicted(at: t, enabled: true)-e.snapshot.sample.angle) <= 2)
        assert(e.snapshot.predicted(at: t+0.11, enabled: true) == e.snapshot.sample.angle)
        assert(e.snapshot.predicted(at: t, enabled: false) == e.snapshot.sample.angle)
        e.ingest(sample(t+0.01, 111))
        assert(e.snapshot.velocity == 0, "Reverse must reset estimator")
        e.ingest(sample(t+0.02, 111, valid: false))
        assert(e.snapshot.velocity == 0)
        e.ingest(sample(t+1, 95))
        assert(e.snapshot.predicted(at: t+1, enabled: true) == 95)
        for _ in 0..<3 { e.reset(); assert(e.snapshot.velocity == 0) }
        e.ingest(sample(t+1.01, 94))
        assert(e.snapshot.direction == -1 && e.snapshot.moving(at: t+1.01), "First change after reset must wake capture")
        assert(e.snapshot.velocity == 0, "First sample after reset must not reuse old velocity")
        for mode in PerformanceMode.allCases {
            for ac in [false,true] { for low in [false,true] {
                let expected: PerformanceMode = low ? .saver : (mode == .automatic ? (ac ? .responsive : .saver) : mode)
                assert(mode.resolved(onAC: ac, lowPower: low) == expected)
            } }
        }
        assert(CapturePolicy.fps(mode: .saver, clearDuration: 1.9, approaching: false) == 30)
        assert(CapturePolicy.fps(mode: .saver, clearDuration: 2, approaching: false) == 0)
        assert(CapturePolicy.fps(mode: .saver, clearDuration: 20, approaching: true) == 30)
        assert(CapturePolicy.fps(mode: .balanced, clearDuration: 1, approaching: false) == 60)
        assert(CapturePolicy.fps(mode: .responsive, clearDuration: 200, approaching: false) == 0)
        var segmenter = MotionSegmenter()
        for i in 0...100 {
            assert(segmenter.ingest(MotionRecord(kind: "sample", time: Double(i)/100, sample: sample(Double(i)/100,120))).isEmpty)
        }
        let begin = segmenter.ingest(MotionRecord(kind: "sample", time: 1.01, sample: sample(1.01,119)))
        assert(begin.first?.kind == "actionStart")
        assert(begin.first!.time >= 0.50 && begin.first!.time <= 0.52)
        let end = segmenter.ingest(MotionRecord(kind: "sample", time: 2.02, sample: sample(2.02,119)))
        assert(end.last?.kind == "actionEnd" && segmenter.action == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duo-tests-\(UUID().uuidString)")
        let suite = "duo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let recorder = MotionRecorder(directory: root.appendingPathComponent("records"), defaults: defaults)
        assert(recorder.status().enabled && recorder.status().deadline != nil)
        var estimator = MotionEstimator()
        for i in 0..<240 {
            let angle = i < 60 ? 120 : (i < 100 ? 120-Double(i-60)/2 : 100)
            estimator.ingest(sample(Double(i)/120, angle)); recorder.ingest(estimator.snapshot)
        }
        recorder.close()
        assert(recorder.status().actions == 1 && recorder.status().bytes > 0)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("records"), includingPropertiesForKeys: nil)
        let content = try String(contentsOf: files[0], encoding: .utf8)
        for line in content.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        assert(content.contains("actionStart") && content.contains("actionEnd") && content.contains("raw"))
        assert(content.contains("\"schema\":2") && content.contains("wallTime") && content.contains("processingWait"))
        // More than one completed action must remain independently replayable.
        var second = MotionEstimator()
        for i in 0..<220 {
            second.ingest(sample(3 + Double(i)/120, i < 60 ? 100 : 105))
            recorder.ingest(second.snapshot)
        }
        recorder.close()
        let actions = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("records"), includingPropertiesForKeys: nil)
        assert(actions.count == 2 && recorder.status().actions == 2)
        for action in actions {
            let lines = try String(contentsOf: action, encoding: .utf8).split(separator: "\n")
            let decoded = try lines.map { try JSONDecoder().decode(MotionRecord.self, from: Data($0.utf8)) }
            assert(decoded.filter { $0.kind == "actionStart" }.count == 1)
            assert(decoded.filter { $0.kind == "actionEnd" }.count == 1)
        }
        recorder.setEnabled(false); recorder.close(); assert(!recorder.status().enabled)
        recorder.setEnabled(true, newPeriod: true); recorder.close(); assert(recorder.status().enabled)
        let expiredSuite = "duo-expired-\(UUID().uuidString)"
        let expired = UserDefaults(suiteName: expiredSuite)!
        defer { expired.removePersistentDomain(forName: expiredSuite) }
        expired.set(true, forKey: "recording.initialized.v1"); expired.set(true, forKey: "recording.enabled")
        expired.set(Date.distantPast, forKey: "recording.deadline")
        let expiredRecorder = MotionRecorder(directory: root.appendingPathComponent("expired"), defaults: expired)
        assert(!expiredRecorder.status().enabled)
        let failed = MotionRecorder(directory: URL(fileURLWithPath: "/dev/null/records"), defaults: expired)
        assert(!failed.status().enabled && failed.status().error != nil)
        let writeSuite = "duo-write-failure-\(UUID().uuidString)"
        let writeDefaults = UserDefaults(suiteName: writeSuite)!
        defer { writeDefaults.removePersistentDomain(forName: writeSuite) }
        let writePath = root.appendingPathComponent("write-failure")
        let writeFailure = MotionRecorder(directory: writePath, defaults: writeDefaults)
        assert(writeFailure.status().enabled)
        try FileManager.default.removeItem(at: writePath)
        try Data("directory replaced during collection".utf8).write(to: writePath)
        var writeEstimator = MotionEstimator()
        for i in 0..<15 {
            writeEstimator.ingest(sample(Double(i)/120, 110 - Double(i)))
            writeFailure.ingest(writeEstimator.snapshot)
        }
        writeFailure.synchronize()
        assert(!writeFailure.status().enabled && writeFailure.status().error != nil,
               "A write failure must stop recording and report the reason")
        let capSuite = "duo-cap-\(UUID().uuidString)"
        let capDefaults = UserDefaults(suiteName: capSuite)!
        defer { capDefaults.removePersistentDomain(forName: capSuite) }
        let limited = MotionRecorder(directory: root.appendingPathComponent("limited"), defaults: capDefaults, capacity: 2048)
        var capEstimator = MotionEstimator()
        for i in 0..<100 {
            capEstimator.ingest(sample(Double(i)/120, Double(100+i%10)))
            limited.ingest(capEstimator.snapshot)
        }
        limited.close()
        assert(!limited.status().enabled && limited.status().bytes <= 2048)
        let exportDone = DispatchSemaphore(value: 0)
        recorder.export(to: root.appendingPathComponent("export")) { error in assert(error == nil); exportDone.signal() }
        exportDone.wait()
        assert(FileManager.default.fileExists(atPath: root.appendingPathComponent("export").path))
        let clearDone = DispatchSemaphore(value: 0)
        recorder.clear { error in assert(error == nil); clearDone.signal() }
        clearDone.wait()
        assert(recorder.status().bytes == 0 && !recorder.status().enabled)
        print("PASS: capacity ceiling, export and explicit clear")
        print("PASS: motion prediction, reverse/stop/gap, power policies, segmentation/pre-roll, persisted JSONL, stop/restart, deadline and disk failure")
    }
}
