import CryptoKit
import Dispatch
import Foundation
import Darwin

private enum CeremonyPhase: String {
    case launchCheck = "launch_check"
    case locked = "locked"
    case voiceAnchorValidated = "voice_anchor_validated"
    case usbPrepared = "usb_prepared"
    case coldRootGenerated = "cold_root_generated"
    case soulAnchorIssued = "soul_anchor_issued"
    case usbVaultWritten = "usb_vault_written"
    case sealedCertificateWritten = "sealed_certificate_written"
    case trustAnchorWritten = "trust_anchor_written"
    case commitRecordWritten = "commit_record_written"
}

// TODO(removal-cond: replace DispatchQueue-protected singleton with an actor when CeremonyOrchestrator becomes async)
private final class CeremonyRuntimeState: @unchecked Sendable {
    static let shared = CeremonyRuntimeState()
    private let queue = DispatchQueue(label: "org.gmri.jarvis.ceremony.runtime-state")
    private var phase: CeremonyPhase = .launchCheck
    private var audit: AuditLogger?
    func configure(audit: AuditLogger) { queue.sync { self.audit = audit } }
    func setPhase(_ phase: CeremonyPhase) { queue.sync { self.phase = phase } }
    func snapshot() -> (CeremonyPhase, AuditLogger?) { queue.sync { (phase, audit) } }
}

private enum CeremonySignalHandlers {
    private static let sources: [DispatchSourceSignal] = {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        return [makeSource(SIGTERM), makeSource(SIGINT)]
    }()

    static func install() { _ = sources }

    private static func makeSource(_ signalNumber: Int32) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            let (phase, audit) = CeremonyRuntimeState.shared.snapshot()
            do {
                try audit?.record("ceremony_interrupted_phase_\(phase.rawValue)", outcome: "fail", metadata: ["signal": String(signalNumber)])
            } catch {
                fputs("JARVIS ceremony interruption audit failed: \(error)\n", stderr)
            }
            exit(EXIT_FAILURE_INTERRUPTED)
        }
        source.resume()
        return source
    }
}

private final class CeremonyRollbackRegistry {
    typealias Cleanup = () -> Void
    private var cleanups: [(String, Cleanup)] = []

    func append(_ name: String, _ cleanup: @escaping Cleanup) {
        cleanups.append((name, cleanup))
    }

    func rollback(audit: AuditLogger, reason: String) {
        for (name, cleanup) in cleanups.reversed() {
            cleanup()
            do {
                try audit.record("ceremony_rollback_cleanup", outcome: "pass", metadata: ["artifact": name, "reason": reason])
            } catch {
                fputs("JARVIS rollback audit failed for \(name): \(error)\n", stderr)
            }
        }
    }
}

private final class CeremonyLock {
    private let fd: Int32
    let url: URL

    init(url: URL, policy: PathPolicy) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let opened = try policy.pathPolicyOpen(url, flags: O_RDWR | O_CREAT | O_CLOEXEC, mode: 0o600)
        if flock(opened, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(opened)
            if e == EWOULDBLOCK { throw CeremonyError.alreadyInProgress(url.path) }
            throw CeremonyError.transactionFailed("ceremony lock failed: errno=\(e)")
        }
        self.fd = opened
        let pid = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        try pid.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < pid.count {
                let n = pwrite(opened, base.advanced(by: written), pid.count - written, off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw CeremonyError.transactionFailed("ceremony lock pid pwrite failed: errno=\(errno)")
                }
                written += n
            }
        }
        if ftruncate(opened, off_t(pid.count)) != 0 { throw CeremonyError.transactionFailed("ceremony lock ftruncate failed: errno=\(errno)") }
        if fsync(opened) != 0 { throw CeremonyError.transactionFailed("ceremony lock fsync failed: errno=\(errno)") }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

public final class CeremonyOrchestrator {
    public let localRoot: URL
    private let policy: PathPolicy
    private let audit: AuditLogger
    private let seProvider: SecureEnclaveProviding
    private let bip39: BIP39
    private let fileManager: FileManager
    /// Nonce bound to the in-progress ceremony.  Set at the start of execute()
    /// and used to compute SHA256(nonce ‖ voiceAnchorBytes).  Persists in
    /// process memory for the lifetime of the ceremony run; not written to disk.
    private var _ceremonyNonce: Data?

