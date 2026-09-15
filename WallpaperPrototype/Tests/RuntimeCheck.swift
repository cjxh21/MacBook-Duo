import AppKit
@main struct RuntimeCheck {
    static func main() throws {
        setenv("DUO_RUNTIME_CHECK", "1", 1)
        guard dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY | RTLD_GLOBAL) != nil else { fatalError("Framework unavailable") }
        guard let models = buildSettingsViewModelsXPC() else { fatalError("Settings codec unsupported") }
        print("Settings codec:", type(of: models))
        guard let context = CAContext.remoteContext() as? CAContext, context.contextId != 0,
              let object = createRemoteContextXPC(contextId: context.contextId) else { fatalError("Remote context unavailable") }
        print("Remote context:", type(of: object))
        print("PASS: private framework classes, settings codec, remote context object. Host composition not tested.")
    }
}
