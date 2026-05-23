import AVFoundation
import Foundation
import JARVISCompanionCore
import UIKit

@MainActor
final class CompanionAppState: ObservableObject {
    @Published var cloudURLText: String
    @Published var pairingCode: String = ""
    @Published private(set) var connectionStatus: String = "Not checked"
    @Published private(set) var lastCommand: String = ""
    @Published private(set) var lastDeviceAction: String = ""
    @Published private(set) var lastReply: String = ""
    @Published private(set) var lastError: String = ""
    @Published private(set) var isPaired: Bool = false
    @Published private(set) var isCommandInFlight: Bool = false

    private let tokenStore: KeychainCompanionTokenStore
    private let defaults: UserDefaults
    private let speaker = AVSpeechSynthesizer()
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

    func pairDevice() async {
        saveConnection()
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            lastError = "Enter the pairing code from JARVIS Cloud."
            return
        }
        do {
            let response = try await makeCloudClient(requireToken: false).pair(
                code: code,
                deviceID: deviceID(),
                label: UIDevice.current.name,
                platform: "ios"
            )
            try tokenStore.saveToken(response.deviceToken)
            pairingCode = ""
            isPaired = true
            lastError = ""
            connectionStatus = "Paired with JARVIS Cloud."
        } catch {
            isPaired = false
            connectionStatus = "Pairing failed"
            lastError = "Pairing failed: \(error.localizedDescription)"
        }
    }

    func makeCloudClient(requireToken: Bool = true) throws -> CloudCompanionClient {
        guard let baseURL = URL(string: cloudURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CompanionClientError.invalidBaseURL
        }
        let token = try tokenStore.loadToken() ?? ""
        if requireToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CloudCompanionClientError.server("Pair this device with JARVIS Cloud first.")
        }
        return CloudCompanionClient(baseURL: baseURL, deviceToken: token)
    }

    func checkConnection() async {
        saveConnection()
        do {
            let client = try makeCloudClient()
            let status = try await client.status()
            isPaired = true
            connectionStatus = status.statusLine
            if let reply = status.latestTurn?.payload?.objectValue?["reply"]?.stringValue, !reply.isEmpty {
                lastReply = reply
            }
            lastError = ""
        } catch {
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

        isCommandInFlight = true
        defer { isCommandInFlight = false }
        do {
            let client = try makeCloudClient()
            lastReply = "I heard you. Asking JARVIS now."
            connectionStatus = "JARVIS is thinking"
            lastError = ""
            speak("Asking JARVIS.")
            let response = try await client.realtimeTurn(text: clean, deviceID: deviceID())
            lastReply = response.reply ?? "JARVIS responded without text."
            connectionStatus = "JARVIS answered"
            speak(lastReply)
        } catch {
            connectionStatus = "Runtime unavailable"
            lastError = "Live JARVIS is not reachable: \(error.localizedDescription)"
            speak("Live JARVIS is not reachable.")
        }
    }

    func speakHealthBriefing(_ snapshot: HealthSnapshot) async {
        lastCommand = "EMS briefing"
        lastDeviceAction = "HealthKit context: \(snapshot.statusLine)"
        lastReply = snapshot.emsBriefing
        connectionStatus = "EMS briefing ready"
        lastError = ""
        speak(snapshot.emsBriefing)
        await publishHealthSnapshot(snapshot, reason: "ems_briefing")
    }

    private func handleDeviceAction(_ action: DeviceActionResult, command: String) async {
        if action.succeeded {
            lastDeviceAction = "\(action.title): \(action.detail)"
            lastReply = "\(action.title)."
            connectionStatus = "Device action complete"
            lastError = ""
            speak(lastReply)
            await publishDeviceAction(command: command, action: action)
        } else {
            lastDeviceAction = "\(action.title) failed: \(action.detail)"
            lastError = "iOS would not open \(action.url.absoluteString)."
            connectionStatus = "Device action blocked"
            speak("Device action blocked.")
        }
    }

    private func publishDeviceAction(command: String, action: DeviceActionResult) async {
        guard isPaired else {
            return
        }
        let event = CompanionEvent(
            source: .iPhone,
            deviceID: deviceID(),
            kind: "device_action",
            confidence: action.succeeded ? 1.0 : 0.0,
            notes: "\(action.title): \(action.detail)",
            extra: [
                "command": .string(command),
                "url": .string(action.url.absoluteString),
                "succeeded": .bool(action.succeeded),
            ]
        )
        do {
            _ = try await makeCloudClient().send(event: event, deviceID: deviceID())
        } catch {
            lastError = "Device action ran locally; cloud context update failed: \(error.localizedDescription)"
        }
    }

    func publishHealthSnapshot(_ snapshot: HealthSnapshot, reason: String) async {
        guard isPaired else {
            return
        }
        let event = CompanionEvent(
            source: .iPhone,
            deviceID: deviceID(),
            kind: "health_context",
            confidence: snapshot.authorized ? 1.0 : 0.0,
            notes: reason,
            extra: snapshot.json
        )
        do {
            _ = try await makeCloudClient().send(event: event, deviceID: deviceID())
        } catch {
            lastError = "Health context stayed local; cloud update failed: \(error.localizedDescription)"
        }
    }

    func send(event: CompanionEvent) async {
        do {
            _ = try await makeCloudClient().send(event: event, deviceID: deviceID())
            connectionStatus = "Sent \(event.kind) to JARVIS Cloud."
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

    private func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return
        }
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.prefersAssistiveTechnologySettings = true
        speaker.speak(utterance)
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
}
