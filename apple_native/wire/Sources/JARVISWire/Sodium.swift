#if canImport(CsodiumShim) && os(macOS)
import CsodiumShim
#else
import CryptoKit
import Security
#endif
import Foundation

public enum WireError: Error, Equatable, Sendable {
    case sodiumInitializationFailed
    case invalidKeySize(expected: Int, actual: Int)
    case invalidNonceSize(expected: Int, actual: Int)
    case invalidSignatureSize(expected: Int, actual: Int)
    case invalidFrame
    case invalidCiphertext
    case invalidSignature
    case replayDetected
    case staleTimestamp
    case sequenceRollback
    case roleMismatch
    case pairingExpired
    case shortCodeMismatch
    case malformedPairingPayload
    case operatorAttestationRequired
    case resourceLimitExceeded
    // §2 AGENTS.md: no silent fallback on a security organ. SecRandomCopyBytes failure
    // must propagate; there is no degraded path.
    case entropyUnavailable(osStatus: Int32)
}

#if canImport(CsodiumShim) && os(macOS)
public enum Sodium {
    public static func initialize() throws {
        if sodium_init() < 0 { throw WireError.sodiumInitializationFailed }
    }

    public static var signPublicKeyBytes: Int { Int(crypto_sign_publickeybytes()) }
    public static var signSecretKeyBytes: Int { Int(crypto_sign_secretkeybytes()) }
    public static var signBytes: Int { Int(crypto_sign_bytes()) }
    public static var kxPublicKeyBytes: Int { Int(crypto_kx_publickeybytes()) }
    public static var kxSecretKeyBytes: Int { Int(crypto_kx_secretkeybytes()) }
    public static var kxSessionKeyBytes: Int { Int(crypto_kx_sessionkeybytes()) }
    public static var aeadKeyBytes: Int { Int(crypto_aead_xchacha20poly1305_ietf_keybytes()) }
    public static var aeadNonceBytes: Int { Int(crypto_aead_xchacha20poly1305_ietf_npubbytes()) }
    public static var aeadABYTES: Int { Int(crypto_aead_xchacha20poly1305_ietf_abytes()) }

