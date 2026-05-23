import Foundation
import JARVISCompanionCore

@MainActor
final class CompanionAppState: ObservableObject {
    @Published var baseURLText: String
    @Published var companionToken: String
    @Published private(set) var connectionStatus: String = "Not checked"
    @Published private(set) var lastReply: String = ""
    @Published private(set) var lastError: String = ""

    private let tokenStore: KeychainCompanionTokenStore
    private let defaults: UserDefaults
    private let baseURLKey = "jarvis.companion.baseURL"

    init(defaults: UserDefaults = .standard, tokenStore: KeychainCompanionTokenStore = KeychainCompanionTokenStore()) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.baseURLText = defaults.string(forKey: baseURLKey) ?? "http://127.0.0.1:8788"
        self.companionToken = (try? tokenStore.loadToken()) ?? ""
    }

    func saveConnection() {
        defaults.set(baseURLText.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey)
        do {
            if companionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try tokenStore.deleteToken()
            } else {
                try tokenStore.saveToken(companionToken)
            }
            lastError = ""
            connectionStatus = "Saved"
        } catch {
            lastError = "Could not save token: \(error)"
        }
    }

    func makeClient() throws -> CompanionClient {
        guard let baseURL = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CompanionClientError.invalidBaseURL
        }
        return CompanionClient(configuration: CompanionConfiguration(baseURL: baseURL, token: companionToken))
    }

    func checkConnection() async {
        saveConnection()
        do {
            let client = try makeClient()
            let status = try await client.status()
            connectionStatus = "Connected. \(status.eventCount) companion events on the Mac."
            lastError = ""
        } catch {
            connectionStatus = "Not connected"
            lastError = "Connection check failed: \(error)"
        }
    }

    func sendTurn(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            lastError = "Say or type something for JARVIS first."
            return
        }
        do {
            let response = try await makeClient().turn(text: clean)
            lastReply = response.reply ?? "JARVIS responded without text."
            lastError = ""
        } catch {
            lastError = "Turn failed: \(error)"
        }
    }

    func send(event: CompanionEvent) async {
        do {
            _ = try await makeClient().send(event: event)
            connectionStatus = "Sent \(event.kind) from \(event.source)."
            lastError = ""
        } catch {
            lastError = "Event send failed: \(error)"
        }
    }
}
