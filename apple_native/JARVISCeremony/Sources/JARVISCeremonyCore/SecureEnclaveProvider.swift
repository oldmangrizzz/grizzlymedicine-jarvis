import CryptoKit
import Foundation
import IOKit
import JARVISSecureEnclave
import Security

public protocol SecureEnclaveProviding {
    func descriptor() throws -> SecureEnclaveDescriptor
    func assertSoulAnchorAbsent() throws
    func issueSoulAnchorKey() throws -> Data
    /// Remove the issued Soul Anchor key as part of a rollback.
    /// Returns true if the key is confirmed absent after the call, false if it
    /// could not be removed. Callers MUST surface false to the operator — a
    /// Soul Anchor key left behind after a failed ceremony is a critical state.
    @discardableResult
    func removeIssuedSoulAnchorKeyForRollback() -> Bool
    func sealForLocalBackup(_ data: Data) throws -> Data
    func unsealForLocalBackup(_ sealedData: Data) throws -> Data
}

public final class RealSecureEnclaveProvider: SecureEnclaveProviding {
    private let manager: SecureEnclaveIdentityManager
    private let sealTag = "org.gmri.jarvis.soul-anchor.local-seal.p256"
    private let sealBlobURL: URL
    private let audit: AuditLogger
    public init(auditLogPath: URL) {
        manager = SecureEnclaveIdentityManager(auditLogPath: auditLogPath, forceSoftwareFallback: false)
        let stateRoot = auditLogPath.deletingLastPathComponent().deletingLastPathComponent()
        self.sealBlobURL = stateRoot.appendingPathComponent("\(sealTag).se.blob")
        self.audit = AuditLogger(logURL: auditLogPath, policy: PathPolicy(homeJarvis: stateRoot))
    }

    public func descriptor() throws -> SecureEnclaveDescriptor {
        let d = try manager.descriptor()
        guard d.mode == .secureEnclave, d.hardwareBindingActive, d.warning == nil else {
            throw CeremonyError.secureEnclaveUnavailable(d.warning ?? "Secure Enclave module entered \(d.mode.rawValue)")
        }
        return SecureEnclaveDescriptor(mode: d.mode.rawValue,
                                       hardwareBindingActive: d.hardwareBindingActive,
                                       keyID: d.keyID,
                                       publicKeyBase64: d.publicKeyBase64,
                                       publicKeySHA256Hex: d.publicKeySHA256Hex,
                                       machineUUID: d.hardwareFingerprint.machineUUID)
    }

    public func assertSoulAnchorAbsent() throws {
        if manager.soulAnchorKeyBlobExists() {
            throw CeremonyError.aborted(CeremonyAbortedError(.soulAnchorAlreadyPresent))
        }
    }

    public func issueSoulAnchorKey() throws -> Data {
        try manager.issueSoulAnchorKey().x963Representation
    }

    @discardableResult
    public func removeIssuedSoulAnchorKeyForRollback() -> Bool {
        manager.removeSoulAnchorKeyBlobForRollback()
        let succeeded = !manager.soulAnchorKeyBlobExists()
        do {
            try audit.record("soul_anchor_key_rollback",
                             outcome: succeeded ? "pass" : "fail",
                             metadata: ["result": succeeded ? "key_absent" : "key_still_present"])
        } catch {
            fputs("JARVIS soul anchor rollback audit failed: \(error)\n", stderr)
        }
        return succeeded
    }

