import XCTest
@testable import JARVISOAuthKeychainBridge

final class OAuthKeychainBridgeTests: XCTestCase {
    func testSaveLoadDeleteRoundTripWithoutPlaintextFiles() throws {
        let service = "org.gmri.jarvis.oauth.tests.\(UUID().uuidString)"
        let account = "gemini"
        let bridge = OAuthKeychainBridge(service: service, requireUserPresence: false)
        defer { try? bridge.delete(providerAccount: account) }

        let token = OAuthStoredToken(accessToken: "access-secret", refreshToken: "refresh-secret", scope: "https://www.googleapis.com/auth/generativelanguage", expiresAtUnix: 1_900_000_000)
        try bridge.save(providerAccount: account, token: token)
        XCTAssertEqual(try bridge.load(providerAccount: account), token)
        try bridge.delete(providerAccount: account)
        XCTAssertNil(try bridge.load(providerAccount: account))
    }

    func testPerProviderServiceNamesRemainSeparate() throws {
        let gemini = OAuthKeychainBridge(service: "org.gmri.jarvis.oauth.tests.gemini.\(UUID().uuidString)", requireUserPresence: false)
        let copilot = OAuthKeychainBridge(service: "org.gmri.jarvis.oauth.tests.github-copilot.\(UUID().uuidString)", requireUserPresence: false)
        defer { try? gemini.delete(providerAccount: "token"); try? copilot.delete(providerAccount: "token") }

        try gemini.save(providerAccount: "token", token: OAuthStoredToken(accessToken: "g", refreshToken: "gr", scope: "generativelanguage", expiresAtUnix: 2))
        try copilot.save(providerAccount: "token", token: OAuthStoredToken(accessToken: "c", refreshToken: "cr", scope: "read:user", expiresAtUnix: 3))

        XCTAssertEqual(try gemini.load(providerAccount: "token")?.accessToken, "g")
        XCTAssertEqual(try copilot.load(providerAccount: "token")?.accessToken, "c")
    }
}
