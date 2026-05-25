import Foundation
import Security

public enum OAuthKeychainError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case accessControlFailed(OSStatus)
    case keychain(OSStatus)
}

public struct OAuthStoredToken: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var tokenType: String
    public var scope: String
    public var expiresAtUnix: Int64

    public init(accessToken: String, refreshToken: String, tokenType: String = "Bearer", scope: String, expiresAtUnix: Int64) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAtUnix = expiresAtUnix
    }
}

public final class OAuthKeychainBridge {
    public let service: String
    private let requireUserPresence: Bool

    public init(service: String, requireUserPresence: Bool = true) {
        self.service = service
        self.requireUserPresence = requireUserPresence
    }

    public func save(providerAccount: String, token: OAuthStoredToken) throws {
        let data = try JSONEncoder().encode(token)
        var query = baseQuery(providerAccount: providerAccount)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        if requireUserPresence {
            var error: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
                throw OAuthKeychainError.accessControlFailed(errSecParam)
            }
            query[kSecAttrAccessControl as String] = accessControl
            query.removeValue(forKey: kSecAttrAccessible as String)
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw OAuthKeychainError.keychain(status) }
    }

    public func load(providerAccount: String) throws -> OAuthStoredToken? {
        var query = baseQuery(providerAccount: providerAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OAuthKeychainError.keychain(status) }
        guard let data = result as? Data else { throw OAuthKeychainError.decodingFailed }
        return try JSONDecoder().decode(OAuthStoredToken.self, from: data)
    }

    public func delete(providerAccount: String) throws {
        let status = SecItemDelete(baseQuery(providerAccount: providerAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OAuthKeychainError.keychain(status) }
    }

    private func baseQuery(providerAccount: String) -> [String: Any] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerAccount
        ]
        return query
    }
}

@_cdecl("JARVISOAuthKeychainSave")
public func JARVISOAuthKeychainSave(_ servicePtr: UnsafePointer<CChar>, _ accountPtr: UnsafePointer<CChar>, _ jsonPtr: UnsafePointer<CChar>) -> Int32 {
    do {
        let bridge = OAuthKeychainBridge(service: String(cString: servicePtr))
        let account = String(cString: accountPtr)
        let data = Data(String(cString: jsonPtr).utf8)
        let token = try JSONDecoder().decode(OAuthStoredToken.self, from: data)
        try bridge.save(providerAccount: account, token: token)
        return 0
    } catch { return -1 }
}

@_cdecl("JARVISOAuthKeychainLoad")
public func JARVISOAuthKeychainLoad(_ servicePtr: UnsafePointer<CChar>, _ accountPtr: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    do {
        let bridge = OAuthKeychainBridge(service: String(cString: servicePtr))
        guard let token = try bridge.load(providerAccount: String(cString: accountPtr)) else { return nil }
        let data = try JSONEncoder().encode(token)
        return strdup(String(decoding: data, as: UTF8.self))
    } catch { return nil }
}

@_cdecl("JARVISOAuthKeychainDelete")
public func JARVISOAuthKeychainDelete(_ servicePtr: UnsafePointer<CChar>, _ accountPtr: UnsafePointer<CChar>) -> Int32 {
    do {
        let bridge = OAuthKeychainBridge(service: String(cString: servicePtr))
        try bridge.delete(providerAccount: String(cString: accountPtr))
        return 0
    } catch { return -1 }
}

@_cdecl("JARVISOAuthKeychainFree")
public func JARVISOAuthKeychainFree(_ ptr: UnsafeMutablePointer<CChar>?) { free(ptr) }