    public func sealForLocalBackup(_ data: Data) throws -> Data {
        guard SecureEnclave.isAvailable else {
            throw CeremonyError.secureEnclaveUnavailable("SecureEnclave.isAvailable returned false")
        }
        let recipient = try loadOrCreateSealKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared: SharedSecret
        do {
            shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient.publicKey)
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("ECDH for seal failed: \(error)")
        }
        let aesKey = sealKey(from: shared)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(data, using: aesKey)
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("AES-GCM seal failed: \(error)")
        }
        let ephemeralPubX963 = ephemeral.publicKey.x963Representation
        var out = Data()
        out.append(0x01)
        out.append(UInt8(ephemeralPubX963.count))
        out.append(ephemeralPubX963)
        guard let combined = sealed.combined else {
            throw CeremonyError.secureEnclaveUnavailable("AES-GCM combined representation unavailable")
        }
        out.append(combined)
        return out
    }

    public func unsealForLocalBackup(_ sealedData: Data) throws -> Data {
        guard SecureEnclave.isAvailable else {
            throw CeremonyError.secureEnclaveUnavailable("SecureEnclave.isAvailable returned false")
        }
        guard sealedData.count > 2, sealedData[0] == 0x01 else {
            throw CeremonyError.secureEnclaveUnavailable("local backup seal container has an unsupported version")
        }
        let pubLen = Int(sealedData[1])
        guard pubLen > 0, sealedData.count > 2 + pubLen else {
            throw CeremonyError.secureEnclaveUnavailable("local backup seal container is truncated")
        }
        let publicKeyData = sealedData.subdata(in: 2..<(2 + pubLen))
        let combined = sealedData.subdata(in: (2 + pubLen)..<sealedData.count)
        let recipient = try loadSealKey()
        let ephemeralPublicKey: P256.KeyAgreement.PublicKey
        do {
            ephemeralPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKeyData)
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("local backup ephemeral public key rejected: \(error)")
        }
        let shared: SharedSecret
        do {
            shared = try recipient.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("ECDH for unseal failed: \(error)")
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: sealKey(from: shared))
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("AES-GCM unseal failed: \(error)")
        }
    }

    private func sealKey(from shared: SharedSecret) -> SymmetricKey {
        let salt = Data("jarvis.soul-anchor.local-seal.v1".utf8)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(HKDFDomain.localSeal.rawValue.utf8), outputByteCount: 32)
    }

    private func loadSealKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard FileManager.default.fileExists(atPath: sealBlobURL.path) else {
            throw CeremonyError.secureEnclaveUnavailable("local backup seal key blob is missing")
        }
        let data = try readExistingSealBlob(context: "loadSealKey")
        guard !data.isEmpty else { throw CeremonyError.secureEnclaveUnavailable("local backup seal key blob is empty") }
        let plaintext = try parseSealBlob(data)
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: plaintext)
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("seal key blob reconstitution failed: \(error)")
        }
        if !SecureEnclaveBlobV1.isVersioned(data) {
            let migrated = try SecureEnclaveBlobV1.serialize(plaintext: plaintext, keyTag: sealTag)
            try writeBlobAtomically0600(migrated, to: sealBlobURL, errorContext: "seal blob migration")
            try audit.record("se_blob_migrated_to_v1", outcome: "pass", metadata: ["keytag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(sealTag)])
        }
        return key
    }

    private func loadOrCreateSealKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if FileManager.default.fileExists(atPath: sealBlobURL.path) {
            let data = try readExistingSealBlob(context: "loadOrCreateSealKey")
            guard !data.isEmpty else { throw CeremonyError.secureEnclaveUnavailable("seal key blob exists but is empty; refusing silent rekey") }
            let plaintext = try parseSealBlob(data)
            let key: SecureEnclave.P256.KeyAgreement.PrivateKey
            do {
                key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: plaintext)
            } catch {
                throw CeremonyError.secureEnclaveUnavailable("seal key blob reconstitution failed: \(error)")
            }
            if !SecureEnclaveBlobV1.isVersioned(data) {
                let migrated = try SecureEnclaveBlobV1.serialize(plaintext: plaintext, keyTag: sealTag)
                try writeBlobAtomically0600(migrated, to: sealBlobURL, errorContext: "seal blob migration")
                try audit.record("se_blob_migrated_to_v1", outcome: "pass", metadata: ["keytag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(sealTag)])
            }
            return key
        }
        let fresh: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            fresh = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        } catch {
            throw CeremonyError.secureEnclaveUnavailable("seal key creation failed: \(error)")
        }
        try FileManager.default.createDirectory(at: sealBlobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Fail-closed counterpart to the already-fixed SE module anti-pattern at
        // apple_native/JARVISMacCockpit/SecureEnclave/Sources/JARVISSecureEnclave/SecureEnclaveIdentity.swift:321-323:
        // never use `try? Data(contentsOf:)` for existing SE blobs, because transient I/O
        // failure must not be misread as absence and must never silently rekey JARVIS.
        let sealed = try SecureEnclaveBlobV1.serialize(plaintext: fresh.dataRepresentation, keyTag: sealTag)
        try writeBlobAtomically0600(sealed, to: sealBlobURL, errorContext: "seal blob")
        return fresh
    }

    private func parseSealBlob(_ data: Data) throws -> Data {
        if SecureEnclaveBlobV1.isVersioned(data) {
            do {
                return try SecureEnclaveBlobV1.open(data, keyTag: sealTag)
            } catch let error as BlobIntegrityError {
                try audit.record("secure_enclave_seal_blob_integrity_failed", outcome: "fail", metadata: [
                    "keytag_sha256": SecureEnclaveBlobV1.keytagSHA256Hex(sealTag),
                    "error": error.description,
                ])
                throw error
            }
        }
        return data
    }

    private func readExistingSealBlob(context: String) throws -> Data {
        do {
            return try Data(contentsOf: sealBlobURL)
        } catch {
            let message = "seal blob read failed during \(context): \(error)"
            do {
                try audit.record("secure_enclave_seal_blob_read_failed", outcome: "fail", metadata: ["context": context])
            } catch {
                throw CeremonyError.secureEnclaveUnavailable("\(message); audit record failed: \(error)")
            }
            throw CeremonyError.secureEnclaveUnavailable(message)
        }
    }
}
