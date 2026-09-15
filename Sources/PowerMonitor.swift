import Foundation
import IOKit.ps

@MainActor
final class PowerMonitor {
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?
    private(set) var onAC = false
    private(set) var lowPower = false
    init() {
        refresh()
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(pointer).takeUnretainedValue().refresh()
            }
        }, pointer)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func refresh() {
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onAC = (type as String) == kIOPSACPowerValue
        }
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        onChange?()
    }
    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
