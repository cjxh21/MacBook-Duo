import Foundation

/// Files shared by the unsandboxed MacBook Duo app and the sandboxed wallpaper
/// extension. The extension resolves its own Documents directory; the host uses
/// the matching container path so no broad filesystem access is needed.
enum DuoWallpaperPaths {
    static let extensionBundleID = "studio.prototype.DuoWallpaper.extension"
    static let customWallpaperName = "duo-wallpaper.png"
    static let thumbnailName = "duo-thumbnail.png"
    static let angleBridgeName = "duo-state.bin"

    static var documentsDirectory: URL {
        if Bundle.main.bundleIdentifier == extensionBundleID,
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return directory
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionBundleID)/Data/Documents", isDirectory: true)
    }

    static var customWallpaperURL: URL { documentsDirectory.appendingPathComponent(customWallpaperName) }
    static var thumbnailURL: URL { documentsDirectory.appendingPathComponent(thumbnailName) }
    static var angleBridgeURL: URL { documentsDirectory.appendingPathComponent(angleBridgeName) }
}
