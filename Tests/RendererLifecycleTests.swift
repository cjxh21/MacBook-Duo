import AppKit
import MetalKit
import CoreVideo

@main
struct RendererLifecycleTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:640,height:420), styleMask:.borderless, backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        // The live panel is fully transparent until a fresh GPU frame completes.
        window.alphaValue = 0
        let view = GlassMetalView(); window.contentView = view; window.orderFrontRegardless()
        precondition(view.isOperational)
        var buffer: CVPixelBuffer?
        let attrs:[String:Any] = [kCVPixelBufferMetalCompatibilityKey as String:true, kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        precondition(CVPixelBufferCreate(nil,640,420,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&buffer) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(buffer!,[])
        memset(CVPixelBufferGetBaseAddress(buffer!),220,CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!,[])
        func run(_ seconds: Double) { let deadline=Date().addingTimeInterval(seconds);while Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.005)) } }
        view.receive(buffer!); run(0.2)
        precondition(view.frameCount == 0 && view.pyramidBuildCount == 0, "hidden renderer must do no GPU work")
        view.onReady = { window.alphaValue = 1 }
        view.renderingEnabled = true; view.setLiveAngle(20); view.draw(); run(1)
        precondition(view.readyForDisplay && view.pyramidBuildCount == 1 && window.alphaValue == 1, "fresh frame must prepare behind zero-alpha panel")
        let settledCount=view.frameCount; run(0.3)
        precondition(view.frameCount == settledCount, "static texture/angle must pause")
        view.setLiveAngle(35); run(0.7)
        precondition(view.frameCount > settledCount && view.pyramidBuildCount == 1, "angle must not rebuild blur")
        view.setLiveAngle(0); view.draw()
        precondition(view.settled, "The real clear boundary must bypass smoothing immediately")
        view.renderingEnabled = false
        let hiddenCount=view.frameCount
        for _ in 0..<100 { view.receive(buffer!) }; run(0.2)
        precondition(view.frameCount == hiddenCount && view.pyramidBuildCount == 1)
        view.renderingEnabled = true; run(0.3)
        precondition(view.pyramidBuildCount == 2, "latest-frame mailbox must coalesce hidden captures")
        view.invalidateContent(); precondition(!view.readyForDisplay)
        view.receive(buffer!); view.renderingEnabled = true; view.setLiveAngle(20); run(0.7)
        precondition(view.readyForDisplay, "resume must use a fresh GPU-complete frame")
        window.orderOut(nil)
        print("PASS: hidden zero-render, first-frame readiness, static pause, angle-only blur reuse, latest-frame coalescing, fresh resume")
    }
}
