import AVFoundation
import Foundation
import JARVISCompanionCore
import UIKit

@MainActor
final class CompanionAppState: ObservableObject {
    @Published var cloudURLText: String
    @Published private(set) var connectionStatus: String = "Not checked"
    @Published private(set) var lastCommand: String = ""
    @Published private(set) var lastDeviceAction: String = ""
    @Published private(set) var lastReply: String = ""
    @Published private(set) var lastError: String = ""
    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isConnecting: Bool = false
    @Published private(set) var isCommandInFlight: Bool = false
    @Published private(set) var dreamStatus: DreamStatus?
    @Published private(set) var dreamReadinessStatus: String = "Dream readiness not checked"
    @Published private(set) var voicePathStatus: String = "Voice path unchecked"

    private let tokenStore: KeychainCompanionTokenStore
    private let defaults: UserDefaults
    private var voicePlayer: AVAudioPlayer?
    private let cloudURLKey = "jarvis.companion.cloudURL"
    private let deviceIDKey = "jarvis.companion.deviceID"
    private let defaultCloudURL = "https://fleet-goose-114.convex.site"

    init(
        defaults: UserDefaults = .standard,
        tokenStore: KeychainCompanionTokenStore = KeychainCompanionTokenStore(account: "convex-device-token")
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.cloudURLText = defaults.string(forKey: cloudURLKey) ?? defaultCloudURL
        let loadedToken = (try? tokenStore.loadToken()) ?? ""
        self.isPaired = !loadedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveConnection() {
        defaults.set(cloudURLText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: cloudURLKey)
    }

    func ensureRegistered() async {
        if hasStoredToken {
            isPaired = true
            return
        }
        await registerDevice()
    }

    func registerDevice() async {
        saveConnection()
        guard !isConnecting else {
            connectionStatus = "Connecting to JARVIS Cloud"
            return
        }
        isConnecting = true
        connectionStatus = "Connecting to JARVIS Cloud"
        defer { isConnecting = false }
        do {
            let response = try await makeCloudClient(requireToken: false).register(
                deviceID: deviceID(),
                label: UIDevice.current.name,
                platform: "ios"
            )
            try tokenStore.saveToken(response.deviceToken)
            isPaired = true
            lastError = ""
            connectionStatus = "Connected to JARVIS Cloud."
        } catch {
            isPaired = false
            connectionStatus = "Cloud registration failed"
            lastError = "Could not connect this device to JARVIS Cloud: \(error.localizedDescription)"
        }
    }

    func makeCloudClient(requireToken: Bool = true) throws -> CloudCompanionClient {
        guard let baseURL = URL(string: cloudURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CompanionClientError.invalidBaseURL
        }
        let token = try tokenStore.loadToken() ?? ""
        if requireToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CloudCompanionClientError.server("Connect this device to JARVIS Cloud first.")
        }
        return CloudCompanionClient(baseURL: baseURL, deviceToken: token)
    }

    func checkConnection() async {
        saveConnection()
        await ensureRegistered()
        guard isPaired else {
            return
        }
        do {
            let client = try makeCloudClient()
            let status = try await client.status()
            isPaired = true
            connectionStatus = status.statusLine
            if let reply = status.latestTurn?.payload?.objectValue?["reply"]?.stringValue, !reply.isEmpty {
                lastReply = reply
            }
            updateDreamStatus(status.dreamReadiness)
            lastError = ""
        } catch {
            if error.invalidatesStoredDeviceToken {
                try? tokenStore.deleteToken()
            }
            isPaired = false
            connectionStatus = "Not connected"
            lastError = "Cloud check failed: \(error.localizedDescription)"
        }
    }

    func sendTurn(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            lastError = "I did not catch a command. Speak again or use the touch fallback."
            return
        }

        lastCommand = clean

        if let action = await DeviceActionRouter.route(clean) {
            await handleDeviceAction(action, command: clean)
            return
        }

        await ensureRegistered()
        guard isPaired else {
            lastReply = "JARVIS Cloud is not reachable."
            return
        }

