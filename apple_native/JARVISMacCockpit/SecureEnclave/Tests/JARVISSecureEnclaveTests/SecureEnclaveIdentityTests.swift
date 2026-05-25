import Foundation
import Security
import XCTest
@testable import JARVISSecureEnclave

final class SecureEnclaveIdentityTests: XCTestCase {
    private func artifactURL(_ name: String) throws -> URL {
        let env = ProcessInfo.processInfo.environment["JARVIS_TEST_DATA_ROOT"]
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? packageRoot.appendingPathComponent(".build/test_artifacts", isDirectory: true)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func uniqueTag(_ suffix: String) -> String {
        "org.gmri.jarvis.tests.secure-enclave.\(suffix).\(UUID().uuidString)"
    }

    func testSecureEnclaveKeyCreationAndSigning() throws {
        let dir = try artifactURL("se_key_creation")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("hardware"), auditLogPath: dir.appendingPathComponent("audit.jsonl"))
        _ = try manager.issueAuditSealMasterBlob()
        _ = try manager.issueCryptoKitSecureEnclaveKey()
        let descriptor = try manager.descriptor()
        XCTAssertEqual(descriptor.mode, .secureEnclave)
        XCTAssertTrue(descriptor.hardwareBindingActive)
        XCTAssertNil(descriptor.warning)
        XCTAssertEqual(descriptor.publicKeySHA256Hex, sha256Hex(Data(base64Encoded: descriptor.publicKeyBase64)!))

        let challenge = Data("jarvis-secure-enclave-challenge".utf8)
        let signed = try manager.signChallenge(challenge)
        XCTAssertEqual(signed.mode, .secureEnclave)
        XCTAssertTrue(signed.hardwareBindingActive)
        XCTAssertEqual(signed.publicKeySHA256Hex, descriptor.publicKeySHA256Hex)
        XCTAssertTrue(try verifyP256Signature(signatureBase64: signed.signatureBase64,
                                             publicKeyBase64: signed.publicKeyBase64,
                                             message: challenge))
    }

    func testCertificateGenerationAndVerification() throws {
        let dir = try artifactURL("certificate")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("certificate"), auditLogPath: dir.appendingPathComponent("audit.jsonl"))
        _ = try manager.issueAuditSealMasterBlob()
        _ = try manager.issueCryptoKitSecureEnclaveKey()
        let root = try generateColdRootForTestsOnly()
        let certificate = try manager.createCertificate(valuesHash: String(repeating: "a", count: 64),
                                                        coldRootPublicKey: root.publicKey,
                                                        coldRootPrivateKey: root.privateKey,
                                                        createdAtUnix: "1716508800")
        XCTAssertEqual(certificate.mode, .secureEnclave)
        XCTAssertTrue(certificate.hardwareBindingActive)
        XCTAssertEqual(certificate.hardwareFingerprint.secureEnclaveKeyID, certificate.hotPublicKeySHA256Hex)

