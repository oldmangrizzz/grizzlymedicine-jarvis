import CLibsodium
import CryptoKit
import Darwin
import Foundation
import IOKit
import Security

public enum HotIdentityMode: String, Codable, Equatable {
    case secureEnclave = "secure-enclave"
    case libsodiumFallback = "libsodium-fallback"
}

public enum SecureEnclaveIdentityError: Error, CustomStringConvertible {
    case libsodiumUnavailable
    case invalidRootKey
    case invalidChallenge
    case certificateVerificationFailed(String)
    case keychain(OSStatus, String)
    case crypto(String)
    case auditEventTooLarge(Int)
    case auditChainBroken(String)
    case decode(String)
    case ceremonyArtifactMissing(artifact: String, path: String, reason: String)

    public var description: String {
        switch self {
        case .libsodiumUnavailable: return "libsodium initialization failed"
        case .invalidRootKey: return "cold root key must be Ed25519 libsodium public=32/private=64 bytes"
        case .invalidChallenge: return "challenge must not be empty"
        case .certificateVerificationFailed(let reason): return "certificate verification failed: \(reason)"
        case .keychain(let status, let context): return "Keychain/Secure Enclave error \(status): \(context)"
        case .crypto(let message): return message
        case .auditEventTooLarge(let bytes): return "Secure Enclave audit event exceeds 512-byte PIPE_BUF cap: \(bytes) bytes"
        case .auditChainBroken(let message): return "Secure Enclave audit chain broken: \(message)"
        case .decode(let message): return message
        case .ceremonyArtifactMissing(let artifact, let path, let reason): return "Ceremony artifact '\(artifact)' missing at \(path): \(reason)"
        }
    }
}


public enum BlobIntegrityError: Error, CustomStringConvertible, Equatable {
    case magicMismatch
    case keytagMismatch
    case aeadVerifyFailed
    case malformedLength
    case sodiumUnavailable

    public var description: String {
        switch self {
        case .magicMismatch: return "BlobIntegrityError.magicMismatch"
        case .keytagMismatch: return "BlobIntegrityError.keytagMismatch"
        case .aeadVerifyFailed: return "BlobIntegrityError.aeadVerifyFailed"
        case .malformedLength: return "BlobIntegrityError.malformedLength"
        case .sodiumUnavailable: return "BlobIntegrityError.sodiumUnavailable"
        }
    }
}

// ─── SE-local path/tag fingerprinting ────────────────────────────────────────
// Used to redact absolute paths and key tags from error messages and audit
// metadata within this module. Produces the first 8 hex characters of SHA-256.
private func seFingerprint(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
}
private func sePathFP(_ url: URL) -> String { seFingerprint(url.path) }
private func seKeyTagFP(_ tag: String) -> String { seFingerprint(tag) }

public enum SecureEnclaveBlobV1 {
    public static let magic = Data([0x4a, 0x41, 0x52, 0x56, 0x49, 0x53, 0x76, 0x31, 0x00])
    // Blob v1 uses libsodium XChaCha20-Poly1305-IETF; nonce length is 24 bytes.
    public static var nonceLengthForTest: Int { Int(crypto_aead_xchacha20poly1305_ietf_npubbytes()) }
    public static let cipherNameForTest = "XChaCha20-Poly1305-IETF"
    private static var nonceBytes: Int { nonceLengthForTest }
    private static var tagBytes: Int { Int(crypto_aead_xchacha20poly1305_ietf_abytes()) }

    public static func isVersioned(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    public static func serialize(plaintext: Data, keyTag: String) throws -> Data {
        guard sodium_init() >= 0 else { throw BlobIntegrityError.sodiumUnavailable }
        let tagHash = keytagHash(keyTag)
        var nonce = Data(count: nonceBytes)
        let nonceCount = nonce.count
        nonce.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { randombytes_buf(base, nonceCount) }
        }
        var aad = Data(); aad.append(magic); aad.append(tagHash); aad.append(nonce)
        let key = aeadKey(keyTag: keyTag)
        var ciphertext = Data(count: plaintext.count + tagBytes)
        var cipherLen: UInt64 = 0
        let rc = ciphertext.withUnsafeMutableBytes { cipher in
            plaintext.withUnsafeBytes { plain in
                aad.withUnsafeBytes { aadRaw in
                    nonce.withUnsafeBytes { nonceRaw in
                        key.withUnsafeBytes { keyRaw in
                            guard let cipherBase = cipher.bindMemory(to: UInt8.self).baseAddress,
                                  let plainBase = plain.bindMemory(to: UInt8.self).baseAddress,
                                  let aadBase = aadRaw.bindMemory(to: UInt8.self).baseAddress,
                                  let nonceBase = nonceRaw.bindMemory(to: UInt8.self).baseAddress,
                                  let keyBase = keyRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                            return crypto_aead_xchacha20poly1305_ietf_encrypt(cipherBase, &cipherLen, plainBase, UInt64(plaintext.count), aadBase, UInt64(aad.count), nil, nonceBase, keyBase)
                        }
                    }
                }
            }
        }
        guard rc == 0 else { throw BlobIntegrityError.aeadVerifyFailed }
        ciphertext.count = Int(cipherLen)
        var out = Data(); out.append(magic); out.append(tagHash); out.append(nonce); out.append(ciphertext)
        return out
    }

    public static func open(_ blob: Data, keyTag: String) throws -> Data {
        guard blob.starts(with: magic) else { throw BlobIntegrityError.magicMismatch }
        guard sodium_init() >= 0 else { throw BlobIntegrityError.sodiumUnavailable }
        let header = magic.count + 32 + nonceBytes
        guard blob.count >= header + tagBytes else { throw BlobIntegrityError.malformedLength }
        let storedHash = blob.subdata(in: magic.count..<(magic.count + 32))
        guard storedHash == keytagHash(keyTag) else { throw BlobIntegrityError.keytagMismatch }
        let nonce = blob.subdata(in: (magic.count + 32)..<header)
        let ciphertext = blob.subdata(in: header..<blob.count)
        var aad = Data(); aad.append(magic); aad.append(storedHash); aad.append(nonce)
        let key = aeadKey(keyTag: keyTag)
        var plaintext = Data(count: ciphertext.count - tagBytes)
        var plainLen: UInt64 = 0
        let rc = plaintext.withUnsafeMutableBytes { plain in
            ciphertext.withUnsafeBytes { cipher in
                aad.withUnsafeBytes { aadRaw in
                    nonce.withUnsafeBytes { nonceRaw in
                        key.withUnsafeBytes { keyRaw in
                            guard let plainBase = plain.bindMemory(to: UInt8.self).baseAddress,
                                  let cipherBase = cipher.bindMemory(to: UInt8.self).baseAddress,
                                  let aadBase = aadRaw.bindMemory(to: UInt8.self).baseAddress,
                                  let nonceBase = nonceRaw.bindMemory(to: UInt8.self).baseAddress,
                                  let keyBase = keyRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                            return crypto_aead_xchacha20poly1305_ietf_decrypt(plainBase, &plainLen, nil, cipherBase, UInt64(ciphertext.count), aadBase, UInt64(aad.count), nonceBase, keyBase)
                        }
                    }
                }
            }
        }
        guard rc == 0 else { throw BlobIntegrityError.aeadVerifyFailed }
        plaintext.count = Int(plainLen)
        return plaintext
    }

