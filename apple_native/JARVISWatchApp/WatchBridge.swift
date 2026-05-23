@preconcurrency import WatchConnectivity
import Foundation
import WatchKit

@MainActor
final class WatchBridge: NSObject, ObservableObject {
    @Published private(set) var status: String = "Starting"

    func activate() {
        guard WCSession.isSupported() else {
            status = "WatchConnectivity unavailable"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendCheckIn(_ value: String) {
        send([
            "source": "apple_watch",
            "device_id": WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "apple-watch",
            "check_in": value,
            "notes": "watchOS quick action",
        ])
    }

    func sendCommand(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            status = "Speak or dictate a command first"
            return
        }
        send([
            "source": "apple_watch",
            "device_id": WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "apple-watch",
            "turn_text": clean,
        ])
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.isSupported() else {
            status = "WatchConnectivity unavailable"
            return
        }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.status = (reply["ok"] as? Bool) == true ? "Sent to phone" : "Phone refused"
                }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.status = "Send failed: \(error.localizedDescription)"
                }
            })
        } else {
            WCSession.default.transferUserInfo(message)
            status = "Handed to phone"
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                status = "Activation failed: \(error.localizedDescription)"
            } else {
                status = activationState == .activated ? "Ready" : "Activation \(activationState.rawValue)"
            }
        }
    }
}
