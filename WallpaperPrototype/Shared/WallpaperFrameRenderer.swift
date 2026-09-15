import AppKit
import MetalKit
import CoreVideo

// Reuses the production Gaussian pyramid and shader, but targets IOSurface
// pixel buffers for remote wallpaper composition instead of a local MTKView.
final class WallpaperFrameRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let pyramid: GaussianPyramid
    private(set) var source: MTLTexture
    let width: Int
    let height: Int
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var pyramidReady = false
    private(set) var frameCount = 0
    private(set) var pyramidBuilds = 0
    private(set) var lastBuffer: CVPixelBuffer?

    init(width: Int, height: Int, sourceImage: CGImage? = nil) throws {
        self.width = max(64, min(1920, width)); self.height = max(64, min(1920, height))
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Self.failure("Metal unavailable") }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: GlassMetalView.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "glassMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pyramid = try GaussianPyramid(device: device, library: library)
        source = try MTKTextureLoader(device: device).newTexture(cgImage: sourceImage ?? DuoBackdrop.image(), options: [.SRGB: false])
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else { throw Self.failure("Texture cache") }
        let attributes: [String: Any] = [kCVPixelBufferWidthKey as String: self.width,
            kCVPixelBufferHeightKey as String: self.height, kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw Self.failure("Pixel pool") }
    }
    static func failure(_ description: String) -> NSError {
        NSError(domain: "DuoWallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    func replaceSource(_ image: CGImage) throws {
        source = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false])
        pyramidReady = false
    }
    func render(tilt: Double, opacity: Double, frost: Double = 0.09, softness: Double = 1) throws -> CVPixelBuffer {
        guard tilt.isFinite, opacity.isFinite, frost.isFinite, softness.isFinite, let pool, let cache else { throw Self.failure("Invalid parameters") }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw Self.failure("Pixel pool busy") }
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper) == kCVReturnSuccess,
              let wrapper, let texture = CVMetalTextureGetTexture(wrapper), let command = queue.makeCommandBuffer() else { throw Self.failure("IOSurface texture") }
        if !pyramidReady {
            guard pyramid.encode(source: source, command: command) else { throw Self.failure("Gaussian pyramid") }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw Self.failure("Render encoder") }
        encoder.setRenderPipelineState(pipeline)
        for (index, level) in pyramid.levels.enumerated() { encoder.setFragmentTexture(level, index: index) }
        var params: [Float] = [Float(width), Float(height), Float(tilt), Float(frost), 2.4,
                              Float(source.width) / Float(source.height), Float(softness), Float(opacity)]
        encoder.setFragmentBytes(&params, length: params.count * 4, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(wrapper) {}
        guard command.status == .completed else { throw Self.failure(command.error?.localizedDescription ?? "GPU failure") }
        if !pyramidReady { pyramidReady = true; pyramidBuilds += 1 }
        frameCount += 1; lastBuffer = buffer
        return buffer
    }
}