    public static func keytagSHA256Hex(_ keyTag: String) -> String { sha256Hex(Data(keyTag.utf8)) }

    private static func keytagHash(_ keyTag: String) -> Data { Data(SHA256.hash(data: Data(keyTag.utf8))) }

    private static func aeadKey(keyTag: String) -> Data {
        var context = Data("JARVIS.se.blob.v1.aead".utf8)
        context.append(Data(keyTag.utf8))
        context.append(Data(machineUUID().utf8))
        return Data(SHA256.hash(data: context))
    }
}

public struct HardwareFingerprint: Codable, Equatable {
    public let machineUUID: String
    public let secureEnclaveKeyID: String

    public var canonicalJSONString: String {
        canonicalObject([
            "machine_uuid": machineUUID,
            "secure_enclave_key_id": secureEnclaveKeyID,
        ])
    }
}

public struct HotKeyDescriptor: Codable, Equatable {
    public let version: String
    public let operatorID: String
    public let subjectID: String
    public let mode: HotIdentityMode
    public let hardwareBindingActive: Bool
    public let keyTag: String
    public let keyID: String
    public let algorithm: String
    public let publicKeyBase64: String
    public let publicKeySHA256Hex: String
    public let hardwareFingerprint: HardwareFingerprint
    public let warning: String?
}

public struct HotIdentityCertificate: Codable, Equatable {
    public let version: String
    public let operatorID: String
    public let subjectID: String
    public let createdAtUnix: String
    public let mode: HotIdentityMode
    public let hardwareBindingActive: Bool
    public let hotKeyAlgorithm: String
    public let hotPublicKeyBase64: String
    public let hotPublicKeySHA256Hex: String
    public let hardwareFingerprint: HardwareFingerprint
    public let valuesHash: String
    public let coldRootPublicKeyHex: String
    public let warning: String?
    public let signatureHex: String

    public var canonicalPayload: String {
        canonicalObject([
            "cold_root_public_key": coldRootPublicKeyHex,
            "created_at": createdAtUnix,
            "hardware_binding_active": hardwareBindingActive ? "true" : "false",
            "hardware_fingerprint": hardwareFingerprint.canonicalJSONString,
            "hot_key_algorithm": hotKeyAlgorithm,
            "hot_public_key_base64": hotPublicKeyBase64,
            "hot_public_key_sha256": hotPublicKeySHA256Hex,
            "mode": mode.rawValue,
            "operator_id": operatorID,
            "subject_id": subjectID,
            "v": version,
            "values_hash": valuesHash,
            "warning": warning ?? "",
        ], rawJSONKeys: ["hardware_fingerprint"])
    }
}

public struct CertificateVerification: Codable, Equatable {
    public let ok: Bool
    public let status: String
    public let mode: HotIdentityMode?
    public let hardwareBindingActive: Bool
    public let reason: String?
}

public struct ChallengeSignature: Codable, Equatable {
    public let mode: HotIdentityMode
    public let hardwareBindingActive: Bool
    public let keyID: String
    public let algorithm: String
    public let publicKeyBase64: String
    public let publicKeySHA256Hex: String
    public let signatureBase64: String
    public let warning: String?
}

public final class SecureEnclaveIdentityManager {
    public static let certificateVersion = "jarvis-se-hot-identity-1"
    public static let operatorID = "Robert \"Grizzly\" Hanson, GMRI"
    public static let subjectID = "JARVIS"
    public static let defaultKeyTag = "org.gmri.jarvis.soul-anchor.hot-identity.p256"
    public static let fallbackWarning = "hardware-binding NOT active: Secure Enclave unavailable; using libsodium software fallback"

    private let keyTag: String
    private let auditLogPath: URL
    private let keysRoot: URL
    private let forceSoftwareFallback: Bool

    public init(keyTag: String = SecureEnclaveIdentityManager.defaultKeyTag,
                auditLogPath: URL? = nil,
                keysRoot: URL? = nil,
                forceSoftwareFallback: Bool = false) {
        self.keyTag = keyTag
        let stateRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis", isDirectory: true)
        self.auditLogPath = auditLogPath ?? stateRoot.appendingPathComponent("audit/secure_enclave_identity.jsonl")
        self.keysRoot = keysRoot ?? stateRoot.appendingPathComponent("keys", isDirectory: true)
        self.forceSoftwareFallback = forceSoftwareFallback
    }

    public func descriptor() throws -> HotKeyDescriptor {
        let material = try hotKeyMaterial()
        return material.descriptor
    }

    public func soulAnchorKeyBlobExists() -> Bool {
        FileManager.default.fileExists(atPath: seKeyBlobURL().path)
    }

    public func issueSoulAnchorKey() throws -> P256.Signing.PublicKey {
        if soulAnchorKeyBlobExists() {
            throw SecureEnclaveIdentityError.ceremonyArtifactMissing(
                artifact: "soul_anchor_key_blob",
                path: seKeyBlobURL().path,
                reason: "Soul Anchor key already exists; refusing overwrite"
            )
        }
        let key = try issueCryptoKitSecureEnclaveKey()
        return key.publicKey
    }

    public func removeSoulAnchorKeyBlobForRollback() {
        _ = unlink(seKeyBlobURL().path)
    }

