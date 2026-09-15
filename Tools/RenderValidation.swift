import AppKit
import MetalKit
import QuartzCore

@main
struct RenderValidation {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Validation/Visuals")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("No Metal") }
        let lib = try device.makeLibrary(source: GlassMetalView.shader, options: nil)
        let old = try device.makeLibrary(source: String(contentsOf: root.appendingPathComponent("Validation/Baseline/legacy.metal"), encoding: .utf8), options: nil)
        func pipeline(_ library: MTLLibrary) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor(); d.vertexFunction = library.makeFunction(name: "vertexMain")
            d.fragmentFunction = library.makeFunction(name: "glassMain"); d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let newPipeline = try pipeline(lib), oldPipeline = try pipeline(old)
        let width = args.contains("--benchmark") ? 2940 : 1200, height = args.contains("--benchmark") ? 1912 : 780
        func texture(_ w: Int, _ h: Int, mip: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: mip)
            d.usage = [.shaderRead, .renderTarget]; d.storageMode = .shared
            return device.makeTexture(descriptor: d)!
        }
        func fixture(_ name: String) -> MTLTexture {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (name == "dark" ? NSColor(calibratedWhite: 0.04, alpha: 1) : NSColor.white).setFill()
            NSBezierPath(rect: NSRect(x:0,y:0,width:width,height:height)).fill()
            if name == "checker" {
                for y in stride(from: 0, to: height, by: 40) { for x in stride(from: 0, to: width, by: 40) where (x/40+y/40)%2 == 0 {
                    NSColor.darkGray.setFill(); NSBezierPath(rect: NSRect(x:x,y:y,width:40,height:40)).fill()
                } }
            } else if name != "flat" {
                let color: NSColor = name == "dark" ? .white : .black
                for y in stride(from: 36, to: height-30, by: name == "text" ? 28 : 80) {
                    let text = name == "text" ? "Aa Bb Cc 0123456789 · 铰链与桌面  Swift Metal let angle = 120.0;" : "MacBook Duo   清晰 · 柔和 · 开合测试  0123456789"
                    (text as NSString).draw(at: NSPoint(x:70,y:y), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: name == "text" ? 15 : 24, weight: .regular), .foregroundColor: color])
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let cg = context.makeImage()!
            return try! MTKTextureLoader(device: device).newTexture(cgImage: cg, options: [.SRGB: false, .generateMipmaps: true])
        }
        func save(_ t: MTLTexture, _ name: String) throws {
            var data = [UInt8](repeating: 0, count: width*height*4)
            t.getBytes(&data, bytesPerRow: width*4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
            let provider = CGDataProvider(data: Data(data) as CFData)!
            let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let rep = NSBitmapImageRep(cgImage: cg)
            try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        }
        let destination = texture(width,height)
        func render(source: MTLTexture, pyramid: GaussianPyramid, legacy: Bool, tilt: Float, rebuild: Bool, opacity: Float = 1) -> Double {
            let command = queue.makeCommandBuffer()!
            if !legacy && rebuild { pyramid.encode(source: source, command: command) }
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = destination
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(legacy ? oldPipeline : newPipeline)
            if legacy { encoder.setFragmentTexture(source, index: 0) }
            else { for (i,t) in pyramid.levels.enumerated() { encoder.setFragmentTexture(t, index:i) } }
            var parameters: [Float] = [Float(width),Float(height),tilt,0.09,2.4,Float(source.width)/Float(source.height),1,opacity]
            encoder.setFragmentBytes(&parameters, length: parameters.count*4,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU command failed: \(String(describing: command.error))")
            return command.gpuEndTime-command.gpuStartTime
        }
        if args.contains("--handoff") {
            let directory = output.appendingPathComponent("Handoff")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var samples: [[String: Any]] = []
            for name in ["light", "checker"] {
                let source = fixture(name), pyramid = try GaussianPyramid(device: device, library: lib)
                for (index, deficit) in [8.0,6,4,3,2,1,0.5,0.25,0].enumerated() {
                    let angle = HingeMotion.clearAngle(endpoint: 115) - deficit
                    let oldTilt = 80 * HingeMotion.remaining(angle: angle, endpoint: 115)
                    let newTilt = HingeMotion.tilt(angle: angle, endpoint: 115)
                    let opacity = HingeMotion.effectOpacity(angle: angle, endpoint: 115)
                    for before in [true, false] {
                        _ = render(source: source, pyramid: pyramid, legacy: false,
                            tilt: Float(before ? oldTilt : newTilt), rebuild: index == 0 && before,
                            opacity: before ? 1 : Float(opacity))
                        try save(destination, "Handoff/\(name)-\(index)-\(before ? "before" : "after").png")
                    }
                    samples.append(["fixture": name, "index": index, "raw_angle": angle,
                        "deficit_before_clear_deg": deficit, "before_tilt": oldTilt,
                        "after_tilt": newTilt, "after_opacity": opacity])
                }
            }
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted,.sortedKeys])
                .write(to: directory.appendingPathComponent("samples.json"))
            print("PASS: 36 actual GPU endpoint frames; same blur shader, before/after handoff")
        } else if args.contains("--benchmark") {
            let source = fixture("light"), pyramid = try GaussianPyramid(device: device, library:lib)
            let legacy = args.contains("--legacy")
            let duration = 60.0
            var gpu: [Double] = [], intervals: [Double] = []
            var previous = CACurrentMediaTime(), start = previous, next = previous
            while CACurrentMediaTime()-start < duration {
                let now = CACurrentMediaTime()
                let tilt = Float(28+20*sin((now-start)*2))
                gpu.append(render(source:source,pyramid:pyramid,legacy:legacy,tilt:tilt,rebuild:gpu.isEmpty || args.contains("--dynamic")))
                let finished = CACurrentMediaTime()
                if gpu.count > 1 { intervals.append(now-previous) }
                previous = now; next += 1.0/60
                if next > finished { Thread.sleep(forTimeInterval: next-finished) } else { next = finished }
            }
            func stats(_ v: [Double]) -> [String:Double] {
                let a=v.sorted(); return ["mean_ms":a.reduce(0,+)/Double(a.count)*1000,"p95_ms":a[Int(Double(a.count-1)*0.95)]*1000]
            }
            let result: [String:Any] = ["legacy":legacy,"duration":CACurrentMediaTime()-start,"frames":gpu.count,"gpu":stats(gpu),"offscreen_interval":stats(intervals),"size":"\(width)x\(height)","device":device.name,"capture":false,"dynamic":args.contains("--dynamic")]
            let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
            let name="benchmark-\(legacy ? "old":"new")-\(args.contains("--dynamic") ? "dynamic":"motion").json"
            try data.write(to:root.appendingPathComponent("Validation/\(name)")); print(String(data:data,encoding:.utf8)!)
        } else {
            for name in ["light","dark","text","checker","flat"] {
                let source=fixture(name), pyramid=try GaussianPyramid(device:device,library:lib)
                for tilt in [Float(0),5,15,35,60,80] {
                    for legacy in [true,false] {
                        _=render(source:source,pyramid:pyramid,legacy:legacy,tilt:tilt,rebuild:true)
                        try save(destination,"\(name)-\(Int(tilt))-\(legacy ? "old":"new").png")
                    }
                }
            }
            print("PASS: old/new runtime shaders, Gaussian compute, 60 offscreen visual fixtures")
        }
    }
}
