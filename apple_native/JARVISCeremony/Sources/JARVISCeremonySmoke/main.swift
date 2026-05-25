import Darwin
import Foundation
import JARVISCeremonyCore

final class MockSEProvider: SecureEnclaveProviding {
    var soulAnchorPresent: Bool
    var issueFailure: Error?
    let soulAnchorPublicKey = Data([0x04]) + Data(repeating: 7, count: 64)

    init(soulAnchorPresent: Bool = false, issueFailure: Error? = nil) {
        self.soulAnchorPresent = soulAnchorPresent
        self.issueFailure = issueFailure
    }

    func descriptor() throws -> SecureEnclaveDescriptor {
        SecureEnclaveDescriptor(mode: "secure-enclave", hardwareBindingActive: true,
                                keyID: sha256Hex(soulAnchorPublicKey),
                                publicKeyBase64: soulAnchorPublicKey.base64EncodedString(),
                                publicKeySHA256Hex: sha256Hex(soulAnchorPublicKey),
                                machineUUID: "mock-machine-uuid")
    }
    func assertSoulAnchorAbsent() throws {
        if soulAnchorPresent { throw CeremonyError.aborted(CeremonyAbortedError(.soulAnchorAlreadyPresent)) }
    }
    func issueSoulAnchorKey() throws -> Data {
        if let issueFailure { throw issueFailure }
        if soulAnchorPresent { throw CeremonyError.aborted(CeremonyAbortedError(.soulAnchorAlreadyPresent)) }
        soulAnchorPresent = true
        return soulAnchorPublicKey
    }
    @discardableResult
    func removeIssuedSoulAnchorKeyForRollback() -> Bool { soulAnchorPresent = false; return true }
    func sealForLocalBackup(_ data: Data) throws -> Data { Data("MOCK-SE-SEAL:".utf8) + data }
    func unsealForLocalBackup(_ sealedData: Data) throws -> Data {
        let prefix = Data("MOCK-SE-SEAL:".utf8)
        guard sealedData.starts(with: prefix) else { throw CeremonyError.secureEnclaveUnavailable("mock local backup seal rejected") }
        return Data(sealedData.dropFirst(prefix.count))
    }
}

final class MockVault: USBVaultWriting {
    let device: USBDevice
    init(root: URL) { device = USBDevice(id: root.path, volumeURL: root, displayName: "MOCK_USB", sizeBytes: 8_000_000_000, filesystem: "APFS", wholeDiskIdentifier: nil) }
    func prepareIfNeeded(formatApproved: Bool, audit: AuditLogger) throws {
        if let raw = ProcessInfo.processInfo.environment["JARVIS_SMOKE_HOLD_SECONDS"], let seconds = UInt32(raw), seconds > 0 {
            sleep(seconds)
        }
    }
    func writeColdVaultAtomically(certificate: BirthCertificate,
                                  publicKey: Data,
                                  privateKeyWriter: (_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Void,
                                  usbCertificateSigner: (_ canonicalPayload: Data) throws -> Data,
                                  mnemonic: SecureMnemonic,
                                  ceremonyHash: String,
                                  ceremonyID: String,
                                  policy: PathPolicy,
                                  audit: AuditLogger) throws -> URL {
        let vault = device.volumeURL.appendingPathComponent("JARVIS_COLD_ROOT", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try writeBlobAtomically0600(try certificate.jsonData(), to: vault.appendingPathComponent("birth_certificate.json"), errorContext: "mock birth certificate")
        try writeBlobAtomically0600(publicKey, to: vault.appendingPathComponent("cold_root_public.key"), errorContext: "mock public key")
        try privateKeyWriter { bytes in
            try writeBlobAtomically0600(bytes, to: vault.appendingPathComponent("cold_root_private.key"), errorContext: "mock cold_root_private.key")
        }
        let identity = USBDevicePhysicalIdentity(volumeUUID: "mock-volume-uuid", bsdName: "mockdisk1", vendorString: "mock-vendor", modelString: "mock-model", writeProtectState: "writable")
        let usbCert = try USBVaultWriter.makeUSBDeviceCertificate(identity: identity, ceremonyID: ceremonyID, signer: usbCertificateSigner)
        try USBVaultWriter.verifyUSBDeviceCertificate(usbCert, expected: identity, publicKey: publicKey)
        try writeBlobAtomically0600(try usbCert.jsonData(), to: vault.appendingPathComponent(".jarvis_usb_cert"), errorContext: "mock USB device certificate")
        let words = try mnemonic.withMnemonicWords { $0.joined(separator: " ") }
        try writeBlobAtomically0600(Data(words.utf8), to: vault.appendingPathComponent("paper_backup_words.txt"), errorContext: "mock paper words")
        return vault.appendingPathComponent("birth_certificate.json")
    }
    func cleanupIncompleteCeremony(policy: PathPolicy) {
        let vault = device.volumeURL.appendingPathComponent("JARVIS_COLD_ROOT", isDirectory: true)
        if FileManager.default.fileExists(atPath: vault.path) { try? FileManager.default.removeItem(at: vault) }
    }
}

func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CeremonyError.transactionFailed("smoke assertion failed: \(message)") }
}