    /// Sign a challenge with the hot identity key (SE P-256 or libsodium fallback).
    ///
    /// **Caller audit — ConsumedChallengeStore discipline (AGENTS.md §2):**
    ///
    /// Known production callers:
    ///   1. `CABI.swift:jarvis_se_sign_challenge` → `beliefstore_persistence.cpp:
    ///      derive_beliefstore_key_from_secure_enclave`.
    ///      Challenge: `"jarvis-beliefstore-sqlcipher-key-v1|<db-path>"` — a DETERMINISTIC
    ///      KDF input, NOT a ceremony-issued replay-protected challenge.  ConsumedChallengeStore
    ///      is intentionally NOT called; applying it here would make the database inaccessible
    ///      after first open.  ⚠️ SURFACE: this caller bypasses ChallengeStore.consume because
    ///      it uses signChallenge as a KDF primitive (sign → hash → SQLCipher key).  An
    ///      architectural split — `signChallengeOnce` (replay-protected) vs
    ///      `deriveKeyViaSigning` (deterministic KDF) — is the correct long-term fix.
    ///
    ///   2. Test callers (`SecureEnclaveIdentityTests.swift:40, 108`, `main.swift:36` smoke):
    ///      not production; replay protection does not apply.
    ///
    /// Adding ConsumedChallengeStore.consume inside this function would break caller (1).
    /// Operator law §4: surface anomaly rather than silently relax.
    public func signChallenge(_ challenge: Data) throws -> ChallengeSignature {
        guard !challenge.isEmpty else { throw SecureEnclaveIdentityError.invalidChallenge }
        do {
            let material = try hotKeyMaterial()
            let signature: Data
            switch material.mode {
            case .secureEnclave:
                guard let ckKey = material.cryptoKitPrivateKey else {
                    throw SecureEnclaveIdentityError.crypto("Secure Enclave private key handle absent")
                }
                do {
                    let sig = try ckKey.signature(for: challenge)
                    signature = sig.derRepresentation
                } catch {
                    throw SecureEnclaveIdentityError.crypto("Secure Enclave (CryptoKit) signing failed: \(error)")
                }
            case .libsodiumFallback:
                guard let seed = material.fallbackPrivateKey else {
                    throw SecureEnclaveIdentityError.crypto("libsodium fallback key missing")
                }
                signature = try sodiumSign(challenge, privateKey: seed.dataView)
            }
            let result = ChallengeSignature(mode: material.mode,
                                            hardwareBindingActive: material.hardwareBindingActive,
                                            keyID: material.keyID,
                                            algorithm: material.signatureAlgorithm,
                                            publicKeyBase64: material.publicKey.base64EncodedString(),
                                            publicKeySHA256Hex: sha256Hex(material.publicKey),
                                            signatureBase64: signature.base64EncodedString(),
                                            warning: material.warning)
            try audit(event: "hot_identity_challenge_signed", outcome: "pass", metadata: [
                "mode": material.mode.rawValue,
                "hardware_binding_active": String(material.hardwareBindingActive),
                "key_id": material.keyID,
                "hot_public_key_sha256": result.publicKeySHA256Hex,
                "challenge_sha256": sha256Hex(challenge),
            ])
            return result
        } catch {
            try audit(event: "hot_identity_challenge_signed", outcome: "fail", metadata: [
                "error": String(describing: error),
                "challenge_sha256": sha256Hex(challenge),
            ])
            throw error
        }
    }

    public func createCertificate(valuesHash: String,
                                  coldRootPublicKey: Data,
                                  coldRootPrivateKey: Data,
                                  createdAtUnix: String? = nil) throws -> HotIdentityCertificate {
        guard coldRootPublicKey.count == 32, coldRootPrivateKey.count == 64 else {
            throw SecureEnclaveIdentityError.invalidRootKey
        }
        let material = try hotKeyMaterial()
        let unsigned = HotIdentityCertificate(version: Self.certificateVersion,
                                              operatorID: Self.operatorID,
                                              subjectID: Self.subjectID,
                                              createdAtUnix: createdAtUnix ?? String(Int(Date().timeIntervalSince1970)),
                                              mode: material.mode,
                                              hardwareBindingActive: material.hardwareBindingActive,
                                              hotKeyAlgorithm: material.keyAlgorithm,
                                              hotPublicKeyBase64: material.publicKey.base64EncodedString(),
                                              hotPublicKeySHA256Hex: sha256Hex(material.publicKey),
                                              hardwareFingerprint: material.hardwareFingerprint,
                                              valuesHash: valuesHash,
                                              coldRootPublicKeyHex: hex(coldRootPublicKey),
                                              warning: material.warning,
                                              signatureHex: "")
        let signature = try sodiumSign(Data(unsigned.canonicalPayload.utf8), privateKey: coldRootPrivateKey)
        let certificate = HotIdentityCertificate(version: unsigned.version,
                                                 operatorID: unsigned.operatorID,
                                                 subjectID: unsigned.subjectID,
                                                 createdAtUnix: unsigned.createdAtUnix,
                                                 mode: unsigned.mode,
                                                 hardwareBindingActive: unsigned.hardwareBindingActive,
                                                 hotKeyAlgorithm: unsigned.hotKeyAlgorithm,
                                                 hotPublicKeyBase64: unsigned.hotPublicKeyBase64,
                                                 hotPublicKeySHA256Hex: unsigned.hotPublicKeySHA256Hex,
                                                 hardwareFingerprint: unsigned.hardwareFingerprint,
                                                 valuesHash: unsigned.valuesHash,
                                                 coldRootPublicKeyHex: unsigned.coldRootPublicKeyHex,
                                                 warning: unsigned.warning,
                                                 signatureHex: hex(signature))
        try audit(event: "hot_identity_certificate_created", outcome: "pass", metadata: [
            "mode": certificate.mode.rawValue,
            "hardware_binding_active": String(certificate.hardwareBindingActive),
            "hot_public_key_sha256": certificate.hotPublicKeySHA256Hex,
            "values_hash": certificate.valuesHash,
        ])
        return certificate
    }

    public static func verifyCertificate(_ certificate: HotIdentityCertificate,
                                         coldRootPublicKey: Data) -> CertificateVerification {
        guard coldRootPublicKey.count == 32 else {
            return CertificateVerification(ok: false, status: "BROKEN", mode: certificate.mode, hardwareBindingActive: certificate.hardwareBindingActive, reason: "invalid cold-root public key length")
        }
        guard certificate.version == certificateVersion,
              certificate.operatorID == operatorID,
              certificate.subjectID == subjectID else {
            return CertificateVerification(ok: false, status: "BROKEN", mode: certificate.mode, hardwareBindingActive: certificate.hardwareBindingActive, reason: "certificate identity fields mismatch")
        }
        guard hex(coldRootPublicKey) == certificate.coldRootPublicKeyHex else {
            return CertificateVerification(ok: false, status: "TAMPERED", mode: certificate.mode, hardwareBindingActive: certificate.hardwareBindingActive, reason: "cold-root public key mismatch")
        }
        guard let hotPublicKey = Data(base64Encoded: certificate.hotPublicKeyBase64),
              constantTimeEqual(sha256Hex(hotPublicKey), certificate.hotPublicKeySHA256Hex),
              constantTimeEqual(certificate.hardwareFingerprint.secureEnclaveKeyID, certificate.hotPublicKeySHA256Hex) else {
            return CertificateVerification(ok: false, status: "TAMPERED", mode: certificate.mode, hardwareBindingActive: certificate.hardwareBindingActive, reason: "hot public key digest mismatch")
        }
        guard let signature = unhex(certificate.signatureHex) else {
            return CertificateVerification(ok: false, status: "BROKEN", mode: certificate.mode, hardwareBindingActive: certificate.hardwareBindingActive, reason: "invalid signature hex")
        }
        let ok = sodiumVerify(signature: signature, message: Data(certificate.canonicalPayload.utf8), publicKey: coldRootPublicKey)
        return CertificateVerification(ok: ok, status: ok ? "OK" : "BROKEN", mode: certificate.mode, hardwareBindingActive: certificate.hardwareBindingActive, reason: ok ? nil : "cold-root signature verification failed")
    }

