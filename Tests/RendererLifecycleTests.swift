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
        // Exercise the renderer's scheduling flags even when the physical
        // display is asleep and its display link does not deliver callbacks.
        func run(_ seconds: Double) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if view.renderingEnabled && !view.isPaused { view.draw() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }
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
        view.invalidateContent()
        var wakeAngle = 90.0
        view.wakeAngleProvider = { wakeAngle }
        view.movingProvider = { true }
        let priorPyramids = view.pyramidBuildCount
        let cover = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false; cover.backgroundColor = .black
        cover.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        cover.orderFrontRegardless()
        var wakeReady = false
        view.onReady = { wakeReady = true; window.alphaValue = 1; cover.orderOut(nil) }
        window.alphaValue = 0
        view.receive(buffer!); view.renderingEnabled = true; view.draw(); run(0.4)
        precondition(wakeReady && !cover.isVisible, "The folded first frame must become ready behind the black cover")
        precondition(view.pyramidBuildCount == priorPyramids, "Wake frames must skip the blur pyramid")
        wakeAngle = 45; run(0.15)
        wakeAngle = 0; run(0.15)
        view.wakeAngleProvider = nil; view.movingProvider = nil; view.continuousRendering = false
        view.setLiveAngle(0); view.draw(); run(0.2)
        precondition(view.pyramidBuildCount == priorPyramids + 1, "Returning to hinge rendering prepares the latest source once")
        window.orderOut(nil)
        print("PASS: hidden zero-render, first-frame readiness, static pause, angle-only blur reuse, fresh resume, covered wake handoff and separate wake rendering")
    }
}
