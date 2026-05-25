import CryptoKit
import Foundation
import Security
import XCTest
@testable import JARVISMacCockpit

final class AuthorizedSpeakerStoreTests: XCTestCase {
    func testAuditKeyMissingWithoutKeychainLegacyOrCeremonyThrowsAuditKeyMissing() throws {
        let fixture = try fixtureStore()
        defer { cleanupFixture(fixture) }

        XCTAssertThrowsError(try fixture.store.auditKey()) { error in
            XCTAssertEqual(error as? AuthorizedSpeakerStoreError, .auditKeyMissing(reason: "ceremony audit key not present; cannot register speakers"))
        }
    }

    func testAuditKeyWithCeremonyDerivedKeyInKeychainReturnsKey() throws {
        let fixture = try fixtureStore()
        defer { cleanupFixture(fixture) }
        let expected = Data((0..<32).map(UInt8.init))

        try fixture.store.storeAuditKeyInKeychain(expected)
        let key = try fixture.store.auditKey()

        XCTAssertEqual(data(from: key), expected)
    }

    func testAuditKeyWithLegacyInvalidHMACCanaryRefusesImport() throws {
        let fixture = try fixtureStore()
        defer { cleanupFixture(fixture) }
        let legacyKey = Data(repeating: 0x42, count: 32)
        let payload: [String: String] = [
            "key_b64": legacyKey.base64EncodedString(),
            "canary_hmac_hex": String(repeating: "0", count: 64)
        ]
        try FileManager.default.createDirectory(at: fixture.legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: fixture.legacyURL)

        XCTAssertThrowsError(try fixture.store.auditKey()) { error in
            guard case .invalidLegacyAuditKey = error as? AuthorizedSpeakerStoreError else {
                return XCTFail("expected invalidLegacyAuditKey, got \(error)")
            }
        }
    }

    private struct Fixture {
        let root: URL
        let legacyURL: URL
        let service: String
        let account: String
        let store: AuthorizedSpeakerStore
    }

    private func fixtureStore() throws -> Fixture {
        let service = "org.gmri.jarvis.mac-cockpit.authorized-speakers.audit-hmac.tests.\(UUID().uuidString)"
        let account = "authorized_speakers_tests"
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-artifacts/authorized-speakers/\(UUID().uuidString)", isDirectory: true)
        let legacyURL = root.appendingPathComponent("legacy/authorized_speakers.key")
        let ceremonyURL = root.appendingPathComponent("missing/seal_master.se.blob")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        let store = AuthorizedSpeakerStore(root: root,
                                           auditKeyService: service,
                                           auditKeyAccount: account,
                                           legacyAuditKeyURL: legacyURL,
                                           ceremonyAuditSealBlobURL: ceremonyURL)
        return Fixture(root: root, legacyURL: legacyURL, service: service, account: account, store: store)
    }

    private func cleanupFixture(_ fixture: Fixture) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fixture.service,
            kSecAttrAccount as String: fixture.account
        ] as CFDictionary)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func data(from key: SymmetricKey) -> Data {
        var out = Data()
        key.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }
}