    private func hotKeyMaterial() throws -> HotKeyMaterial {
        // Operator law #3: cognition organs are never silently bypassed.
        // The Secure Enclave is the hardware-bound root of the operator's hot identity;
        // a transient SE failure must NEVER silently downgrade to software-bound libsodium.
        // The libsodium fallback path is reachable only when the caller has explicitly
        // attested `forceSoftwareFallback == true` (e.g. CI, smoke tests, headless servers
        // with no SE hardware) — never as an implicit consolation prize.
        if forceSoftwareFallback {
            let fallback = try fallbackMaterial()
            try audit(event: "hardware_binding_not_active", outcome: "warn", metadata: [
                "mode": fallback.mode.rawValue,
                "warning": "se_unavailable_forced",
                "reason": "forceSoftwareFallback_true",
                "key": fallback.keyID,
            ])
            fputs("JARVIS Soul Anchor warning: \(Self.fallbackWarning); reason: operator-attested forced fallback\n", stderr)
            return fallback
        }
        return try secureEnclaveMaterial()
    }

    private func secureEnclaveMaterial() throws -> HotKeyMaterial {
        let ckKey = try loadCryptoKitSecureEnclaveKey()
        let publicKeyData = ckKey.publicKey.x963Representation
        let keyID = sha256Hex(publicKeyData)
        let fp = HardwareFingerprint(machineUUID: machineUUID(), secureEnclaveKeyID: keyID)
        return HotKeyMaterial(mode: .secureEnclave,
                              hardwareBindingActive: true,
                              keyTag: keyTag,
                              keyID: keyID,
                              keyAlgorithm: "P-256 Secure Enclave public key (X9.63)",
                              signatureAlgorithm: "ECDSA-P256-SHA256-X9.62",
                              publicKey: publicKeyData,
                              cryptoKitPrivateKey: ckKey,
                              fallbackPrivateKey: nil,
                              hardwareFingerprint: fp,
                              warning: nil)
    }

    private func seKeyBlobURL() -> URL {
        // SE-sealed blob lives under ~/.jarvis/keys/, independent of the audit log location.
        // The on-disk filename is sha256(keyTag) hex — eliminates filename collision between
        // distinct keyTags that would survive a naive `/` → `_` substitution, and refuses any
        // path-traversal payload (e.g. "../../etc/passwd") as a keyTag.
        let nameHash = sha256Hex(Data(keyTag.utf8))
        return keysRoot.appendingPathComponent(nameHash + ".se.blob")
    }

