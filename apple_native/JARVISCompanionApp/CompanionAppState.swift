import Foundation
import JARVISCompanionCore
import UIKit

@MainActor
final class CompanionAppState: ObservableObject {
    @Published var cloudURLText: String
    @Published var pairingCode: String = ""
    @Published private(set) var connectionStatus: String = "Not checked"
    @Published private(set) var lastReply: String = ""
    @Published private(set) var lastError: String = ""
    @Published private(set) var isPaired: Bool = false

    private let tokenStore: KeychainCompanionTokenStore
    private let defaults: UserDefaults
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
            lastError = "Say or type something for JARVIS first."
            return
        }
        do {
            let requestID = "ios-\(UUID().uuidString.lowercased())"
            let client = try makeCloudClient()
            let queued = try await client.requestTurn(text: clean, requestID: requestID, deviceID: deviceID())
            lastReply = "Queued for JARVIS Cloud (\(queued.requestId))."
            connectionStatus = "Turn queued"
            lastError = ""
            await pollTurn(requestID: queued.requestId, client: client)
        } catch {
            lastError = "Turn failed: \(error.localizedDescription)"
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

    private func pollTurn(requestID: String, client: CloudCompanionClient) async {
        for _ in 0..<12 {
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard let request = try await client.controlStatus(requestID: requestID) else {
                    continue
                }
                switch request.status {
                case "done":
                    lastReply = request.replyText ?? "JARVIS completed the turn without reply text."
                    connectionStatus = "Turn complete"
                    return
                case "error":
                    lastError = "JARVIS turn failed: \(request.error ?? "unknown error")"
                    connectionStatus = "Turn failed"
                    return
                case "refused":
                    lastError = "JARVIS refused the request: \(request.reason ?? "no reason supplied")"
                    connectionStatus = "Turn refused"
                    return
                default:
                    connectionStatus = "Turn \(request.status)"
                }
            } catch {
                lastError = "Turn status check failed: \(error.localizedDescription)"
                return
            }
        }
        connectionStatus = "Turn queued"
        lastReply = "Queued for JARVIS Cloud. The runtime will answer when it is online."
    }

    private func deviceID() -> String {
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let created = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(created, forKey: deviceIDKey)
        return created
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
