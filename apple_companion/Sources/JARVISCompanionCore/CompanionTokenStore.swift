import Foundation
import Security

public protocol CompanionTokenStore: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

public enum CompanionTokenStoreError: Error, Equatable {
    case emptyToken
    case encodingFailed
    case unexpectedData
    case keychainStatus(OSStatus)
}

public struct KeychainCompanionTokenStore: CompanionTokenStore {
    public var service: String
    public var account: String

    public init(service: String = "org.grizzlymedicine.jarvis.companion", account: String = "companion-ingress-token") {
        self.service = service
        self.account = account
    }

    public func loadToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CompanionTokenStoreError.keychainStatus(status)
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw CompanionTokenStoreError.unexpectedData
        }
        return token
    }

    public func saveToken(_ token: String) throws {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw CompanionTokenStoreError.emptyToken
        }
        guard let data = clean.data(using: .utf8) else {
            throw CompanionTokenStoreError.encodingFailed
        }

        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw CompanionTokenStoreError.keychainStatus(status)
        }

        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CompanionTokenStoreError.keychainStatus(addStatus)
        }
    }

    public func deleteToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionTokenStoreError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