        let verification = SecureEnclaveIdentityManager.verifyCertificate(certificate, coldRootPublicKey: root.publicKey)
        XCTAssertTrue(verification.ok)
        XCTAssertEqual(verification.status, "OK")
    }

    func testCertificateTamperFailsVerification() throws {
        let dir = try artifactURL("tamper")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("tamper"), auditLogPath: dir.appendingPathComponent("audit.jsonl"))
        _ = try manager.issueAuditSealMasterBlob()
        _ = try manager.issueCryptoKitSecureEnclaveKey()
        let root = try generateColdRootForTestsOnly()
        let certificate = try manager.createCertificate(valuesHash: String(repeating: "b", count: 64),
                                                        coldRootPublicKey: root.publicKey,
                                                        coldRootPrivateKey: root.privateKey,
                                                        createdAtUnix: "1716508800")
        let tampered = HotIdentityCertificate(version: certificate.version,
                                              operatorID: certificate.operatorID,
                                              subjectID: certificate.subjectID,
                                              createdAtUnix: certificate.createdAtUnix,
                                              mode: certificate.mode,
                                              hardwareBindingActive: certificate.hardwareBindingActive,
                                              hotKeyAlgorithm: certificate.hotKeyAlgorithm,
                                              hotPublicKeyBase64: certificate.hotPublicKeyBase64,
                                              hotPublicKeySHA256Hex: certificate.hotPublicKeySHA256Hex,
                                              hardwareFingerprint: certificate.hardwareFingerprint,
                                              valuesHash: String(repeating: "c", count: 64),
                                              coldRootPublicKeyHex: certificate.coldRootPublicKeyHex,
                                              warning: certificate.warning,
                                              signatureHex: certificate.signatureHex)
        let verification = SecureEnclaveIdentityManager.verifyCertificate(tampered, coldRootPublicKey: root.publicKey)
        XCTAssertFalse(verification.ok)
        XCTAssertEqual(verification.status, "BROKEN")
    }

    func testFallbackBehaviorWarnsAndAudits() throws {
        let dir = try artifactURL("fallback")
        let audit = dir.appendingPathComponent("audit.jsonl")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("fallback"), auditLogPath: audit, forceSoftwareFallback: true)
        _ = try manager.issueAuditSealMasterBlob()
        _ = try manager.issueFallbackKeypair()
        let descriptor = try manager.descriptor()
        XCTAssertEqual(descriptor.mode, .libsodiumFallback)
        XCTAssertFalse(descriptor.hardwareBindingActive)
        XCTAssertEqual(descriptor.warning, SecureEnclaveIdentityManager.fallbackWarning)

        let signature = try manager.signChallenge(Data("software fallback challenge".utf8))
        XCTAssertEqual(signature.mode, .libsodiumFallback)
        XCTAssertEqual(signature.warning, SecureEnclaveIdentityManager.fallbackWarning)

        let auditText = try String(contentsOf: audit, encoding: .utf8)
        XCTAssertTrue(auditText.contains("hardware_binding_not_active"))
        // Audit log records metadata_sha256 (hash-redacted); raw warning text is emitted to stderr
        // (see SecureEnclaveIdentityManager.material(forceSoftwareFallback) fputs) and is not
        // available in the persisted audit file by design.
    }

    func testCABIExportsCertificateVerification() throws {
        let dir = try artifactURL("cabi")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("cabi"), auditLogPath: dir.appendingPathComponent("audit.jsonl"), forceSoftwareFallback: true)
        _ = try manager.issueAuditSealMasterBlob()
        _ = try manager.issueFallbackKeypair()
        let root = try generateColdRootForTestsOnly()
        let certificate = try manager.createCertificate(valuesHash: String(repeating: "d", count: 64),
                                                        coldRootPublicKey: root.publicKey,
                                                        coldRootPrivateKey: root.privateKey,
                                                        createdAtUnix: "1716508800")
        let certJSON = try encodeJSON(certificate)
        var verificationPtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let ok = certJSON.withCString { certCString in
            root.publicKey.withUnsafeBytes { rootRaw in
                jarvis_se_verify_certificate(certCString,
                                             rootRaw.bindMemory(to: UInt8.self).baseAddress,
                                             root.publicKey.count,
                                             &verificationPtr,
                                             &errorPtr)
            }
        }
        XCTAssertTrue(ok, errorPtr.map { String(cString: $0) } ?? "")
        defer {
            jarvis_se_free(verificationPtr)
            jarvis_se_free(errorPtr)
        }
        let verificationJSON = String(cString: verificationPtr!)
        let verification = try decodeJSON(CertificateVerification.self, from: verificationJSON)
        XCTAssertTrue(verification.ok)
    }

    func testLoadHotKeyMissingThrowsCeremonyArtifactMissing() throws {
        let dir = try artifactURL("fail_closed_hot_key")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("fail-hot"), auditLogPath: dir.appendingPathComponent("audit.jsonl"))
        do {
            _ = try manager.descriptor()
            XCTFail("Expected ceremonyArtifactMissing, got success")
        } catch SecureEnclaveIdentityError.ceremonyArtifactMissing(let artifact, _, let reason) {
            XCTAssertEqual(artifact, "secure_enclave_hot_key_blob")
            XCTAssertTrue(reason.contains("jarvis-ceremony issue-hot-key"))
        } catch {
            XCTFail("Expected ceremonyArtifactMissing, got \(error)")
        }
    }

    func testLoadFallbackMissingThrowsCeremonyArtifactMissing() throws {
        let dir = try artifactURL("fail_closed_fallback")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("fail-fallback"), auditLogPath: dir.appendingPathComponent("audit.jsonl"), forceSoftwareFallback: true)
        do {
            _ = try manager.descriptor()
            XCTFail("Expected ceremonyArtifactMissing, got success")
        } catch SecureEnclaveIdentityError.ceremonyArtifactMissing(let artifact, _, let reason) {
            XCTAssertEqual(artifact, "fallback_keypair")
            XCTAssertTrue(reason.contains("jarvis-ceremony issue-fallback"))
        } catch {
            XCTFail("Expected ceremonyArtifactMissing, got \(error)")
        }
    }

    func testLoadAuditSealMissingThrowsCeremonyArtifactMissing() throws {
        let dir = try artifactURL("fail_closed_audit_seal")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("fail-audit"), auditLogPath: dir.appendingPathComponent("audit.jsonl"))
        // Issue the hot-key blob WITHOUT issuing the audit seal first; the blob lands on disk
        // even though the subsequent audit-event write fails fail-closed on the missing seal.
        do {
            _ = try manager.issueCryptoKitSecureEnclaveKey()
            XCTFail("Expected ceremonyArtifactMissing(audit_seal_master_blob) during issue, got success")
        } catch SecureEnclaveIdentityError.ceremonyArtifactMissing(let artifact, _, let reason) {
            XCTAssertEqual(artifact, "audit_seal_master_blob")
            XCTAssertTrue(reason.contains("jarvis-ceremony issue-audit-seal"))
        }
        // The hot-key blob is on disk; descriptor() now loads it and tries to audit the load,
        // which again fails fail-closed on the missing audit seal master blob.
        do {
            _ = try manager.descriptor()
            XCTFail("Expected ceremonyArtifactMissing, got success")
        } catch SecureEnclaveIdentityError.ceremonyArtifactMissing(let artifact, _, let reason) {
            XCTAssertEqual(artifact, "audit_seal_master_blob")
            XCTAssertTrue(reason.contains("jarvis-ceremony issue-audit-seal"))
        } catch {
            XCTFail("Expected ceremonyArtifactMissing, got \(error)")
        }
    }

    func testIssueThenLoadRoundTrip() throws {
        let dir = try artifactURL("issue_then_load")
        let manager = SecureEnclaveIdentityManager(keyTag: uniqueTag("roundtrip"), auditLogPath: dir.appendingPathComponent("audit.jsonl"))
        _ = try manager.issueAuditSealMasterBlob()
        let issuedKey = try manager.issueCryptoKitSecureEnclaveKey()
        let descriptor1 = try manager.descriptor()
        let descriptor2 = try manager.descriptor()
        XCTAssertEqual(descriptor1.publicKeySHA256Hex, descriptor2.publicKeySHA256Hex)
        XCTAssertEqual(descriptor1.publicKeyBase64, descriptor2.publicKeyBase64)
        let issuedPublicData = issuedKey.publicKey.x963Representation
        let loadedPublicData = Data(base64Encoded: descriptor1.publicKeyBase64)!
        XCTAssertEqual(sha256Hex(issuedPublicData), descriptor1.publicKeySHA256Hex)
        XCTAssertEqual(issuedPublicData, loadedPublicData)
    }

    private func verifyP256Signature(signatureBase64: String, publicKeyBase64: String, message: Data) throws -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64),
              let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            XCTFail("signature or public key is not base64")
            return false
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, &error)
    }
}
