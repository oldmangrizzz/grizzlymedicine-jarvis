@preconcurrency import WatchConnectivity
import Foundation
import WatchKit

@MainActor
final class WatchBridge: NSObject, ObservableObject {
    @Published private(set) var status: String = "Starting"
    @Published private(set) var accentHue: String = UserDefaults.standard.string(forKey: "jarvis.watch.accentHue") ?? "white"

    func activate() {
        guard WCSession.isSupported() else {
            status = "WatchConnectivity unavailable"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendCheckIn(_ value: String) {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let battery = device.batteryLevel >= 0 ? String(Double(device.batteryLevel * 100.0)) : ""
        let charging: String
        switch device.batteryState {
        case .charging, .full:
            charging = "true"
        case .unplugged:
            charging = "false"
        case .unknown:
            charging = ""
        @unknown default:
            charging = ""
        }
        send([
            "source": "apple_watch",
            "device_id": device.identifierForVendor?.uuidString ?? "apple-watch",
            "check_in": value,
            "notes": "watchOS quick action",
            "active": "true",
            "battery": battery,
            "charging": charging,
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

    private func applyAccent(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else {
            return
        }
        accentHue = rawValue
        UserDefaults.standard.set(rawValue, forKey: "jarvis.watch.accentHue")
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                status = "Activation failed: \(error.localizedDescription)"
            } else {
                status = activationState == .activated ? "Ready" : "Activation \(activationState.rawValue)"
                applyAccent(session.receivedApplicationContext["accent_hue"] as? String)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let accent = applicationContext["accent_hue"] as? String
        Task { @MainActor in
            applyAccent(accent)
        }
    }
}
