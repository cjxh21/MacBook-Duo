import SwiftUI
import MetalKit
import CoreVideo
import Combine

struct RenderTiming: Sendable {
    let frameID: UInt64
    let encodeStart: Double
    let submitted: Double
    let completed: Double
    let gpuStart: Double
    let gpuEnd: Double
    let captureArrival: Double?
    let sensorTime: Double?
    let moving: Bool
    let succeeded: Bool
    var gpuDuration: Double { max(0, gpuEnd - gpuStart) }
}

struct GlassSurface: NSViewRepresentable {
    let image: NSImage
    let tilt: Double
    let frost: Double
    let distance: Double
    var softness: Double = 1
    var angleProvider: (() -> Double)?
    var movingProvider: (() -> Bool)?
    var opacityProvider: (() -> Double)?
    var motionUpdates: AnyPublisher<Void, Never>?
    var enabled = true
    var maximumFPS = 60
    final class Coordinator {
        var updates: AnyCancellable?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> GlassMetalView {
        let view = GlassMetalView()
        context.coordinator.updates = motionUpdates?.sink { [weak view] in
            guard let view else { return }
            view.continuousRendering = view.movingProvider?() ?? false
            if let provider = view.angleProvider { view.setLiveAngle(provider()) }
        }
        return view
    }
    func updateNSView(_ view: GlassMetalView, context: Context) {
        view.angleProvider = angleProvider
        view.movingProvider = movingProvider
        view.opacityProvider = opacityProvider
        view.preferredFramesPerSecond = maximumFPS
        view.renderingEnabled = enabled
        view.configure(image: image, tilt: tilt, frost: frost, distance: distance, softness: softness)
    }
    static func dismantleNSView(_ view: GlassMetalView, coordinator: Coordinator) {
        coordinator.updates?.cancel()
        view.renderingEnabled = false
    }
}

// Separable Gaussian downsampling with clamped edge extension. Each level is
// generated only when source content changes, never for angle-only animation.
final class GaussianPyramid {
    let device: MTLDevice
    let horizontal: MTLComputePipelineState
    let vertical: MTLComputePipelineState
    private(set) var levels: [MTLTexture] = []
    private var temporary: [MTLTexture] = []
    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        horizontal = try device.makeComputePipelineState(function: library.makeFunction(name: "gaussianHorizontal")!)
        vertical = try device.makeComputePipelineState(function: library.makeFunction(name: "gaussianVertical")!)
    }
    @discardableResult
    func encode(source: MTLTexture, command: MTLCommandBuffer) -> Bool {
        if levels.first?.width != source.width || levels.first?.height != source.height {
            levels = [source]; temporary = []
            var w = source.width; var h = source.height
            for _ in 1..<8 {
                let nw = max(1, w / 2), nh = max(1, h / 2)
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: nw, height: h, mipmapped: false)
                desc.storageMode = .private; desc.usage = [.shaderRead, .shaderWrite]
                guard let temp = device.makeTexture(descriptor: desc) else { levels = []; return false }
                desc.height = nh
                guard let result = device.makeTexture(descriptor: desc) else { levels = []; return false }
                temporary.append(temp); levels.append(result)
                w = nw; h = nh
            }
        }
        guard levels.count == 8 else { return false }
        levels[0] = source
        for i in 1..<8 {
            for (pipeline, input, output) in [(horizontal, levels[i-1], temporary[i-1]), (vertical, temporary[i-1], levels[i])] {
                guard let encoder = command.makeComputeCommandEncoder() else { return false }
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
                encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                encoder.endEncoding()
            }
        }
        return true
    }
}

