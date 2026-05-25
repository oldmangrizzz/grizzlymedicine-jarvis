import CharacterValuesBridge
import Foundation

public enum CharacterValuesClient {
    public static func installAuditBridgeKey(_ key: Data) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let ok = key.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return jarvis_cv_install_audit_bridge_key(base, UInt(key.count), &errPtr)
        }
        guard ok else {
            let message = errPtr.map { String(cString: $0) } ?? "audit bridge key install failed"
            if let errPtr { jarvis_cv_free(errPtr) }
            throw CeremonyError.characterValues(message)
        }
    }

    public static func canonical() throws -> CharacterValuesAnchor {
        var jsonPtr: UnsafeMutablePointer<CChar>?
        var errPtr: UnsafeMutablePointer<CChar>?
        guard jarvis_cv_canonical_json(&jsonPtr, &errPtr), let jsonPtr else {
            let message = errPtr.map { String(cString: $0) } ?? "CharacterValues bridge returned no error"
            if let errPtr { jarvis_cv_free(errPtr) }
            throw CeremonyError.characterValues(message)
        }
        defer { jarvis_cv_free(jsonPtr) }
        let data = Data(String(cString: jsonPtr).utf8)
        struct BridgeJSON: Decodable {
            let boot_identity: String; let values_hash: String; let origin_hash: String; let identity_hash: String
            let hv_anchor: String; let hv_kernel: String; let hv_dimension: Int
        }
        let decoded = try JSONDecoder().decode(BridgeJSON.self, from: data)
        return CharacterValuesAnchor(bootIdentity: decoded.boot_identity,
                                     valuesHash: decoded.values_hash,
                                     originHash: decoded.origin_hash,
                                     identityHash: decoded.identity_hash,
                                     hvAnchor: decoded.hv_anchor,
                                     hvKernel: decoded.hv_kernel,
                                     hvDimension: decoded.hv_dimension)
    }
}