    public static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                randombytes_buf(baseAddress, count)
            }
        }
        return data
    }

    public static func signKeypair() throws -> SigningKeyPair {
        try initialize()
        var publicKey = Data(count: signPublicKeyBytes)
        var secretKey = Data(count: signSecretKeyBytes)
        let rc = publicKey.withUnsafeMutableBytes { pk in
            secretKey.withUnsafeMutableBytes { sk in
                guard let pkBase = pk.bindMemory(to: UInt8.self).baseAddress,
                      let skBase = sk.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                return crypto_sign_keypair(pkBase, skBase)
            }
        }
        if rc != 0 { throw WireError.invalidKeySize(expected: signPublicKeyBytes, actual: publicKey.count) }
        return SigningKeyPair(publicKey: publicKey, secretKey: secretKey)
    }

    public static func kxKeypair() throws -> KeyExchangeKeyPair {
        try initialize()
        var publicKey = Data(count: kxPublicKeyBytes)
        var secretKey = Data(count: kxSecretKeyBytes)
        let rc = publicKey.withUnsafeMutableBytes { pk in
            secretKey.withUnsafeMutableBytes { sk in
                guard let pkBase = pk.bindMemory(to: UInt8.self).baseAddress,
                      let skBase = sk.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                return crypto_kx_keypair(pkBase, skBase)
            }
        }
        if rc != 0 { throw WireError.invalidKeySize(expected: kxPublicKeyBytes, actual: publicKey.count) }
        return KeyExchangeKeyPair(publicKey: publicKey, secretKey: secretKey)
    }

    public static func sign(_ message: Data, secretKey: Data) throws -> Data {
        try initialize()
        guard secretKey.count == signSecretKeyBytes else { throw WireError.invalidKeySize(expected: signSecretKeyBytes, actual: secretKey.count) }
        var signature = Data(count: signBytes)
        var sigLen: UInt64 = 0
        let rc = signature.withUnsafeMutableBytes { sig in
            message.withUnsafeBytes { msg in
                secretKey.withUnsafeBytes { sk in
                    guard let sigBase = sig.bindMemory(to: UInt8.self).baseAddress,
                          let msgBase = msg.bindMemory(to: UInt8.self).baseAddress,
                          let skBase = sk.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                    return crypto_sign_detached(sigBase, &sigLen, msgBase, UInt64(message.count), skBase)
                }
            }
        }
        if rc != 0 { throw WireError.invalidSignature }
        return signature
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) throws -> Bool {
        try initialize()
        guard publicKey.count == signPublicKeyBytes else { throw WireError.invalidKeySize(expected: signPublicKeyBytes, actual: publicKey.count) }
        guard signature.count == signBytes else { throw WireError.invalidSignatureSize(expected: signBytes, actual: signature.count) }
        let rc = signature.withUnsafeBytes { sig in
            message.withUnsafeBytes { msg in
                publicKey.withUnsafeBytes { pk in
                    guard let sigBase = sig.bindMemory(to: UInt8.self).baseAddress,
                          let msgBase = msg.bindMemory(to: UInt8.self).baseAddress,
                          let pkBase = pk.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                    return crypto_sign_verify_detached(sigBase, msgBase, UInt64(message.count), pkBase)
                }
            }
        }
        return rc == 0
    }

    public static func derive(role: WireRole, selfKeyPair: KeyExchangeKeyPair, peerPublicKey: Data) throws -> SessionKeys {
        try initialize()
        guard selfKeyPair.publicKey.count == kxPublicKeyBytes else { throw WireError.invalidKeySize(expected: kxPublicKeyBytes, actual: selfKeyPair.publicKey.count) }
        guard selfKeyPair.secretKey.count == kxSecretKeyBytes else { throw WireError.invalidKeySize(expected: kxSecretKeyBytes, actual: selfKeyPair.secretKey.count) }
        guard peerPublicKey.count == kxPublicKeyBytes else { throw WireError.invalidKeySize(expected: kxPublicKeyBytes, actual: peerPublicKey.count) }
        var rx = Data(count: kxSessionKeyBytes)
        var tx = Data(count: kxSessionKeyBytes)
        let rc = rx.withUnsafeMutableBytes { rxPtr in
            tx.withUnsafeMutableBytes { txPtr in
                selfKeyPair.publicKey.withUnsafeBytes { pk in
                    selfKeyPair.secretKey.withUnsafeBytes { sk in
                        peerPublicKey.withUnsafeBytes { peer in
                            guard let rxBase = rxPtr.bindMemory(to: UInt8.self).baseAddress,
                                  let txBase = txPtr.bindMemory(to: UInt8.self).baseAddress,
                                  let pkBase = pk.bindMemory(to: UInt8.self).baseAddress,
                                  let skBase = sk.bindMemory(to: UInt8.self).baseAddress,
                                  let peerBase = peer.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                            if role == .companion {
                                return crypto_kx_client_session_keys(rxBase, txBase, pkBase, skBase, peerBase)
                            }
                            return crypto_kx_server_session_keys(rxBase, txBase, pkBase, skBase, peerBase)
                        }
                    }
                }
            }
        }
        if rc != 0 { throw WireError.invalidKeySize(expected: kxPublicKeyBytes, actual: peerPublicKey.count) }
        return SessionKeys(receiveKey: rx, transmitKey: tx)
    }

    public static func seal(plaintext: Data, aad: Data, nonce: Data, key: Data) throws -> Data {
        try initialize()
        guard key.count == aeadKeyBytes else { throw WireError.invalidKeySize(expected: aeadKeyBytes, actual: key.count) }
        guard nonce.count == aeadNonceBytes else { throw WireError.invalidNonceSize(expected: aeadNonceBytes, actual: nonce.count) }
        var ciphertext = Data(count: plaintext.count + aeadABYTES)
        var cipherLen: UInt64 = 0
        let rc = ciphertext.withUnsafeMutableBytes { cipher in
            plaintext.withUnsafeBytes { plain in
                aad.withUnsafeBytes { aadPtr in
                    nonce.withUnsafeBytes { noncePtr in
                        key.withUnsafeBytes { keyPtr in
                            guard let cipherBase = cipher.bindMemory(to: UInt8.self).baseAddress,
                                  let plainBase = plain.bindMemory(to: UInt8.self).baseAddress,
                                  let aadBase = aadPtr.bindMemory(to: UInt8.self).baseAddress,
                                  let nonceBase = noncePtr.bindMemory(to: UInt8.self).baseAddress,
                                  let keyBase = keyPtr.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                            return crypto_aead_xchacha20poly1305_ietf_encrypt(cipherBase, &cipherLen, plainBase, UInt64(plaintext.count), aadBase, UInt64(aad.count), nil, nonceBase, keyBase)
                        }
                    }
                }
            }
        }
        if rc != 0 { throw WireError.invalidCiphertext }
        ciphertext.count = Int(cipherLen)
        return ciphertext
    }

    public static func open(ciphertext: Data, aad: Data, nonce: Data, key: Data) throws -> Data {
        try initialize()
        guard key.count == aeadKeyBytes else { throw WireError.invalidKeySize(expected: aeadKeyBytes, actual: key.count) }
        guard nonce.count == aeadNonceBytes else { throw WireError.invalidNonceSize(expected: aeadNonceBytes, actual: nonce.count) }
        guard ciphertext.count >= aeadABYTES else { throw WireError.invalidCiphertext }
        var plaintext = Data(count: ciphertext.count - aeadABYTES)
        var plainLen: UInt64 = 0
        let rc = plaintext.withUnsafeMutableBytes { plain in
            ciphertext.withUnsafeBytes { cipher in
                aad.withUnsafeBytes { aadPtr in
                    nonce.withUnsafeBytes { noncePtr in
                        key.withUnsafeBytes { keyPtr in
                            guard let plainBase = plain.bindMemory(to: UInt8.self).baseAddress,
                                  let cipherBase = cipher.bindMemory(to: UInt8.self).baseAddress,
                                  let aadBase = aadPtr.bindMemory(to: UInt8.self).baseAddress,
                                  let nonceBase = noncePtr.bindMemory(to: UInt8.self).baseAddress,
                                  let keyBase = keyPtr.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                            return crypto_aead_xchacha20poly1305_ietf_decrypt(plainBase, &plainLen, nil, cipherBase, UInt64(ciphertext.count), aadBase, UInt64(aad.count), nonceBase, keyBase)
                        }
                    }
                }
            }
        }
        if rc != 0 { throw WireError.invalidCiphertext }
        plaintext.count = Int(plainLen)
        return plaintext
    }
}

