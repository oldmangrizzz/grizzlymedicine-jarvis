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
        let value = message["check_in"] as? String ?? "watch_check_in"
        let deviceID = message["device_id"] as? String ?? "apple-watch"
        let notes = message["notes"] as? String
        replyHandler(["ok": true])
        Task { @MainActor in
            await handleWatchCheckIn(value: value, deviceID: deviceID, notes: notes)
        }
    }
}