        isCommandInFlight = true
        defer { isCommandInFlight = false }
        do {
            let client = try makeCloudClient()
            lastReply = "I heard you. Asking JARVIS now."
            connectionStatus = "JARVIS is thinking"
            lastError = ""
            let response = try await client.realtimeTurn(text: clean, deviceID: deviceID())
            lastReply = response.reply ?? "JARVIS responded without text."
            connectionStatus = "JARVIS answered"
            await speak(lastReply)
        } catch {
            connectionStatus = "Runtime unavailable"
            lastError = "Live JARVIS is not reachable: \(error.localizedDescription)"
            lastReply = "Live JARVIS is not reachable."
        }
    }

    func transcribeAudio(data: Data, contentType: String) async throws -> String {
        await ensureRegistered()
        guard isPaired else {
            throw CompanionVoiceError.cloudUnavailable
        }
        let maxBytes = 6_000_000
        guard !data.isEmpty else {
            throw CompanionVoiceError.emptyAudio
        }
        guard data.count <= maxBytes else {
            throw CompanionVoiceError.audioTooLarge
        }
        do {
            let response = try await makeCloudClient().transcribeAudio(
                audioBase64: data.base64EncodedString(),
                contentType: contentType,
                deviceID: deviceID()
            )
            let transcript = response.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw CompanionVoiceError.emptyTranscript
            }
            lastError = ""
            return transcript
        } catch {
            lastError = "JARVIS could not transcribe that audio: \(error.localizedDescription)"
            throw error
        }
    }

    func acknowledgeLocalCommand(_ command: String, reply: String) async {
        lastCommand = command
        lastReply = reply
        connectionStatus = "Updated"
        lastError = ""
        await speak(reply)
    }

    func speakHealthBriefing(_ snapshot: HealthSnapshot) async {
        lastCommand = "EMS briefing"
        lastDeviceAction = "HealthKit context: \(snapshot.statusLine)"
        lastReply = snapshot.emsBriefing
        connectionStatus = "EMS briefing ready"
        lastError = ""
        await speak(snapshot.emsBriefing)
        await publishHealthSnapshot(snapshot, reason: "ems_briefing")
    }

    private func handleDeviceAction(_ action: DeviceActionResult, command: String) async {
        if action.succeeded {
            lastDeviceAction = "\(action.title): \(action.detail)"
            lastReply = "\(action.title)."
            connectionStatus = "Device action complete"
            lastError = ""
            await speak(lastReply)
            await publishDeviceAction(command: command, action: action)
        } else {
            lastDeviceAction = "\(action.title) failed: \(action.detail)"
            lastError = "iOS would not open \(action.url.absoluteString)."
            connectionStatus = "Device action blocked"
            await speak("Device action blocked.")
        }
    }

    private func publishDeviceAction(command: String, action: DeviceActionResult) async {
        await ensureRegistered()
        guard isPaired else {
            return
        }
        let event = CompanionEvent(
            source: .iPhone,
            deviceID: deviceID(),
            kind: "device_action",
            active: true,
            interactionMode: "device_action",
            confidence: action.succeeded ? 1.0 : 0.0,
            notes: "\(action.title): \(action.detail)",
            extra: [
                "command": .string(command),
                "url": .string(action.url.absoluteString),
                "succeeded": .bool(action.succeeded),
            ]
        )
        do {
            let response = try await makeCloudClient().send(event: event, deviceID: deviceID())
            updateDreamStatus(response.dream)
        } catch {
            lastError = "Device action ran locally; cloud context update failed: \(error.localizedDescription)"
        }
    }

    func publishHealthSnapshot(_ snapshot: HealthSnapshot, reason: String) async {
        await ensureRegistered()
        guard isPaired else {
            return
        }
        let event = CompanionEvent(
            source: .iPhone,
            deviceID: deviceID(),
            kind: "health_context",
            active: true,
            interactionMode: "health_context",
            confidence: snapshot.authorized ? 1.0 : 0.0,
            notes: reason,
            extra: snapshot.json
        )
        do {
            let response = try await makeCloudClient().send(event: event, deviceID: deviceID())
            updateDreamStatus(response.dream)
        } catch {
            lastError = "Health context stayed local; cloud update failed: \(error.localizedDescription)"
        }
    }

    func send(event: CompanionEvent) async {
        await send(event: event, updateConnectionStatus: true)
    }

    var watchProxySnapshot: [String: String] {
        let distressTerms = [connectionStatus, lastDeviceAction, lastReply, lastError, dreamReadinessStatus]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains("distress")
        let active = isCommandInFlight || connectionStatus.localizedCaseInsensitiveContains("thinking") || !lastCommand.isEmpty
        let state = distressTerms ? "distress" : (active ? "active" : "idle")
        return [
            "jarvis_state": state,
            "jarvis_status_line": connectionStatus,
            "jarvis_dream_line": dreamReadinessStatus,
        ]
    }

    func publishPhoneState(active: Bool, reason: String) async {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryLevel = UIDevice.current.batteryLevel
        let battery = batteryLevel >= 0 ? Double(batteryLevel * 100.0) : nil
        let charging: Bool?
        switch UIDevice.current.batteryState {
        case .charging, .full:
            charging = true
        case .unplugged:
            charging = false
        case .unknown:
            charging = nil
        @unknown default:
            charging = nil
        }
        let event = CompanionEvent(
            source: .iPhone,
            deviceID: deviceID(),
            kind: "phone_state",
            timestamp: Date().timeIntervalSince1970,
            charging: charging,
            battery: battery,
            active: active,
            interactionMode: active ? "companion_foreground" : "companion_idle",
            confidence: 0.8,
            notes: reason
        )
        await send(event: event, updateConnectionStatus: false)
    }

    private func send(event: CompanionEvent, updateConnectionStatus: Bool) async {
        await ensureRegistered()
        guard isPaired else {
            return
        }
        do {
            let response = try await makeCloudClient().send(event: event, deviceID: deviceID())
            if updateConnectionStatus {
                connectionStatus = "Sent \(event.kind) to JARVIS Cloud."
            }
            updateDreamStatus(response.dream)
            lastError = ""
        } catch {
            lastError = "Event send failed: \(error.localizedDescription)"
        }
    }

    private func deviceID() -> String {
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let created = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(created, forKey: deviceIDKey)
        return created
    }

    private var hasStoredToken: Bool {
        let token = (try? tokenStore.loadToken()) ?? ""
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateDreamStatus(_ status: DreamStatus?) {
        guard let status else {
            return
        }
        dreamStatus = status
        dreamReadinessStatus = status.readinessLine
    }

    private func speak(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return
        }

        await ensureRegistered()
        guard isPaired else {
            return
        }

        do {
            let response = try await makeCloudClient().speech(text: clean, deviceID: deviceID())
            try validateSpeechResponse(response)
            guard response.ok, response.spoken == true else {
                voicePathStatus = "Voice unavailable — silent"
                lastError = "JARVIS voice unavailable: \(response.unavailabilityText)"
                return
            }
            guard let audioBase64 = response.audioBase64,
                  let data = Data(base64Encoded: audioBase64) else {
                lastError = "JARVIS voice returned invalid audio."
                return
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            voicePlayer?.stop()
            let player = try AVAudioPlayer(data: data)
            voicePlayer = player
            player.prepareToPlay()
            player.play()
            voicePathStatus = "JARVIS native voice playing"
        } catch {
            voicePathStatus = "Voice unavailable — silent"
            lastError = "JARVIS voice unavailable: \(error.localizedDescription)"
        }
    }

    private func validateSpeechResponse(_ response: CloudSpeechResponse) throws {
        if response.wrongVoiceFallbackAllowed == true ||
            response.systemVoiceFallbackAllowed == true ||
            response.nativeSystemVoiceAllowed == true ||
            response.pythonTTSAllowed == true {
            throw CompanionVoiceError.voicePolicyViolation
        }
        let backend = [response.backend, response.backendKind].compactMap { $0 }.joined(separator: " ")
        if backendLooksForbidden(backend) {
            throw CompanionVoiceError.voicePolicyViolation
        }
        if response.spoken == true {
            let audio = response.audioBase64 ?? ""
            let contentType = response.contentType ?? ""
            guard response.ok, !audio.isEmpty, contentType.hasPrefix("audio/") else {
                throw CompanionVoiceError.fakeSpokenSuccess
            }
        }
    }

    private func backendLooksForbidden(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("nsspeech") ||
            lower.contains("avspeech") ||
            lower.contains("speechsynthesis") ||
            lower.contains("system voice") ||
            lower.contains("tts_pocket") ||
            lower.contains("jarvis_bridge.py") ||
            lower.contains("python") ||
            lower == "say"
    }
}

