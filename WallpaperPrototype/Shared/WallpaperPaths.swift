import Foundation
import Darwin

/// A dedicated shared directory, outside either application's private container.
/// The sandboxed extension has access only to this directory via its entitlement.
enum DuoWallpaperPaths {
    static let extensionBundleID = "studio.prototype.DuoWallpaper.extension"
    static let customWallpaperName = "duo-wallpaper.png"
    static let thumbnailName = "duo-thumbnail.png"
    static let angleBridgeName = "duo-state-v2.bin"

    static var documentsDirectory: URL {
        // Foundation's home directory is container-relative inside the extension.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/MacBook Duo/Wallpaper", isDirectory: true)
    }

    /// Only the extension migrates its own legacy container. Never overwrite a
    /// newer import and never copy the stale motion bridge.
    static func migrateWallpaper(from legacy: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let source = legacy.appendingPathComponent(customWallpaperName)
        let target = destination.appendingPathComponent(customWallpaperName)
        if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) {
            do { try fm.copyItem(at: source, to: target) }
            catch where (error as NSError).code == NSFileWriteFileExistsError { }
        }
    }

    static var customWallpaperURL: URL { documentsDirectory.appendingPathComponent(customWallpaperName) }
    static var thumbnailURL: URL { documentsDirectory.appendingPathComponent(thumbnailName) }
    static var angleBridgeURL: URL { documentsDirectory.appendingPathComponent(angleBridgeName) }
}