final class GlassMetalView: MTKView, MTKViewDelegate {
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var pyramid: GaussianPyramid?
    private var texture: MTLTexture?
    private var sourceImage: NSImage?
    private var pendingBuffer: CVPixelBuffer?
    private var imageDirty = false
    private var target: Float = 0
    private var displayed: Float = 0
    private var frost: Float = 0.09
    private var eyeDistance: Float = 2.4
    private var softness: Float = 1
    private var lastTime = CACurrentMediaTime()
    private var videoCache: CVMetalTextureCache?
    private var inFlight = 0
    private var epoch = 0
    private var fresh = false
    private var pendingArrival: Double?
    private var sourceArrival: Double?
    var angleProvider: (() -> Double)?
    var sensorTimeProvider: (() -> Double)?
    var movingProvider: (() -> Bool)?
    var opacityProvider: (() -> Double)?
    var onFrame: ((RenderTiming) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?
    var renderingEnabled = false {
        didSet {
            guard renderingEnabled != oldValue else { return }
            epoch += 1; fresh = false
            if !renderingEnabled { isPaused = true } else { requestFrame() }
        }
    }
    var continuousRendering = false
    var isOperational: Bool { pipeline != nil && pyramid != nil }
    var readyForDisplay: Bool { fresh && pipeline != nil }
    var settled: Bool { abs(displayed - target) < 0.03 }
    private(set) var frameCount = 0
    private(set) var pyramidBuildCount = 0
    func setLiveAngle(_ angle: Double) {
        if target != Float(angle) || !settled { target = Float(angle); requestFrame() }
    }
    func resetLiveAngle() { target = 0; displayed = 0; continuousRendering = false; isPaused = true }
    func invalidateContent() {
        epoch += 1; fresh = false; pendingBuffer = nil; sourceImage = nil; texture = nil
        pendingArrival = nil; sourceArrival = nil; imageDirty = false
        renderingEnabled = false; resetLiveAngle()
    }
    func setAppearance(frost: Double, distance: Double = 2.4, softness: Double) {
        guard self.frost != Float(frost) || eyeDistance != Float(distance) || self.softness != Float(softness) else { return }
        self.frost = Float(frost); eyeDistance = Float(distance); self.softness = Float(softness)
        requestFrame()
    }
    func receive(_ buffer: CVPixelBuffer, arrivalTime: Double = CACurrentMediaTime()) {
        pendingBuffer = buffer // bounded, latest-frame-only mailbox
        pendingArrival = arrivalTime
        requestFrame()
    }
    private func requestFrame() {
        guard renderingEnabled else { return }
        if isPaused { lastTime = CACurrentMediaTime() - 1 / Double(max(1, preferredFramesPerSecond)) }
        isPaused = false
    }
    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm; framebufferOnly = true
        preferredFramesPerSecond = 60; isPaused = true; enableSetNeedsDisplay = false
        clearColor = MTLClearColorMake(0.015, 0.018, 0.025, 1)
        autoresizingMask = [.width, .height]
        guard let device else { return }
        queue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &videoCache)
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "glassMain")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pyramid = try GaussianPyramid(device: device, library: library)
        } catch { NSLog("MacBook Duo Metal: %@", String(describing: error)) }
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func configure(image: NSImage, tilt: Double, frost: Double, distance: Double, softness: Double = 1) {
        if sourceImage !== image, let device, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            do {
                texture = try MTKTextureLoader(device: device).newTexture(cgImage: cgImage, options: [.SRGB: false])
                sourceImage = image; imageDirty = true
            } catch { NSLog("Image texture failed: %@", String(describing: error)) }
        }
        setAppearance(frost: frost, distance: distance, softness: softness)
        setLiveAngle(tilt)
        if imageDirty { requestFrame() }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestFrame() }
    func draw(in view: MTKView) {
        guard renderingEnabled, inFlight < 2, let device, let queue, let pipeline, let pyramid else { return }
        if let angleProvider { target = Float(angleProvider()) }
        if let movingProvider { continuousRendering = movingProvider() }
        let encodeStart = CACurrentMediaTime()
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor, let command = queue.makeCommandBuffer() else { return }
        var retainedWrapper: CVMetalTexture?
        var retainedBuffer: CVPixelBuffer?
        if let buffer = pendingBuffer, let cache = videoCache {
            var wrapper: CVMetalTexture?
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &wrapper) == kCVReturnSuccess,
               let wrapper, let source = CVMetalTextureGetTexture(wrapper) {
                if texture?.width != w || texture?.height != h || sourceImage != nil {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                    d.storageMode = .private; d.usage = [.shaderRead]
                    texture = device.makeTexture(descriptor: d); sourceImage = nil
                }
                if let texture, let blit = command.makeBlitCommandEncoder() {
                    blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                              sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture,
                              destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                    blit.endEncoding(); imageDirty = true
                    retainedWrapper = wrapper; retainedBuffer = buffer; pendingBuffer = nil
                    sourceArrival = pendingArrival; pendingArrival = nil
                }
            }
        }
        guard let texture else { isPaused = true; return }
        if imageDirty {
            guard pyramid.encode(source: texture, command: command) else { isPaused = true; onFailure?(); return }
            pyramidBuildCount += 1; imageDirty = false
        }
        guard pyramid.levels.count == 8, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        if !fresh || target == 0 { displayed = target }
        else { displayed += (target - displayed) * Float(HingeMotion.blend(deltaTime: now - lastTime)) }
        if abs(target - displayed) < 0.001 { displayed = target }
        lastTime = now
        var p = [Float(drawableSize.width), Float(drawableSize.height), displayed, frost, eyeDistance,
                 Float(texture.width) / Float(texture.height), softness, Float(opacityProvider?() ?? 1)]
        encoder.setRenderPipelineState(pipeline)
        for (i, level) in pyramid.levels.enumerated() { encoder.setFragmentTexture(level, index: i) }
        encoder.setFragmentBytes(&p, length: p.count * MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
        command.present(drawable)
        let token = epoch
        inFlight += 1; frameCount += 1
        let frameID = UInt64(frameCount)
        let arrival = sourceArrival, sampleTime = sensorTimeProvider?()
        let moving = continuousRendering
        let submitted = CACurrentMediaTime()
        command.addCompletedHandler { [weak self, retainedWrapper, retainedBuffer] command in
            _ = retainedWrapper; _ = retainedBuffer
            let completed = CACurrentMediaTime()
            let success = command.status == .completed
            let timing = RenderTiming(frameID: frameID, encodeStart: encodeStart, submitted: submitted,
                completed: completed, gpuStart: command.gpuStartTime, gpuEnd: command.gpuEndTime,
                captureArrival: arrival, sensorTime: sampleTime, moving: moving, succeeded: success)
            Task { @MainActor in
                guard let self else { return }
                self.inFlight -= 1
                self.onFrame?(timing)
                guard self.epoch == token else { return }
                if success {
                    let first = !self.fresh
                    self.fresh = true
                    if first { self.onReady?() }
                } else { self.isPaused = true; self.onFailure?() }
            }
        }
        command.commit()
        if !continuousRendering && abs(target - displayed) < 0.005 && pendingBuffer == nil { isPaused = true }
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    constant float weights[5] = {0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216};
    kernel void gaussianHorizontal(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(p) + 0.5) / float2(dst.get_width(), dst.get_height());
        float2 d = float2(1.0 / src.get_width(), 0);
        float4 c = src.sample(s, uv) * weights[0];
        for (int i=1; i<5; i++) c += (src.sample(s, uv + d*i) + src.sample(s, uv - d*i))*weights[i];
        dst.write(c, p);
    }
    kernel void gaussianVertical(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = (float2(p) + 0.5) / float2(dst.get_width(), dst.get_height());
        float2 d = float2(0, 1.0 / src.get_height());
        float4 c = src.sample(s, uv) * weights[0];
        for (int i=1; i<5; i++) c += (src.sample(s, uv + d*i) + src.sample(s, uv - d*i))*weights[i];
        dst.write(c, p);
    }
    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct Params { float2 size; float angle; float frost; float eye; float imageAspect; float softness; float opacity; };
    float2 normalCDF(float2 x) {
        float2 a = abs(x) * 0.70710678118;
        float2 t = 1.0 / (1.0 + 0.3275911 * a);
        float2 erfAbs = 1.0 - (((((1.061405429*t - 1.453152027)*t) + 1.421413741)*t - 0.284496736)*t + 0.254829592)*t*exp(-a*a);
        return 0.5 + 0.5 * sign(x) * erfAbs;
    }
    vertex VertexOut vertexMain(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1), uv};
    }
    fragment float4 glassMain(VertexOut in [[stage_in]], array<texture2d<float>, 8> tex [[texture(0)]], constant Params& p [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float angle = p.angle * M_PI_F / 180;
        float2 pixel = in.uv * p.size;
        float d = p.size.y - pixel.y;
        float gap = d * sin(angle);
        float2 glass = float2(pixel.x, p.size.y - d * cos(angle));
        float eye = p.size.y * p.eye;
        float2 hit = p.size*0.5 + (glass-p.size*0.5)*eye/max(eye-gap, eye*0.15);
        float screenAspect = p.size.x/p.size.y;
        float2 fit = screenAspect > p.imageAspect ? float2(1, screenAspect/p.imageAspect) : float2(p.imageAspect/screenAspect, 1);
        float2 uv = (hit/p.size-0.5)/fit+0.5;
        if (abs(p.angle) < 0.00001) return float4(tex[0].sample(s, uv).rgb, 1);
        float radius = min(abs(gap)*p.frost, p.size.y*0.055);
        float sigma = radius*0.5 * float(tex[0].get_height())/(p.size.y*fit.y);
        // Nine-tap Gaussian variance plus linear downsampling. Variances add
        // through the pyramid; mix adjacent levels in variance, continuously.
        float variance = sigma * sigma;
        float firstVariance = 3.105;
        float level = 0.5 * log2(1.0 + 3.0 * variance / firstVariance);
        level = clamp(level, 0.0f, 7.0f);
        uint lo = uint(floor(level)), hi = min(lo+1, 7u);
        float loVariance = firstVariance * (exp2(2.0 * float(lo))-1.0) / 3.0;
        float hiVariance = firstVariance * (exp2(2.0 * float(hi))-1.0) / 3.0;
        float blend = clamp((variance-loVariance)/max(0.00001f, hiVariance-loVariance), 0.0f, 1.0f);
        float3 color = sigma < 0.05 ? tex[0].sample(s, uv).rgb :
            mix(tex[lo].sample(s, uv).rgb, tex[hi].sample(s, uv).rgb, blend);
        float2 edgeDistance = min(uv, 1-uv)*p.size*fit;
        // Analytic Gaussian coverage for the extended content plane, in the
        // same pixel units as content blur. Derivatives provide subpixel AA;
        // there is no constant glow at the fully open angle.
        float2 edgeSigma = max(radius * 0.5 * p.softness, 0.35 * fwidth(edgeDistance));
        float2 coverageXY = normalCDF(edgeDistance / max(edgeSigma, float2(0.00001)));
        float coverage = coverageXY.x * coverageXY.y;
        color *= 1-min(abs(gap)/p.size.y*0.30, 0.25);
        float sheen = exp(-pow((in.uv.y-(0.25+sin(angle)*0.7))/0.19, 2.0));
        color += float3(0.78,0.87,1)*sheen*abs(sin(angle))*0.025;
        float3 result = mix(float3(0.015,0.018,0.025), color, coverage);
        // Screenshot mode dissolves to the aligned original. Live mode uses
        // panel opacity to reveal the real desktop, with the same angle curve.
        if (p.opacity < 1) {
            float2 originalUV = (in.uv - 0.5) / fit + 0.5;
            result = mix(tex[0].sample(s, originalUV).rgb, result, saturate(p.opacity));
        }
        return float4(result, 1);
    }
    """
}