    /// Load the Secure Enclave hot-key blob. Fail-closed: throws .ceremonyArtifactMissing
    /// if the blob does not exist. Silent regeneration of the soul-anchor key violates
    /// operator law §10 (long-term identity artifacts bound to physical context/ceremony).
    private func loadCryptoKitSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveIdentityError.crypto("SecureEnclave.isAvailable returned false on this device")
        }
        let blobURL = seKeyBlobURL()
        let parent = blobURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        guard FileManager.default.fileExists(atPath: blobURL.path) else {
            throw SecureEnclaveIdentityError.ceremonyArtifactMissing(
                artifact: "secure_enclave_hot_key_blob",
                path: "[path:\(sePathFP(blobURL))]",
                reason: "blob absent; path-fp=\(sePathFP(blobURL)) — run ceremony tool 'jarvis-ceremony issue-hot-key'"
            )
        }

        // Real read — never collapse errors to nil. A `try?` here would silently rotate
        // the operator's soul anchor on a transient I/O error (EACCES on the volume,
        // momentarily unmounted disk, etc.), invalidating every prior certificate with
        // no audit signal. If the blob is unreadable for any reason, fail closed.
        let data: Data
        do {
            data = try Data(contentsOf: blobURL)
        } catch {
            throw SecureEnclaveIdentityError.crypto("Secure Enclave key blob unreadable; path-fp=\(sePathFP(blobURL))")
        }
        guard !data.isEmpty else {
            throw SecureEnclaveIdentityError.crypto("Secure Enclave key blob present but empty; path-fp=\(sePathFP(blobURL))")
        }
        let plaintext: Data
        if SecureEnclaveBlobV1.isVersioned(data) {
            do {
                plaintext = try SecureEnclaveBlobV1.open(data, keyTag: keyTag)
            } catch let error as BlobIntegrityError {
                try audit(event: "secure_enclave_hot_key_blob_integrity_failed", outcome: "fail", metadata: [
                    "key_tag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(keyTag),
                    "error": error.description,
                ])
                throw error
            }
        } else {
            plaintext = data
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do {
            key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: plaintext)
        } catch {
            throw SecureEnclaveIdentityError.crypto("Secure Enclave key blob reconstitution failed: \(type(of: error))")
        }
        if !SecureEnclaveBlobV1.isVersioned(data) {
            let migrated = try SecureEnclaveBlobV1.serialize(plaintext: plaintext, keyTag: keyTag)
            try writeBlobAtomically0600(migrated, to: blobURL)
            try audit(event: "se_blob_migrated_to_v1", outcome: "pass", metadata: [
                "key_tag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(keyTag),
                "blob_path_fp": sePathFP(blobURL),
            ])
        }
        try audit(event: "secure_enclave_hot_key_loaded", outcome: "pass", metadata: [
            "key_tag_fp": seKeyTagFP(keyTag),
            "persistence": "cryptokit-blob-v1",
            "blob_path_fp": sePathFP(blobURL),
            "key_tag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(keyTag),
        ])
        return key
    }

    /// Issue a new Soul Anchor key (the SE-resident P-256 identity key that signs runtime challenges).
    /// Generates a fresh P256.Signing.PrivateKey backed by the Secure Enclave,
    /// seals it with XChaCha20-Poly1305-IETF, writes with no-replace 0600+fsync discipline,
    /// and emits a "SOUL_ANCHOR_ISSUED" audit event.
    public func issueCryptoKitSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveIdentityError.crypto("SecureEnclave.isAvailable returned false on this device")
        }
        let blobURL = seKeyBlobURL()
        if FileManager.default.fileExists(atPath: blobURL.path) {
            throw SecureEnclaveIdentityError.crypto("Soul Anchor key blob already exists; path-fp=\(sePathFP(blobURL)); refusing overwrite")
        }
        let parent = blobURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])

        let fresh: SecureEnclave.P256.Signing.PrivateKey
        do {
            fresh = try SecureEnclave.P256.Signing.PrivateKey()
        } catch {
            throw SecureEnclaveIdentityError.crypto("Secure Enclave Soul Anchor key creation failed: \(error)")
        }
        let blob = fresh.dataRepresentation
        let sealedBlob = try SecureEnclaveBlobV1.serialize(plaintext: blob, keyTag: keyTag)
        try writeBlobOnceAtomically0600(sealedBlob, to: blobURL)
        try audit(event: "SOUL_ANCHOR_ISSUED", outcome: "pass", metadata: [
            "key_tag_fp": seKeyTagFP(keyTag),
            "persistence": "cryptokit-blob-v1",
            "blob_path_fp": sePathFP(blobURL),
            "blob_sha256": sha256Hex(sealedBlob),
            "key_tag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(keyTag),
        ])
        return fresh
    }

    private func writeBlobOnceAtomically0600(_ data: Data, to dest: URL) throws {
        let tmp = dest.appendingPathExtension("tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SecureEnclaveIdentityError.crypto("Soul Anchor blob temp open failed: errno=\(errno)") }
        var closed = false
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    guard data.isEmpty else { throw SecureEnclaveIdentityError.crypto("Soul Anchor blob buffer unavailable") }
                    return
                }
                var written = 0
                while written < data.count {
                    let n = write(fd, base.advanced(by: written), data.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw SecureEnclaveIdentityError.crypto("Soul Anchor blob write failed: errno=\(errno)")
                    }
                    written += n
                }
            }
            if fsync(fd) != 0 { throw SecureEnclaveIdentityError.crypto("Soul Anchor blob fsync failed: errno=\(errno)") }
            if close(fd) != 0 { throw SecureEnclaveIdentityError.crypto("Soul Anchor blob close failed: errno=\(errno)") }
            closed = true
            if link(tmp.path, dest.path) != 0 {
                let e = errno
                if e == EEXIST { throw SecureEnclaveIdentityError.crypto("Soul Anchor key blob already exists; path-fp=\(sePathFP(dest)); refusing overwrite") }
                throw SecureEnclaveIdentityError.crypto("Soul Anchor blob no-replace link failed: errno=\(e)")
            }
            if unlink(tmp.path) != 0 { throw SecureEnclaveIdentityError.crypto("Soul Anchor blob temp unlink failed: errno=\(errno)") }
        } catch {
            if !closed { close(fd) }
            _ = unlink(tmp.path)
            throw error
        }
    }

    /// Writes `data` to `dest` so that:
    ///   * The file never exists on disk at any moment with permissions wider than 0600.
    ///   * Either the full new content lands or the prior file (if any) remains untouched.
    ///   * No staging file persists on failure.
    /// Uses POSIX `open(O_WRONLY|O_CREAT|O_EXCL, 0o600)` for the temp, an explicit `fsync`
    /// before `rename(2)`, and falls back to `unlink` on every failure path.
    private func writeBlobAtomically0600(_ data: Data, to dest: URL) throws {
        let tmp = dest.appendingPathExtension("tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw SecureEnclaveIdentityError.crypto("open(tmp blob, O_CREAT|O_EXCL, 0600) failed: errno=\(errno)")
        }
        let writeOK = data.withUnsafeBytes { raw -> Bool in
            guard var ptr = raw.baseAddress else { return data.isEmpty }
            var remaining = data.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
            return true
        }
        if !writeOK {
            let werr = errno
            _ = close(fd)
            _ = unlink(tmp.path)
            throw SecureEnclaveIdentityError.crypto("write(SE blob) failed: errno=\(werr)")
        }
        if fsync(fd) != 0 {
            let ferr = errno
            _ = close(fd)
            _ = unlink(tmp.path)
            throw SecureEnclaveIdentityError.crypto("fsync(SE blob) failed: errno=\(ferr)")
        }
        _ = close(fd)
        if rename(tmp.path, dest.path) != 0 {
            let rerr = errno
            _ = unlink(tmp.path)
            throw SecureEnclaveIdentityError.crypto("rename(SE blob) failed: errno=\(rerr)")
        }
    }

    private func fallbackMaterial() throws -> HotKeyMaterial {
        var pair = try loadFallbackKeypair()
        // §8 / Deliverable 5: zero the private-key Data on the stack before returning.
        // LockedSeed copies the bytes into mlock'd memory; after that the plain Data
        // allocation is dead weight.  sodium_memzero via withUnsafeMutableBytes runs
        // in the defer, which fires before the return value is handed to the caller
        // — no copy of the raw seed escapes into ARC-managed heap after this point.
        defer {
            pair.privateKey.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress, buf.count > 0 else { return }
                sodium_memzero(base, buf.count)
            }
        }
        let keyID = sha256Hex(pair.publicKey)
        let fp = HardwareFingerprint(machineUUID: machineUUID(), secureEnclaveKeyID: keyID)
        return HotKeyMaterial(mode: .libsodiumFallback,
                              hardwareBindingActive: false,
                              keyTag: keyTag,
                              keyID: keyID,
                              keyAlgorithm: "Ed25519 libsodium software fallback",
                              signatureAlgorithm: "Ed25519-libsodium",
                              publicKey: pair.publicKey,
                              cryptoKitPrivateKey: nil,
                              fallbackPrivateKey: LockedSeed(pair.privateKey),
                              hardwareFingerprint: fp,
                              warning: Self.fallbackWarning)
    }

    /// Load the libsodium fallback keypair from Keychain. Fail-closed: throws
    /// .ceremonyArtifactMissing if the Keychain item is absent. Silent regeneration
    /// of the fallback key violates operator law §10.
    private func loadFallbackKeypair() throws -> (publicKey: Data, privateKey: Data) {
        try ensureSodium()
        let service = "org.gmri.jarvis.secure-enclave-fallback"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 96 {
            return (Data(data.prefix(32)), Data(data.suffix(64)))
        }
        guard status == errSecItemNotFound else {
            throw SecureEnclaveIdentityError.keychain(status, "load libsodium fallback key")
        }
        throw SecureEnclaveIdentityError.ceremonyArtifactMissing(
            artifact: "fallback_keypair",
            path: "Keychain[\(service)/\(keyTag)]",
            reason: "Keychain item missing — run ceremony tool 'jarvis-ceremony issue-fallback'"
        )
    }

    /// Issue a new libsodium fallback keypair. One-shot ceremony operation.
    /// Generates a fresh Ed25519 keypair, stores it in the Keychain with
    /// kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
    public func issueFallbackKeypair() throws -> (publicKey: Data, privateKey: Data) {
        try ensureSodium()
        let service = "org.gmri.jarvis.secure-enclave-fallback"
        var publicKey = Data(count: 32)
        var privateKey = Data(count: 64)
        let keypairRC = publicKey.withUnsafeMutableBytes { pubRaw in
            privateKey.withUnsafeMutableBytes { privRaw in
                guard let pubPtr = pubRaw.bindMemory(to: UInt8.self).baseAddress,
                      let privPtr = privRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                return crypto_sign_keypair(pubPtr, privPtr)
            }
        }
        guard keypairRC == 0 else { throw SecureEnclaveIdentityError.crypto("libsodium fallback keypair generation failed") }
        var combined = Data()
        combined.append(publicKey)
        combined.append(privateKey)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyTag,
            kSecValueData as String: combined,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureEnclaveIdentityError.keychain(addStatus, "store libsodium fallback key")
        }
        return (publicKey, privateKey)
    }

    private func audit(event: String, outcome: String, metadata: [String: String]) throws {
        try SecureEnclaveAuditChain(logURL: auditLogPath).append(event: event, outcome: outcome, metadata: metadata)
    }

    /// Issue the audit seal master blob backing the SE-anchored audit-chain HMAC key.
    /// One-shot ceremony operation; thin bridge into the private SecureEnclaveAuditChain.
    /// Callers (ceremony tooling, smoke, tests) invoke this once before any append()
    /// so that subsequent audit events can derive the HMAC key from the sealed material.
    @discardableResult
    public func issueAuditSealMasterBlob() throws -> Bool {
        _ = try SecureEnclaveAuditChain(logURL: auditLogPath).issueAuditSealMasterBlob()
        return true
    }
}

