@preconcurrency import WatchConnectivity
import Foundation
import JARVISCompanionCore

@MainActor
final class PhoneWatchBridge: NSObject, ObservableObject {
    @Published private(set) var watchStatus: String = "Watch not activated"
    private weak var appState: CompanionAppState?
    private var enrolledWatchIDs: Set<String> = []

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
        var context = appState?.watchProxySnapshot ?? [:]
        context["accent_hue"] = hue.rawValue
        sendContext(context)
    }

    func sendStatusSnapshot() {
        sendContext(appState?.watchProxySnapshot ?? [:])
    }

    private func sendContext(_ context: [String: String]) {
        guard WCSession.isSupported() else { return }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            watchStatus = "Watch sync failed: \(error.localizedDescription)"
        }
    }

    private func handleWatchMessage(_ message: [String: String]) async {
        let kind = message["jarvis_kind"] ?? legacyKind(for: message)
        switch kind {
        case "audio_input":
            watchStatus = "Watch audio metadata received; waiting for file"
        case "alert":
            await handleWatchAlert(message)
        case "heartbeat":
            await handleWatchHeartbeat(message)
        case "command":
            if let turnText = message["turn_text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !turnText.isEmpty {
                await appState?.sendTurn(turnText)
                watchStatus = "Forwarded watch command"
            }
        default:
            await handleWatchCheckIn(value: message["check_in"] ?? "watch_check_in", deviceID: message["device_id"] ?? "apple-watch", notes: message["notes"], message: message)
        }
        sendStatusSnapshot()
    }

    private func handleWatchAudio(_ data: Data, contentType: String = "audio/wav") async {
        guard let appState else {
            watchStatus = "iPhone app state is not ready"
            return
        }
        do {
            let transcript = try await appState.transcribeAudio(data: data, contentType: contentType)
            await appState.sendTurn(transcript)
            watchStatus = "Relayed watch audio to JARVIS"
        } catch {
            watchStatus = "Watch audio relay failed"
        }
        sendStatusSnapshot()
    }

    private func handleWatchAlert(_ message: [String: String]) async {
        guard let appState else {
            watchStatus = "iPhone app state is not ready"
            return
        }
        let deviceID = message["device_id"] ?? "apple-watch"
        let event = CompanionEvent(
            source: .appleWatch,
            deviceID: deviceID,
            kind: "alert",
            timestamp: Date().timeIntervalSince1970,
            active: true,
            interactionMode: "watch_long_press_alert",
            confidence: 1.0,
            notes: "operator-attested emergency signal from Apple Watch",
            extra: [
                "wire_type": .string("distress"),
                "severity": .string(message["severity"] ?? "9"),
                "reason": .string(message["reason"] ?? "operator_long_press_watch_alert"),
                "needs_immediate_attention": .bool(true),
                "audit": .string(message["audit"] ?? "operator_attested_emergency_signal"),
            ]
        )
        await appState.send(event: event)
        watchStatus = "Forwarded Watch ALERT"
    }

    private func handleWatchHeartbeat(_ message: [String: String]) async {
        let deviceID = message["device_id"] ?? "apple-watch"
        if !enrolledWatchIDs.contains(deviceID) {
            enrolledWatchIDs.insert(deviceID)
            await enrollWatchExtension(deviceID: deviceID)
        }
        let event = CompanionEvent(
            source: .appleWatch,
            deviceID: deviceID,
            kind: "heartbeat",
            timestamp: Date().timeIntervalSince1970,
            active: true,
            interactionMode: "watch_heartbeat",
            confidence: 0.9,
            notes: "watch heartbeat via iPhone proxy",
            extra: ["counter": .string(message["counter"] ?? "0")]
        )
        await appState?.send(event: event)
        watchStatus = "Watch heartbeat relayed"
    }

    private func enrollWatchExtension(deviceID: String) async {
        let event = CompanionEvent(
            source: .appleWatch,
            deviceID: deviceID,
            kind: "watch_extension_enrollment",
            timestamp: Date().timeIntervalSince1970,
            active: true,
            interactionMode: "iphone_wire_proxy_enrollment",
            confidence: 1.0,
            notes: "Apple Watch enrolled as an iPhone-proxied JARVIS Wire extension device",
            extra: [
                "wire_pairing_holder": .string("iphone_companion"),
                "extension_certificate_scope": .string("watch_relay_status_audio_alert_only"),
                "transcript_policy": .string("no_watch_transcripts"),
            ]
        )
        await appState?.send(event: event)
    }

    private func handleWatchCheckIn(value: String, deviceID: String, notes: String?, message: [String: String]) async {
        guard let appState else {
            watchStatus = "iPhone app state is not ready"
            return
        }
        let event = CompanionEvent(
            source: .appleWatch,
            deviceID: deviceID,
            kind: "check_in",
            timestamp: Date().timeIntervalSince1970,
            charging: Self.boolValue(message["charging"]),
            battery: Self.doubleValue(message["battery"]),
            active: true,
            wristState: message["wrist_state"],
            interactionMode: "watch_quick_action",
            checkIn: value,
            confidence: 1.0,
            notes: notes
        )
        await appState.send(event: event)
        watchStatus = "Forwarded watch check-in"
    }

    private func legacyKind(for message: [String: String]) -> String {
        if message["turn_text"] != nil { return "command" }
        if message["check_in"] != nil { return "check_in" }
        return "unknown"
    }

    private static func boolValue(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    private static func doubleValue(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                watchStatus = "Watch activation failed: \(error.localizedDescription)"
            } else {
                watchStatus = "Watch activation: \(activationState.rawValue)"
                sendStatusSnapshot()
            }
        }
    }

    // WCSessionDelegate protocol still nominally requires these (pre-iOS 17)
    // but iOS 17+ SDK marks them unavailable for override. The @available
    // annotation satisfies the protocol witness without triggering the
    // unavailable-override error. No-op bodies because the system handles
    // inactive/reactivate transitions implicitly on iOS 17+.
    @available(iOS, introduced: 9.0, deprecated: 17.0)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    @available(iOS, introduced: 9.0, deprecated: 17.0)
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let copiedMessage = PhoneWatchMessage(message)
        replyHandler(["ok": true])
        Task { @MainActor in await handleWatchMessage(copiedMessage.dictionary) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let copiedMessage = PhoneWatchMessage(userInfo)
        Task { @MainActor in await handleWatchMessage(copiedMessage.dictionary) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        replyHandler(Data("ok".utf8))
        Task { @MainActor in await handleWatchAudio(messageData) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let contentType = (file.metadata?["content_type"] as? String) ?? "audio/wav"
        let url = file.fileURL
        Task { @MainActor in
            do {
                let data = try Data(contentsOf: url)
                await handleWatchAudio(data, contentType: contentType)
            } catch {
                watchStatus = "Watch audio file unreadable"
            }
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
