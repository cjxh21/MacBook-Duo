import Foundation
import Darwin

struct WallpaperAngle {
    var time: Double
    var angle: Double
    var predicted: Double
    var endpoint: Double
    var frost: Double
    var softness: Double
    var valid: Bool
    var awake: Bool
    func fresh(at now: Double) -> Bool {
        valid && awake && time.isFinite && now >= time && now - time < 0.5 &&
        angle.isFinite && (0...180).contains(angle) && predicted.isFinite &&
        (0...180).contains(predicted) && endpoint.isFinite && (1...180).contains(endpoint) &&
        frost.isFinite && (0...1).contains(frost) && softness.isFinite && (0...4).contains(softness)
    }
}

// One fixed-size memory-mapped page, not a stream of files. Advisory locks are
// held only around a 72-byte copy. A dead process cannot leave a held flock.
final class AngleBridge {
    static let byteCount = 72
    private let fd: Int32
    private let memory: UnsafeMutableRawPointer
    init(url: URL, create: Bool) throws {
        fd = open(url.path, O_RDWR | O_NOFOLLOW | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            close(fd); throw NSError(domain: "DuoBridge", code: 1)
        }
        if create && info.st_size == 0 { _ = ftruncate(fd, off_t(Self.byteCount)) }
        _ = fstat(fd, &info)
        guard info.st_size == Self.byteCount,
              let mapped = mmap(nil, Self.byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else {
            close(fd); throw NSError(domain: "DuoBridge", code: 2)
        }
        memory = mapped
    }
    deinit { munmap(memory, Self.byteCount); close(fd) }
    @discardableResult func write(_ s: WallpaperAngle) -> Bool {
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        let fields = [1.0, s.time, s.angle, s.predicted, s.endpoint, s.frost, s.softness, s.valid ? 1.0 : 0.0, s.awake ? 1.0 : 0.0]
        fields.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: Self.byteCount) }
        return true
    }
    func read() -> WallpaperAngle? {
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        let f = Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: Double.self), count: 9))
        guard f[0] == 1 else { return nil }
        return WallpaperAngle(time: f[1], angle: f[2], predicted: f[3], endpoint: f[4], frost: f[5], softness: f[6], valid: f[7] == 1, awake: f[8] == 1)
    }
}