public struct SecureEnclaveAuditAnchor: Equatable {
    public let startSequenceID: UInt64
    public let startPrevHash: String
    public let keyFingerprint: String

    public init(startSequenceID: UInt64, startPrevHash: String, keyFingerprint: String) {
        self.startSequenceID = startSequenceID
        self.startPrevHash = startPrevHash
        self.keyFingerprint = keyFingerprint
    }
}

public struct SecureEnclaveAuditVerification: Equatable {
    public let ok: Bool
    public let verifiedLines: Int
    public let failure: String?
}

public final class SecureEnclaveAuditVerifier {
    private let chain: SecureEnclaveAuditChain

    public init(logURL: URL) {
        self.chain = SecureEnclaveAuditChain(logURL: logURL)
    }

    public func verify(anchor: SecureEnclaveAuditAnchor) throws -> SecureEnclaveAuditVerification {
        try chain.verify(anchor: anchor)
    }

    public func genesisAnchor() throws -> SecureEnclaveAuditAnchor {
        try chain.anchor()
    }
}

private final class SecureEnclaveAuditChain {
    private static let pipeBufCap = 512
    private static let genesisPrevHash = String(repeating: "0", count: 64)
    private let logURL: URL

    init(logURL: URL) { self.logURL = logURL }

    func append(event: String, outcome: String, metadata: [String: String]) throws {
        // PIPE_BUF on macOS is 512 bytes (per getconf PIPE_BUF). O_APPEND atomic only for writes ≤ PIPE_BUF.
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key = try deriveAuditKey()
        let fd = open(logURL.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit open failed at \(logURL.path): errno=\(errno)") }
        defer { _ = close(fd) }
        try verifyOpenedAuditFile(fd: fd)
        guard flock(fd, LOCK_EX) == 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit flock failed: errno=\(errno)") }
        defer { _ = flock(fd, LOCK_UN) }
        let state = try tailState(fd: fd, key: key)
        var fields = metadata
        fields["event"] = event
        fields["outcome"] = outcome
        fields["operator_id"] = SecureEnclaveIdentityManager.operatorID
        fields["subject_id"] = SecureEnclaveIdentityManager.subjectID
        let ts = String(Int(Date().timeIntervalSince1970))
        fields["created_at"] = ts
        var json = canonicalObject(fields)
        let seq = state.nextSequence
        let prev = state.prevHash
        var own = Self.hmacHex(key: key, sequence: seq, prevHash: prev, unixTS: ts, eventJSON: json)
        var line = "\(seq)|\(prev)|\(own)|\(ts)|\(json)\n"
        if line.utf8.count > Self.pipeBufCap {
            let compactFields = [
                "event": event,
                "outcome": outcome,
                "created_at": ts,
                "operator_id_sha256": sha256Hex(Data(SecureEnclaveIdentityManager.operatorID.utf8)),
                "subject_id": SecureEnclaveIdentityManager.subjectID,
                "metadata_sha256": sha256Hex(Data(canonicalObject(metadata).utf8)),
            ]
            json = canonicalObject(compactFields)
            own = Self.hmacHex(key: key, sequence: seq, prevHash: prev, unixTS: ts, eventJSON: json)
            line = "\(seq)|\(prev)|\(own)|\(ts)|\(json)\n"
        }
        let bytes = Array(line.utf8)
        guard bytes.count <= Self.pipeBufCap else { throw SecureEnclaveIdentityError.auditEventTooLarge(bytes.count) }
        try writeAll(fd: fd, bytes: bytes)
        guard fsync(fd) == 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit fsync failed: errno=\(errno)") }
    }

    func verify(anchor: SecureEnclaveAuditAnchor) throws -> SecureEnclaveAuditVerification {
        let key = try deriveAuditKey()
        let fingerprint = sha256Hex(key)
        guard fingerprint == anchor.keyFingerprint else {
            return SecureEnclaveAuditVerification(ok: false, verifiedLines: 0, failure: "key fingerprint mismatch")
        }
        let fd = open(logURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit verifier open failed: errno=\(errno)") }
        defer { _ = close(fd) }
        guard flock(fd, LOCK_SH) == 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit verifier flock failed: errno=\(errno)") }
        defer { _ = flock(fd, LOCK_UN) }
        let data = try readAll(fd: fd)
        guard data.isEmpty || data.last == 0x0a else {
            return SecureEnclaveAuditVerification(ok: false, verifiedLines: 0, failure: "truncated final line")
        }
        let text = String(decoding: data, as: UTF8.self)
        var expectedSeq = anchor.startSequenceID
        var expectedPrev = anchor.startPrevHash
        var verified = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) where !rawLine.isEmpty {
            let line = String(rawLine)
            let parts = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, let seq = UInt64(parts[0]) else {
                return SecureEnclaveAuditVerification(ok: false, verifiedLines: verified, failure: "malformed line \(verified + 1)")
            }
            guard seq == expectedSeq else { return SecureEnclaveAuditVerification(ok: false, verifiedLines: verified, failure: "sequence mismatch at \(seq)") }
            guard parts[1] == expectedPrev else { return SecureEnclaveAuditVerification(ok: false, verifiedLines: verified, failure: "prev_hash mismatch at \(seq)") }
            let computed = Self.hmacHex(key: key, sequence: seq, prevHash: parts[1], unixTS: parts[3], eventJSON: parts[4])
            guard constantTimeEqual(computed, parts[2]) else { return SecureEnclaveAuditVerification(ok: false, verifiedLines: verified, failure: "own_hash mismatch at \(seq)") }
            verified += 1
            expectedSeq = seq + 1
            expectedPrev = parts[2]
        }
        return SecureEnclaveAuditVerification(ok: true, verifiedLines: verified, failure: nil)
    }

    func anchor() throws -> SecureEnclaveAuditAnchor {
        let key = try deriveAuditKey()
        return SecureEnclaveAuditAnchor(startSequenceID: 0, startPrevHash: Self.genesisPrevHash, keyFingerprint: sha256Hex(key))
    }

    /// Load the Secure Enclave audit seal master blob. Fail-closed: throws
    /// .ceremonyArtifactMissing if the blob does not exist. Silent regeneration
    /// of the audit HMAC master violates operator law §10.
    private func loadAuditSealMasterBlob() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveIdentityError.crypto("SecureEnclave.isAvailable returned false for audit seal master load")
        }
        let blobURL = logURL.deletingLastPathComponent().appendingPathComponent("seal_master.se.blob")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.fileExists(atPath: blobURL.path) else {
            throw SecureEnclaveIdentityError.ceremonyArtifactMissing(
                artifact: "audit_seal_master_blob",
                path: blobURL.path,
                reason: "blob absent at \(blobURL.path) — run ceremony tool 'jarvis-ceremony issue-audit-seal'"
            )
        }
        let blob = try Data(contentsOf: blobURL)
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
    }

    /// Issue a new Secure Enclave audit seal master blob. One-shot ceremony operation.
    /// Generates a fresh P256.KeyAgreement.PrivateKey backed by the Secure Enclave,
    /// writes it atomically with O_EXCL+0600+fsync.
    internal func issueAuditSealMasterBlob() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveIdentityError.crypto("SecureEnclave.isAvailable returned false for audit seal master issue")
        }
        let blobURL = logURL.deletingLastPathComponent().appendingPathComponent("seal_master.se.blob")
        try FileManager.default.createDirectory(at: blobURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        try writeBlobAtomically0600(privateKey.dataRepresentation, to: blobURL, context: "audit seal master blob")
        return privateKey
    }

    private func deriveAuditKey() throws -> Data {
        let privateKey = try loadAuditSealMasterBlob()
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                       salt: Data("JARVIS-AuditHMAC-v1".utf8),
                                                       sharedInfo: Data(HKDFDomain.auditHmacKey.rawValue.utf8),
                                                       outputByteCount: 32)
        var data = Data()
        symmetric.withUnsafeBytes { raw in data.append(contentsOf: raw) }
        guard data.count == 32 else { throw SecureEnclaveIdentityError.crypto("audit HMAC derivation returned \(data.count) bytes") }
        return data
    }

    private func tailState(fd: Int32, key: Data) throws -> (nextSequence: UInt64, prevHash: String) {
        let data = try readAll(fd: fd)
        guard data.isEmpty || data.last == 0x0a else { throw SecureEnclaveIdentityError.auditChainBroken("truncated final line") }
        let text = String(decoding: data, as: UTF8.self)
        var expectedSeq: UInt64 = 0
        var expectedPrev = Self.genesisPrevHash
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) where !rawLine.isEmpty {
            let parts = String(rawLine).split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5, let seq = UInt64(parts[0]) else { throw SecureEnclaveIdentityError.auditChainBroken("malformed line before append") }
            guard seq == expectedSeq, parts[1] == expectedPrev else { throw SecureEnclaveIdentityError.auditChainBroken("sequence or prev_hash mismatch before append") }
            let computed = Self.hmacHex(key: key, sequence: seq, prevHash: parts[1], unixTS: parts[3], eventJSON: parts[4])
            guard constantTimeEqual(computed, parts[2]) else { throw SecureEnclaveIdentityError.auditChainBroken("own_hash mismatch before append at \(seq)") }
            expectedSeq = seq + 1
            expectedPrev = parts[2]
        }
        return (expectedSeq, expectedPrev)
    }

    private func writeBlobAtomically0600(_ data: Data, to dest: URL, context: String) throws {
        let tmp = dest.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SecureEnclaveIdentityError.crypto("\(context) open failed: errno=\(errno)") }
        do {
            try data.withUnsafeBytes { raw in
                guard var ptr = raw.baseAddress else { return }
                var remaining = data.count
                while remaining > 0 {
                    let n = write(fd, ptr, remaining)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw SecureEnclaveIdentityError.crypto("\(context) write failed: errno=\(errno)")
                    }
                    ptr = ptr.advanced(by: n)
                    remaining -= n
                }
            }
            guard fsync(fd) == 0 else { throw SecureEnclaveIdentityError.crypto("\(context) fsync failed: errno=\(errno)") }
            guard close(fd) == 0 else { throw SecureEnclaveIdentityError.crypto("\(context) close failed: errno=\(errno)") }
            guard rename(tmp.path, dest.path) == 0 else { throw SecureEnclaveIdentityError.crypto("\(context) rename failed: errno=\(errno)") }
        } catch {
            _ = close(fd)
            _ = unlink(tmp.path)
            throw error
        }
    }

    private func verifyOpenedAuditFile(fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit fstat failed: errno=\(errno)") }
        guard st.st_uid == geteuid() else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit owner mismatch") }
        guard (st.st_mode & 0o077) == 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit permissions wider than 0600") }
    }

    private func readAll(fd: Int32) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw SecureEnclaveIdentityError.crypto("Secure Enclave audit seek failed: errno=\(errno)") }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SecureEnclaveIdentityError.crypto("Secure Enclave audit read failed: errno=\(errno)")
            }
            if n == 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }

    private func writeAll(fd: Int32, bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer { buf in
            guard var ptr = buf.baseAddress.map({ UnsafeRawPointer($0) }) else { return }
            var remaining = buf.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SecureEnclaveIdentityError.crypto("Secure Enclave audit write failed: errno=\(errno)")
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }

    private static func hmacHex(key: Data, sequence: UInt64, prevHash: String, unixTS: String, eventJSON: String) -> String {
        let payload = "\(sequence)|\(prevHash)|\(unixTS)|\(eventJSON)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
/// Pinned heap buffer for libsodium-fallback Ed25519 private-key material.
/// The bytes are mlock'd to prevent paging to swap, and sodium_memzero'd before
/// being released, so the seed never leaks into freed-but-unzeroed heap or a
/// coredump for the lifetime of the process.
private final class LockedSeed {
    private let ptr: UnsafeMutablePointer<UInt8>
    let count: Int

    init(_ data: Data) {
        let n = data.count
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        data.withUnsafeBytes { src in
            if let base = src.bindMemory(to: UInt8.self).baseAddress {
                p.update(from: base, count: n)
            }
        }
        _ = mlock(p, n)
        self.ptr = p
        self.count = n
    }

    /// View the locked bytes as a non-owning Data for cryptographic use.
    /// Caller must not retain the Data beyond a single use; LockedSeed owns the storage.
    var dataView: Data {
        Data(bytesNoCopy: ptr, count: count, deallocator: .none)
    }

    deinit {
        sodium_memzero(ptr, count)
        _ = munlock(ptr, count)
        ptr.deallocate()
    }
}

private struct HotKeyMaterial {
    let mode: HotIdentityMode
    let hardwareBindingActive: Bool
    let keyTag: String
    let keyID: String
    let keyAlgorithm: String
    let signatureAlgorithm: String
    let publicKey: Data
    let cryptoKitPrivateKey: SecureEnclave.P256.Signing.PrivateKey?
    let fallbackPrivateKey: LockedSeed?
    let hardwareFingerprint: HardwareFingerprint
    let warning: String?

    var descriptor: HotKeyDescriptor {
        HotKeyDescriptor(version: SecureEnclaveIdentityManager.certificateVersion,
                         operatorID: SecureEnclaveIdentityManager.operatorID,
                         subjectID: SecureEnclaveIdentityManager.subjectID,
                         mode: mode,
                         hardwareBindingActive: hardwareBindingActive,
                         keyTag: keyTag,
                         keyID: keyID,
                         algorithm: keyAlgorithm,
                         publicKeyBase64: publicKey.base64EncodedString(),
                         publicKeySHA256Hex: sha256Hex(publicKey),
                         hardwareFingerprint: hardwareFingerprint,
                         warning: warning)
    }
}

private func ensureSodium() throws {
    if sodium_init() < 0 { throw SecureEnclaveIdentityError.libsodiumUnavailable }
}

private func sodiumSign(_ message: Data, privateKey: Data) throws -> Data {
    try ensureSodium()
    guard privateKey.count == 64 else { throw SecureEnclaveIdentityError.invalidRootKey }
    var signature = Data(count: 64)
    var sigLen: UInt64 = 0
    let rc = signature.withUnsafeMutableBytes { sigRaw in
        message.withUnsafeBytes { msgRaw in
            privateKey.withUnsafeBytes { keyRaw in
                guard let sigPtr = sigRaw.bindMemory(to: UInt8.self).baseAddress,
                      let msgPtr = msgRaw.bindMemory(to: UInt8.self).baseAddress,
                      let keyPtr = keyRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                return crypto_sign_detached(sigPtr,
                                            &sigLen,
                                            msgPtr,
                                            UInt64(message.count),
                                            keyPtr)
            }
        }
    }
    guard rc == 0, sigLen == 64 else { throw SecureEnclaveIdentityError.crypto("libsodium detached signature failed") }
    return signature
}

private func sodiumVerify(signature: Data, message: Data, publicKey: Data) -> Bool {
    guard publicKey.count == 32, signature.count == 64, sodium_init() >= 0 else { return false }
    let rc = signature.withUnsafeBytes { sigRaw in
        message.withUnsafeBytes { msgRaw in
            publicKey.withUnsafeBytes { pubRaw in
                guard let sigPtr = sigRaw.bindMemory(to: UInt8.self).baseAddress,
                      let msgPtr = msgRaw.bindMemory(to: UInt8.self).baseAddress,
                      let pubPtr = pubRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
                return crypto_sign_verify_detached(sigPtr,
                                                   msgPtr,
                                                   UInt64(message.count),
                                                   pubPtr)
            }
        }
    }
    return rc == 0
}

public func generateColdRootForTestsOnly() throws -> (publicKey: Data, privateKey: Data) {
    try ensureSodium()
    var publicKey = Data(count: 32)
    var privateKey = Data(count: 64)
    let rc = publicKey.withUnsafeMutableBytes { pubRaw in
        privateKey.withUnsafeMutableBytes { privRaw in
            guard let pubPtr = pubRaw.bindMemory(to: UInt8.self).baseAddress,
                  let privPtr = privRaw.bindMemory(to: UInt8.self).baseAddress else { return Int32(-1) }
            return crypto_sign_keypair(pubPtr, privPtr)
        }
    }
    guard rc == 0 else { throw SecureEnclaveIdentityError.crypto("libsodium keypair generation failed") }
    return (publicKey, privateKey)
}

public func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

public func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Constant-time string comparison via UTF-8 byte XOR.
/// XORs all byte pairs into an accumulator and branches only on the final result.
/// Length mismatch returns false without revealing which side is longer; equal-length
/// strings with different content take the same time regardless of where they first
/// differ.  Use for HMAC hex, own_hash, and digest hex comparisons.
func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var delta: UInt8 = 0
    for (x, y) in zip(a, b) { delta |= x ^ y }
    return delta == 0
}

public func unhex(_ value: String) -> Data? {
    guard value.count % 2 == 0 else { return nil }
    var output = Data()
    output.reserveCapacity(value.count / 2)
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
        output.append(byte)
        index = next
    }
    return output
}