private extension Error {
    var invalidatesStoredDeviceToken: Bool {
        guard let error = self as? CloudCompanionClientError,
              case .server(let message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("bad device token") ||
            message.localizedCaseInsensitiveContains("missing device token")
    }
}

private enum CompanionVoiceError: LocalizedError {
    case audioTooLarge
    case cloudUnavailable
    case emptyAudio
    case emptyTranscript
    case fakeSpokenSuccess
    case voicePolicyViolation

    var errorDescription: String? {
        switch self {
        case .audioTooLarge:
            return "The voice recording is too large. Try a shorter command."
        case .cloudUnavailable:
            return "JARVIS Cloud is not reachable."
        case .emptyAudio:
            return "No voice recording was captured."
        case .emptyTranscript:
            return "JARVIS did not hear words in that recording."
        case .fakeSpokenSuccess:
            return "Speech response claimed spoken=true without native JARVIS audio."
        case .voicePolicyViolation:
            return "Speech response violated JARVIS voice-or-silence policy."
        }
    }
}

private extension CloudStatusResponse {
    var statusLine: String {
        if let updatedAt = runtime?.updatedAt {
            let age = max(0, Date().timeIntervalSince1970 - updatedAt)
            if age < 120 {
                return "Connected to JARVIS Cloud. Runtime updated \(Int(age))s ago."
            }
        }
        return "Connected to JARVIS Cloud."
    }

    var dreamReadiness: DreamStatus? {
        dream?.payload?.decoded(DreamStatus.self)
    }
}

private extension CloudControlRequest {
    var replyText: String? {
        output?.objectValue?["reply"]?.stringValue
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    func decoded<T: Decodable>(_: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

private extension DreamStatus {
    var readinessLine: String {
        if deepReady {
            return "Dream readiness: deep ready; idle \(idleDescription)."
        }
        if microReady {
            return "Dream readiness: micro ready; idle \(idleDescription)."
        }
        if !activeSignals.isEmpty {
            return "Dream readiness: active signals observed."
        }
        if quietEnough {
            return "Dream readiness: quiet signals observed; idle \(idleDescription)."
        }
        return "Dream readiness: waiting for observable idle context."
    }

    private var idleDescription: String {
        guard let idleSeconds else {
            return "unknown"
        }
        if idleSeconds >= 3600 {
            return "\(Int(idleSeconds / 3600))h"
        }
        if idleSeconds >= 60 {
            return "\(Int(idleSeconds / 60))m"
        }
        return "\(Int(idleSeconds))s"
    }
}
