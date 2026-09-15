import Foundation

@main
struct PermissionPreparationTests {
    static func main() {
        var checks = 0
        let granted = { checks += 1; return true }
        for _ in 0..<3 {
            precondition(ScreenCapturePermissionPreparation.prepare(checkAccess: granted) == nil)
        }
        precondition(checks == 3, "Every launch checks the current system grant")
        precondition(ScreenCapturePermissionPreparation.prepare(checkAccess: { false }) != nil)
        precondition(ScreenCapturePermissionPreparation.prepare(checkAccess: granted) == nil,
                     "A later authorization must be accepted on the next check")
        print("PASS: existing grants preserved across launches; current system authorization remains authoritative")
    }
}