private func machineUUID() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    if service != 0 {
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
           !uuid.isEmpty {
            return uuid.lowercased()
        }
    }
    var hostnameBuffer = [CChar](repeating: 0, count: 256)
    if gethostname(&hostnameBuffer, hostnameBuffer.count - 1) == 0 {
        let hostname = hostnameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return "hostname-sha256:" + sha256Hex(Data(hostname))
    }
    return "unknown-machine"
}

private func canonicalObject(_ fields: [String: String], rawJSONKeys: Set<String> = []) -> String {
    let body = fields.keys.sorted().map { key -> String in
        let value = fields[key] ?? ""
        if rawJSONKeys.contains(key) {
            return "\"\(jsonEscape(key))\":\(value)"
        }
        return "\"\(jsonEscape(key))\":\"\(jsonEscape(value))\""
    }.joined(separator: ",")
    return "{" + body + "}"
}

private func jsonEscape(_ value: String) -> String {
    var out = ""
    out.reserveCapacity(value.count + 8)
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5c: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0c: out += "\\f"
        case 0x0a: out += "\\n"
        case 0x0d: out += "\\r"
        case 0x09: out += "\\t"
        case 0x00...0x1f: out += String(format: "\\u%04x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

public func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
}

public func decodeJSON<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
    guard let data = string.data(using: .utf8) else { throw SecureEnclaveIdentityError.decode("input is not UTF-8") }
    return try JSONDecoder().decode(type, from: data)
}
