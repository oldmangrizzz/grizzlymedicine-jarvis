@preconcurrency import WatchConnectivity
import Foundation
import JARVISCompanionCore

@MainActor
final class PhoneWatchBridge: NSObject, ObservableObject {
    @Published private(set) var watchStatus: String = "Watch not activated"
    private weak var appState: CompanionAppState?

    func activate(appState: CompanionAppState) {
        self.appState = appState
        guard WCSession.isSupported() else {
            watchStatus = "WatchConnectivity is not supported on this device."
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendAccent(_ hue: CompanionAccentHue) {
        guard WCSession.isSupported() else {
            return
        }
        do {
            try WCSession.default.updateApplicationContext(["accent_hue": hue.rawValue])
        } catch {
            watchStatus = "Watch accent sync failed: \(error.localizedDescription)"
        }
    }

    private func handleWatchMessage(_ message: [String: Any]) async {
        let deviceID = message["device_id"] as? String ?? "apple-watch"
        if let turnText = (message["turn_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnText.isEmpty {
            await appState?.sendTurn(turnText)
            watchStatus = "Forwarded watch command"
            return
        }

        let value = message["check_in"] as? String ?? "watch_check_in"
        let notes = message["notes"] as? String
        await handleWatchCheckIn(value: value, deviceID: deviceID, notes: notes)
    }

    private func handleWatchCheckIn(value: String, deviceID: String, notes: String?) async {
        guard let appState else {
            watchStatus = "iPhone app state is not ready"
            return
        }
        let event = CompanionEvent(
            source: .appleWatch,
            deviceID: deviceID,
            kind: "check_in",
            checkIn: value,
            confidence: 1.0,
            notes: notes
        )
        await appState.send(event: event)
        watchStatus = "Forwarded watch check-in"
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                watchStatus = "Watch activation failed: \(error.localizedDescription)"
            } else {
                watchStatus = "Watch activation: \(activationState.rawValue)"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            watchStatus = "Watch session inactive"
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        Task { @MainActor in
            watchStatus = "Watch session reactivated"
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let copiedMessage = PhoneWatchMessage(message)
        replyHandler(["ok": true])
        Task { @MainActor in
            await handleWatchMessage(copiedMessage.dictionary)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let copiedMessage = PhoneWatchMessage(userInfo)
        Task { @MainActor in
            await handleWatchMessage(copiedMessage.dictionary)
        }
    }
}

private struct PhoneWatchMessage: Sendable {
    let dictionary: [String: String]

    init(_ raw: [String: Any]) {
        var copied: [String: String] = [:]
        for (key, value) in raw {
            if let string = value as? String {
                copied[key] = string
            }
        }
        dictionary = copied
    }
}
