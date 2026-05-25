import Darwin
import Foundation

@_cdecl("jarvis_se_free")
public func jarvis_se_free(_ ptr: UnsafeMutableRawPointer?) {
    free(ptr)
}

@_cdecl("jarvis_se_hot_key_descriptor")
public func jarvis_se_hot_key_descriptor(_ keyTagPtr: UnsafePointer<CChar>?,
                                         _ auditLogPathPtr: UnsafePointer<CChar>?,
                                         _ descriptorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                         _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    bridgeResult(errorOut: errorOut) {
        let manager = SecureEnclaveIdentityManager(keyTag: stringOrDefault(keyTagPtr, SecureEnclaveIdentityManager.defaultKeyTag),
                                                   auditLogPath: urlOrNil(auditLogPathPtr))
        return try encodeJSON(manager.descriptor())
    } assign: { descriptorOut?.pointee = duplicateCString($0) }
}

@_cdecl("jarvis_se_sign_challenge")
public func jarvis_se_sign_challenge(_ keyTagPtr: UnsafePointer<CChar>?,
                                     _ challengePtr: UnsafePointer<UInt8>?,
                                     _ challengeLen: Int,
                                     _ auditLogPathPtr: UnsafePointer<CChar>?,
                                     _ signatureOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                     _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    bridgeResult(errorOut: errorOut) {
        guard let challengePtr, challengeLen > 0 else { throw SecureEnclaveIdentityError.invalidChallenge }
        let manager = SecureEnclaveIdentityManager(keyTag: stringOrDefault(keyTagPtr, SecureEnclaveIdentityManager.defaultKeyTag),
                                                   auditLogPath: urlOrNil(auditLogPathPtr))
        let challenge = Data(bytes: challengePtr, count: challengeLen)
        return try encodeJSON(manager.signChallenge(challenge))
    } assign: { signatureOut?.pointee = duplicateCString($0) }
}

@_cdecl("jarvis_se_create_certificate")
public func jarvis_se_create_certificate(_ keyTagPtr: UnsafePointer<CChar>?,
                                         _ valuesHashPtr: UnsafePointer<CChar>?,
                                         _ rootPublicKeyPtr: UnsafePointer<UInt8>?,
                                         _ rootPublicKeyLen: Int,
                                         _ rootPrivateKeyPtr: UnsafePointer<UInt8>?,
                                         _ rootPrivateKeyLen: Int,
                                         _ auditLogPathPtr: UnsafePointer<CChar>?,
                                         _ certificateOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                         _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    bridgeResult(errorOut: errorOut) {
        guard let valuesHashPtr else { throw SecureEnclaveIdentityError.decode("values_hash is required") }
        guard let rootPublicKeyPtr, rootPublicKeyLen == 32, let rootPrivateKeyPtr, rootPrivateKeyLen == 64 else {
            throw SecureEnclaveIdentityError.invalidRootKey
        }
        let manager = SecureEnclaveIdentityManager(keyTag: stringOrDefault(keyTagPtr, SecureEnclaveIdentityManager.defaultKeyTag),
                                                   auditLogPath: urlOrNil(auditLogPathPtr))
        let certificate = try manager.createCertificate(valuesHash: String(cString: valuesHashPtr),
                                                        coldRootPublicKey: Data(bytes: rootPublicKeyPtr, count: rootPublicKeyLen),
                                                        coldRootPrivateKey: Data(bytes: rootPrivateKeyPtr, count: rootPrivateKeyLen))
        return try encodeJSON(certificate)
    } assign: { certificateOut?.pointee = duplicateCString($0) }
}

@_cdecl("jarvis_se_verify_certificate")
public func jarvis_se_verify_certificate(_ certificatePtr: UnsafePointer<CChar>?,
                                         _ rootPublicKeyPtr: UnsafePointer<UInt8>?,
                                         _ rootPublicKeyLen: Int,
                                         _ verificationOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                         _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Bool {
    bridgeResult(errorOut: errorOut) {
        guard let certificatePtr else { throw SecureEnclaveIdentityError.decode("certificate_json is required") }
        guard let rootPublicKeyPtr, rootPublicKeyLen == 32 else { throw SecureEnclaveIdentityError.invalidRootKey }
        let certificate = try decodeJSON(HotIdentityCertificate.self, from: String(cString: certificatePtr))
        let verification = SecureEnclaveIdentityManager.verifyCertificate(certificate,
                                                                          coldRootPublicKey: Data(bytes: rootPublicKeyPtr, count: rootPublicKeyLen))
        return try encodeJSON(verification)
    } assign: { verificationOut?.pointee = duplicateCString($0) }
}

private func bridgeResult(errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                          body: () throws -> String,
                          assign: (String) -> Void) -> Bool {
    do {
        assign(try body())
        return true
    } catch {
        errorOut?.pointee = duplicateCString(String(describing: error))
        return false
    }
}

private func stringOrDefault(_ ptr: UnsafePointer<CChar>?, _ fallback: String) -> String {
    guard let ptr else { return fallback }
    let value = String(cString: ptr)
    return value.isEmpty ? fallback : value
}

private func urlOrNil(_ ptr: UnsafePointer<CChar>?) -> URL? {
    guard let ptr else { return nil }
    let value = String(cString: ptr)
    return value.isEmpty ? nil : URL(fileURLWithPath: value)
}

private func duplicateCString(_ string: String) -> UnsafeMutablePointer<CChar>? {
    strdup(string)
}
