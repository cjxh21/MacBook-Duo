import Foundation

/// Compare cached notifications with current OS state, including missed wakes.
enum SystemResumeState {
    struct Change: Equatable {
        var reason: String
        var pausing: Bool
    }
    static func changes(paused: Set<String>, displayAsleep: Bool,
                        locked: Bool, onConsole: Bool) -> [Change] {
        var result: [Change] = []
        // macOS may enter its temporary lock state immediately after idle
        // display sleep. Preserve whether sleep began on an unlocked desktop.
        if displayAsleep, !paused.contains("display") {
            result.append(Change(reason: "display", pausing: true))
        }
        // Resolve lock/session before display wake. Never show desktop content
        // in a locked or switched-away session.
        for (reason, value) in [("lock", locked), ("session", !onConsole)] {
            if paused.contains(reason) != value {
                result.append(Change(reason: reason, pausing: value))
            }
        }
        if !displayAsleep, paused.contains("display") {
            result.append(Change(reason: "display", pausing: false))
        }
        if !displayAsleep, onConsole, paused.contains("system") {
            result.append(Change(reason: "system", pausing: false))
        }
        return result
    }
}
