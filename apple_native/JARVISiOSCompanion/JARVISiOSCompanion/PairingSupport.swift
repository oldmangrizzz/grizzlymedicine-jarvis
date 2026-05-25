import Foundation
import Security
import UIKit
import JARVISWire

extension SigningKeyPair: @retroactive Codable {
    private enum CodingKeys: String, CodingKey { case publicKey, secretKey }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            publicKey: try container.decode(Data.self, forKey: .publicKey),
            secretKey: try container.decode(Data.self, forKey: .secretKey)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(publicKey, forKey: .publicKey)
        try container.encode(secretKey, forKey: .secretKey)
    }
}

struct StoredPairingMaterial: Codable, Equatable {
    var record: PairingRecord
    var companionSigningKey: SigningKeyPair
}

protocol PairingStore {
    func load() throws -> StoredPairingMaterial?
    func save(_ material: StoredPairingMaterial) throws
    func delete() throws
}

struct KeychainPairingStore: PairingStore {
    private let service = "ai.realjarvis.iphone.surface.pairing"
    private let account = "jarvis-wire-pairing"

    func load() throws -> StoredPairingMaterial? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(StoredPairingMaterial.self, from: data)
    }

    func save(_ material: StoredPairingMaterial) throws {
        let data = try JSONEncoder().encode(material)
        try deleteIgnoringMissing()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = deleteStatus()
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func deleteIgnoringMissing() throws {
        let status = deleteStatus()
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func deleteStatus() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus
    var errorDescription: String? { "Keychain operation failed with OSStatus \(status)" }
}

struct PairingCoordinator {
    let companionKind = "iphone-sensory-effector-surface"

    func completePairing(qrPayload: String, displayedShortCode: String, companionID: String = UIDeviceIdentifier.current) throws -> StoredPairingMaterial {
        let offer = try PairingCeremony.decodeQRCodePayload(qrPayload.trimmingCharacters(in: .whitespacesAndNewlines))
        let signingKey = try SigningKeyPair.generate()
        let response = try PairingCeremony.createResponse(
            offer: offer,
            companionID: companionID,
            companionKind: companionKind,
            companionSigningKey: signingKey,
            displayedShortCode: displayedShortCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let record = PairingRecord(
            hostID: offer.hostID,
            companionID: response.companionID,
            companionKind: response.companionKind,
            operatorID: offer.operatorID,
            anchorPublicKey: offer.anchorPublicKey,
            companionSigningPublicKey: response.companionSigningPublicKey,
            enrollmentSignature: response.signature
        )
        return StoredPairingMaterial(record: record, companionSigningKey: signingKey)
    }
}

enum UIDeviceIdentifier {
    static var current: String {
#if os(iOS)
        "ios-" + (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
#else
        "ios-" + UUID().uuidString
#endif
    }
}
