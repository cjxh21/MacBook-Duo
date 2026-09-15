import AppKit
func remapToRealXPC(_ viewModels: SettingsViewModels) -> AnyObject? {
    let shimXPC = ShimViewModelsXPC(value: viewModels)

    let data: Data
    do {
        data = try NSKeyedArchiver.archivedData(withRootObject: shimXPC, requiringSecureCoding: false)
    } catch {
        extensionLog("  [Remap] Archive failed: \(error)")
        return nil
    }

    guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else {
        extensionLog("  [Remap] WallpaperSettingsViewModelsXPC class not found")
        return nil
    }

    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
        extensionLog("  [Remap] Failed to create unarchiver")
        return nil
    }
    unarchiver.requiresSecureCoding = false
    unarchiver.decodingFailurePolicy = .setErrorAndReturn
    unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")

    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = unarchiver.error {
        extensionLog("  [Remap] Unarchive error: \(error)")
    }
    unarchiver.finishDecoding()

    if result == nil {
        extensionLog("  [Remap] Decoded result is nil")
    }
    return result as AnyObject?
}

func buildSettingsViewModelsXPC() -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? "studio.prototype.DuoWallpaper.extension"
    let directory = dataDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = try? AngleBridge(url: directory.appendingPathComponent(DuoWallpaperPaths.angleBridgeName), create: true)
    let thumbnail = directory.appendingPathComponent(DuoWallpaperPaths.thumbnailName)
    let custom = directory.appendingPathComponent(DuoWallpaperPaths.customWallpaperName)
    let thumbnailImage = NSImage(contentsOf: custom)?.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? DuoBackdrop.image()
    if let data = NSBitmapImageRep(cgImage: thumbnailImage).representation(using: .png, properties: [:]) {
        try? data.write(to: thumbnail, options: .atomic)
    }
    let hasCustomWallpaper = FileManager.default.fileExists(atPath: custom.path)
    let hingeTitle = hasCustomWallpaper ? "Duo · 随开合变化（自定义）" : "Duo · 随开合变化"
    // WallpaperAgent routes selectable dynamic items through the canonical
    // dynamic group identifier used by Apple's own wallpaper extensions.
    // Keep the visible group name custom, but use that stable routing ID for
    // both the group and each item.
    let dynamicGroupID = GroupID(id: "DynamicWallpaperGroup")
    // Expose one production choice.  The two visual states (wake page-turn
    // and live hinge response) are selected by the lock-screen presentation
    // state inside Handler.swift, rather than by making the user choose a
    // diagnostic tile first.
    let items = [("hinge", hingeTitle)].map { id, title in
        // The extension owns these files inside its container. Advertising them
        // as downloadable choice dependencies makes WallpaperAgent treat the
        // tile as a download request, which can leave a click as a no-op. The
        // provider resolves the files itself when acquire() receives the choice.
        let files: [URL] = []
        let choiceID = ChoiceID(id: id, descriptor: ChoiceIDDescriptor(provider: ChoiceProviderID(rawValue: bundleID),
            identifier: id, files: files, configuration: Data(id.utf8)))
        // macOS 26 only routes a third-party item in the merged dynamic group
        // when its subgroup is also the canonical group ID.  Leaving this out
        // renders the card in stale caches but makes the Settings click a no-op.
        return SettingsItem(id: choiceID, groupID: dynamicGroupID, subgroupID: dynamicGroupID, localizedName: title, thumbnail: .image(url: thumbnail),
            choice: ChoiceDescriptor(id: choiceID, provider: ChoiceProviderID(rawValue: bundleID), identifier: id, name: title,
                localizedDescription: "自定义动态壁纸；系统时钟和密码框由 macOS 管理", thumbnail: .image(url: thumbnail), isDownloaded: true, options: []),
            // This provider emits a live frame timeline. Marking it as a
            // dynamic choice keeps the Wallpaper settings tile selectable;
            // the video badge is reserved for downloadable movie content.
            contentBadge: .dynamic, showInTopLevel: true, sortOrder: 0,
            disposability: .none, contextMenu: nil)
    }
    let group = SettingsGroup(id: dynamicGroupID, items: items, localizedName: "MacBook Duo · 锁屏壁纸",
        disposability: .none, sortOrder: 0, sortID: GroupSortID(id: "com.apple.wallpaper.dynamic"), allChoiceID: nil, shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil)
    let model = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    return remapToRealXPC(SettingsViewModels(desktop: model, screenSaver: model))
}
