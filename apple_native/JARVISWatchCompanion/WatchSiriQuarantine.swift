import Foundation

struct SiriWatchFaceMitigation: Equatable, Sendable {
    var isAcknowledged: Bool
    let remediation = "Remove the Siri watch face: press the current face, swipe to the Siri face, swipe up, tap Remove. Then reopen JARVIS."
}

enum SiriWatchFaceGate {
    static let acknowledgementKey = "jarvis.watch.siriFaceRemoved.v1"

    static func current(defaults: UserDefaults = .standard) -> SiriWatchFaceMitigation {
        SiriWatchFaceMitigation(isAcknowledged: defaults.bool(forKey: acknowledgementKey))
    }

    static func acknowledgeRemoved(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: acknowledgementKey)
    }
}