let smokeBase = ProcessInfo.processInfo.environment["JARVIS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/smoke-artifacts", isDirectory: true)
let smokeRoot = smokeBase.appendingPathComponent("JARVISCeremonySmoke/\(UUID().uuidString)", isDirectory: true)

func clean(_ name: String) throws -> URL {
    let url = smokeRoot.appendingPathComponent(name, isDirectory: true)
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeAnchoredState(at root: URL) throws {
    let cert = Data("sealed".utf8)
    let certURL = root.appendingPathComponent("birth_cert.sealed")
    try writeBlobAtomically0600(cert, to: certURL, errorContext: "smoke anchored sealed cert")
    let anchorURL = root.appendingPathComponent("trust/anchor_root.pub")
    let auditURL = root.appendingPathComponent("trust/audit_anchor.json")
    let consumedURL = root.appendingPathComponent("state/consumed_challenges.jsonl")
    try writeBlobAtomically0600(Data("anchor".utf8), to: anchorURL, errorContext: "smoke anchor")
    try writeBlobAtomically0600(Data("audit".utf8), to: auditURL, errorContext: "smoke audit anchor")
    try writeBlobAtomically0600(Data(), to: consumedURL, errorContext: "smoke consumed challenges")
    let commit = CeremonyCommitRecord(ceremonyHash: "smoke", voiceAnchorSHA256: String(repeating: "1", count: 64), sealedCertSHA256: sha256Hex(cert), anchorRootSHA256: try sha256Hex(of: anchorURL), auditAnchorSHA256: try sha256Hex(of: auditURL), consumedChallengesInitialSHA256: try sha256Hex(of: consumedURL), sealedCertPath: certURL.path, ceremonyID: "smoke")
    try writeBlobAtomically0600(try commit.jsonData(), to: root.appendingPathComponent("ceremony_commit.v1.json"), errorContext: "smoke commit")
}

if let singleRootRaw = ProcessInfo.processInfo.environment["JARVIS_SMOKE_SINGLE_ROOT"] {
    do {
        let root = URL(fileURLWithPath: singleRootRaw, isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        let usb = root.appendingPathComponent("usb", isDirectory: true)
        let voiceDir = root.appendingPathComponent("voice", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usb, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        let anchor = voiceDir.appendingPathComponent("operator_anchor.wav")
        if !FileManager.default.fileExists(atPath: anchor.path) {
            try writeBlobAtomically0600(Data("mock 16k mono voice anchor".utf8), to: anchor, errorContext: "single smoke voice anchor")
        }
        let orchestrator = try CeremonyOrchestrator(localRoot: local, seProvider: MockSEProvider())
        let artifacts = try orchestrator.execute(vault: MockVault(root: usb), usbUseConfirmed: true, formatApproved: true, operatorInitials: "RH", operatorID: "Test Operator", paperBackupConfirmed: true, operatorVoiceAnchorURL: anchor, voiceNonce: Data(repeating: 0xC1, count: 16))
        print("single smoke committed: \(artifacts.ceremonyHash)")
        exit(0)
    } catch {
        fputs("single smoke refused: \(error)\n", stderr)
        exit(2)
    }
}

do {
    let bip39 = try BIP39()
    let seed = Data((0..<32).map(UInt8.init))
    let words = try bip39.mnemonic(from: seed)
    try assert(words.count == 24, "mnemonic has 24 words")
    let roundTrip = try bip39.entropy(from: words)
    try assert(roundTrip == seed, "mnemonic round trip")

    let anchored = try clean("already/local")
    try writeAnchoredState(at: anchored)
    do { try CeremonyOrchestrator(localRoot: anchored, seProvider: MockSEProvider()).assertCanLaunch(); throw CeremonyError.transactionFailed("expected already anchored refusal") }
    catch CeremonyError.alreadyAnchored { }

    let corrupt = try clean("mismatch/local")
    try writeAnchoredState(at: corrupt)
    let badCommit = CeremonyCommitRecord(ceremonyHash: "smoke", voiceAnchorSHA256: String(repeating: "1", count: 64), sealedCertSHA256: String(repeating: "f", count: 64), anchorRootSHA256: try sha256Hex(of: corrupt.appendingPathComponent("trust/anchor_root.pub")), auditAnchorSHA256: try sha256Hex(of: corrupt.appendingPathComponent("trust/audit_anchor.json")), consumedChallengesInitialSHA256: try sha256Hex(of: corrupt.appendingPathComponent("state/consumed_challenges.jsonl")), sealedCertPath: corrupt.appendingPathComponent("birth_cert.sealed").path, ceremonyID: "smoke")
    try writeBlobAtomically0600(try badCommit.jsonData(), to: corrupt.appendingPathComponent("ceremony_commit.v1.json"), errorContext: "smoke corrupt commit")
    do { try CeremonyOrchestrator(localRoot: corrupt, seProvider: MockSEProvider()).assertCanLaunch(); throw CeremonyError.transactionFailed("expected commit mismatch") }
    catch CeremonyError.integrity(.commitHashMismatch) { }

    let usbSpoofKey = try ColdRootKey(seed: Data(repeating: 9, count: 32))
    let originalUSBIdentity = USBDevicePhysicalIdentity(volumeUUID: "same-volume", bsdName: "disk4s1", vendorString: "vendor-a", modelString: "model-a", writeProtectState: "writable")
    let spoofedUSBIdentity = USBDevicePhysicalIdentity(volumeUUID: "same-volume", bsdName: "disk9s1", vendorString: "vendor-b", modelString: "model-b", writeProtectState: "writable")
    let usbDeviceCertificate = try USBVaultWriter.makeUSBDeviceCertificate(identity: originalUSBIdentity, ceremonyID: "smoke", signer: usbSpoofKey.sign)
    do {
        try USBVaultWriter.verifyUSBDeviceCertificate(usbDeviceCertificate, expected: spoofedUSBIdentity, publicKey: usbSpoofKey.publicKey)
        throw CeremonyError.transactionFailed("expected USB certificate spoof refusal")
    } catch CeremonyError.usbIdentityChanged { }

    let script = VoiceAnchorScript.operatorScript(name: "Robert Hanson", date: Date(timeIntervalSince1970: 1_779_580_800))
    try assert(script.text.contains("JARVIS knows my voice"), "operator voice script names JARVIS as a person")
    let syntheticVoice = (0..<(48_000 * 4)).map { i -> Int16 in
        let phase = Double(i % 96) / 96.0
        return phase < 0.5 ? 3200 : -3200
    }
    let validation = VoiceAnchorValidator().validate(samples: syntheticVoice, sampleRate: 48_000, channelCount: 1)
    if case .ok = validation {} else { throw CeremonyError.transactionFailed("voice validation smoke failed: \(validation)") }

    let symlinkLocal = try clean("lock-symlink/local")
    let symlinkUSB = try clean("lock-symlink/usb")
    let symlinkVoice = try clean("lock-symlink/voice").appendingPathComponent("operator_anchor.wav")
    let sentinel = smokeRoot.appendingPathComponent("lock-symlink/sentinel")
    try writeBlobAtomically0600(Data("DO-NOT-TRUNCATE".utf8), to: sentinel, errorContext: "lock symlink sentinel")
    try writeBlobAtomically0600(Data("mock voice".utf8), to: symlinkVoice, errorContext: "lock symlink voice")
    symlink(sentinel.path, symlinkLocal.appendingPathComponent("ceremony.lock").path)
    do {
        _ = try CeremonyOrchestrator(localRoot: symlinkLocal, seProvider: MockSEProvider()).execute(vault: MockVault(root: symlinkUSB), usbUseConfirmed: true, formatApproved: true, operatorInitials: "RH", operatorID: "Test Operator", paperBackupConfirmed: true, operatorVoiceAnchorURL: symlinkVoice, voiceNonce: Data(repeating: 0xC2, count: 16))
        throw CeremonyError.transactionFailed("expected symlinked lock refusal")
    } catch CeremonyError.writeRefused { }
    let sentinelText = String(data: try Data(contentsOf: sentinel), encoding: .utf8)
    try assert(sentinelText == "DO-NOT-TRUNCATE", "symlinked ceremony.lock sentinel was not truncated")

    let local = try clean("flow/local")
    let usb = try clean("flow/usb")
    let anchor = try clean("flow/voice").appendingPathComponent("operator_anchor.wav")
    try writeBlobAtomically0600(Data("mock 16k mono voice anchor".utf8), to: anchor, errorContext: "mock voice anchor")
    let orchestrator = try CeremonyOrchestrator(localRoot: local, seProvider: MockSEProvider())
    let artifacts = try orchestrator.execute(vault: MockVault(root: usb), usbUseConfirmed: true, formatApproved: true, operatorInitials: "RH", operatorID: "Test Operator", paperBackupConfirmed: true, operatorVoiceAnchorURL: anchor, voiceNonce: Data(repeating: 0xC3, count: 16))
    let unsealed = try orchestrator.unsealForLocalBackup()
    let expectedCertificateData = try artifacts.certificate.jsonData()
    try assert(unsealed == expectedCertificateData, "sealed birth certificate unseals byte-equal")
    try assert(FileManager.default.fileExists(atPath: artifacts.usbCertificateURL.path), "USB certificate written")
    try assert(FileManager.default.fileExists(atPath: artifacts.localSealedBackupURL.path), "local sealed backup written")
    try assert(FileManager.default.fileExists(atPath: artifacts.localPlainJsonURL.path), "local plain birth certificate written")
    let localPlainCertificateData = try Data(contentsOf: artifacts.localPlainJsonURL)
    try assert(localPlainCertificateData == expectedCertificateData, "local plain birth certificate byte-equal")
    try assert(FileManager.default.fileExists(atPath: local.appendingPathComponent("ceremony_commit.v1.json").path), "commit record written")
    try assert(FileManager.default.fileExists(atPath: local.appendingPathComponent("trust/anchor_root.pub").path), "trust anchor root public key written")
    try assert(FileManager.default.fileExists(atPath: local.appendingPathComponent("trust/audit_anchor.json").path), "audit anchor written")
    if ProcessInfo.processInfo.environment["JARVIS_HOME"] != nil {
        for artifact in [artifacts.usbCertificateURL, artifacts.localSealedBackupURL, artifacts.localPlainJsonURL, local.appendingPathComponent("ceremony_commit.v1.json"), local.appendingPathComponent("trust/anchor_root.pub"), local.appendingPathComponent("trust/audit_anchor.json")] {
            try assert(artifact.standardizedFileURL.path.hasPrefix(smokeBase.path + "/"), "artifact escaped JARVIS_HOME: \(artifact.path)")
        }
    }
    let privateKeyAttrs = try FileManager.default.attributesOfItem(atPath: usb.appendingPathComponent("JARVIS_COLD_ROOT/cold_root_private.key").path)
    let privateKeyMode = (privateKeyAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    try assert(privateKeyMode & 0o777 == 0o600, "cold root private key mode is 0600")
    let pub = try Data(contentsOf: usb.appendingPathComponent("JARVIS_COLD_ROOT/cold_root_public.key"))
    guard let sig = unhex(artifacts.certificate.signatureHex) else { throw CeremonyError.verificationFailed }
    try assert(ColdRootKey.verify(signature: sig, message: artifacts.certificate.canonicalPayloadData, publicKey: pub), "certificate verifies")
    try assert(!artifacts.certificate.operatorVoiceAnchorSHA256Hex.isEmpty, "voice anchor hash embedded in certificate")
    try assert(!artifacts.certificate.coldRootPublicKeyHex.isEmpty, "cold root public key embedded in certificate")
    try assert(!artifacts.certificate.soulAnchorPublicKeyHex.isEmpty, "Soul Anchor public key embedded in certificate")
    try assert(!artifacts.certificate.machineUUID.isEmpty, "hardware fingerprint embedded in certificate")
    let certObject = try JSONSerialization.jsonObject(with: artifacts.certificate.jsonData()) as? [String: Any]
    try assert(certObject?["soul_anchor_pub"] as? String == artifacts.certificate.soulAnchorPublicKeyHex, "birth certificate JSON uses soul_anchor_pub")

    let failLocal = try clean("soul-anchor-failure/local")
    let failUSB = try clean("soul-anchor-failure/usb")
    let failVoice = failLocal.appendingPathComponent("_local_voice/operator_anchor.wav")
    try writeBlobAtomically0600(Data("mock voice".utf8), to: failVoice, errorContext: "failure voice")
    let failProvider = MockSEProvider(issueFailure: CeremonyError.secureEnclaveUnavailable("mock Soul Anchor issuance failure"))
    do {
        _ = try CeremonyOrchestrator(localRoot: failLocal, seProvider: failProvider).execute(vault: MockVault(root: failUSB), usbUseConfirmed: true, formatApproved: true, operatorInitials: "RH", operatorID: "Test Operator", paperBackupConfirmed: true, operatorVoiceAnchorURL: failVoice, voiceNonce: Data(repeating: 0xC4, count: 16))
        throw CeremonyError.transactionFailed("expected Soul Anchor issuance failure")
    } catch CeremonyError.aborted(let aborted) {
        guard case .soulAnchorIssuanceFailed = aborted.reason else { throw CeremonyError.transactionFailed("expected soulAnchorIssuanceFailed") }
    }
    try assert(!failProvider.soulAnchorPresent, "Soul Anchor mock rolled back after issuance failure")
    try assert(!FileManager.default.fileExists(atPath: failVoice.path), "voice anchor file rolled back after issuance failure")
    try assert(!FileManager.default.fileExists(atPath: failLocal.appendingPathComponent("birth_cert.sealed").path), "no birth cert after issuance failure")
    try assert(!FileManager.default.fileExists(atPath: failUSB.appendingPathComponent("JARVIS_COLD_ROOT").path), "no cold root vault after issuance failure")

    let presentLocal = try clean("soul-anchor-present/local")
    let presentUSB = try clean("soul-anchor-present/usb")
    let presentSentinel = presentLocal.appendingPathComponent("existing-artifact")
    try writeBlobAtomically0600(Data("KEEP".utf8), to: presentSentinel, errorContext: "present sentinel")
    let presentVoice = presentLocal.appendingPathComponent("_local_voice/operator_anchor.wav")
    try writeBlobAtomically0600(Data("mock voice".utf8), to: presentVoice, errorContext: "present voice")
    do {
        _ = try CeremonyOrchestrator(localRoot: presentLocal, seProvider: MockSEProvider(soulAnchorPresent: true)).execute(vault: MockVault(root: presentUSB), usbUseConfirmed: true, formatApproved: true, operatorInitials: "RH", operatorID: "Test Operator", paperBackupConfirmed: true, operatorVoiceAnchorURL: presentVoice, voiceNonce: Data(repeating: 0xC5, count: 16))
        throw CeremonyError.transactionFailed("expected Soul Anchor already-present refusal")
    } catch CeremonyError.aborted(let aborted) {
        try assert(aborted.reason == .soulAnchorAlreadyPresent, "Soul Anchor already-present typed refusal")
    }
    let presentSentinelText = String(data: try Data(contentsOf: presentSentinel), encoding: .utf8)
    try assert(presentSentinelText == "KEEP", "already-present refusal did not touch existing artifact")
    try assert(FileManager.default.fileExists(atPath: presentVoice.path), "already-present refusal left voice anchor untouched")

    let swapRoot = try clean("tamper-swap/local")
    try writeAnchoredState(at: swapRoot)
    try writeBlobAtomically0600(Data("attacker".utf8), to: swapRoot.appendingPathComponent("trust/anchor_root.pub"), errorContext: "tamper swapped anchor")
    do { try CeremonyOrchestrator(localRoot: swapRoot, seProvider: MockSEProvider()).assertCanLaunch(); throw CeremonyError.transactionFailed("expected swapped trust file refusal") }
    catch CeremonyError.integrity(.commitHashMismatch) { }

    let bitFlipRoot = try clean("tamper-bitflip/local")
    try writeAnchoredState(at: bitFlipRoot)
    let auditURL = bitFlipRoot.appendingPathComponent("trust/audit_anchor.json")
    var auditBytes = try Data(contentsOf: auditURL)
    auditBytes[0] ^= 0x01
    try writeBlobAtomically0600(auditBytes, to: auditURL, errorContext: "tamper bit-flipped audit anchor")
    do { try CeremonyOrchestrator(localRoot: bitFlipRoot, seProvider: MockSEProvider()).assertCanLaunch(); throw CeremonyError.transactionFailed("expected bit-flipped trust file refusal") }
    catch CeremonyError.integrity(.commitHashMismatch) { }

    let schemaRoot = try clean("tamper-schema/local")
    try writeAnchoredState(at: schemaRoot)
    let oldPrevKey = "start_" + "prev_" + "hash"
    let oldFingerprintKey = "key_" + "fingerprint"
    try writeBlobAtomically0600(Data("{\"\(oldPrevKey)\":\"bad\",\"\(oldFingerprintKey)\":\"bad\"}".utf8), to: schemaRoot.appendingPathComponent("trust/audit_anchor.json"), errorContext: "tamper schema mismatch audit anchor")
    do { try CeremonyOrchestrator(localRoot: schemaRoot, seProvider: MockSEProvider()).assertCanLaunch(); throw CeremonyError.transactionFailed("expected schema-mismatch trust file refusal") }
    catch CeremonyError.integrity(.commitHashMismatch) { }

    print("JARVISCeremonySmoke passed: JARVIS_HOME hermetic root, symlinked lock refusal, USB cert spoof refusal, commit-record refusal, mismatch refusal, trust-file swap/bitflip/schema-mismatch refusals, voice-capture script, validation gating, mocked ceremony with Soul Anchor binding, Soul Anchor failure rollback, already-present refusal, local-backup unseal round-trip, BIP-39 round-trip, certificate verification")
    try FileManager.default.removeItem(at: smokeRoot)
} catch {
    fputs("JARVISCeremonySmoke failed: \(error)\n", stderr)
    if FileManager.default.fileExists(atPath: smokeRoot.path) { try FileManager.default.removeItem(at: smokeRoot) }
    exit(1)
}
