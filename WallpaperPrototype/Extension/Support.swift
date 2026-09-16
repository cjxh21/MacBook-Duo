import AppKit
import IOSurface

func extensionLog(_ text: String) {
    NSLog("DuoWallpaper: %@", text)
}
func traceLog(_ text: String) { extensionLog(text) }
func property(_ name: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 8 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == name { return child.value }
        if let found = property(name, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}
func enumName(_ value: Any) -> String {
    let m = Mirror(reflecting: value)
    return m.displayStyle == .enum ? (m.children.first?.label ?? String(describing: value)) : String(describing: value)
}
func dataDirectory() -> URL {
    if ProcessInfo.processInfo.environment["DUO_RUNTIME_CHECK"] == "1" {
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("WallpaperPrototype/build/validation/runtime-data")
    }
    return DuoWallpaperPaths.documentsDirectory
}
func makeSnapshot(_ buffer: CVPixelBuffer) -> AnyObject? {
    guard let ref = CVPixelBufferGetIOSurface(buffer) else { return nil }
    return createSnapshotXPC(surface: ref.takeUnretainedValue())
}
