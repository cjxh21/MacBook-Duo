import AppKit
import AVFoundation

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    struct Surface {
        let context: CAContext
        let renderer: WallpaperFrameRenderer
        let layer: AVSampleBufferDisplayLayer
        let diagnostic: Bool
        var lastTilt = -1.0
        var lastOpacity = -1.0
        var smoothTilt = 0.0
        var smoothAt = 0.0
        var firstFrame = true
        var format: CMVideoFormatDescription?
        var sourceDate: Date?
    }
    private var surfaces: [String: Surface] = [:]
    private var timer: Timer?
    private var bridge: AngleBridge?
    private var locked = false
    private var wakeTurn = WakePageTurn()
    private var observers: [NSObjectProtocol] = []
    private let start = CACurrentMediaTime()
    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        for (name, awake) in [(NSWorkspace.screensDidSleepNotification, false),
                              (NSWorkspace.screensDidWakeNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setAwake(awake)
            })
        }
    }
    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    private func setAwake(_ awake: Bool) {
        let wasAwake = wakeTurn.awake
        wakeTurn.setAwake(awake, at: CACurrentMediaTime())
        if awake != wasAwake { extensionLog("display awake=\(awake) locked=\(locked)") }
        if awake && !wasAwake {
            for key in Array(surfaces.keys) {
                surfaces[key]?.layer.flush()
                surfaces[key]?.firstFrame = true
            }
        }
    }

    private func key(_ id: Any?) -> String { extractWallpaperUUID(fromID: id)?.uuidString ?? "default" }
    private func customWallpaperDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: DuoWallpaperPaths.customWallpaperURL.path)[.modificationDate]) as? Date
    }
    private func customWallpaper() -> (image: CGImage?, date: Date?) {
        let url = DuoWallpaperPaths.customWallpaperURL
        let date = customWallpaperDate()
        guard let image = NSImage(contentsOf: url) else { return (nil, date) }
        return (image.cgImage(forProposedRect: nil, context: nil, hints: nil), date)
    }
    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        extensionLog("acquire: begin id=\(String(describing: id))")
        DispatchQueue.main.async {
            do {
                let k = self.key(id)
                if let old = self.surfaces[k] { reply(createRemoteContextXPC(contextId: old.context.contextId), nil); return }
                let size = request.flatMap { property("size", in: $0) as? CGSize } ?? CGSize(width: 1470, height: 956)
                let config = request.flatMap { property("configuration", in: $0) as? Data }
                let diagnostic = config == Data("diagnostic".utf8)
                let custom: (image: CGImage?, date: Date?) = diagnostic ? (nil, nil) : self.customWallpaper()
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      let context = CAContext.remoteContext() as? CAContext, context.contextId != 0 else { throw WallpaperFrameRenderer.failure("Remote context unavailable") }
                let renderer = try WallpaperFrameRenderer(width: Int(min(1920, size.width)), height: Int(min(1920, size.height)), sourceImage: custom.0)
                let layer = AVSampleBufferDisplayLayer()
                layer.frame = CGRect(origin: .zero, size: size)
                layer.videoGravity = .resizeAspectFill
                let selector = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
                if layer.responds(to: selector), let implementation = class_getMethodImplementation(type(of: layer), selector) {
                    typealias Setter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
                    unsafeBitCast(implementation, to: Setter.self)(layer, selector, true)
                }
                context.layer = layer
                self.surfaces[k] = Surface(context: context, renderer: renderer, layer: layer, diagnostic: diagnostic, sourceDate: custom.1)
                try self.draw(k, force: true)
                CATransaction.flush()
                reply(createRemoteContextXPC(contextId: context.contextId), nil)
                if self.timer == nil {
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
                }
                extensionLog("acquire: success \(k) diagnostic=\(diagnostic)")
            } catch {
                extensionLog("acquire: error \(error)")
                reply(nil, error)
            }
        }
    }
    private func tick() {
        // Notifications can be missed; keep polling even while asleep.
        setAwake(CGDisplayIsAsleep(CGMainDisplayID()) == 0)
        guard wakeTurn.awake else { return }
        if bridge == nil { bridge = try? AngleBridge(url: dataDirectory().appendingPathComponent(DuoWallpaperPaths.angleBridgeName), create: false) }
        let wakeTilt = wakeTurn.tilt(at: CACurrentMediaTime(), locked: locked, sample: bridge?.read())
        for key in surfaces.keys { do { try draw(key, wakeTilt: wakeTilt) } catch { extensionLog("render: \(error)") } }
    }
    private func draw(_ key: String, force: Bool = false, wakeTilt: Double? = nil) throws {
        guard var s = surfaces[key] else { return }
        if bridge == nil { bridge = try? AngleBridge(url: dataDirectory().appendingPathComponent(DuoWallpaperPaths.angleBridgeName), create: false) }
        let now = CACurrentMediaTime()
        let sample = bridge?.read()
        // The production choice must remain a normal, visible wallpaper when
        // the desktop is active or while the lock-screen sensor sample is
        // temporarily stale.  The effect opacity below only describes the
        // short hinge handoff; a zero default made a freshly acquired frame
        // look like a black wallpaper on some lock/unlock transitions.
        var targetTilt = 0.0, targetOpacity = 1.0
        var frost = 0.09, softness = 1.0
        if s.diagnostic { targetTilt = 18 + 16 * sin((now - start) * 0.7); targetOpacity = 1 }
        else if locked, let sample, sample.fresh(at: now) {
            targetTilt = HingeMotion.tilt(angle: sample.predicted, endpoint: sample.endpoint)
            targetOpacity = HingeMotion.effectOpacity(angle: sample.angle, endpoint: sample.endpoint)
            frost = sample.frost; softness = sample.softness
            if HingeMotion.remaining(angle: sample.angle, endpoint: sample.endpoint) == 0 { targetTilt = 0 }
        }
        if !s.diagnostic, locked, let wakeTilt {
            targetTilt = wakeTilt
            targetOpacity = 1
        }
        // Keep the same angle settling used by the desktop renderer. The sensor
        // reports quantized hinge angles, while HingeMotion.blend supplies the
        // existing 25 ms response curve.
        let dt = s.smoothAt > 0 ? min(0.2, max(0, now - s.smoothAt)) : (1.0 / 30.0)
        let blend = force ? 1.0 : HingeMotion.blend(deltaTime: dt)
        let tilt = force || targetTilt == 0 ? targetTilt : s.smoothTilt + (targetTilt - s.smoothTilt) * blend
        // The production overlay applies effect opacity directly from the
        // current sample; only the angle itself is eased.
        let opacity = targetOpacity
        s.smoothTilt = tilt; s.smoothAt = now
        var sourceChanged = false
        if !s.diagnostic {
            let date = customWallpaperDate()
            if date != s.sourceDate {
                let custom = customWallpaper()
                try s.renderer.replaceSource(custom.image ?? DuoBackdrop.image())
                s.sourceDate = custom.date
                sourceChanged = true
            }
        }
        guard force || s.firstFrame || sourceChanged || abs(s.lastTilt - tilt) > 0.001 || abs(s.lastOpacity - opacity) > 0.001 else {
            surfaces[key] = s
            return
        }
        surfaces[key] = s
        let buffer = try s.renderer.render(tilt: tilt, opacity: opacity, frost: frost, softness: softness)
        if s.format == nil {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &created) == noErr,
                  let created else { throw WallpaperFrameRenderer.failure("Format") }
            s.format = created
        }
        guard let format = s.format else { throw WallpaperFrameRenderer.failure("Format") }
        // Use the time at which the frame is ready. The previous code stamped
        // frames before the GPU wait, so they could arrive late and be shown in
        // bursts when the lid was moving quickly.
        let presentation = CACurrentMediaTime()
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: presentation, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var frame: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &frame) == noErr, let frame else { throw WallpaperFrameRenderer.failure("Sample") }
        // DisplayImmediately is needed for the first frame when WallpaperAgent
        // switches contexts. Applying it to every frame bypasses the video
        // queue's pacing and is a visible source of jitter during fast motion.
        if s.firstFrame, let attachments = CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if s.layer.status == .failed { s.layer.flush() }
        s.layer.enqueue(frame)
        s.lastTilt = tilt; s.lastOpacity = opacity; s.firstFrame = false; surfaces[key] = s
    }
    func update(withId id: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("update: begin id=\(String(describing: id))")
        DispatchQueue.main.async {
            if let request {
                if let mode = property("presentationMode", in: request) { self.locked = enumName(mode) == "locked" }
                if let state = property("activityState", in: request) { self.setAwake(enumName(state) != "suspended") }
            }
            self.tick(); extensionLog("update: complete"); reply(nil)
        }
    }
    func invalidate(withId id: Any?, reply: @escaping (Error?) -> Void) {
        extensionLog("invalidate: begin id=\(String(describing: id))")
        DispatchQueue.main.async {
            self.surfaces.removeValue(forKey: self.key(id))
            if self.surfaces.isEmpty { self.timer?.invalidate(); self.timer = nil }
            extensionLog("invalidate: complete")
            reply(nil)
        }
    }
    func snapshot(withId id: Any?, reply: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async {
            if let buffer = self.surfaces[self.key(id)]?.renderer.lastBuffer { reply(makeSnapshot(buffer), nil) }
            else { reply(nil, WallpaperFrameRenderer.failure("No snapshot yet")) }
        }
    }
    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void) {
        extensionLog("provideSettingsViewModels: begin")
        DispatchQueue.main.async {
            let models = buildSettingsViewModelsXPC()
            extensionLog("provideSettingsViewModels: complete models=\(models != nil)")
            reply(models, nil)
        }
    }
    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess process: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func selectedChoicesDidChange(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func invokeContextMenuAction(withMenuItemID id: Any?, groupItemID group: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func isChoiceDownloaded(with id: Any?, reply: @escaping (Bool, Error?) -> Void) {
        extensionLog("isChoiceDownloaded")
        reply(true, nil)
    }
    func download(withChoiceID id: Any?, reply: (Error?) -> Void) -> Any? { reply(nil); return nil }
    func migrateSelectedChoice(for id: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func migrate(from a: Any?, to b: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func skipShuffledContent(withId id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId id: Any?, reply: @escaping (Bool, Error?) -> Void) {
        extensionLog("canSkipShuffledContent")
        reply(false, nil)
    }
    func handleDebugRequest(for request: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func handleNotification(withNamed name: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func pauseDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func cancelDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func resumeDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
}
