import Foundation
import QuartzCore

struct RecordingContext: Codable, Sendable, Equatable {
    var endpoint = 120.0
    var mode = "automatic"
    var policy = "saver"
    var onAC = false
    var prediction = true
    var state = "off"
    var version = "0.7"
    var lowPower: Bool? = false
    var build: String? = "7"
}

struct MotionRecord: Codable, Sendable {
    var schema = 2
    var kind: String
    var time: Double
    var action: String?
    var sample: MotionSample?
    // Always the candidate with prediction enabled; context.prediction records
    // the user's display choice. Raw acquisition never depends on that switch.
    var predicted: Double?
    var context: RecordingContext?
    var duration: Double?
    var processingWait: Double?
    var processingDuration: Double?
    var frameID: UInt64?
    var sourceTime: Double?
    var wallTime: String?
    var period: String?
    var reason: String?
}

/// Buffers only half a second while idle. Timestamps on repeated readings are
/// retained, but a repeated value never starts or prolongs an action.
struct MotionSegmenter {
    private var preRoll: [MotionRecord] = []
    private var lastAngle: Double?
    private var lastSampleTime: Double?
    private var lastChange = -Double.infinity
    private(set) var action: String?

    mutating func reset() {
        preRoll.removeAll(keepingCapacity: true)
        lastAngle = nil
        lastSampleTime = nil
        lastChange = -.infinity
        action = nil
    }
    mutating func finish(time: Double, reason: String) -> MotionRecord? {
        let record = action.map { MotionRecord(kind: "actionEnd", time: time, action: $0, reason: reason) }
        reset()
        return record
    }
    mutating func ingest(_ record: MotionRecord) -> [MotionRecord] {
        guard record.time.isFinite else { return [] }
        if record.sample == nil {
            if let action {
                var copy = record; copy.action = action
                return [copy]
            }
            buffer(record)
            return []
        }
        let sample = record.sample!
        var output: [MotionRecord] = []
        if let last = lastSampleTime, record.time <= last || record.time - last > 0.1 {
            if let end = finish(time: last, reason: "dataGap") { output.append(end) }
        }
        lastSampleTime = record.time
        guard sample.valid else {
            if let action {
                var copy = record; copy.action = action
                output.append(copy)
                if let end = finish(time: record.time, reason: "invalidSample") { output.append(end) }
            } else { reset() }
            return output
        }
        let changed = lastAngle != nil && lastAngle != sample.angle
        lastAngle = sample.angle
        if changed { lastChange = record.time }
        guard let action else {
            buffer(record)
            guard changed else { return output }
            let id = UUID().uuidString
            self.action = id
            let records = preRoll.sorted { $0.time < $1.time }.map { item -> MotionRecord in
                var copy = item; copy.action = id
                return copy
            }
            output.append(MotionRecord(kind: "actionStart", time: records.first?.time ?? record.time, action: id))
            output.append(contentsOf: records)
            preRoll.removeAll(keepingCapacity: true)
            return output
        }
        var copy = record; copy.action = action
        output.append(copy)
        if record.time - lastChange >= 1 {
            output.append(MotionRecord(kind: "actionEnd", time: record.time, action: action, reason: "stable"))
            self.action = nil
            preRoll.removeAll(keepingCapacity: true)
            // Keep this terminal sample as the beginning of the next pre-roll.
            var idle = record; idle.action = nil
            buffer(idle)
        }
        return output
    }
    private mutating func buffer(_ record: MotionRecord) {
        preRoll.append(record)
        preRoll.removeAll { record.time - $0.time > 0.5 }
        if preRoll.count > 512 { preRoll.removeFirst(preRoll.count - 512) }
    }
}

struct RecorderStatus: Sendable, Equatable {
    var enabled = false
    var deadline: Date?
    var bytes = 0
    var actions = 0
    var error: String?
    var stopReason: String?
}

