import Foundation
import UserNotifications

protocol DistressNotificationRelaying {
    func relayDistressBanner()
}

struct LocalDistressNotificationRelay: DistressNotificationRelaying {
    func relayDistressBanner() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "JARVIS distress signal"
            content.body = "Open app"
            content.sound = .default
            let request = UNNotificationRequest(identifier: "jarvis-distress-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }
}

enum SiriQuarantineGuard {
    static func assertQuarantined(bundle: Bundle) throws {
        let dictionary = bundle.infoDictionary ?? [:]
        let forbiddenKeys = [
            "NSSiriUsageDescription",
            "INIntentsSupported",
            "INIntentsRestrictedWhileLocked",
            "NSUserActivityTypes",
            "NSCameraUsageDescription",
            "NSContactsUsageDescription",
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSSpeechRecognitionUsageDescription"
        ]
        if let key = forbiddenKeys.first(where: { dictionary[$0] != nil }) {
            throw SiriQuarantineError.forbiddenInfoPlistKey(key)
        }
    }

    static let policySummary = "No SiriKit intents, no Shortcuts donations, no Siri usage description, no camera, contacts, location, or speech-recognition privacy prompts."
}

enum SiriQuarantineError: LocalizedError, Equatable {
    case forbiddenInfoPlistKey(String)

    var errorDescription: String? {
        switch self {
        case .forbiddenInfoPlistKey(let key): "Siri quarantine violation: Info.plist contains \(key)"
        }
    }
}
