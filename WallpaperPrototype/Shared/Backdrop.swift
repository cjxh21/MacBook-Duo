import AppKit

// Deliberately synthetic wallpaper; no desktop capture or user's files.
enum DuoBackdrop {
    static func image(width: Int = 1200, height: Int = 780) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [NSColor(red: 0.02, green: 0.08, blue: 0.18, alpha: 1).cgColor,
                      NSColor(red: 0.02, green: 0.48, blue: 0.53, alpha: 1).cgColor,
                      NSColor(red: 0.30, green: 0.18, blue: 0.55, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
        ctx.setLineWidth(1)
        for i in 0...18 {
            let x = CGFloat(i) / 18 * CGFloat(width)
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: CGFloat(height)))
        }
        for i in 0...12 {
            let y = CGFloat(i) / 12 * CGFloat(height)
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: CGFloat(width), y: y))
        }
        ctx.strokePath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("DUO  /  LOCK SCREEN LAB" as NSString).draw(at: CGPoint(x: 45, y: 42), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
