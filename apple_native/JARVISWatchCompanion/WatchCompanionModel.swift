@preconcurrency import WatchConnectivity
import Foundation
import WatchKit
import WidgetKit

@MainActor
enum JarvisSessionState: String, Sendable {
    case idle
    case active
    case distress

    var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .active: return "waveform.circle.fill"
        case .distress: return "heart.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .active: return "Active"
        case .distress: return "Distress"
        }
    }
}

@MainActor
final class WatchCompanionModel: NSObject, ObservableObject {
    @Published private(set) var sessionState: JarvisSessionState = .idle
    @Published private(set) var transportStatus = "Pair through iPhone"
    @Published private(set) var siriMitigation = SiriWatchFaceGate.current()
    @Published private(set) var isRecording = false
    @Published private(set) var lastError = ""

    private var heartbeatCounter: UInt64 = 0
    private let deviceID = WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "apple-watch"

    func activate() {
        guard WCSession.isSupported() else {
            transportStatus = "WatchConnectivity unavailable"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
        sendHeartbeat()
    }

    func checkSiriWatchFaceMitigation() async {
        siriMitigation = SiriWatchFaceGate.current()
        if !siriMitigation.isAcknowledged {
            transportStatus = "Siri Watch Face removal required"
        }
    }

    func acknowledgeSiriFaceRemoved() {
        SiriWatchFaceGate.acknowledgeRemoved()
        siriMitigation = SiriWatchFaceGate.current()
        transportStatus = "Ready"
    }

    func beginTapToSpeak() {
        guard siriMitigation.isAcknowledged else {
            transportStatus = "Remove Siri Watch Face first"
            return
        }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jarvis-watch-\(UUID().uuidString).wav")
        let options = [WKAudioRecorderControllerOptionsMaximumDurationKey: 20]
        isRecording = true
        WKExtension.shared().visibleInterfaceController?.presentAudioRecorderController(
            withOutputURL: url,
            preset: .wideBandSpeech,
            options: options
        ) { [weak self] didSave, error in
            Task { @MainActor in
                self?.isRecording = false
                if let error {
                    self?.lastError = "Recording failed: \(error.localizedDescription)"
                    return
                }
                guard didSave else {
                    self?.transportStatus = "Recording cancelled"
                    return
                }
                self?.sendAudioRecording(url)
            }
        }
    }

    func sendAlert() {
        guard siriMitigation.isAcknowledged else {
            transportStatus = "Remove Siri Watch Face first"
            return
        }
        playEmergencyHaptic()
        send([
            "jarvis_kind": "alert",
            "source": "apple_watch",
            "device_id": deviceID,
            "created_at": String(Date().timeIntervalSince1970),
            "severity": "9",
            "reason": "operator_long_press_watch_alert",
            "needs_immediate_attention": "true",
            "audit": "operator_attested_emergency_signal"
        ])
    }

    private func sendHeartbeat() {
        heartbeatCounter += 1
        send([
            "jarvis_kind": "heartbeat",
            "source": "apple_watch",
            "device_id": deviceID,
            "counter": String(heartbeatCounter)
        ])
    }

    private func sendAudioRecording(_ url: URL) {
        guard WCSession.isSupported() else {
            transportStatus = "WatchConnectivity unavailable"
            return
        }
        let metadata = [
            "jarvis_kind": "audio_input",
            "source": "apple_watch",
            "device_id": deviceID,
            "content_type": "audio/wav",
            "transcript_policy": "no_watch_transcript"
        ]
        if WCSession.default.isReachable {
            do {
                let data = try Data(contentsOf: url)
                WCSession.default.sendMessageData(data, replyHandler: { [weak self] _ in
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch CocoaError.fileNoSuchFile {
                        // Already gone — not an error.
                    } catch {
                        // [audit-cleanup] Audio temp removal failed; WRITE_FAILED, path not surfaced.
                        NSLog("[JARVIS][watch] audio-temp-remove WRITE_FAILED")
                        Task { @MainActor in self?.lastError = "WRITE_FAILED" }
                    }
                    Task { @MainActor in self?.transportStatus = "Audio relayed to iPhone" }
                }, errorHandler: { [weak self] error in
                    WCSession.default.transferFile(url, metadata: metadata)
                    Task { @MainActor in
                        self?.transportStatus = "Queued audio for iPhone"
                        self?.lastError = error.localizedDescription
                    }
                })
            } catch {
                lastError = "Audio read failed: \(error.localizedDescription)"
            }
        } else {
            WCSession.default.transferFile(url, metadata: metadata)
            transportStatus = "Queued audio for iPhone"
        }
    }

    private func send(_ message: [String: String]) {
        guard WCSession.isSupported() else {
            transportStatus = "WatchConnectivity unavailable"
            return
        }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.transportStatus = (reply["ok"] as? Bool) == true ? "Relayed by iPhone" : "iPhone refused"
                }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.transportStatus = "Queued for iPhone"
                    self?.lastError = error.localizedDescription
                }
                WCSession.default.transferUserInfo(message)
            })
        } else {
            WCSession.default.transferUserInfo(message)
            transportStatus = "Queued for iPhone"
        }
    }

    private func apply(context: [String: String]) {
        let raw = context["jarvis_state"] ?? "idle"
        let next = JarvisSessionState(rawValue: raw) ?? .idle
        let wasDistress = sessionState == .distress
        sessionState = next
        UserDefaults.standard.set(next.rawValue, forKey: "jarvis.watch.complication.state")
        transportStatus = context["jarvis_status_line"] ?? next.label
        WidgetCenter.shared.reloadAllTimelines()
        if next == .distress && !wasDistress {
            playDistressHaptic()
        }
    }

    private func playDistressHaptic() {
        WKInterfaceDevice.current().play(.failure)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { WKInterfaceDevice.current().play(.retry) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) { WKInterfaceDevice.current().play(.failure) }
    }

    private func playEmergencyHaptic() {
        WKInterfaceDevice.current().play(.start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { WKInterfaceDevice.current().play(.success) }
    }
}

extension WatchCompanionModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if let error {
                transportStatus = "Activation failed: \(error.localizedDescription)"
            } else {
                transportStatus = activationState == .activated ? "Waiting for iPhone proxy" : "Activation \(activationState.rawValue)"
                apply(context: Self.stringContext(session.receivedApplicationContext))
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let copied = Self.stringContext(applicationContext)
        Task { @MainActor in apply(context: copied) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let copied = Self.stringContext(message)
        Task { @MainActor in apply(context: copied) }
    }

    private nonisolated static func stringContext(_ raw: [String: Any]) -> [String: String] {
        var copied: [String: String] = [:]
        for (key, value) in raw {
            if let value = value as? String {
                copied[key] = value
            }
        }
        return copied
    }
}