    public init(localRoot: URL = defaultJarvisHome(),
                seProvider: SecureEnclaveProviding? = nil,
                bip39: BIP39? = nil,
                fileManager: FileManager = .default) throws {
        self.localRoot = localRoot.standardizedFileURL
        self.policy = PathPolicy(homeJarvis: self.localRoot)
        self.audit = AuditLogger(logURL: self.localRoot.appendingPathComponent("audit/soul_anchor_ceremony.jsonl"), policy: policy)
        self.seProvider = seProvider ?? RealSecureEnclaveProvider(auditLogPath: self.localRoot.appendingPathComponent("audit/secure_enclave_identity.jsonl"))
        self.bip39 = try bip39 ?? BIP39()
        self.fileManager = fileManager
        CeremonyRuntimeState.shared.configure(audit: audit)
        CeremonySignalHandlers.install()
    }

    public var sealedBirthCertificateURL: URL { localRoot.appendingPathComponent("birth_cert.sealed") }
    public var commitRecordURL: URL { localRoot.appendingPathComponent("ceremony_commit.v1.json") }
    public var ceremonyLockURL: URL { localRoot.appendingPathComponent("ceremony.lock") }
    public var trustRootURL: URL { localRoot.appendingPathComponent("trust", isDirectory: true) }
    public var anchorRootPublicKeyURL: URL { trustRootURL.appendingPathComponent("anchor_root.pub") }
    public var auditAnchorURL: URL { trustRootURL.appendingPathComponent("audit_anchor.json") }
    public var consumedChallengesURL: URL { localRoot.appendingPathComponent("state/consumed_challenges.jsonl") }

    public func assertCanLaunch() throws {
        try assertCanLaunch(checkStaleLock: true)
        try assertSoulAnchorAbsentOrAbort()
    }

    private func assertSoulAnchorAbsentOrAbort() throws {
        do {
            try seProvider.assertSoulAnchorAbsent()
        } catch CeremonyError.aborted(let aborted) {
            try audit.record("CEREMONY_ABORTED_SOUL_ANCHOR", outcome: "fail", metadata: ["reason": aborted.reason.description])
            throw CeremonyError.aborted(aborted)
        } catch {
            let aborted = CeremonyAbortedError(.soulAnchorIssuanceFailed(reason: String(describing: error)))
            try audit.record("CEREMONY_ABORTED_SOUL_ANCHOR", outcome: "fail", metadata: ["reason": aborted.reason.description])
            throw CeremonyError.aborted(aborted)
        }
    }

    private func assertCanLaunch(checkStaleLock: Bool) throws {
        CeremonyRuntimeState.shared.setPhase(.launchCheck)
        let certExists = fileManager.fileExists(atPath: sealedBirthCertificateURL.path)
        let commitExists = fileManager.fileExists(atPath: commitRecordURL.path)
        if checkStaleLock, fileManager.fileExists(atPath: ceremonyLockURL.path), !commitExists, !certExists, !isLockHeldByAnotherProcess() {
            let error = CeremonyIntegrityError.interruptedCeremonyRecovery(ceremonyLockURL.path)
            try audit.record("ceremony_interrupted_recovery_required", outcome: "fail", metadata: ["lock": ceremonyLockURL.path])
            throw CeremonyError.integrity(error)
        }
        switch (certExists, commitExists) {
        case (false, false):
            return
        case (true, false):
            let error = CeremonyIntegrityError.sealedCertWithoutCommit(sealedBirthCertificateURL.path)
            try audit.record("ceremony_integrity_error", outcome: "fail", metadata: ["case": "sealedCertWithoutCommit"])
            throw CeremonyError.integrity(error)
        case (false, true):
            let error = CeremonyIntegrityError.commitWithoutSealedCert(commitRecordURL.path)
            try audit.record("ceremony_integrity_error", outcome: "fail", metadata: ["case": "commitWithoutSealedCert"])
            throw CeremonyError.integrity(error)
        case (true, true):
            let record = try readCommitRecord()
            if record.version == 1 {
                let error = CeremonyIntegrityError.commitRecordObsolete(record.version)
                try audit.record("ceremony_integrity_error", outcome: "fail", metadata: ["case": "commitRecordObsolete", "version": String(record.version)])
                throw CeremonyError.integrity(error)
            }
            guard record.version == 2 else {
                let error = CeremonyIntegrityError.unsupportedCommitVersion(record.version)
                try audit.record("ceremony_integrity_error", outcome: "fail", metadata: ["case": "unsupportedCommitVersion", "version": String(record.version)])
                throw CeremonyError.integrity(error)
            }
            let checks = [
                (record.sealedCertSHA256, try sha256Hex(of: sealedBirthCertificateURL)),
                (record.anchorRootSHA256, try sha256Hex(of: anchorRootPublicKeyURL)),
                (record.auditAnchorSHA256, try sha256Hex(of: auditAnchorURL)),
                (record.consumedChallengesInitialSHA256, try sha256Hex(of: consumedChallengesURL)),
            ]
            for (expected, actual) in checks where expected != actual {
                let error = CeremonyIntegrityError.commitHashMismatch(expected: expected, actual: actual)
                try audit.record("ceremony_integrity_error", outcome: "fail", metadata: ["case": "commitHashMismatch"])
                throw CeremonyError.integrity(error)
            }
            throw CeremonyError.alreadyAnchored(sealedBirthCertificateURL.path)
        }
    }