final class MotionRecorder: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "duo.recording", qos: .utility)
    private let lock = NSLock()
    private var statusValue = RecorderStatus()
    private var context = RecordingContext()
    private var segmenter = MotionSegmenter()
    private var pending = Data()
    private var file: FileHandle?
    private var activeFileAction: String?
    private var lastRecordTime = 0.0
    private var lastFlush = 0.0
    private var finishing = false
    private let encoder = JSONEncoder()
    private let defaults: UserDefaults
    private var period = ""
    // Decimal MB: the actual data store never exceeds the advertised 100 MB.
    static let capacity = 100_000_000
    private let capacityLimit: Int
    private let endReserve = 384
    var onStatusChange: (@Sendable () -> Void)?

    init(directory: URL? = nil, defaults: UserDefaults = .standard, capacity: Int = MotionRecorder.capacity) {
        capacityLimit = capacity
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBook Duo/Motion", isDirectory: true)
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                scan()
                if defaults.object(forKey: "recording.initialized.v1") == nil {
                    defaults.set(true, forKey: "recording.initialized.v1")
                    defaults.set(Date().addingTimeInterval(7 * 86400), forKey: "recording.deadline")
                    defaults.set(true, forKey: "recording.enabled")
                }
                period = defaults.string(forKey: "recording.period") ?? UUID().uuidString
                defaults.set(period, forKey: "recording.period")
                changeStatus {
                    $0.deadline = defaults.object(forKey: "recording.deadline") as? Date
                    $0.enabled = defaults.bool(forKey: "recording.enabled")
                    $0.error = defaults.string(forKey: "recording.error")
                    $0.stopReason = defaults.string(forKey: "recording.stopReason")
                }
                checkLimit()
            } catch { fail(error) }
        }
    }
    func status() -> RecorderStatus { lock.lock(); defer { lock.unlock() }; return statusValue }
    private func changeStatus(_ update: (inout RecorderStatus) -> Void) {
        lock.lock(); update(&statusValue); lock.unlock()
    }
    private func notifyStatus() { onStatusChange?() }
    func setContext(_ value: RecordingContext) { queue.async { self.context = value } }
    func setEnabled(_ enabled: Bool, newPeriod: Bool = false) {
        queue.async {
            self.finishAction(reason: enabled ? "restart" : "userStopped")
            if newPeriod {
                self.period = UUID().uuidString
                self.defaults.set(self.period, forKey: "recording.period")
                self.changeStatus { $0.deadline = Date().addingTimeInterval(7 * 86400) }
            }
            self.changeStatus {
                $0.enabled = enabled
                $0.error = nil
                $0.stopReason = enabled ? nil : "已手动停止"
            }
            self.persistStatus()
            self.checkLimit()
            self.notifyStatus()
        }
    }
    func ingest(_ snapshot: MotionSnapshot) {
        guard status().enabled else { return }
        queue.async {
            self.checkLimit()
            guard self.status().enabled else { return }
            let start = CACurrentMediaTime()
            var record = MotionRecord(kind: "sample", time: snapshot.sample.time, sample: snapshot.sample,
                predicted: snapshot.predicted(at: snapshot.sample.time, enabled: true), context: self.context,
                processingWait: max(0, start - snapshot.sample.time))
            record.processingDuration = CACurrentMediaTime() - start
            self.write(self.segmenter.ingest(record))
            if CACurrentMediaTime() - self.lastFlush >= 1 { self.flush() }
        }
    }
    func event(_ kind: String, time: Double = CACurrentMediaTime(), duration: Double? = nil,
               frameID: UInt64? = nil, sourceTime: Double? = nil) {
        guard status().enabled else { return }
        queue.async {
            guard self.status().enabled else { return }
            let record = MotionRecord(kind: kind, time: time, duration: duration,
                frameID: frameID, sourceTime: sourceTime)
            self.write(self.segmenter.ingest(record))
        }
    }
    private func write(_ records: [MotionRecord]) {
        for record in records {
            guard status().enabled else { break }
            do {
                if record.kind == "actionStart" {
                    // A separate file per action makes export and replay independent
                    // of clean application termination.
                    flush()
                    try file?.close(); file = nil
                    activeFileAction = record.action
                    let name = "action-v2-\(record.action ?? UUID().uuidString).jsonl"
                    let url = directory.appendingPathComponent(name)
                    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                    file = try FileHandle(forWritingTo: url)
                    let header = MotionRecord(kind: "clock", time: CACurrentMediaTime(), action: record.action,
                        context: context, wallTime: ISO8601DateFormatter().string(from: Date()), period: period)
                    guard append(header), append(record) else { break }
                    changeStatus { $0.actions += 1 }
                    notifyStatus()
                } else {
                    guard file != nil, record.action == activeFileAction else { continue }
                    guard append(record) else { break }
                }
                lastRecordTime = record.time
                if record.kind == "actionEnd" {
                    flush()
                    try file?.close(); file = nil; activeFileAction = nil
                    notifyStatus()
                } else if pending.count >= 64 * 1024 { flush() }
            } catch { fail(error) }
        }
    }
    @discardableResult
    private func append(_ record: MotionRecord, reserveEnd: Bool = true) -> Bool {
        do {
            var data = try encoder.encode(record); data.append(10)
            let reserve = reserveEnd && record.kind != "actionEnd" ? endReserve : 0
            guard status().bytes + pending.count + data.count + reserve <= capacityLimit else {
                if !finishing { stopForLimit("记录已达 100MB，已停止；已有数据保留") }
                return false
            }
            pending.append(data)
            return true
        } catch { fail(error); return false }
    }
    private func flush() {
        guard !pending.isEmpty, let file else { return }
        do {
            try file.write(contentsOf: pending)
            changeStatus { $0.bytes += pending.count }
            pending.removeAll(keepingCapacity: true)
            lastFlush = CACurrentMediaTime()
            notifyStatus()
        } catch { fail(error) }
    }
    private func persistStatus() {
        let s = status()
        defaults.set(s.enabled, forKey: "recording.enabled")
        defaults.set(s.deadline, forKey: "recording.deadline")
        defaults.set(s.error, forKey: "recording.error")
        defaults.set(s.stopReason, forKey: "recording.stopReason")
    }
    private func fail(_ error: Error) {
        changeStatus { $0.enabled = false; $0.error = "记录已停止：\(error.localizedDescription)" }
        pending.removeAll()
        try? file?.close(); file = nil; activeFileAction = nil
        segmenter.reset()
        scan() // account for a possible partial write
        persistStatus()
        notifyStatus()
    }
    private func stopForLimit(_ reason: String) {
        guard !finishing else { return }
        finishAction(reason: "collectionLimit")
        changeStatus { $0.enabled = false; $0.stopReason = reason }
        persistStatus()
        notifyStatus()
    }
    private func checkLimit() {
        let s = status()
        guard s.enabled else { return }
        if s.bytes + pending.count >= capacityLimit {
            stopForLimit("记录已达 100MB，已停止；已有数据保留")
        } else if s.deadline == nil || Date() >= s.deadline! {
            stopForLimit("7 天采集期已结束；已有数据保留")
        }
    }
    private func finishAction(reason: String) {
        guard !finishing else { return }
        finishing = true
        if let id = activeFileAction, file != nil {
            _ = append(MotionRecord(kind: "actionEnd", time: max(lastRecordTime, CACurrentMediaTime()),
                action: id, reason: reason), reserveEnd: false)
        }
        flush()
        try? file?.close(); file = nil; activeFileAction = nil
        segmenter.reset()
        finishing = false
    }
    func breakSegment(reason: String = "reset") {
        queue.async { self.finishAction(reason: reason) }
    }
    func tick() { guard status().enabled else { return }; queue.async { self.checkLimit() } }
    func close() { queue.sync { finishAction(reason: "applicationExit") } }
    // Allows deterministic tools to drain asynchronous writes without ending an action.
    func synchronize() { queue.sync {} }
    func export(to destination: URL, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.finishAction(reason: "export")
            do {
                try FileManager.default.copyItem(at: self.directory, to: destination)
                let manifest: [String: Any] = ["schema": 2, "exportedAt": ISO8601DateFormatter().string(from: Date()),
                    "contents": "Angle samples and local software timing only. No desktop images.",
                    "absolutePhysicalLatencyMeasured": false, "trainingPerformed": false]
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                    .write(to: destination.appendingPathComponent("manifest.json"))
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }
    func clear(completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.finishAction(reason: "userCleared")
            self.changeStatus { $0.enabled = false }
            self.persistStatus()
            do {
                for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
                    where url.pathExtension == "jsonl" {
                    try FileManager.default.removeItem(at: url)
                }
                self.changeStatus { $0.bytes = 0; $0.actions = 0; $0.error = nil; $0.stopReason = "记录已清空" }
                self.persistStatus()
                self.notifyStatus()
                completion(nil)
            } catch { self.fail(error); completion(error.localizedDescription) }
        }
    }
    private func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var bytes = 0, actions = 0
        for url in files where url.pathExtension == "jsonl" {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            // Streaming migration also counts actions in old multi-action files.
            var carry = Data()
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                carry.append(chunk)
                while let newline = carry.firstIndex(of: 10) {
                    let line = carry.prefix(upTo: newline)
                    if let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       value["kind"] as? String == "actionStart" { actions += 1 }
                    carry.removeSubrange(...newline)
                }
                if carry.count > 1_048_576 { carry.removeAll() }
            }
        }
        changeStatus { $0.bytes = bytes; $0.actions = actions }
    }
}