#else
public enum Sodium {
    public static func initialize() throws {}

    public static var signPublicKeyBytes: Int { 32 }
    public static var signSecretKeyBytes: Int { 32 }
    public static var signBytes: Int { 64 }
    public static var kxPublicKeyBytes: Int { 32 }
    public static var kxSecretKeyBytes: Int { 32 }
    public static var kxSessionKeyBytes: Int { 32 }
    public static var aeadKeyBytes: Int { 32 }
    public static var aeadNonceBytes: Int { 24 }
    public static var aeadABYTES: Int { 16 }

    // Domain-separated HKDF labels for key derivation in this package.
    enum HKDFDomain: String {
        case wireSessionCompanionTransmit = "jarvis.wire.session.companionTransmit.v1"
        case wireSessionHostTransmit      = "jarvis.wire.session.hostTransmit.v1"
    }

    public static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            // §2 AGENTS.md: no silent fallback on a security organ (RNG).
            // Do NOT fall back to UInt8.random or any weaker source.
            throw WireError.entropyUnavailable(osStatus: status)
        }
        return data
    }

    public static func signKeypair() throws -> SigningKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        return SigningKeyPair(publicKey: privateKey.publicKey.rawRepresentation, secretKey: privateKey.rawRepresentation)
    }

    public static func kxKeypair() throws -> KeyExchangeKeyPair {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return KeyExchangeKeyPair(publicKey: privateKey.publicKey.rawRepresentation, secretKey: privateKey.rawRepresentation)
    }

    public static func sign(_ message: Data, secretKey: Data) throws -> Data {
        guard secretKey.count == signSecretKeyBytes else { throw WireError.invalidKeySize(expected: signSecretKeyBytes, actual: secretKey.count) }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey)
        return try privateKey.signature(for: message)
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) throws -> Bool {
        guard publicKey.count == signPublicKeyBytes else { throw WireError.invalidKeySize(expected: signPublicKeyBytes, actual: publicKey.count) }
        guard signature.count == signBytes else { throw WireError.invalidSignatureSize(expected: signBytes, actual: signature.count) }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: message)
    }

    public static func derive(role: WireRole, selfKeyPair: KeyExchangeKeyPair, peerPublicKey: Data) throws -> SessionKeys {
        guard selfKeyPair.publicKey.count == kxPublicKeyBytes else { throw WireError.invalidKeySize(expected: kxPublicKeyBytes, actual: selfKeyPair.publicKey.count) }
        guard selfKeyPair.secretKey.count == kxSecretKeyBytes else { throw WireError.invalidKeySize(expected: kxSecretKeyBytes, actual: selfKeyPair.secretKey.count) }
        guard peerPublicKey.count == kxPublicKeyBytes else { throw WireError.invalidKeySize(expected: kxPublicKeyBytes, actual: peerPublicKey.count) }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: selfKeyPair.secretKey)
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let companionTransmit = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("JARVISWire-v1".utf8), sharedInfo: Data(HKDFDomain.wireSessionCompanionTransmit.rawValue.utf8), outputByteCount: kxSessionKeyBytes).dataRepresentation
        let hostTransmit = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("JARVISWire-v1".utf8), sharedInfo: Data(HKDFDomain.wireSessionHostTransmit.rawValue.utf8), outputByteCount: kxSessionKeyBytes).dataRepresentation
        if role == .companion {
            return SessionKeys(receiveKey: hostTransmit, transmitKey: companionTransmit)
        }
        return SessionKeys(receiveKey: companionTransmit, transmitKey: hostTransmit)
    }

    public static func seal(plaintext: Data, aad: Data, nonce: Data, key: Data) throws -> Data {
        guard key.count == aeadKeyBytes else { throw WireError.invalidKeySize(expected: aeadKeyBytes, actual: key.count) }
        guard nonce.count == aeadNonceBytes else { throw WireError.invalidNonceSize(expected: aeadNonceBytes, actual: nonce.count) }
        let symmetricKey = SymmetricKey(data: key)
        let cryptoNonce = try AES.GCM.Nonce(data: nonce.prefix(12))
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: cryptoNonce, authenticating: aad)
        return sealedBox.ciphertext + sealedBox.tag
    }

    public static func open(ciphertext: Data, aad: Data, nonce: Data, key: Data) throws -> Data {
        guard key.count == aeadKeyBytes else { throw WireError.invalidKeySize(expected: aeadKeyBytes, actual: key.count) }
        guard nonce.count == aeadNonceBytes else { throw WireError.invalidNonceSize(expected: aeadNonceBytes, actual: nonce.count) }
        guard ciphertext.count >= aeadABYTES else { throw WireError.invalidCiphertext }
        let symmetricKey = SymmetricKey(data: key)
        let cipher = ciphertext.dropLast(aeadABYTES)
        let tag = ciphertext.suffix(aeadABYTES)
        let cryptoNonce = try AES.GCM.Nonce(data: nonce.prefix(12))
        let box = try AES.GCM.SealedBox(nonce: cryptoNonce, ciphertext: cipher, tag: tag)
        return try AES.GCM.open(box, using: symmetricKey, authenticating: aad)
    }

    static func genericHashPrefix(_ material: Data, byteCount: Int) -> Data {
        Data(SHA256.hash(data: material).prefix(byteCount))
    }
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
#endif