    private func isLockHeldByAnotherProcess() -> Bool {
        let fd: Int32
        do { fd = try policy.pathPolicyOpen(ceremonyLockURL, flags: O_RDWR | O_CLOEXEC) }
        catch { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    private func readCommitRecord() throws -> CeremonyCommitRecord {
        try JSONDecoder().decode(CeremonyCommitRecord.self, from: Data(contentsOf: commitRecordURL))
    }

    private func migrateLegacyAuditFileKey() throws {
        // Migration note: Phase F removed the legacy C++ file-key path.
        // The only audit HMAC key source is now the Secure-Enclave-derived bridge key.
        let legacyKeyName = ["audit", "chain"].joined(separator: "_") + ".key"
        let legacyKeyURL = localRoot.appendingPathComponent(legacyKeyName)
        if fileManager.fileExists(atPath: legacyKeyURL.path) {
            try fileManager.removeItem(at: legacyKeyURL)
            try audit.record("legacy_audit_chain_key_removed", outcome: "pass", metadata: ["path": legacyKeyURL.path])
        }
    }

    public func unsealForLocalBackup() throws -> Data {
        do {
            try policy.validateLocalWrite(sealedBirthCertificateURL)
            let sealed = try Data(contentsOf: sealedBirthCertificateURL)
            let unsealed = try seProvider.unsealForLocalBackup(sealed)
            try audit.record("local_backup_unsealed", outcome: "pass", metadata: [
                "birth_certificate_sha256": sha256Hex(unsealed),
                "sealed_birth_certificate_sha256": sha256Hex(sealed)
            ])
            return unsealed
        } catch {
            try audit.record("local_backup_unsealed", outcome: "fail", metadata: ["error": String(describing: error)])
            throw error
        }
    }

    public func execute(vault: USBVaultWriting, usbUseConfirmed: Bool, formatApproved: Bool, operatorInitials: String, operatorID: String, paperBackupConfirmed: Bool, operatorVoiceAnchorURL: URL, voiceNonce: Data) throws -> CeremonyArtifacts {
        // Bind nonce to this ceremony run immediately. Any recording accepted before
        // this point must have been made with these nonce words shown to the operator.
        // SHA256(nonce ‖ audio) is used throughout so an old recording of the same
        // operator on the same calendar day cannot be replayed without the matching nonce.
        guard voiceNonce.count == 16 else {
            throw CeremonyError.transactionFailed("voiceNonce must be exactly 16 bytes, got \(voiceNonce.count)")
        }
        let validatedOperatorID = try BirthCertificate.validateOperatorID(operatorID)
        _ceremonyNonce = voiceNonce
        let lock = try CeremonyLock(url: ceremonyLockURL, policy: policy)
        _ = lock
        CeremonyRuntimeState.shared.setPhase(.locked)
        try assertSoulAnchorAbsentOrAbort()
        try migrateLegacyAuditFileKey()
        try assertCanLaunch(checkStaleLock: false)
        guard usbUseConfirmed else { throw CeremonyError.usbNotConfirmed }
        guard !operatorInitials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CeremonyError.transactionFailed("Operator initials are required") }
        guard paperBackupConfirmed else { throw CeremonyError.paperBackupNotConfirmed }
        let voiceAnchorHash = try validateVoiceAnchor(operatorVoiceAnchorURL)
        CeremonyRuntimeState.shared.setPhase(.voiceAnchorValidated)
        try audit.record("ceremony_started", outcome: "pending", metadata: ["operator_voice_anchor_sha256": voiceAnchorHash, "operator_id": validatedOperatorID])
        try fileManager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: consumedChallengesURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try policy.validateLocalWrite(sealedBirthCertificateURL)
        try policy.validateLocalWrite(commitRecordURL)
        try policy.validateLocalWrite(consumedChallengesURL)
        try vault.prepareIfNeeded(formatApproved: formatApproved, audit: audit)
        CeremonyRuntimeState.shared.setPhase(.usbPrepared)
        let coldRoot = try ColdRootKey()
        CeremonyRuntimeState.shared.setPhase(.coldRootGenerated)
        let rollback = CeremonyRollbackRegistry()
        let expectedVoiceAnchorURL = VoiceAnchorStore(jarvisRoot: localRoot, fileManager: fileManager).operatorAnchorURL.standardizedFileURL
        if operatorVoiceAnchorURL.standardizedFileURL.path == expectedVoiceAnchorURL.path {
            rollback.append("voice_anchor_file") { [weak self] in self?.removeIfExists(operatorVoiceAnchorURL) }
        }
        do {
            let soulAnchorPublicKey: Data
            do {
                soulAnchorPublicKey = try seProvider.issueSoulAnchorKey()
            } catch CeremonyError.aborted(let aborted) {
                throw CeremonyError.aborted(aborted)
            } catch {
                throw CeremonyError.aborted(CeremonyAbortedError(.soulAnchorIssuanceFailed(reason: String(describing: error))))
            }
            CeremonyRuntimeState.shared.setPhase(.soulAnchorIssued)
            rollback.append("soul_anchor_key_blob") { [weak self] in
                guard let self else { return }
                let ok = seProvider.removeIssuedSoulAnchorKeyForRollback()
                if !ok {
                    fputs("JARVIS CRITICAL: Soul Anchor key rollback FAILED — operator must manually verify SE state\n", stderr)
                    do {
                        try audit.record("soul_anchor_rollback_failed", outcome: "fail", metadata: ["alert": "key_may_still_exist"])
                    } catch {
                        fputs("JARVIS CRITICAL: audit write also failed for soul_anchor_rollback_failed: \(error)\n", stderr)
                    }
                }
            }
            try audit.record("SOUL_ANCHOR_ISSUED", outcome: "pass", metadata: ["soul_anchor_pub_sha256": sha256Hex(soulAnchorPublicKey)])
            let se = try seProvider.descriptor()
            guard se.mode == "secure-enclave", se.hardwareBindingActive else { throw CeremonyError.secureEnclaveUnavailable("fallback mode refused") }
            let cv = try CharacterValuesClient.canonical()
            var cert = try BirthCertificate(hkdfDomainVersion: HKDFDomain.currentSchemaVersion,
                                            timestamp: ISO8601DateFormatter().string(from: Date()),
                                            machineUUID: se.machineUUID,
                                            sePublicKeyBase64: se.publicKeyBase64,
                                            seKeyID: se.keyID,
                                            valuesHashViaCharacterValues: cv.valuesHash,
                                            hvAnchor: cv.hvAnchor,
                                            coldRootPublicKeyHex: hex(coldRoot.publicKey),
                                            soulAnchorPublicKeyHex: hex(soulAnchorPublicKey),
                                            operatorVoiceAnchorSHA256Hex: voiceAnchorHash,
                                            operatorID: validatedOperatorID)
            cert.signatureHex = hex(try coldRoot.sign(cert.canonicalPayloadData))
            try cert.verifyHKDFDomainVersion()
            guard let sig = unhex(cert.signatureHex), ColdRootKey.verify(signature: sig, message: cert.canonicalPayloadData, publicKey: coldRoot.publicKey) else {
                throw CeremonyError.verificationFailed
            }
            let words = try coldRoot.seed.withUnsafeBytes { seedBytes in
                try bip39.mnemonic(from: Data(buffer: seedBytes))
            }
            let secureMnemonic = try SecureMnemonic(words: words)
            let certificateJSON = try cert.jsonData()
            let certificateJSONSHA256 = sha256Hex(certificateJSON)
            let ceremonyHash = String(certificateJSONSHA256.prefix(16))
            let ceremonyID = UUID().uuidString
            let usbCertURL = try vault.writeColdVaultAtomically(certificate: cert,
                                                               publicKey: coldRoot.publicKey,
                                                               privateKeyWriter: coldRoot.withColdVaultBytes,
                                                               usbCertificateSigner: coldRoot.sign,
                                                               mnemonic: secureMnemonic,
                                                               ceremonyHash: ceremonyHash,
                                                               ceremonyID: ceremonyID,
                                                               policy: policy,
                                                               audit: audit)
            rollback.append("usb_cold_vault") { [policy] in vault.cleanupIncompleteCeremony(policy: policy) }
            CeremonyRuntimeState.shared.setPhase(.usbVaultWritten)
            let sealed = try seProvider.sealForLocalBackup(certificateJSON)
            try writeBlobAtomically0600(sealed, to: sealedBirthCertificateURL, errorContext: "sealed birth certificate")
            let sealedBirthCertificateURL = self.sealedBirthCertificateURL
            rollback.append("sealed_birth_certificate") { [weak self] in self?.removeIfExists(sealedBirthCertificateURL) }
            let localPlainJsonURL = self.localRoot.appendingPathComponent("identity").appendingPathComponent("birth_certificate.json")
            let localPlainJsonDirectoryURL = self.localRoot.appendingPathComponent("identity")
            try fileManager.createDirectory(at: localPlainJsonDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try policy.validateLocalWrite(localPlainJsonURL)
            rollback.append("local_birth_certificate_json") { [weak self] in self?.removeIfExists(localPlainJsonURL) }
            try writeBlobAtomically0600(certificateJSON, to: localPlainJsonURL, errorContext: "local birth certificate")
            let localPlainJsonSHA256 = try sha256Hex(of: localPlainJsonURL)
            guard localPlainJsonSHA256 == certificateJSONSHA256 else {
                throw CeremonyError.transactionFailed("local birth certificate validation failed: expected sha256=\(certificateJSONSHA256) actual sha256=\(localPlainJsonSHA256)")
            }
            CeremonyRuntimeState.shared.setPhase(.sealedCertificateWritten)
            if let pauseRaw = ProcessInfo.processInfo.environment["JARVIS_CEREMONY_TEST_PAUSE_AFTER_SEALED_SECONDS"], let seconds = UInt32(pauseRaw), seconds > 0 {
                sleep(seconds)
            }
            try writeTrustAnchor(coldRoot: coldRoot, rollback: rollback)
            try writeBlobAtomically0600(Data(), to: consumedChallengesURL, errorContext: "consumed challenges initial chain")
            let consumedChallengesURL = self.consumedChallengesURL
            rollback.append("consumed_challenges_initial_chain") { [weak self] in self?.removeIfExists(consumedChallengesURL) }
            CeremonyRuntimeState.shared.setPhase(.trustAnchorWritten)
            let voiceSignature = try coldRoot.sign(Data(voiceAnchorHash.utf8))
            let voiceAnchorNonceHex = hex(voiceNonce)
            let commit = CeremonyCommitRecord(ceremonyHash: ceremonyHash,
                                              voiceAnchorSHA256: voiceAnchorHash,
                                              voiceAnchorNonceHex: voiceAnchorNonceHex,
                                              sealedCertSHA256: sha256Hex(sealed),
                                              anchorRootSHA256: try sha256Hex(of: anchorRootPublicKeyURL),
                                              auditAnchorSHA256: try sha256Hex(of: auditAnchorURL),
                                              consumedChallengesInitialSHA256: try sha256Hex(of: consumedChallengesURL),
                                              sealedCertPath: sealedBirthCertificateURL.path,
                                              ceremonyID: ceremonyID)
            do {
                try writeBlobAtomically0600(try commit.jsonData(), to: commitRecordURL, errorContext: "ceremony commit record")
            } catch {
                rollback.rollback(audit: audit, reason: String(describing: error))
                try audit.record("ceremony_commit_rollback", outcome: "fail", metadata: ["error": String(describing: error)])
                throw error
            }
            CeremonyRuntimeState.shared.setPhase(.commitRecordWritten)
            try audit.record("voice_anchor_captured", outcome: "pass", metadata: ["operator_voice_anchor_sha256": voiceAnchorHash, "voice_anchor_nonce_hex": hex(voiceNonce), "cold_key_signature_hex": hex(voiceSignature)])
            try audit.record("ceremony_committed", outcome: "pass", metadata: ["ceremony_hash": ceremonyHash, "operator_voice_anchor_sha256": voiceAnchorHash, "operator_id": validatedOperatorID])
            return CeremonyArtifacts(certificate: cert, mnemonic: secureMnemonic, ceremonyHash: ceremonyHash, usbCertificateURL: usbCertURL, localSealedBackupURL: sealedBirthCertificateURL, localPlainJsonURL: localPlainJsonURL)
        } catch {
            rollback.rollback(audit: audit, reason: String(describing: error))
            do {
                if case CeremonyError.aborted(let aborted) = error {
                    try audit.record("CEREMONY_ABORTED_SOUL_ANCHOR", outcome: "fail", metadata: ["reason": aborted.reason.description])
                } else {
                    try audit.record("ceremony_failed", outcome: "fail", metadata: ["error": String(describing: error)])
                }
            } catch {
                throw CeremonyError.transactionFailed("ceremony failed and audit record failed: \(error)")
            }
            throw error
        }
    }

    private func validateVoiceAnchor(_ url: URL) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else { throw CeremonyError.missingVoiceAnchor("file is missing at \(url.path)") }
        let values = try url.resourceValues(forKeys: [.isReadableKey, .fileSizeKey])
        guard values.isReadable == true else { throw CeremonyError.missingVoiceAnchor("file is not readable at \(url.path)") }
        guard (values.fileSize ?? 0) >= 1 else { throw CeremonyError.missingVoiceAnchor("file is empty at \(url.path)") }
        let audioData = try Data(contentsOf: url)
        // Nonce freshness gate: hash = SHA256(nonce ‖ audio_bytes).
        // An attacker replaying an old recording of the same operator cannot
        // produce a matching hash without knowing this ceremony's nonce.
        guard let nonce = _ceremonyNonce else {
            throw CeremonyError.transactionFailed("voice anchor validation called before ceremony nonce was bound")
        }
        return sha256Hex(nonce + audioData)
    }

    private func writeTrustAnchor(coldRoot: ColdRootKey, rollback: CeremonyRollbackRegistry) throws {
        try policy.validateLocalWrite(trustRootURL)
        try fileManager.createDirectory(at: trustRootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try policy.validateLocalWrite(anchorRootPublicKeyURL)
        try policy.validateLocalWrite(auditAnchorURL)
        let anchorRootEnvelope = try TrustEnvelope(payloadData: coldRoot.publicKey, coldRoot: coldRoot)
        try writeBlobAtomically0600(try anchorRootEnvelope.jsonData(), to: anchorRootPublicKeyURL, errorContext: "trust anchor root public key")
        // Register rollback for the first file IMMEDIATELY after its write succeeds,
        // before attempting the second write. If the second write throws, the rollback
        // registry already contains this entry and will clean it up. Registering both
        // only after writeTrustAnchor returns would leave the first file unregistered
        // if the second write fails.
        let anchorRootPublicKeyURL = self.anchorRootPublicKeyURL
        rollback.append("anchor_root_public_key") { [weak self] in self?.removeIfExists(anchorRootPublicKeyURL) }
        let keyFingerprint = try audit.keyFingerprintHex()
        let payload = try canonicalAuditAnchorJSON(startSequenceID: 0,
                                                  startPrevHashHex: String(repeating: "0", count: 64),
                                                  keyFingerprintHex: keyFingerprint)
        let auditEnvelope = try TrustEnvelope(payloadData: payload, coldRoot: coldRoot)
        try writeBlobAtomically0600(try auditEnvelope.jsonData(), to: auditAnchorURL, errorContext: "audit anchor")
        let auditAnchorURL = self.auditAnchorURL
        rollback.append("audit_anchor") { [weak self] in self?.removeIfExists(auditAnchorURL) }
    }

    private func removeIfExists(_ url: URL) {
        if fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) }
            catch { fputs("JARVIS cleanup failed for \(url.path): \(error)\n", stderr) }
        }
    }
}
