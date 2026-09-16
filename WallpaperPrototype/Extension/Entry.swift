import AppKit
import ExtensionFoundation

@main final class DuoWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(path, RTLD_LAZY | RTLD_GLOBAL) == nil { extensionLog("WallpaperExtensionKit unavailable") }
        if ProcessInfo.processInfo.environment["DUO_RUNTIME_CHECK"] != "1",
           let legacy = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            do { try DuoWallpaperPaths.migrateWallpaper(from: legacy, to: dataDirectory()) }
            catch { extensionLog("Wallpaper migration failed: \(error)") }
        }
        try? FileManager.default.createDirectory(at: dataDirectory(), withIntermediateDirectories: true)
        _ = try? AngleBridge(url: dataDirectory().appendingPathComponent(DuoWallpaperPaths.angleBridgeName), create: true)
        extensionLog("Extension started")
    }
    var configuration: some AppExtensionConfiguration {
        WallpaperExtensionConfig()
    }
}
