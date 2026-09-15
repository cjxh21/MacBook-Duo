import CoreGraphics

/// Inspect the current system grant without changing or resetting it.
enum ScreenCapturePermissionPreparation {
    static func prepare(checkAccess: () -> Bool = { CGPreflightScreenCaptureAccess() }) -> String? {
        checkAccess() ? nil : "启用实时桌面效果需要屏幕录制权限，请在系统提示中允许 MacBook Duo。"
    }
}
