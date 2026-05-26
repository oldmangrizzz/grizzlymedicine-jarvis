// APTRedTeamTests — V4R R11d
//
// Advanced Persistent Threat red-team regression suite. New sibling file to
// BootLifecycleATPTests; covers the F-C01..F-C05 findings from the R11c APT
// walk. Each test pins one attacker capability and proves the defense in
// place under R11d.
//
// Coverage matrix (this file is the source of truth):
//
//   F-C01 — external cold-root pubkey pinning
//     a. matching pin → verify passes
//     b. attacker key + pin mismatch → invalidSignature + audit emission
//     c. no pin present (fail closed) → malformed + audit emission
//     d. Keychain takes precedence over file pin when both present
//
//   F-C02 — env-override gating (compile-flag behavior)
//     a. release-build path ignores env overrides (compile-time assertion)
//     b. debug+JARVIS_INSECURE_PATHS records an audit event when the
//        override is consulted (added with F-C02 patch)
//
//   F-C03 — audit hash chain (added with F-C03 patch)
//     a. records chain prev_sha correctly
//     b. truncation detected by verifier
//     c. surgical in-place edit detected by verifier
//
//   F-C04 — mlpackage compile integrity (added with F-C04 patch)
//     a. matching SHA passes
//     b. byte-swap detected
//     c. legacy BC (missing field) emits WARN audit, continues boot
//
//   F-C05 — operator.txt mode/owner re-check (added with F-C05 patch)
//     a. world-readable operator.txt falls back, audit fires

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import JARVISMacCockpit

final class APTRedTeamTests: XCTestCase {

    // MARK: - Fixture helpers (shared across F-C01..F-C05)

    /// Hermetic temp root per test. The env overrides bound below redirect every
    /// identity/security path under this root, so production state is untouched.
    private struct Fixture {
        let root: URL
        let identityDir: URL
        let auditDir: URL
        let pinFilePath: String
        let bcPath: String
        let keychainSuffix: String
    }

    private func makeFixture(file: StaticString = #file, line: UInt = #line) throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apt-\(UUID().uuidString)")
        let identityDir = root.appendingPathComponent("identity")
        let auditDir = root.appendingPathComponent("audit")
        try FileManager.default.createDirectory(at: identityDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let suffix = "smoke-\(UUID().uuidString.prefix(8))"
        return Fixture(
            root: root,
            identityDir: identityDir,
            auditDir: auditDir,
            pinFilePath: identityDir.appendingPathComponent("cold_root_public.key").path,
            bcPath: identityDir.appendingPathComponent("birth_certificate.json").path,
            keychainSuffix: String(suffix)
        )
    }

    private func setEnvForFixture(_ f: Fixture) {
        setenv("JARVIS_HOME", f.root.path, 1)
        setenv("JARVIS_AUDIT_ROOT", f.auditDir.path, 1)
        setenv("JARVIS_BIRTH_CERT_PATH", f.bcPath, 1)
        setenv("JARVIS_COLD_ROOT_PIN_FILE", f.pinFilePath, 1)
        setenv("JARVIS_COLD_ROOT_KEYCHAIN_SUFFIX", f.keychainSuffix, 1)
    }

    private func unsetEnvForFixture(_ f: Fixture) {
        // Unseal Keychain item if F-C01 sealing was used (no-op when not seeded).
        NativeColdRootPin.unsealForTest()
        unsetenv("JARVIS_HOME")
        unsetenv("JARVIS_AUDIT_ROOT")
        unsetenv("JARVIS_BIRTH_CERT_PATH")
        unsetenv("JARVIS_COLD_ROOT_PIN_FILE")
        unsetenv("JARVIS_COLD_ROOT_KEYCHAIN_SUFFIX")
        // R11l α.3 B.1: audit files are armed with UF_APPEND which blocks
        // unlink on macOS (EPERM). Recursively clear flags before removal so
        // the fixture tree can be reaped between tests.
        clearChflagsRecursive(at: f.root)
        try? FileManager.default.removeItem(at: f.root)
    }

    /// Recursively walks `url` and clears all chflags. Test-only helper to
    /// unblock unlink on UF_APPEND-armed audit files (F-KE03 / α.3 B.1).
    private func clearChflagsRecursive(at url: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return }
        var paths: [String] = [url.path]
        for case let child as URL in enumerator { paths.append(child.path) }
        for p in paths { _ = chflags(p, 0) }
    }

    /// Read every audit line from the fixture's audit dir; returns parsed JSON.
    private func readAuditEvents(_ f: Fixture) -> [[String: Any]] {
        let url = f.auditDir.appendingPathComponent("network_security.jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// Write the cold-root pin file at fixture's canonical path with mode 0600,
    /// matching the F-D03 fstat requirement enforced by NativeColdRootPin.
    @discardableResult
    private func writePinFile(_ pub: Data, at path: String) throws -> String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: path)
        try pub.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    /// Write a birth-certificate fixture at the canonical path with mode 0600,
    /// matching the F-KD03 leaf-mode requirement enforced by the §7 reader
    /// helper (`readSection7Anchored`). Production ceremony writes BC via
    /// `writeBlobAtomically0600`; fixtures must mirror that mode or the reader
    /// refuses with `leaf_mode_mismatch`.
    @discardableResult
    private func writeBCFixture(_ data: Data, at path: String) throws -> String {
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    /// Returns this Mac's IOPlatformUUID, the value the BC verifier requires
    /// `machineUUID` to match. Fixture BCs must carry this exact value.
    private func currentMachineUUID() -> String {
        // Mirror of the private currentMachineUUID() in NativeBirthCertificateVerifier.
        // Use sysctl as a portable fallback if IOKit lookup fails in test ctx.
        if let uuid = ioKitMachineUUID() { return uuid }
        return ProcessInfo.processInfo.globallyUniqueString
    }

    private func ioKitMachineUUID() -> String? {
        // Read via popen-shell-out — keeps the test file IOKit-free and reuses
        // the same source the verifier ultimately depends on (ioreg wraps IOKit).
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        for line in s.components(separatedBy: "\n") {
            if line.contains("IOPlatformUUID") {
                // Format: "    "IOPlatformUUID" = "ABC-123..."
                if let r = line.range(of: "= \"") {
                    let after = line[r.upperBound...]
                    if let q = after.firstIndex(of: "\"") { return String(after[..<q]) }
                }
            }
        }
        return nil
    }

    /// Mint a BC JSON signed by `signingKey`, with `coldRootPublicKeyHex` field
    /// set to `inCertColdRoot`. When `inCertColdRoot` differs from `signingKey`'s
    /// pubkey, the signature still verifies against the in-cert pubkey iff
    /// signingKey corresponds to inCertColdRoot — used to model attacker-forged
    /// BCs in F-C01-b.
    /// R11h F-E31 — describes a witness for BC fixture construction.
    /// `pubkeyHex` is computed from the signing key; the test helper
    /// signs the canonical payload with `key` to produce the signature.
    private struct FixtureWitness {
        let name: String
        let role: String
        let signingKey: Curve25519.Signing.PrivateKey
        let attestationTimestamp: Int64
        let jurisdiction: String?
    }

    private func mintBC(
        signingKey: Curve25519.Signing.PrivateKey,
        inCertColdRoot: Data,
        machineUUID: String,
        voiceAnchorSHA: String = String(repeating: "a", count: 64),
        operatorID: String = "operator-test",
        subjectID: String = "subject-test",
        witnesses: [FixtureWitness] = [],
        witnessSignaturesOverrideValid: Bool = true,
        otsReceiptB64: String? = nil,
        sbomHashHex: String? = nil,
        sbomSignatureHex: String? = nil,
        payloadVersion: Int? = nil
    ) -> Data {
        let inCertHex = inCertColdRoot.map { String(format: "%02x", $0) }.joined()
        let timestamp = "2026-05-25T16:00:00Z"
        let version = "v4r"
        let sePub = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        let seKeyID = "se-key-id-test"
        let valuesHash = "values-hash-test"
        let hvAnchor = "hv-anchor-test"
        let soulAnchorPub = String(repeating: "b", count: 64)

        // Canonical payload — sorted keys, snake_case, simple escaping.
        var payloadDict: [String: String] = [
            "cold_root_public_key": inCertHex,
            "hv_anchor": hvAnchor,
            "machine_uuid": machineUUID,
            "operator_id": operatorID,
            "operator_voice_anchor_sha256": voiceAnchorSHA,
            "se_key_id": seKeyID,
            "se_pubkey": sePub,
            "soul_anchor_pub": soulAnchorPub,
            "subject_id": subjectID,
            "timestamp": timestamp,
            "v": version,
            "values_hash_via_CharacterValues": valuesHash,
        ]

        // R11j F-F10 — when payloadVersion >= 2, inject the four binding
        // hashes into the canonical payload BEFORE signing. Verifier
        // will recompute live and reject any drift. The witnesses_root
        // binding excludes signature_hex (witnesses sign canonical,
        // which contains the binding — including sigs would be
        // circular; pubkeys are bound so swap-attacks fail at
        // verifyWitnesses).
        var v2WitnessRootHex: String? = nil
        var v2OTSReceiptHashHex: String? = nil
        var v2SBOMBindingHex: String? = nil
        var v2SBOMSigHashHex: String? = nil
        var witnessPubkeyHexes: [String: String] = [:]  // by name
        if let pv = payloadVersion, pv >= 2 {
            let witnessesActualBytes: Data
            if witnesses.isEmpty {
                witnessesActualBytes = Data("[]".utf8)
            } else {
                let sorted = witnesses.sorted { $0.name < $1.name }
                var entries: [String] = []
                for w in sorted {
                    let pubHex = w.signingKey.publicKey.rawRepresentation
                        .map { String(format: "%02x", $0) }.joined()
                    witnessPubkeyHexes[w.name] = pubHex
                    var fields: [String] = []
                    fields.append("\"attestation_timestamp\":\(w.attestationTimestamp)")
                    if let j = w.jurisdiction {
                        fields.append("\"jurisdiction\":\"\(j)\"")
                    }
                    fields.append("\"name\":\"\(w.name)\"")
                    fields.append("\"pubkey_hex\":\"\(pubHex)\"")
                    fields.append("\"role\":\"\(w.role)\"")
                    entries.append("{" + fields.joined(separator: ",") + "}")
                }
                witnessesActualBytes = Data(("[" + entries.joined(separator: ",") + "]").utf8)
            }
            v2WitnessRootHex = SHA256.hash(data: witnessesActualBytes)
                .map { String(format: "%02x", $0) }.joined()
            v2OTSReceiptHashHex = SHA256.hash(data: Data((otsReceiptB64 ?? "").utf8))
                .map { String(format: "%02x", $0) }.joined()
            v2SBOMBindingHex = (sbomHashHex ?? "").lowercased()
            v2SBOMSigHashHex = SHA256.hash(data: Data((sbomSignatureHex ?? "").utf8))
                .map { String(format: "%02x", $0) }.joined()
            payloadDict["payload_version"] = String(pv)
            payloadDict["witnesses_root_sha256_hex"] = v2WitnessRootHex ?? ""
            payloadDict["cold_root_ots_receipt_sha256_hex"] = v2OTSReceiptHashHex ?? ""
            payloadDict["sbom_binding_sha256_hex"] = v2SBOMBindingHex ?? ""
            payloadDict["sbom_cold_root_signature_sha256_hex"] = v2SBOMSigHashHex ?? ""
        }

        let canonical = "{" + payloadDict.keys.sorted().map { k in
            "\"\(k)\":\"\(payloadDict[k] ?? "")\""
        }.joined(separator: ",") + "}"
        let canonicalData = Data(canonical.utf8)

        // Sign canonical payload bytes with the supplied private key.
        let signature = try! signingKey.signature(for: canonicalData)
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

        // The on-disk BC is a flat JSON with camelCase struct keys
        // (NativeBirthCertificate.CodingKeys).
        var bcDict: [String: Any] = [
            "version": version,
            "timestamp": timestamp,
            "machineUUID": machineUUID,
            "sePublicKeyBase64": sePub,
            "seKeyID": seKeyID,
            "valuesHashViaCharacterValues": valuesHash,
            "hvAnchor": hvAnchor,
            "coldRootPublicKeyHex": inCertHex,
            "soul_anchor_pub": soulAnchorPub,
            "operatorVoiceAnchorSHA256Hex": voiceAnchorSHA,
            "operatorID": operatorID,
            "subjectID": subjectID,
            "signatureHex": signatureHex,
        ]
        if let pv = payloadVersion {
            bcDict["payload_version"] = pv
            if let h = v2WitnessRootHex { bcDict["witnesses_root_sha256_hex"] = h }
            if let h = v2OTSReceiptHashHex { bcDict["cold_root_ots_receipt_sha256_hex"] = h }
            if let h = v2SBOMBindingHex { bcDict["sbom_binding_sha256_hex"] = h }
            if let h = v2SBOMSigHashHex { bcDict["sbom_cold_root_signature_sha256_hex"] = h }
        }
        if !witnesses.isEmpty {
            var witnessArray: [[String: Any]] = []
            for w in witnesses {
                let pubHex = w.signingKey.publicKey.rawRepresentation
                    .map { String(format: "%02x", $0) }.joined()
                let sigBytes: Data
                if witnessSignaturesOverrideValid {
                    sigBytes = try! w.signingKey.signature(for: canonicalData)
                } else {
                    // Produce a signature over different bytes so it fails.
                    sigBytes = try! w.signingKey.signature(for: Data("tampered".utf8))
                }
                let sigHex = sigBytes.map { String(format: "%02x", $0) }.joined()
                var entry: [String: Any] = [
                    "name": w.name,
                    "role": w.role,
                    "pubkey_hex": pubHex,
                    "signature_hex": sigHex,
                    "attestation_timestamp": w.attestationTimestamp,
                ]
                if let j = w.jurisdiction { entry["jurisdiction"] = j }
                witnessArray.append(entry)
            }
            bcDict["witnesses"] = witnessArray
        }
        if let ots = otsReceiptB64 {
            bcDict["cold_root_ots_receipt_b64"] = ots
        }
        if let h = sbomHashHex {
            bcDict["sbom_sha256_hex"] = h
        }
        if let s = sbomSignatureHex {
            bcDict["sbom_cold_root_signature_hex"] = s
        }
        return try! JSONSerialization.data(withJSONObject: bcDict, options: [.sortedKeys])
    }

    // ================================================================
    // F-C01 — external cold-root pubkey pinning
    // ================================================================

    func test_APT_C01_a_bc_with_matching_pin_verifies() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        // Honest cold root: same key signs the BC and is written to the pin.
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)
        XCTAssertEqual(result.result, .verified,
                       "Honest BC against matching pin must verify. reason=\(result.reason)")
    }

    func test_APT_C01_b_bc_with_attacker_key_rejected_when_pin_present() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        // Honest ceremony pin K.
        let honestRoot = Curve25519.Signing.PrivateKey()
        let honestPub = honestRoot.publicKey.rawRepresentation
        try writePinFile(honestPub, at: f.pinFilePath)

        // Attacker mints a fresh keypair A and a self-consistent BC signed by A.
        let attackerKey = Curve25519.Signing.PrivateKey()
        let attackerPub = attackerKey.publicKey.rawRepresentation
        let bc = mintBC(signingKey: attackerKey, inCertColdRoot: attackerPub,
                        machineUUID: currentMachineUUID(),
                        voiceAnchorSHA: String(repeating: "f", count: 64))
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)
        XCTAssertEqual(result.result, .invalidSignature,
                       "Attacker-self-signed BC must be rejected when pin disagrees")
        XCTAssertTrue(result.reason.contains("externally-pinned"),
                      "Reason must surface the pin-mismatch cause, got: \(result.reason)")

        let events = readAuditEvents(f).map { ($0["event"] as? String) ?? "" }
        XCTAssertTrue(events.contains("boot_cold_root_pin_mismatch"),
                      "Audit must record pin mismatch event, saw: \(events)")
    }

    func test_APT_C01_c_no_pin_available_fails_closed() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        // Mint a self-consistent BC (any attacker can do this) but DO NOT seed pin.
        let key = Curve25519.Signing.PrivateKey()
        let bc = mintBC(signingKey: key, inCertColdRoot: key.publicKey.rawRepresentation,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)
        XCTAssertEqual(result.result, .malformed,
                       "Missing pin must cause boot to fail closed (not verified)")
        XCTAssertTrue(result.reason.contains("no externally-pinned cold root"),
                      "Reason must surface the missing-pin cause, got: \(result.reason)")

        let events = readAuditEvents(f).map { ($0["event"] as? String) ?? "" }
        XCTAssertTrue(events.contains("boot_cold_root_pin_missing"),
                      "Audit must record pin missing event, saw: \(events)")
    }

    func test_APT_C01_d_keychain_takes_precedence_over_file() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        // File pin says key K_file. Keychain pin says key K_kc. BC is signed by K_kc.
        // If file took precedence, verify would say invalidSignature against K_file.
        // If Keychain takes precedence, verify passes.
        let kFile = Curve25519.Signing.PrivateKey()
        try writePinFile(kFile.publicKey.rawRepresentation, at: f.pinFilePath)

        let kKc = Curve25519.Signing.PrivateKey()
        let kKcPub = kKc.publicKey.rawRepresentation
        let sealed = NativeColdRootPin.sealPinnedColdRootPublicKey(kKcPub)
        // Keychain may be unavailable in CI / sandbox; document and skip when so.
        try XCTSkipUnless(sealed, "Keychain access not available in this test ctx — skipping precedence assertion")

        // Re-write file pin to a DIFFERENT key so the test is meaningful.
        try writePinFile(kFile.publicKey.rawRepresentation, at: f.pinFilePath)

        let bc = mintBC(signingKey: kKc, inCertColdRoot: kKcPub,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)
        XCTAssertEqual(result.result, .verified,
                       "Keychain pin must take precedence over file pin. reason=\(result.reason)")
    }

    // R11f F-D02 — pin file load must refuse symlinks. Tests that a symlink
    // planted at the canonical pin path (even pointing at a structurally
    // valid 32-byte target file) is rejected via O_NOFOLLOW, with audit
    // emission, and the load throws .pinFileMalformed.
    func test_APT_C01_e_pin_file_symlink_rejected() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        NativeColdRootPin.unsealForTest(env: ProcessInfo.processInfo.environment)

        // Plant a structurally-valid 32-byte target file outside the pin path.
        let attackerKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let attackerKeyPath = f.root.appendingPathComponent("attacker_key.bin").path
        try attackerKey.write(to: URL(fileURLWithPath: attackerKeyPath))

        // Plant a symlink at the canonical pin path pointing to attacker_key.bin.
        try? FileManager.default.removeItem(atPath: f.pinFilePath)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: f.pinFilePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: f.pinFilePath, withDestinationPath: attackerKeyPath)

        var threw = false
        do {
            _ = try NativeColdRootPin.loadPinnedColdRootPublicKey(env: ProcessInfo.processInfo.environment)
        } catch let e as NativeColdRootPinError {
            threw = true
            switch e {
            case .pinFileMalformed(_, let reason):
                XCTAssertTrue(reason.contains("symlink_refused"),
                              "expected symlink_refused reason, got: \(reason)")
            default:
                XCTFail("expected .pinFileMalformed, got \(e)")
            }
        }
        XCTAssertTrue(threw, "loadPinnedColdRootPublicKey must throw on symlink")

        let events = try readAuditEvents(f)
        XCTAssertTrue(
            events.contains(where: { ev in
                (ev["event"] as? String) == "cold_root_pin_file_check_failed"
                    && (ev["reason"] as? String) == "symlink_refused"
            }),
            "expected cold_root_pin_file_check_failed:symlink_refused; got \(events)"
        )
    }

    // R11f F-D03 — pin file with wrong mode (e.g. 0644) must be refused even
    // if content is structurally valid. Closes the second wall around F-C01.
    func test_APT_C01_f_pin_file_wrong_mode_rejected() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        NativeColdRootPin.unsealForTest(env: ProcessInfo.processInfo.environment)

        let validKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: f.pinFilePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try writePinFile(validKey, at: f.pinFilePath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: f.pinFilePath)

        var threw = false
        do {
            _ = try NativeColdRootPin.loadPinnedColdRootPublicKey(env: ProcessInfo.processInfo.environment)
        } catch let e as NativeColdRootPinError {
            threw = true
            switch e {
            case .pinFileMalformed(_, let reason):
                XCTAssertTrue(reason.contains("mode_mismatch"),
                              "expected mode_mismatch reason, got: \(reason)")
            default:
                XCTFail("expected .pinFileMalformed, got \(e)")
            }
        }
        XCTAssertTrue(threw, "loadPinnedColdRootPublicKey must throw on wrong mode")

        let events = try readAuditEvents(f)
        XCTAssertTrue(
            events.contains(where: { ev in
                (ev["event"] as? String) == "cold_root_pin_file_check_failed"
                    && (ev["reason"] as? String) == "mode_mismatch"
            }),
            "expected cold_root_pin_file_check_failed:mode_mismatch; got \(events)"
        )
    }

    // R11f F-D03 — uid mismatch path. Fault-injection of st_uid in a unit
    // test is impractical without sudo (cannot chown to a different uid).
    // The mechanism is exercised at fstat-call-time identically to the mode
    // check; manual verification: chown root pin_file && run as operator
    // reproduces uid_mismatch audit + throw. Documented here per R11f gate.
    func test_APT_C01_g_pin_file_wrong_uid_rejected() throws {
        throw XCTSkip("uid fault-injection requires sudo; mechanism verified via inline read of NativeColdRootPin.swift:140-150, mirror of mode check at lines 156-166. Operator-side manual repro: chown root ~/.jarvis/identity/cold_root_public.key && cockpit boot → cold_root_pin_file_check_failed:uid_mismatch audit + .pinFileMalformed throw.")
    }

    // ================================================================
    // F-C02 — env-override gating (compile-flag behavior)
    // ================================================================

    /// In a build configuration WITHOUT -D JARVIS_INSECURE_PATHS the test
    /// target's swiftSettings wouldn't define the flag, and env overrides
    /// would be ignored. The test target DOES define the flag, so this test
    /// body is compiled-out under the test build. The test body is preserved
    /// for the audit trail and would execute if anyone removed the flag —
    /// at which point this test would prove env overrides are inert.
    func test_APT_C02_a_env_overrides_ignored_when_flag_absent() throws {
        #if JARVIS_INSECURE_PATHS
        throw XCTSkip("Test target compiled with JARVIS_INSECURE_PATHS — body verifies behavior when flag is absent. Drop the flag from Package.swift to exercise.")
        #else
        // This branch executes only if the test target is built without the
        // flag — currently it is built WITH the flag, so this code is dead
        // by design under the standard configuration. Compiled-in for the
        // audit trail (anti-lie: assertion of intent in code, not docstring).
        setenv("JARVIS_BIRTH_CERT_PATH", "/tmp/attacker.json", 1)
        defer { unsetenv("JARVIS_BIRTH_CERT_PATH") }
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertFalse(result.path.hasPrefix("/tmp/"),
                       "Without JARVIS_INSECURE_PATHS, env override must be ignored. path=\(result.path)")
        #endif
    }

    func test_APT_C02_b_debug_flag_override_emits_audit() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        NativeInsecurePathOverride.resetEmissionsForTest()

        // Seed pin so the verify path reaches the resolve() call. The pin file
        // path is itself overridden, so the resolve() call fires the audit.
        let coldRoot = Curve25519.Signing.PrivateKey()
        try writePinFile(coldRoot.publicKey.rawRepresentation, at: f.pinFilePath)
        let bc = mintBC(signingKey: coldRoot,
                        inCertColdRoot: coldRoot.publicKey.rawRepresentation,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        _ = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)

        let events = readAuditEvents(f)
        let overrideRecords = events.filter { ($0["event"] as? String) == "insecure_path_override_active" }
        XCTAssertFalse(overrideRecords.isEmpty,
                       "Override consumption must emit insecure_path_override_active. events=\(events.map { $0["event"] ?? "?" })")
        let vars = Set(overrideRecords.compactMap { $0["var"] as? String })
        XCTAssertTrue(vars.contains("JARVIS_COLD_ROOT_PIN_FILE"),
                      "At least the pin-file override must be recorded. vars=\(vars)")
    }

    func test_APT_C02_c_override_audit_is_one_shot_per_var() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        NativeInsecurePathOverride.resetEmissionsForTest()

        // Seed pin and BC.
        let coldRoot = Curve25519.Signing.PrivateKey()
        try writePinFile(coldRoot.publicKey.rawRepresentation, at: f.pinFilePath)
        let bc = mintBC(signingKey: coldRoot,
                        inCertColdRoot: coldRoot.publicKey.rawRepresentation,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        // Three verify() calls — should produce exactly ONE
        // insecure_path_override_active for JARVIS_COLD_ROOT_PIN_FILE.
        _ = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)
        _ = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)
        _ = NativeBirthCertificateVerifier.verify(env: ProcessInfo.processInfo.environment)

        let events = readAuditEvents(f)
        let pinFileEmissions = events.filter {
            ($0["event"] as? String) == "insecure_path_override_active" &&
            ($0["var"] as? String) == "JARVIS_COLD_ROOT_PIN_FILE"
        }
        XCTAssertEqual(pinFileEmissions.count, 1,
                       "One-shot emission per (envVar, value) — got \(pinFileEmissions.count) for JARVIS_COLD_ROOT_PIN_FILE")
    }

    // ================================================================
    // F-C03 — tamper-evident audit hash chain
    // ================================================================

    func test_APT_C03_a_chain_genesis_record_has_zero_prev_and_seq_1() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        try NativeSecurityAudit.record("chain_test_event_a", fields: ["k": "v"])

        let events = readAuditEvents(f)
        XCTAssertEqual(events.count, 1, "Expected exactly one record")
        let rec = events[0]
        XCTAssertEqual(rec["event"] as? String, "chain_test_event_a")
        XCTAssertEqual(rec["seq"] as? Int, 1, "Genesis record must have seq=1")
        XCTAssertEqual(rec["prev_sha"] as? String, String(repeating: "0", count: 64),
                       "Genesis prev_sha must be 64 zeros")
        let sha = rec["sha"] as? String ?? ""
        XCTAssertEqual(sha.count, 64, "sha must be 64 hex chars")
        XCTAssertFalse(sha.isEmpty)
    }

    func test_APT_C03_b_chain_links_across_records() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        try NativeSecurityAudit.record("evt_one", fields: ["a": "1"])
        try NativeSecurityAudit.record("evt_two", fields: ["a": "2"])
        try NativeSecurityAudit.record("evt_three", fields: ["a": "3"])

        let events = readAuditEvents(f)
        XCTAssertEqual(events.count, 3, "Expected three records")
        XCTAssertEqual(events[0]["seq"] as? Int, 1)
        XCTAssertEqual(events[1]["seq"] as? Int, 2)
        XCTAssertEqual(events[2]["seq"] as? Int, 3)
        XCTAssertEqual(events[1]["prev_sha"] as? String, events[0]["sha"] as? String,
                       "record 2 prev_sha must equal record 1 sha")
        XCTAssertEqual(events[2]["prev_sha"] as? String, events[1]["sha"] as? String,
                       "record 3 prev_sha must equal record 2 sha")
    }

    func test_APT_C03_c_verifier_tool_accepts_valid_chain_rejects_tamper() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        try NativeSecurityAudit.record("verify_evt_one", fields: ["k": "alpha"])
        try NativeSecurityAudit.record("verify_evt_two", fields: ["k": "beta"])
        try NativeSecurityAudit.record("verify_evt_three", fields: ["k": "gamma"])

        // Build the verifier tool (idempotent if already built) and run it
        // against the audit file. Path is the test's hermetic audit root.
        let auditFile = f.auditDir.appendingPathComponent("network_security.jsonl").path

        // Resolve binary path: SwiftPM puts executables under
        // <pkg>/.build/<triple>/debug/<name>. Use `swift build --show-bin-path`
        // — invariant across triple + config.
        let binDir = try resolveSwiftPMBinPath()
        let toolPath = binDir.appendingPathComponent("jarvis-audit-verify-swift").path

        // Acceptance run.
        let okResult = runProcess(executable: toolPath, args: [auditFile])
        XCTAssertEqual(okResult.exitCode, 0,
                       "verifier must accept untampered chain. stdout=\(okResult.stdout) stderr=\(okResult.stderr)")
        XCTAssertTrue(okResult.stdout.contains("audit chain valid"),
                      "stdout=\(okResult.stdout)")

        // Tamper: flip one character in the second record's `k` value.
        let raw = try String(contentsOfFile: auditFile, encoding: .utf8)
        let tampered = raw.replacingOccurrences(of: "\"beta\"", with: "\"BETA\"")
        XCTAssertNotEqual(raw, tampered, "tamper must actually change file")
        // R11l α.3 B.1: clear UF_APPEND to simulate the in-threat-model attacker
        // who has uid=operator and can clear an owner-clearable flag. Documents
        // honestly that UF_APPEND is defense-in-depth, NOT primary control.
        _ = chflags(auditFile, 0)
        try tampered.write(toFile: auditFile, atomically: true, encoding: String.Encoding.utf8)

        let badResult = runProcess(executable: toolPath, args: [auditFile])
        XCTAssertEqual(badResult.exitCode, 1,
                       "verifier must reject tampered chain. stdout=\(badResult.stdout) stderr=\(badResult.stderr)")
        XCTAssertTrue(badResult.stderr.contains("sha mismatch") || badResult.stderr.contains("prev_sha"),
                      "stderr must explain mismatch. stderr=\(badResult.stderr)")
    }

    // R11f F-D01: anchor-aware verifier must REJECT a chain that contains
    // zero boot anchors. Simulates total-rewrite scenario where an attacker
    // with file-write replaces the chain with their own internally-consistent
    // sequence (no anchors, because they lack the aux signing key).
    func test_APT_C03_d_anchor_aware_rejects_chain_with_no_anchors() throws {
        let f = try makeFixture()
        defer {
            unsetEnvForFixture(f)
            NativeAuditChainAnchor.unsealAuxForTest(env: ProcessInfo.processInfo.environment)
        }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let aux = Curve25519.Signing.PrivateKey()
        let auxCert = try NativeAuditChainAnchor.mintAuxCertificate(
            auxPublicKey: aux.publicKey,
            validFrom: Int(Date().timeIntervalSince1970) - 60,
            validUntil: Int(Date().timeIntervalSince1970) + 3600,
            coldRootSigningKey: coldRoot
        )
        XCTAssertTrue(NativeAuditChainAnchor.sealAuxForTest(privateKey: aux, certificate: auxCert),
                      "sealAuxForTest must succeed")

        // Write a few audit events but NO anchor.
        try NativeSecurityAudit.record("attacker_evt_one", fields: ["k": "alpha"])
        try NativeSecurityAudit.record("attacker_evt_two", fields: ["k": "beta"])

        let auditFile = f.auditDir.appendingPathComponent("network_security.jsonl").path
        let binDir = try resolveSwiftPMBinPath()
        let toolPath = binDir.appendingPathComponent("jarvis-audit-verify-swift").path

        // Plain mode: passes (chain is internally consistent).
        let okPlain = runProcess(executable: toolPath, args: [auditFile])
        XCTAssertEqual(okPlain.exitCode, 0,
                       "plain mode must accept internally-consistent chain. stderr=\(okPlain.stderr)")

        // Anchor-aware mode: rejects because no anchor records were minted.
        let coldRootHex = coldRoot.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let certPath = f.root.appendingPathComponent("aux_cert_for_test.json").path
        try auxCert.write(to: URL(fileURLWithPath: certPath))

        let badResult = runProcess(
            executable: toolPath,
            args: [auditFile,
                   "--cold-root-pubkey-hex", coldRootHex,
                   "--aux-cert-path", certPath]
        )
        XCTAssertEqual(badResult.exitCode, 1,
                       "anchor-aware mode must reject chain with no anchors. stdout=\(badResult.stdout) stderr=\(badResult.stderr)")
        XCTAssertTrue(badResult.stderr.contains("no boot anchors"),
                      "stderr must explain missing anchors. stderr=\(badResult.stderr)")
    }

    // R11f F-D01: anchor-aware verifier must REJECT an anchor record signed
    // by a key other than the cert's aux pubkey. Simulates an attacker who
    // observed the anchor record format and tries to mint their own.
    func test_APT_C03_e_anchor_aware_rejects_anchor_signed_by_wrong_key() throws {
        let f = try makeFixture()
        defer {
            unsetEnvForFixture(f)
            NativeAuditChainAnchor.unsealAuxForTest(env: ProcessInfo.processInfo.environment)
        }
        setEnvForFixture(f)

        // Honest aux + cert.
        let coldRoot = Curve25519.Signing.PrivateKey()
        let aux = Curve25519.Signing.PrivateKey()
        let auxCert = try NativeAuditChainAnchor.mintAuxCertificate(
            auxPublicKey: aux.publicKey,
            validFrom: Int(Date().timeIntervalSince1970) - 60,
            validUntil: Int(Date().timeIntervalSince1970) + 3600,
            coldRootSigningKey: coldRoot
        )

        // Seal ATTACKER aux key in Keychain (different key than what the
        // cert authorizes). When sealBootAnchor is called, it will sign with
        // the attacker key — the verifier with the honest cert must reject.
        let attackerAux = Curve25519.Signing.PrivateKey()
        XCTAssertTrue(NativeAuditChainAnchor.sealAuxForTest(privateKey: attackerAux, certificate: auxCert),
                      "sealAuxForTest must succeed")

        try NativeSecurityAudit.record("setup_evt", fields: ["k": "alpha"])
        // sealBootAnchor signs with the attacker key (currently in Keychain).
        try NativeAuditChainAnchor.sealBootAnchor(env: ProcessInfo.processInfo.environment)

        let auditFile = f.auditDir.appendingPathComponent("network_security.jsonl").path
        let binDir = try resolveSwiftPMBinPath()
        let toolPath = binDir.appendingPathComponent("jarvis-audit-verify-swift").path
        let coldRootHex = coldRoot.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let certPath = f.root.appendingPathComponent("aux_cert_for_test.json").path
        try auxCert.write(to: URL(fileURLWithPath: certPath))

        let badResult = runProcess(
            executable: toolPath,
            args: [auditFile,
                   "--cold-root-pubkey-hex", coldRootHex,
                   "--aux-cert-path", certPath]
        )
        XCTAssertEqual(badResult.exitCode, 1,
                       "verifier must reject anchor signed by wrong key. stdout=\(badResult.stdout) stderr=\(badResult.stderr)")
        XCTAssertTrue(badResult.stderr.contains("anchor_signature_hex verification failed"),
                      "stderr must explain signature failure. stderr=\(badResult.stderr)")
    }

    // R11f F-D01: anchor-aware verifier must accept a properly-signed anchor
    // AND detect replay/position-binding attacks where an attacker carries
    // forward an old anchor record into a rewritten chain (prev_chain_tail_sha
    // ≠ recorded prev_sha at the new position).
    func test_APT_C03_f_anchor_aware_accepts_valid_chain_and_detects_replay() throws {
        let f = try makeFixture()
        defer {
            unsetEnvForFixture(f)
            NativeAuditChainAnchor.unsealAuxForTest(env: ProcessInfo.processInfo.environment)
        }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let aux = Curve25519.Signing.PrivateKey()
        let auxCert = try NativeAuditChainAnchor.mintAuxCertificate(
            auxPublicKey: aux.publicKey,
            validFrom: Int(Date().timeIntervalSince1970) - 60,
            validUntil: Int(Date().timeIntervalSince1970) + 3600,
            coldRootSigningKey: coldRoot
        )
        XCTAssertTrue(NativeAuditChainAnchor.sealAuxForTest(privateKey: aux, certificate: auxCert),
                      "sealAuxForTest must succeed")

        try NativeSecurityAudit.record("boot_evt_one", fields: ["k": "alpha"])
        try NativeAuditChainAnchor.sealBootAnchor(env: ProcessInfo.processInfo.environment)
        try NativeSecurityAudit.record("post_anchor_evt", fields: ["k": "gamma"])

        let auditFile = f.auditDir.appendingPathComponent("network_security.jsonl").path
        let binDir = try resolveSwiftPMBinPath()
        let toolPath = binDir.appendingPathComponent("jarvis-audit-verify-swift").path
        let coldRootHex = coldRoot.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let certPath = f.root.appendingPathComponent("aux_cert_for_test.json").path
        try auxCert.write(to: URL(fileURLWithPath: certPath))

        // Acceptance.
        let okResult = runProcess(
            executable: toolPath,
            args: [auditFile,
                   "--cold-root-pubkey-hex", coldRootHex,
                   "--aux-cert-path", certPath]
        )
        XCTAssertEqual(okResult.exitCode, 0,
                       "verifier must accept valid anchor-aware chain. stderr=\(okResult.stderr)")
        XCTAssertTrue(okResult.stdout.contains("anchor"),
                      "stdout must mention anchor count. stdout=\(okResult.stdout)")

        // Replay attack: attacker takes the existing anchor record, builds
        // a SHORTER chain where the anchor sits at seq=1 (no prior events).
        // Since the original signed prev_chain_tail_sha was over the real
        // seq=2 prev_sha, the position binding check must reject.
        let rawText = try String(contentsOfFile: auditFile, encoding: .utf8)
        let originalLines = rawText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertTrue(originalLines.count >= 2)
        // Find the anchor line in the original chain.
        guard let anchorLine = originalLines.first(where: {
            ($0.contains("\"audit_chain_boot_anchor\""))
        }) else {
            XCTFail("no anchor record found in fixture chain"); return
        }
        // Rewrite chain to: just the anchor, but renumbered to seq=1 with
        // genesis prev_sha. The signed prev_chain_tail_sha will not match.
        guard var parsed = try JSONSerialization.jsonObject(with: Data(anchorLine.utf8)) as? [String: Any] else {
            XCTFail("could not parse anchor"); return
        }
        parsed["seq"] = 1
        parsed["prev_sha"] = String(repeating: "0", count: 64)
        // Recompute sha for the rewritten record so the chain is internally
        // valid — the only thing wrong is the position binding.
        var withoutSha = parsed
        withoutSha.removeValue(forKey: "sha")
        let preShaData = try JSONSerialization.data(withJSONObject: withoutSha, options: [.sortedKeys])
        let newSha = SHA256.hash(data: preShaData).map { String(format: "%02x", $0) }.joined()
        parsed["sha"] = newSha
        let rewrittenLine = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
        var rewrittenChain = Data()
        rewrittenChain.append(rewrittenLine)
        rewrittenChain.append(0x0A)
        // R11l α.3 B.1: clear UF_APPEND before attacker-simulated rewrite (see C03_c).
        _ = chflags(auditFile, 0)
        try rewrittenChain.write(to: URL(fileURLWithPath: auditFile))

        let replayResult = runProcess(
            executable: toolPath,
            args: [auditFile,
                   "--cold-root-pubkey-hex", coldRootHex,
                   "--aux-cert-path", certPath]
        )
        XCTAssertEqual(replayResult.exitCode, 1,
                       "verifier must detect replayed anchor at wrong chain position. stdout=\(replayResult.stdout) stderr=\(replayResult.stderr)")
        XCTAssertTrue(replayResult.stderr.contains("prev_chain_tail_sha")
                       || replayResult.stderr.contains("anchor_signature_hex verification failed"),
                      "stderr must explain anchor binding failure. stderr=\(replayResult.stderr)")
    }

    // MARK: F-C03 helpers

    private func resolveSwiftPMBinPath() throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", "build", "--show-bin-path"]
        // Run from the package directory — assume tests execute in a CWD
        // somewhere inside .build/<triple>/debug; walk up to find Package.swift.
        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while cwd.path != "/" && !FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            cwd.deleteLastPathComponent()
        }
        if !FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            // Fallback to the known absolute path for this repo.
            cwd = URL(fileURLWithPath: "/Users/rbhanson/research/jarvis/apple_native/JARVISMacCockpit")
        }
        p.currentDirectoryURL = cwd
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let line = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: line)
    }

    private func runProcess(executable: String, args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return (-1, "", "spawn failed: \(error)")
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    // ================================================================
    // F-C04 — adjacent signed mlpackage manifest
    // ================================================================

    func test_APT_C04_a_matching_manifest_verifies() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootHex = coldRoot.publicKey.rawRepresentation.hexString
        let pkgDir = try makeFakeMLPackage(under: f.root, name: "voice_state.mlpackage", contents: [
            "Manifest.json": "{\"v\":1}",
            "Data/payload.bin": "alpha-payload-bytes"
        ])
        try mintAndWriteManifest(
            f: f,
            coldRoot: coldRoot,
            mlpackages: [pkgDir.path: try NativeMLPackageManifest.computeTreeHash(at: pkgDir)]
        )

        let result = NativeMLPackageManifest.verify(coldRootPublicKeyHex: coldRootHex,
                                                    env: ProcessInfo.processInfo.environment)
        if case .verified(let n) = result {
            XCTAssertEqual(n, 1)
        } else {
            XCTFail("expected .verified, got \(result)")
        }
    }

    func test_APT_C04_b_tampered_mlpackage_fails() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootHex = coldRoot.publicKey.rawRepresentation.hexString
        let pkgDir = try makeFakeMLPackage(under: f.root, name: "voice_state.mlpackage", contents: [
            "Manifest.json": "{\"v\":1}",
            "Data/payload.bin": "alpha-payload-bytes"
        ])
        try mintAndWriteManifest(
            f: f,
            coldRoot: coldRoot,
            mlpackages: [pkgDir.path: try NativeMLPackageManifest.computeTreeHash(at: pkgDir)]
        )

        // Tamper: flip a byte in the payload after the manifest was signed.
        let payloadURL = pkgDir.appendingPathComponent("Data/payload.bin")
        try "TAMPERED-payload-bytes".write(to: payloadURL, atomically: true, encoding: String.Encoding.utf8)

        let result = NativeMLPackageManifest.verify(coldRootPublicKeyHex: coldRootHex,
                                                    env: ProcessInfo.processInfo.environment)
        if case .hashMismatch(let pkg, let exp, let act) = result {
            XCTAssertEqual(pkg, pkgDir.path)
            XCTAssertNotEqual(exp, act)
        } else {
            XCTFail("expected .hashMismatch, got \(result)")
        }
    }

    func test_APT_C04_c_legacy_no_manifest_returns_absent() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        // No manifest minted. Override manifest path to a known-missing file
        // inside the fixture so the test is hermetic.
        let manifestPath = f.root.appendingPathComponent("identity/mlpackage_manifest.json").path
        setenv("JARVIS_MLPACKAGE_MANIFEST_PATH", manifestPath, 1)
        defer { unsetenv("JARVIS_MLPACKAGE_MANIFEST_PATH") }

        let coldRootHex = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.hexString
        let result = NativeMLPackageManifest.verify(coldRootPublicKeyHex: coldRootHex,
                                                    env: ProcessInfo.processInfo.environment)
        if case .absent(let path) = result {
            XCTAssertEqual(path, manifestPath)
        } else {
            XCTFail("expected .absent, got \(result)")
        }
    }

    func test_APT_C04_d_signature_with_wrong_cold_root_fails() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let signingKey = Curve25519.Signing.PrivateKey()
        let pkgDir = try makeFakeMLPackage(under: f.root, name: "voice_state.mlpackage", contents: [
            "Data/payload.bin": "alpha-payload-bytes"
        ])
        try mintAndWriteManifest(
            f: f,
            coldRoot: signingKey,
            mlpackages: [pkgDir.path: try NativeMLPackageManifest.computeTreeHash(at: pkgDir)]
        )

        // Attempt to verify with a DIFFERENT cold root pubkey.
        let wrongHex = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.hexString
        let result = NativeMLPackageManifest.verify(coldRootPublicKeyHex: wrongHex,
                                                    env: ProcessInfo.processInfo.environment)
        if case .invalidSignature = result { /* expected */ } else {
            XCTFail("expected .invalidSignature, got \(result)")
        }
    }

    // MARK: F-C04 helpers

    private func makeFakeMLPackage(under root: URL, name: String, contents: [String: String]) throws -> URL {
        let dir = root.appendingPathComponent("mlpackages/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (relPath, body) in contents {
            let fullURL = dir.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(at: fullURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try body.write(to: fullURL, atomically: true, encoding: String.Encoding.utf8)
        }
        return dir
    }

    private func mintAndWriteManifest(
        f: Fixture,
        coldRoot: Curve25519.Signing.PrivateKey,
        mlpackages: [String: String]
    ) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let machineUUID = currentMachineUUID()
        let mapString = NativeMLPackageManifest.canonicalizeMLPackageMap(mlpackages)
        let canonical = NativeMLPackageManifest.canonicalPayloadString(
            machineUUID: machineUUID,
            mlpackageSHA256HexString: mapString,
            timestamp: timestamp,
            version: NativeMLPackageManifest.manifestVersionString
        )
        let signature = try coldRoot.signature(for: Data(canonical.utf8))
        let signatureHex = signature.hexString

        // Write the manifest JSON with all fields including signature_hex.
        var fields: [String: String] = [
            "machine_uuid": machineUUID,
            "mlpackage_sha256_hex": mapString,
            "signature_hex": signatureHex,
            "timestamp": timestamp,
            "v": NativeMLPackageManifest.manifestVersionString,
        ]
        let body = fields.keys.sorted().map { key in
            "\"\(jsonEscape(key))\":\"\(jsonEscape(fields[key] ?? ""))\""
        }.joined(separator: ",")
        let json = "{" + body + "}"
        let manifestPath = f.root.appendingPathComponent("identity/mlpackage_manifest.json").path
        setenv("JARVIS_MLPACKAGE_MANIFEST_PATH", manifestPath, 1)
        try json.write(toFile: manifestPath, atomically: true, encoding: String.Encoding.utf8)
    }

    private func jsonEscape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// ================================================================
// F-C05 — operator.txt fstat mode/uid
// ================================================================

extension APTRedTeamTests {
    func test_APT_C05_a_wrong_mode_falls_back() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let path = f.root.appendingPathComponent("identity/operator.txt").path
        setenv("JARVIS_OPERATOR_TXT_PATH", path, 1)
        defer { unsetenv("JARVIS_OPERATOR_TXT_PATH") }

        try "Grizzly".write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
        // World-readable: 0644.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)

        let name = OperatorPresence.readOperatorName(env: ProcessInfo.processInfo.environment)
        XCTAssertEqual(name, OperatorPresence.fallback)

        // Verify audit emission.
        let events = try readAuditEvents(f)
        XCTAssertTrue(events.contains(where: { ($0["event"] as? String) == "operator_presence_mode_check_failed" }),
                      "expected operator_presence_mode_check_failed audit; got \(events)")
    }

    func test_APT_C05_b_correct_mode_reads_name() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let path = f.root.appendingPathComponent("identity/operator.txt").path
        setenv("JARVIS_OPERATOR_TXT_PATH", path, 1)
        defer { unsetenv("JARVIS_OPERATOR_TXT_PATH") }

        try "Grizzly".write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let name = OperatorPresence.readOperatorName(env: ProcessInfo.processInfo.environment)
        XCTAssertEqual(name, "Grizzly")
    }

    // MARK: - F-E32 sealAuxForTest release-gate (R11h P1)

    /// F-E32: NativeAuditChainAnchor.sealAuxForTest is asymmetric to its
    /// sibling unsealAuxForTest — the latter is wrapped in
    /// `#if DEBUG && JARVIS_INSECURE_PATHS` but the former was not. This
    /// test target ALWAYS compiles with that define set (Package.swift
    /// .define("JARVIS_INSECURE_PATHS", .when(configuration: .debug))),
    /// so we cannot exercise the release branch from this XCTest binary.
    /// Instead we structurally assert the protective gate exists in the
    /// source file. A refactor that removes the `#else return false`
    /// branch fails this test. The release binary's actual no-op is
    /// what the gate produces; this test pins that the gate is not
    /// silently deleted.
    func test_F_E32_sealAuxForTest_release_gate_present_in_source() throws {
        // #file under SwiftPM may be a relative-style path. Walk parents
        // until we find the sibling JARVISMacCockpitService directory.
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var srcURL: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(
                "JARVISMacCockpitService/NativeAuditChainAnchor.swift"
            )
            if FileManager.default.fileExists(atPath: candidate.path) {
                srcURL = candidate
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        guard let url = srcURL else {
            XCTFail("F-E32: could not locate NativeAuditChainAnchor.swift from #file=\(#file)")
            return
        }
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(src.contains("F-E32"),
                      "F-E32 gate must remain documented in source")
        let pattern = #"static func sealAuxForTest[\s\S]{0,4000}#if DEBUG && JARVIS_INSECURE_PATHS[\s\S]{0,4000}#else[\s\S]{0,400}return false[\s\S]{0,200}#endif"#
        XCTAssertNotNil(src.range(of: pattern, options: .regularExpression),
                        "F-E32: sealAuxForTest body must be gated #if DEBUG && JARVIS_INSECURE_PATHS / #else return false / #endif")
    }

    /// Companion: under the test build (DEBUG+INSECURE), sealAuxForTest
    /// still functions for the existing F-D01 round-trip tests. This
    /// pins that Patch 1 did not regress the in-gate path.
    func test_F_E32_sealAuxForTest_debug_insecure_still_writes_keychain() throws {
        let f = try makeFixture()
        defer {
            unsetEnvForFixture(f)
            NativeAuditChainAnchor.unsealAuxForTest(env: ProcessInfo.processInfo.environment)
        }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let aux = Curve25519.Signing.PrivateKey()
        let auxCert = try NativeAuditChainAnchor.mintAuxCertificate(
            auxPublicKey: aux.publicKey,
            validFrom: 0,
            validUntil: Int(Date().timeIntervalSince1970) + 86400,
            coldRootSigningKey: coldRoot
        )
        XCTAssertTrue(
            NativeAuditChainAnchor.sealAuxForTest(privateKey: aux, certificate: auxCert),
            "DEBUG+JARVIS_INSECURE_PATHS build must still honour sealAuxForTest after F-E32 gate"
        )
    }

    // MARK: - F-E20 operator duress detection (R11h P2)

    /// Shared helper: write a 0600 file with given UTF-8 content.
    @discardableResult
    private func writeIdentityFile(_ path: String, contents: String) throws -> String {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: path)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }

    private func setOperatorEnvPaths(_ f: Fixture) -> (operator: String, duress: String) {
        let opPath = f.identityDir.appendingPathComponent("operator.txt").path
        let duPath = f.identityDir.appendingPathComponent("operator_duress.txt").path
        setenv("JARVIS_OPERATOR_TXT_PATH", opPath, 1)
        setenv("JARVIS_OPERATOR_DURESS_TXT_PATH", duPath, 1)
        return (opPath, duPath)
    }

    private func unsetOperatorEnvPaths() {
        unsetenv("JARVIS_OPERATOR_TXT_PATH")
        unsetenv("JARVIS_OPERATOR_DURESS_TXT_PATH")
    }

    func test_F_E20_canonical_matches_emits_canonical_audit() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)
        try writeIdentityFile(paths.operator, contents: "Grizzly")
        try writeIdentityFile(paths.duress, contents: "Sentinel")

        let result = OperatorPresence.match()
        XCTAssertEqual(result, .canonical)

        let events = readAuditEvents(f)
        XCTAssertTrue(events.contains(where: { ($0["event"] as? String) == "operator_presence_canonical" }),
                      "expected operator_presence_canonical; got \(events.map { $0["event"] ?? "?" })")
        XCTAssertFalse(events.contains(where: { ($0["event"] as? String) == "operator_presence_duress" }))
    }

    func test_F_E20_duress_matches_emits_duress_audit_continues_boot() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)
        // The coerced-provisioning scenario: operator types duress alias
        // into operator.txt; cockpit detects equality with operator_duress.txt.
        try writeIdentityFile(paths.operator, contents: "Sentinel")
        try writeIdentityFile(paths.duress, contents: "Sentinel")

        let result = OperatorPresence.match()
        XCTAssertEqual(result, .duress)

        // R11j F-F02 — the duress branch now emits the SAME event name
        // as the canonical branch (`operator_presence_canonical`).
        // Audit chain visible to attacker reveals nothing about which
        // boots were under duress without the duress salt. The
        // discriminator is `digest_b64`, an HMAC-SHA256 prefix.
        let events = readAuditEvents(f)
        XCTAssertFalse(events.contains(where: {
            ($0["event"] as? String) == "operator_presence_duress"
        }), "R11j F-F02: legacy operator_presence_duress event MUST NOT appear (steganography break)")
        XCTAssertTrue(events.contains(where: {
            ($0["event"] as? String) == "operator_presence_canonical"
        }), "expected operator_presence_canonical event (duress hidden); got \(events)")
    }

    func test_F_E20_neither_matches_returns_none_audits_mismatch() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)
        // operator.txt does not exist at all → readAndValidate returns nil.
        try? FileManager.default.removeItem(atPath: paths.operator)
        try? FileManager.default.removeItem(atPath: paths.duress)

        let result = OperatorPresence.match()
        XCTAssertEqual(result, .none)

        let events = readAuditEvents(f)
        XCTAssertTrue(events.contains(where: { ($0["event"] as? String) == "operator_presence_mismatch" }))
    }

    func test_F_E20_duress_file_absent_falls_back_to_canonical_only() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)
        try writeIdentityFile(paths.operator, contents: "Grizzly")
        // operator_duress.txt absent → canonical-only behavior.
        try? FileManager.default.removeItem(atPath: paths.duress)

        let result = OperatorPresence.match()
        XCTAssertEqual(result, .canonical)
    }

    func test_F_E20_duress_file_world_readable_treated_as_absent() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)
        try writeIdentityFile(paths.operator, contents: "Sentinel")
        try writeIdentityFile(paths.duress, contents: "Sentinel")
        // Corrupt the duress file's mode → readAndValidate must refuse it.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.duress)

        let result = OperatorPresence.match()
        // operator.txt content == "Sentinel" but duress file rejected →
        // duress check sees no valid duress phrase → canonical branch.
        XCTAssertEqual(result, .canonical,
                       "world-readable duress file must be treated as absent; cockpit cannot trust its content")

        let events = readAuditEvents(f)
        XCTAssertTrue(events.contains(where: {
            let ev = $0["event"] as? String ?? ""
            let reason = ($0["reason"] as? String) ?? ""
            return ev == "operator_presence_mode_check_failed" && reason.contains("mode_mismatch")
        }), "expected mode_mismatch audit on duress file; got \(events)")
    }

    func test_F_E20_duress_file_symlink_rejected() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)
        try writeIdentityFile(paths.operator, contents: "Sentinel")

        // Create operator_duress.txt as a symlink to a real-but-different file.
        let realTarget = f.identityDir.appendingPathComponent("real_duress.txt").path
        try writeIdentityFile(realTarget, contents: "Sentinel")
        try? FileManager.default.removeItem(atPath: paths.duress)
        try FileManager.default.createSymbolicLink(atPath: paths.duress, withDestinationPath: realTarget)

        let result = OperatorPresence.match()
        // Symlink rejected via O_NOFOLLOW → duress file effectively absent →
        // canonical branch.
        XCTAssertEqual(result, .canonical,
                       "symlinked duress file must be refused by O_NOFOLLOW; canonical branch follows")
    }

    // MARK: - F-F02: R11j duress steganography (audit indistinguishability)

    /// F-F02 — both branches emit operator_presence_canonical with
    /// structurally identical field set. The only differentiator is
    /// `digest_b64`, which requires the duress salt to interpret.
    func test_F_F02_duress_emits_canonical_event_structurally_identical() throws {
        let f = try makeFixture()
        defer { unsetOperatorEnvPaths(); unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let paths = setOperatorEnvPaths(f)

        // Provision public salt in env (no BC integration in this test).
        let publicSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let duressSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let duressSaltPath = f.identityDir.appendingPathComponent(
            "operator_presence_duress_salt.bin").path
        try duressSalt.write(to: URL(fileURLWithPath: duressSaltPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: duressSaltPath)

        // Case A: canonical.
        try writeIdentityFile(paths.operator, contents: "Grizzly")
        try writeIdentityFile(paths.duress, contents: "Sentinel")
        let resA = OperatorPresence.match(
            publicSaltB64: publicSalt.base64EncodedString(),
            duressSaltPath: duressSaltPath
        )
        XCTAssertEqual(resA, .canonical)

        // Case B: duress.
        try writeIdentityFile(paths.operator, contents: "Sentinel")
        let resB = OperatorPresence.match(
            publicSaltB64: publicSalt.base64EncodedString(),
            duressSaltPath: duressSaltPath
        )
        XCTAssertEqual(resB, .duress)

        let events = readAuditEvents(f)
        let presence = events.filter {
            ($0["event"] as? String) == "operator_presence_canonical"
        }
        XCTAssertGreaterThanOrEqual(presence.count, 2,
            "both branches must emit operator_presence_canonical; got \(events)")
        // Structural equality: same field key set, both have digest_b64.
        let last2 = Array(presence.suffix(2))
        let keysA = Set(last2[0].keys).subtracting(["timestamp", "monotonic_ns"])
        let keysB = Set(last2[1].keys).subtracting(["timestamp", "monotonic_ns"])
        XCTAssertEqual(keysA, keysB,
            "field key sets must match between canonical and duress emissions: A=\(keysA) B=\(keysB)")
        XCTAssertNotNil(last2[0]["digest_b64"])
        XCTAssertNotNil(last2[1]["digest_b64"])
        // Digests must differ — same content, different salt.
        XCTAssertNotEqual(last2[0]["digest_b64"] as? String,
                          last2[1]["digest_b64"] as? String,
                          "digests must diverge between canonical+duress branches")
    }

    /// F-F02 — without the duress salt, an outside observer cannot
    /// reconstruct the digest for the duress branch, so they cannot
    /// tell a duress audit entry apart from a canonical one with a
    /// different operator-content (which is unknown to them anyway).
    func test_F_F02_audit_indistinguishable_without_duress_salt() throws {
        // This is a property of the HMAC output, not the runtime. The
        // assertion is: HMAC-SHA256(content, salt) is a PRF; given two
        // outputs (one with publicSalt, one with duressSalt), without
        // the duress salt and without the content, you cannot determine
        // which is which.
        let content = "Sentinel"
        let publicSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let duressSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let dA = OperatorPresence.hmacDigest16B64(content: content, salt: publicSalt)
        let dB = OperatorPresence.hmacDigest16B64(content: content, salt: duressSalt)
        XCTAssertEqual(dA.count, 24, "16-byte HMAC prefix → 24-char b64")  // ceil(16/3)*4
        XCTAssertEqual(dB.count, 24)
        XCTAssertNotEqual(dA, dB,
            "different salts must yield different HMAC digests for same content")
        // Symmetric: outside the cockpit, only the operator's recorded
        // forensic tool with `duressSalt` can derive dB from `content`;
        // anyone with only publicSalt + the digest cannot back out which
        // branch produced dB.
        let dAReproduced = OperatorPresence.hmacDigest16B64(content: content, salt: publicSalt)
        XCTAssertEqual(dA, dAReproduced, "HMAC must be deterministic given same inputs")
    }

    // MARK: - F-E31 witness chain in BC schema (R11h P3)

    func test_F_E31_bc_with_two_valid_witnesses_loads() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let w1 = FixtureWitness(
            name: "Jane Notary",
            role: "notary",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_000,
            jurisdiction: "Tarrant TX"
        )
        let w2 = FixtureWitness(
            name: "John Friend",
            role: "friend",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_010,
            jurisdiction: nil
        )

        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        witnesses: [w1, w2])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "BC with two valid witnesses must verify. reason=\(result.reason)")

        let events = readAuditEvents(f)
        XCTAssertTrue(events.contains(where: {
            ($0["event"] as? String) == "birth_certificate_witnesses_verified"
        }), "expected birth_certificate_witnesses_verified; got \(events.map { $0["event"] ?? "?" })")
    }

    func test_F_E31_bc_with_one_invalid_witness_rejects() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let badWitness = FixtureWitness(
            name: "Mallory",
            role: "notary",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_000,
            jurisdiction: nil
        )

        // witnessSignaturesOverrideValid=false → witness signs different bytes.
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        witnesses: [badWitness],
                        witnessSignaturesOverrideValid: false)
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "BC with invalid witness signature must reject")
        XCTAssertTrue(result.reason.contains("witness"),
                      "rejection reason must mention witness; got \(result.reason)")

        let events = readAuditEvents(f)
        XCTAssertTrue(events.contains(where: {
            ($0["event"] as? String) == "birth_certificate_witness_signature_invalid"
        }), "expected witness_signature_invalid audit; got \(events.map { $0["event"] ?? "?" })")
    }

    func test_F_E31_bc_with_zero_witnesses_loads_warns() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        // Existing fixture path: no witnesses array at all.
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "BC with zero witnesses must verify (additive backward compat). reason=\(result.reason)")

        let events = readAuditEvents(f)
        XCTAssertTrue(events.contains(where: {
            let ev = $0["event"] as? String ?? ""
            let sev = $0["severity"] as? String ?? ""
            return ev == "birth_certificate_no_witnesses" && sev == "WARN"
        }), "expected birth_certificate_no_witnesses WARN; got \(events)")
    }

    func test_F_E31_canonical_form_excludes_witnesses_array() throws {
        // Property: cold-root signature MUST verify regardless of whether
        // witnesses[] is present or absent in the JSON. Mint two BCs with
        // identical fields and signatures — one with no witnesses array, one
        // with a witness array — both must verify against the same cold root.
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        // First load: no witnesses → verified.
        let bc0 = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                         machineUUID: currentMachineUUID())
        try writeBCFixture(bc0, at: f.bcPath)
        XCTAssertEqual(NativeBirthCertificateVerifier.verify().result, .verified)

        // Second load: with one witness, all other fields identical.
        let w = FixtureWitness(
            name: "Alice",
            role: "attorney",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_000,
            jurisdiction: nil
        )
        let bc1 = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                         machineUUID: currentMachineUUID(),
                         witnesses: [w])
        try writeBCFixture(bc1, at: f.bcPath)
        XCTAssertEqual(NativeBirthCertificateVerifier.verify().result, .verified,
                       "adding witnesses must not invalidate the cold-root signature — canonical excludes witnesses")
    }

    func test_F_E31_witness_signature_tampering_detected() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let w = FixtureWitness(
            name: "Alice",
            role: "attorney",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_000,
            jurisdiction: nil
        )
        var bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        witnesses: [w])
        // Flip the witness signature's last hex byte to invalidate it.
        guard var json = try JSONSerialization.jsonObject(with: bc) as? [String: Any],
              var ws = json["witnesses"] as? [[String: Any]],
              var entry = ws.first,
              var sigHex = entry["signature_hex"] as? String, sigHex.count == 128 else {
            XCTFail("could not parse witness JSON for tamper test"); return
        }
        // Flip a byte by changing last hex char.
        let last = sigHex.last!
        sigHex.removeLast()
        sigHex.append(last == "f" ? "0" : "f")
        entry["signature_hex"] = sigHex
        ws[0] = entry
        json["witnesses"] = ws
        bc = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "tampered witness signature must reject; got \(result)")
    }

    // MARK: - F-F05: R11j TSA TSTInfo imprint+nonce binding

    /// Build a minimal-valid TimeStampResp containing a CMS SignedData
    /// wrapping a TSTInfo. Signature/certificate bytes are omitted (the
    /// parseTSTInfo path doesn't verify them — that's a separate F-E14
    /// concern). Returns DER bytes ready for parseTimeStampResp.
    private func buildTSAResponse(imprint: Data, nonce: Data?) -> Data {
        // TSTInfo DER.
        let sha256OID: [UInt8] = [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        let algoId = der_seq(Data(sha256OID) + Data([0x05, 0x00]))
        let mi = der_seq(algoId + Data([0x04, UInt8(imprint.count)]) + imprint)
        // GeneralizedTime "20260525160000Z" = 0x18 0x0F + ASCII bytes
        let gt = "20260525160000Z"
        let gtBytes = Array(gt.utf8)
        var tstInfo = Data()
        tstInfo += Data([0x02, 0x01, 0x01])  // version = 1
        tstInfo += Data([0x06, 0x03, 0x2A, 0x03, 0x04])  // policy OID 1.2.3.4
        tstInfo += mi
        tstInfo += Data([0x02, 0x01, 0x2A])  // serialNumber = 42
        tstInfo += Data([0x18, UInt8(gtBytes.count)]) + Data(gtBytes)
        if let n = nonce {
            // INTEGER nonce — prepend 0x00 if high bit set (DER signed)
            var nBytes = Array(n)
            if let first = nBytes.first, (first & 0x80) == 0x80 {
                nBytes.insert(0x00, at: 0)
            }
            tstInfo += Data([0x02, UInt8(nBytes.count)]) + Data(nBytes)
        }
        let tstInfoSeq = der_seq(tstInfo)

        // encapContentInfo SEQUENCE {
        //   OID tstInfo = 1.2.840.113549.1.9.16.1.4,
        //   [0] EXPLICIT OCTET STRING containing TSTInfo
        // }
        let tstInfoOID: [UInt8] = [0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x01, 0x04]
        let octetTST = Data([0x04]) + der_len(tstInfoSeq.count) + tstInfoSeq
        let explicit0 = Data([0xA0]) + der_len(octetTST.count) + octetTST
        let eci = der_seq(Data(tstInfoOID) + explicit0)

        // SignedData SEQUENCE {
        //   version INTEGER 3,
        //   digestAlgorithms SET {},
        //   encapContentInfo,
        //   signerInfos SET {}
        // }
        var sd = Data()
        sd += Data([0x02, 0x01, 0x03])
        sd += Data([0x31, 0x00])  // empty SET
        sd += eci
        sd += Data([0x31, 0x00])  // empty signerInfos SET
        let sdSeq = der_seq(sd)

        // ContentInfo SEQUENCE { OID signedData, [0] EXPLICIT SignedData }
        let signedDataOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        let explicit0SD = Data([0xA0]) + der_len(sdSeq.count) + sdSeq
        let ci = der_seq(Data(signedDataOID) + explicit0SD)

        // TimeStampResp SEQUENCE { PKIStatusInfo, TimeStampToken }
        let statusInfo: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x00]
        let resp = der_seq(Data(statusInfo) + ci)
        return resp
    }

    private func der_len(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func der_seq(_ inner: Data) -> Data {
        return Data([0x30]) + der_len(inner.count) + inner
    }

    func test_F_F05_tsa_token_imprint_must_match() throws {
        let imprint = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let nonce = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let resp = buildTSAResponse(imprint: imprint, nonce: nonce)
        // Sanity: matches itself.
        _ = try NativeAuditTSAClient.parseTimeStampResp(resp, expectedImprint: imprint, expectedNonce: nonce)
        // Mutated expected imprint → reject.
        var wrong = imprint
        wrong[0] ^= 0xFF
        XCTAssertThrowsError(try NativeAuditTSAClient.parseTimeStampResp(
            resp, expectedImprint: wrong, expectedNonce: nonce)) { err in
            if case NativeAuditTSAClientError.responseBindingMismatch(let r) = err {
                XCTAssertTrue(r.contains("messageImprint"), "reason must cite imprint; got: \(r)")
            } else {
                XCTFail("expected responseBindingMismatch, got \(err)")
            }
        }
    }

    func test_F_F05_tsa_token_nonce_must_match() throws {
        let imprint = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let nonce = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let resp = buildTSAResponse(imprint: imprint, nonce: nonce)
        let wrongNonce = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x09])
        XCTAssertThrowsError(try NativeAuditTSAClient.parseTimeStampResp(
            resp, expectedImprint: imprint, expectedNonce: wrongNonce)) { err in
            if case NativeAuditTSAClientError.responseBindingMismatch(let r) = err {
                XCTAssertTrue(r.contains("nonce"), "reason must cite nonce; got: \(r)")
            } else {
                XCTFail("expected responseBindingMismatch, got \(err)")
            }
        }
    }

    func test_F_F05_tsa_token_missing_nonce_rejected() throws {
        let imprint = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        // Response with NO nonce field in TSTInfo.
        let resp = buildTSAResponse(imprint: imprint, nonce: nil)
        XCTAssertThrowsError(try NativeAuditTSAClient.parseTimeStampResp(
            resp, expectedImprint: imprint, expectedNonce: Data([0x01]))) { err in
            if case NativeAuditTSAClientError.responseBindingMismatch(let r) = err {
                XCTAssertTrue(r.contains("nonce missing"),
                              "reason must cite missing nonce; got: \(r)")
            } else {
                XCTFail("expected responseBindingMismatch for missing nonce, got \(err)")
            }
        }
    }

    // MARK: - F-F10: R11j BC payload v=2 binding-hash verification

    // F-F10 P1 — verifies the 4 R11h additive fields (witnesses, OTS,
    // SBOM hash, SBOM sig) now live INSIDE the cold-root-signed
    // canonical payload via SHA-256 binding hashes. Strip / mutation
    // of any of them on disk after ceremony must reject at verify.

    /// Mint a v=2 BC with 2 witnesses then strip the entire `witnesses`
    /// field on disk. canonical payload's witnesses_root_sha256_hex is
    /// SHA-256(canonical of 2 witnesses); recompute on stripped BC
    /// gives SHA-256("[]") → mismatch → .invalidSignature.
    func test_F_F10_witness_strip_rejects_v2_bc() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let w1 = FixtureWitness(name: "Alice", role: "notary",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_000, jurisdiction: "Tarrant TX")
        let w2 = FixtureWitness(name: "Bob", role: "friend",
            signingKey: Curve25519.Signing.PrivateKey(),
            attestationTimestamp: 1_716_700_010, jurisdiction: nil)

        var bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        witnesses: [w1, w2], payloadVersion: 2)
        // Strip witnesses from the on-disk BC.
        guard var json = try JSONSerialization.jsonObject(with: bc) as? [String: Any] else {
            XCTFail("BC not JSON"); return
        }
        json.removeValue(forKey: "witnesses")
        bc = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "stripped-witnesses v=2 BC must reject; got \(result)")
        XCTAssertTrue(result.reason.contains("witnesses_root"),
                      "reason must cite witnesses_root binding; got: \(result.reason)")
    }

    /// Mint a v=2 BC with OTS receipt, strip cold_root_ots_receipt_b64
    /// on disk. Recomputed OTS binding hash = SHA-256("") ≠ canonical.
    func test_F_F10_ots_strip_rejects_v2_bc() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        var bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        otsReceiptB64: "AAECAwQFBgcICQoLDA0ODw==",
                        payloadVersion: 2)
        guard var json = try JSONSerialization.jsonObject(with: bc) as? [String: Any] else {
            XCTFail("BC not JSON"); return
        }
        json.removeValue(forKey: "cold_root_ots_receipt_b64")
        bc = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "stripped-OTS v=2 BC must reject; got \(result)")
        XCTAssertTrue(result.reason.contains("ots_receipt"),
                      "reason must cite ots_receipt binding; got: \(result.reason)")
    }

    /// Mint a v=2 BC with SBOM hash, strip sbom_sha256_hex on disk.
    func test_F_F10_sbom_hash_strip_rejects_v2_bc() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let sbomHash = String(repeating: "c", count: 64)
        var bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        sbomHashHex: sbomHash,
                        payloadVersion: 2)
        guard var json = try JSONSerialization.jsonObject(with: bc) as? [String: Any] else {
            XCTFail("BC not JSON"); return
        }
        json.removeValue(forKey: "sbom_sha256_hex")
        bc = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "stripped-SBOM-hash v=2 BC must reject; got \(result)")
        XCTAssertTrue(result.reason.contains("sbom_binding"),
                      "reason must cite sbom_binding; got: \(result.reason)")
    }

    /// Mint a v=2 BC with SBOM sig, strip sbom_cold_root_signature_hex
    /// on disk.
    func test_F_F10_sbom_sig_strip_rejects_v2_bc() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let sbomSig = String(repeating: "d", count: 128)
        var bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        sbomSignatureHex: sbomSig,
                        payloadVersion: 2)
        guard var json = try JSONSerialization.jsonObject(with: bc) as? [String: Any] else {
            XCTFail("BC not JSON"); return
        }
        json.removeValue(forKey: "sbom_cold_root_signature_hex")
        bc = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "stripped-SBOM-sig v=2 BC must reject; got \(result)")
        XCTAssertTrue(result.reason.contains("sbom_cold_root_signature"),
                      "reason must cite sbom_cold_root_signature; got: \(result.reason)")
    }

    /// Legacy v=1 BC (no payload_version field) must still verify.
    /// Backward-compat invariant.
    func test_F_F10_legacy_v1_bc_still_verifies() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        // payloadVersion: nil → v=1 path. No binding fields injected.
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "legacy v=1 BC must still verify; got \(result)")
    }

    /// v=2 BC minted with no witnesses (sentinel "[]" canonical bytes)
    /// → adding a forged witness on disk post-mint must reject.
    /// Binds the ABSENCE of witnesses.
    func test_F_F10_v2_empty_witnesses_binds_absence() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        var bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        witnesses: [],
                        payloadVersion: 2)
        // Verify clean first.
        try writeBCFixture(bc, at: f.bcPath)
        let pre = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(pre.result, .verified, "clean v=2 BC must verify; got \(pre)")

        // Now inject a forged witness on disk. Attacker controls the
        // signing key; binding-hash recompute should reject.
        let attackerKey = Curve25519.Signing.PrivateKey()
        let attackerPubHex = attackerKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        guard var json = try JSONSerialization.jsonObject(with: bc) as? [String: Any] else {
            XCTFail("BC not JSON"); return
        }
        // Forge a signature over canonical (attacker has canonical bytes;
        // attacker can produce a valid Ed25519 sig under attacker's key).
        // The binding hash still doesn't match because attacker's witness
        // wasn't present at mint.
        let canonical = NativeBirthCertificateVerifier_canonicalForJSON(json)
        let forgedSig = try! attackerKey.signature(for: canonical)
        let forgedSigHex = forgedSig.map { String(format: "%02x", $0) }.joined()
        json["witnesses"] = [[
            "name": "Mallory",
            "role": "attacker",
            "pubkey_hex": attackerPubHex,
            "signature_hex": forgedSigHex,
            "attestation_timestamp": 1_716_900_000,
        ]]
        bc = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try writeBCFixture(bc, at: f.bcPath)

        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "forged-witness on empty-witnesses v=2 BC must reject; got \(result)")
        XCTAssertTrue(result.reason.contains("witnesses_root"),
                      "reason must cite witnesses_root; got: \(result.reason)")
    }

    /// Helper: reconstruct canonical payload bytes from a parsed BC
    /// JSON for the empty-witnesses test. Mirrors the verifier
    /// canonicalPayloadData v=2 branch.
    private func NativeBirthCertificateVerifier_canonicalForJSON(_ json: [String: Any]) -> Data {
        var d: [String: String] = [:]
        d["cold_root_public_key"] = json["coldRootPublicKeyHex"] as? String ?? ""
        d["hv_anchor"] = json["hvAnchor"] as? String ?? ""
        d["machine_uuid"] = json["machineUUID"] as? String ?? ""
        d["operator_id"] = json["operatorID"] as? String ?? ""
        d["operator_voice_anchor_sha256"] = json["operatorVoiceAnchorSHA256Hex"] as? String ?? ""
        d["se_key_id"] = json["seKeyID"] as? String ?? ""
        d["se_pubkey"] = json["sePublicKeyBase64"] as? String ?? ""
        d["soul_anchor_pub"] = json["soul_anchor_pub"] as? String ?? ""
        d["subject_id"] = json["subjectID"] as? String ?? ""
        d["timestamp"] = json["timestamp"] as? String ?? ""
        d["v"] = json["version"] as? String ?? ""
        d["values_hash_via_CharacterValues"] = json["valuesHashViaCharacterValues"] as? String ?? ""
        if let pv = json["payload_version"] as? Int {
            d["payload_version"] = String(pv)
            d["witnesses_root_sha256_hex"] = json["witnesses_root_sha256_hex"] as? String ?? ""
            d["cold_root_ots_receipt_sha256_hex"] = json["cold_root_ots_receipt_sha256_hex"] as? String ?? ""
            d["sbom_binding_sha256_hex"] = json["sbom_binding_sha256_hex"] as? String ?? ""
            d["sbom_cold_root_signature_sha256_hex"] = json["sbom_cold_root_signature_sha256_hex"] as? String ?? ""
        }
        let fields = d.keys.sorted().map { k in
            "\"\(k)\":\"\(d[k] ?? "")\""
        }.joined(separator: ",")
        return Data(("{" + fields + "}").utf8)
    }

    // MARK: - F-E13: RFC 3161 TSA client (R11h)

    /// F-E13 helper: ephemeral tmpdir under NSTemporaryDirectory().
    private func makeTmpDir() -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apt-tsa-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return root.path
    }

    /// F-E13a: TimeStampReq DER encoding is byte-exact for a known
    /// SHA-256 imprint + known nonce. Hand-computed against RFC 3161
    /// §2.4.1 + Annex A on a paper trace. Regression locks the wire
    /// format so that a future "innocent" refactor cannot silently
    /// produce a request rejected by every public TSA.
    func test_APT_F_E13_a_TSARequestEncodingByteExact() throws {
        // Imprint: SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        let imprint = Data([
            0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
            0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
            0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
            0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24,
        ])
        // Fixed 8-byte nonce so the result is reproducible.
        let nonce = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let der = try NativeAuditTSAClient.encodeTimeStampReq(sha256Imprint: imprint, nonce: nonce)

        // Hand-computed expected DER:
        //   30 LL                                       SEQUENCE
        //     02 01 01                                  INTEGER 1 (version)
        //     30 31                                     SEQUENCE MessageImprint
        //       30 0d                                   SEQUENCE AlgorithmIdentifier
        //         06 09 60 86 48 01 65 03 04 02 01      OID sha-256
        //         05 00                                 NULL
        //       04 20 <32 bytes>                        OCTET STRING imprint
        //     02 08 01 02 03 04 05 06 07 08             INTEGER nonce (high-bit clear, no leading 00)
        //     01 01 ff                                  BOOLEAN TRUE (certReq)
        // Total inner = 3 + 51 + 10 + 3 = 67 bytes → 30 43 …
        let expected: [UInt8] = [
            0x30, 0x43,
            0x02, 0x01, 0x01,
            0x30, 0x31,
            0x30, 0x0d,
            0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01,
            0x05, 0x00,
            0x04, 0x20,
            0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
            0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
            0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
            0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24,
            0x02, 0x08, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x01, 0x01, 0xff,
        ]
        XCTAssertEqual(Array(der), expected,
                       "TimeStampReq DER bytes drifted — wire format broken")
    }

    /// F-E13b: TimeStampResp parser extracts the timestampToken DER
    /// bytes verbatim when PKIStatus == 0 (granted), and rejects when
    /// PKIStatus is non-granted. Hand-built fixture: outer SEQUENCE
    /// containing a PKIStatusInfo (just an INTEGER status) and a fake
    /// timeStampToken (any SEQUENCE we can recognize byte-exact).
    func test_APT_F_E13_b_TSAResponseParser() throws {
        // Build response: SEQUENCE { SEQUENCE { INTEGER 0 } , SEQUENCE { ... fake token ... } }
        let statusInfo: [UInt8] = [0x30, 0x03, 0x02, 0x01, 0x00]
        let fakeToken: [UInt8] = [0x30, 0x04, 0x01, 0x02, 0x03, 0x04]
        let inner = statusInfo + fakeToken
        let outer = [UInt8(0x30), UInt8(inner.count)] + inner
        let resp = Data(outer)
        let token = try NativeAuditTSAClient.parseTimeStampResp(resp)
        XCTAssertEqual(Array(token), fakeToken,
                       "timeStampToken DER bytes must be preserved verbatim")

        // Non-granted status (rejection = 2) → throws
        let rejected: [UInt8] = [0x30, 0x05, 0x30, 0x03, 0x02, 0x01, 0x02]
        XCTAssertThrowsError(try NativeAuditTSAClient.parseTimeStampResp(Data(rejected))) { err in
            if case NativeAuditTSAClientError.responseStatusNotGranted(let s) = err {
                XCTAssertEqual(s, 2)
            } else {
                XCTFail("expected responseStatusNotGranted, got \(err)")
            }
        }
    }

    /// F-E13c: With a configured TSA pointing at an unreachable URL
    /// (127.0.0.1:1 = ECONNREFUSED), submit() writes a pending_tsa
    /// entry for retry. No receipts produced. No throws (boot must
    /// not abort on TSA failure).
    func test_APT_F_E13_c_PendingQueueOnNetworkFailure() throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cfgDir = tmp + "/identity"
        let receiptDir = tmp + "/audit/tsa"
        let pendingDir = tmp + "/audit/pending_tsa"
        try FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let cfg = """
        {"tsas":[{"name":"unreach","url":"http://127.0.0.1:1/tsr"}],"timeout_seconds":1}
        """.data(using: .utf8)!
        let cfgPath = cfgDir + "/tsa_urls.json"
        try cfg.write(to: URL(fileURLWithPath: cfgPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfgPath)

        let env: [String: String] = [
            "JARVIS_TSA_CONFIG_PATH": cfgPath,
            "JARVIS_TSA_RECEIPT_DIR": receiptDir,
            "JARVIS_TSA_PENDING_DIR": pendingDir,
        ]
        let anchorSha = "deadbeef".repeated(8)
        NativeAuditTSAClient.submit(anchorShaHex: anchorSha, env: env)

        let pendingFile = pendingDir + "/\(anchorSha).json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFile),
                      "pending_tsa entry must exist after network failure")
        // No receipt should exist.
        let receiptFile = receiptDir + "/\(anchorSha)-unreach.der"
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile),
                       "no receipt should be produced when TSA unreachable")
        // Mode 0600 on pending file.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: pendingFile),
           let mode = attrs[.posixPermissions] as? NSNumber {
            XCTAssertEqual(mode.uint16Value & 0o777, 0o600,
                           "pending_tsa entry must be mode 0600")
        }
        // Parse-able pending payload, lists the failing TSA name.
        let data = try Data(contentsOf: URL(fileURLWithPath: pendingFile))
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pending = parsed["tsas_pending"] as? [String] else {
            XCTFail("pending file malformed"); return
        }
        XCTAssertEqual(pending, ["unreach"])
        XCTAssertEqual(parsed["anchor_sha"] as? String, anchorSha)
    }

    /// F-E13d: When the config file is ABSENT, submit() is a no-op.
    /// Cockpit must boot in fully air-gapped environments without
    /// producing pending entries or receipts. TSA is opt-in.
    func test_APT_F_E13_d_NoConfigIsNoOp() throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let env: [String: String] = [
            "JARVIS_TSA_CONFIG_PATH": tmp + "/identity/tsa_urls.json", // does not exist
            "JARVIS_TSA_RECEIPT_DIR": tmp + "/audit/tsa",
            "JARVIS_TSA_PENDING_DIR": tmp + "/audit/pending_tsa",
        ]
        let anchorSha = "cafebabe".repeated(8)
        NativeAuditTSAClient.submit(anchorShaHex: anchorSha, env: env)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp + "/audit/pending_tsa"),
                       "no pending_tsa dir should appear when config missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp + "/audit/tsa"),
                       "no tsa receipt dir should appear when config missing")
    }

    /// F-E13e: World-readable TSA config file is rejected — symmetric
    /// to the F-C05 operator.txt mode discipline. A weak-mode config
    /// could let a non-privileged process tamper with TSA URLs and
    /// silently redirect timestamp submissions to an attacker server.
    func test_APT_F_E13_e_WorldReadableConfigRejected() throws {
        let tmp = makeTmpDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cfgDir = tmp + "/identity"
        try FileManager.default.createDirectory(atPath: cfgDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let cfgPath = cfgDir + "/tsa_urls.json"
        let cfg = """
        {"tsas":[{"name":"x","url":"http://127.0.0.1:1/"}]}
        """.data(using: .utf8)!
        try cfg.write(to: URL(fileURLWithPath: cfgPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cfgPath)

        let env: [String: String] = ["JARVIS_TSA_CONFIG_PATH": cfgPath]
        XCTAssertThrowsError(try NativeAuditTSAClient.loadConfig(env: env)) { err in
            if case NativeAuditTSAClientError.configBadMode(_, let mode) = err {
                XCTAssertEqual(mode & 0o077, 0o044,
                               "expected world-readable bits detected")
            } else {
                XCTFail("expected configBadMode, got \(err)")
            }
        }
    }

    // MARK: - F-E14: OpenTimestamps receipt field (R11h)

    /// F-E14a: BC carrying a well-formed base64 OTS receipt verifies and
    /// boots — the field is additive and OPT-IN, never a verifier gate.
    /// Cockpit cannot verify the receipt at boot (needs Bitcoin chain
    /// access); it preserves the bytes and audits presence.
    func test_APT_F_E14_a_bc_with_ots_receipt_verifies() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)
        // 32 bytes of arbitrary content, base64-encoded — represents the
        // raw .ots proof file bytes the ceremony would produce.
        let fakeOTS = Data((0..<128).map { UInt8($0 & 0xff) }).base64EncodedString()
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        otsReceiptB64: fakeOTS)
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "BC with valid OTS receipt must verify; got \(result.reason)")
    }

    /// F-E14b: BC WITHOUT OTS receipt still verifies (backward compat)
    /// but emits the WARN audit. Mirrors witness no-witnesses semantics.
    func test_APT_F_E14_b_bc_missing_ots_receipt_verifies_warns() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "BC without OTS receipt must still verify (additive compat)")
        // Confirm WARN audit emitted.
        let log = f.auditDir.appendingPathComponent("network_security.jsonl")
        let logBytes = (try? Data(contentsOf: log)) ?? Data()
        let logStr = String(data: logBytes, encoding: .utf8) ?? ""
        XCTAssertTrue(logStr.contains("birth_certificate_no_ots_receipt"),
                      "expected birth_certificate_no_ots_receipt WARN audit")
    }

    /// F-E14c: BC with a MALFORMED OTS field (non-base64 garbage) does
    /// NOT reject — but DOES emit a WARN audit distinct from the
    /// no-receipt case. Refusing to load on a malformed external-timestamp
    /// field would be a denial-of-service vector (an attacker who only
    /// gets write access to the BC could brick the cockpit). We log loud
    /// instead.
    func test_APT_F_E14_c_bc_with_malformed_ots_warns_but_verifies() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)
        // "@@@@" is not valid base64 (only `=` padding chars after
        // letters/digits are allowed).
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        otsReceiptB64: "@@@@not-base64@@@@")
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "malformed OTS must not brick the cockpit")
        let log = f.auditDir.appendingPathComponent("network_security.jsonl")
        let logBytes = (try? Data(contentsOf: log)) ?? Data()
        let logStr = String(data: logBytes, encoding: .utf8) ?? ""
        XCTAssertTrue(logStr.contains("birth_certificate_ots_receipt_malformed"),
                      "expected birth_certificate_ots_receipt_malformed WARN audit")
    }

    // MARK: - F-E16: SBOM integrity (R11h)

    /// F-E16a: BC carrying valid (sbom_sha256_hex, sbom_cold_root_signature_hex)
    /// AND a matching on-disk SBOM file verifies, with the SBOM-verified
    /// audit emitted.
    func test_APT_F_E16_a_bc_with_valid_sbom_verifies() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f); unsetenv("JARVIS_SBOM_PATH") }
        setEnvForFixture(f)

        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        // SBOM file: arbitrary text. The cockpit only cares that its
        // SHA-256 matches the value the cold root signed.
        let sbomBytes = Data("source_file_a.swift sha256=aaa\nsource_file_b.swift sha256=bbb\n".utf8)
        let sbomPath = f.identityDir.appendingPathComponent("sbom.txt").path
        try sbomBytes.write(to: URL(fileURLWithPath: sbomPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sbomPath)
        setenv("JARVIS_SBOM_PATH", sbomPath, 1)

        let sbomHash = SHA256.hash(data: sbomBytes)
        let sbomHashBytes = Data(sbomHash)
        let sbomHashHex = sbomHashBytes.map { String(format: "%02x", $0) }.joined()
        let sbomSig = try coldRoot.signature(for: sbomHashBytes)
        let sbomSigHex = sbomSig.map { String(format: "%02x", $0) }.joined()

        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        sbomHashHex: sbomHashHex,
                        sbomSignatureHex: sbomSigHex)
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "BC with valid SBOM must verify; got \(result.reason)")
        let log = f.auditDir.appendingPathComponent("network_security.jsonl")
        let logStr = String(data: (try? Data(contentsOf: log)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(logStr.contains("birth_certificate_sbom_verified"),
                      "expected birth_certificate_sbom_verified audit")
    }

    /// F-E16b: BC missing both SBOM fields verifies (additive compat),
    /// emits no-sbom WARN audit. Pre-R11h BCs continue to load.
    func test_APT_F_E16_b_bc_without_sbom_verifies_warns() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID())
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .verified,
                       "BC without SBOM must still verify (additive compat)")
        let log = f.auditDir.appendingPathComponent("network_security.jsonl")
        let logStr = String(data: (try? Data(contentsOf: log)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(logStr.contains("birth_certificate_no_sbom"),
                      "expected birth_certificate_no_sbom WARN audit")
    }

    /// F-E16c: BC + signature are valid, but the on-disk SBOM has been
    /// tampered with — verifier REJECTS. The attack: an APT-level
    /// adversary swaps the SBOM file (which lists source SHAs) to one
    /// describing a different (malicious) source tree, but cannot
    /// re-sign because the cold root is offline. Verifier catches the
    /// hash mismatch and refuses to boot.
    func test_APT_F_E16_c_tampered_sbom_rejected() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f); unsetenv("JARVIS_SBOM_PATH") }
        setEnvForFixture(f)
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)

        let originalSBOM = Data("source_file_a.swift sha256=aaa\n".utf8)
        let sbomPath = f.identityDir.appendingPathComponent("sbom.txt").path
        setenv("JARVIS_SBOM_PATH", sbomPath, 1)

        // Sign the ORIGINAL hash.
        let originalHash = Data(SHA256.hash(data: originalSBOM))
        let sbomHashHex = originalHash.map { String(format: "%02x", $0) }.joined()
        let sbomSig = try coldRoot.signature(for: originalHash)
        let sbomSigHex = sbomSig.map { String(format: "%02x", $0) }.joined()

        // But write a TAMPERED SBOM to disk.
        let tamperedSBOM = Data("source_file_a.swift sha256=DEADBEEF\n".utf8)
        try tamperedSBOM.write(to: URL(fileURLWithPath: sbomPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sbomPath)

        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        sbomHashHex: sbomHashHex,
                        sbomSignatureHex: sbomSigHex)
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "tampered SBOM file must reject; got \(result.reason)")
        XCTAssertTrue(result.reason.contains("SBOM on-disk hash"),
                      "reject reason should reference SBOM hash mismatch; got \(result.reason)")
    }

    /// F-E16d: BC ships asymmetric SBOM fields — hash present but
    /// signature missing. Reject. Either both are there (provenance
    /// claim) or neither is (additive compat). One without the other
    /// is malformed and could indicate an attacker stripped the
    /// signature to bypass verification.
    func test_APT_F_E16_d_asymmetric_sbom_fields_rejected() throws {
        let f = try makeFixture()
        defer { unsetEnvForFixture(f) }
        setEnvForFixture(f)
        let coldRoot = Curve25519.Signing.PrivateKey()
        let coldRootPub = coldRoot.publicKey.rawRepresentation
        try writePinFile(coldRootPub, at: f.pinFilePath)
        let bc = mintBC(signingKey: coldRoot, inCertColdRoot: coldRootPub,
                        machineUUID: currentMachineUUID(),
                        sbomHashHex: String(repeating: "a", count: 64),
                        sbomSignatureHex: nil)
        try writeBCFixture(bc, at: f.bcPath)
        let result = NativeBirthCertificateVerifier.verify()
        XCTAssertEqual(result.result, .invalidSignature,
                       "asymmetric SBOM fields must reject")
        XCTAssertTrue(result.reason.contains("asymmetric"),
                      "reject reason should mention asymmetric fields; got \(result.reason)")
    }

    // MARK: - F-KD08 voice anchor TOCTOU (R11l α.1)

    /// F-KD08: every `~/.jarvis/`-touching reader must use the fd-based
    /// open(O_NOFOLLOW) + fstat(fd) + read(fd) pattern. The pre-R11l code
    /// path-rechecked between symlink_status / lstat / readFileStrict,
    /// giving an attacker a window to swap the inode under us.
    ///
    /// This is a source-level pin (cf. test_F_E32_*_present_in_source).
    /// The behavioural happy-path is the rest of the APT + cockpit suite
    /// staying green — every NativeRuntimeBridge() call routes through
    /// the three readers patched here.
    func testFFKD08_VoiceAnchorTOCTOU_readers_use_fd_based_pattern() throws {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        var srcURL: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(
                "JARVISNativeRuntime/JARVISNativeRuntime.cpp"
            )
            if FileManager.default.fileExists(atPath: candidate.path) {
                srcURL = candidate
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        guard let url = srcURL else {
            XCTFail("F-KD08: could not locate JARVISNativeRuntime.cpp from #file=\(#file)")
            return
        }
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(src.contains("F-KD08"),
                      "F-KD08 patch marker must remain in source so future refactors don't silently re-open the TOCTOU window")

        // Balanced-brace extractor: returns the function body (between the
        // first `{` after the signature line and its matching `}`).
        func body(of fn: String) -> String? {
            guard let sigRange = src.range(of: fn + "(") else { return nil }
            // Find first `{` after the closing `)` of the signature.
            guard let openBrace = src.range(of: "{", range: sigRange.upperBound..<src.endIndex) else {
                return nil
            }
            var depth = 1
            var i = openBrace.upperBound
            while i < src.endIndex && depth > 0 {
                let c = src[i]
                if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1 }
                i = src.index(after: i)
            }
            guard depth == 0 else { return nil }
            return String(src[openBrace.upperBound..<src.index(before: i)])
        }

        let readers = ["readVoiceModelAnchor", "readPersistedVoiceAnchor", "birthCertificateVoiceHashIfPresent"]
        for fn in readers {
            guard let b = body(of: fn) else {
                XCTFail("F-KD08: could not locate body of \(fn)")
                continue
            }
            // Positive gates: fd-based pattern present.
            XCTAssertTrue(b.contains("openNoFollowReadOnly"),
                          "F-KD08: \(fn) body must call openNoFollowReadOnly")
            XCTAssertTrue(b.contains("fstat("),
                          "F-KD08: \(fn) body must fstat(fd) — not lstat(path)")
            XCTAssertTrue(b.contains("readAllFromFdStrict"),
                          "F-KD08: \(fn) body must read via readAllFromFdStrict (no second path lookup)")

            // Negative gates: no path-recheck.
            XCTAssertFalse(b.contains("std::filesystem::exists("),
                           "F-KD08: \(fn) body must not call std::filesystem::exists — that is the TOCTOU pattern eliminated by α.1")
            XCTAssertFalse(b.contains("std::filesystem::symlink_status("),
                           "F-KD08: \(fn) body must not call std::filesystem::symlink_status — fstat(fd) supersedes it")
            XCTAssertFalse(b.contains("::lstat("),
                           "F-KD08: \(fn) body must not call ::lstat(path) — fstat(fd) supersedes it")
            XCTAssertFalse(b.contains("readFileStrict("),
                           "F-KD08: \(fn) body must not call readFileStrict — that re-opens the path post-check")
        }

        // The new fd-based helpers must be defined.
        for helper in ["class FdGuard", "openNoFollowReadOnly", "readAllFromFdStrict"] {
            XCTAssertTrue(src.contains(helper),
                          "F-KD08: helper \(helper) must be defined in JARVISNativeRuntime.cpp")
        }
    }

    // MARK: - F-KD01 / F-KD02 / F-KD03 / F-KD04  (R11l α.2 — Swift §7 fs discipline)
    //
    // Patches route every §7 Swift reader through the shared helper
    // `readSection7Anchored` defined in SecureFileRead.swift. That helper
    // performs realpath()-then-walk-with-O_NOFOLLOW (F-KD04) over each path
    // component, fstats the resulting parent dirfd for mode/uid (F-KD03),
    // and opens the leaf via openat(parentFd, ..., O_RDONLY|O_NOFOLLOW|
    // O_CLOEXEC) with leaf fstat enforcement. The tests below pin the
    // structural shape so a future refactor cannot silently re-introduce
    // a `Data(contentsOf:, options: .mappedIfSafe)` reader (the anti-
    // pattern surfaced in R11k findings F-KD01..F-KD04).

    /// Walk parents from #file to locate a sibling Swift source by relative path.
    private func locateRepoSource(_ relPath: String, limit: Int = 10) -> URL? {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<limit {
            let candidate = dir.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Balanced-brace extractor — returns the function body delimited by
    /// the first `{` after the named function signature and its matching
    /// `}`. Mirrors the extractor used by testFFKD08.
    private func balancedBraceBody(of fnName: String, in src: String) -> String? {
        guard let sigRange = src.range(of: fnName + "(") else { return nil }
        guard let openBrace = src.range(of: "{", range: sigRange.upperBound..<src.endIndex) else {
            return nil
        }
        var depth = 1
        var i = openBrace.upperBound
        while i < src.endIndex && depth > 0 {
            let c = src[i]
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1 }
            i = src.index(after: i)
        }
        guard depth == 0 else { return nil }
        return String(src[openBrace.upperBound..<src.index(before: i)])
    }

    /// Strip Swift `// ...` line comments and `/* ... */` block comments
    /// from a source fragment. Negative gates run against this stripped
    /// form so that comments documenting *what was replaced* (e.g.
    /// "Replaces the prior `Data(contentsOf:, .mappedIfSafe)` reader")
    /// do not falsely trigger the gate.
    private func stripSwiftComments(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        let end = s.endIndex
        while i < end {
            let c = s[i]
            let next = s.index(after: i)
            if c == "/" && next < end && s[next] == "/" {
                while i < end && s[i] != "\n" { i = s.index(after: i) }
            } else if c == "/" && next < end && s[next] == "*" {
                i = s.index(after: next)
                while i < end {
                    if s[i] == "*" {
                        let j = s.index(after: i)
                        if j < end && s[j] == "/" {
                            i = s.index(after: j)
                            break
                        }
                    }
                    i = s.index(after: i)
                }
            } else {
                out.append(c)
                i = next
            }
        }
        return out
    }

    /// F-KD01 (HIGH) — Swift BC verifier: every reader site must route
    /// through `readSection7Anchored`; `Data(contentsOf:` + `.mappedIfSafe`
    /// must not survive in patched function bodies.
    func testFFKD01_BCVerifier_uses_fd_based_pattern_no_DataContentsOf() throws {
        guard let url = locateRepoSource("apple_native/JARVISMacCockpitService/NativeBirthCertificateVerifier.swift") else {
            XCTFail("F-KD01: could not locate NativeBirthCertificateVerifier.swift from #file=\(#file)")
            return
        }
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(src.contains("F-KD01"),
                      "F-KD01 patch marker must remain in source so future refactors don't silently re-open the symlink/TOCTOU window")

        let readers = [
            "static func verify",
            "static func verifiedVoiceAnchorHash",
            "static func verifiedColdRootPublicKeyHex",
            "private static func verifySBOM",
        ]
        for fn in readers {
            guard let rawBody = balancedBraceBody(of: fn, in: src) else {
                XCTFail("F-KD01: could not locate body of \(fn) in NativeBirthCertificateVerifier.swift")
                continue
            }
            let b = stripSwiftComments(rawBody)
            // Positive gate: helper is called.
            XCTAssertTrue(b.contains("readSection7Anchored"),
                          "F-KD01: \(fn) body must read §7 files via readSection7Anchored helper")
            // Negative gates: the anti-patterns from R11k F-KD01.
            XCTAssertFalse(b.contains("Data(contentsOf:"),
                           "F-KD01: \(fn) body must not call Data(contentsOf:) — that follows final-component symlinks via Foundation")
            XCTAssertFalse(b.contains(".mappedIfSafe"),
                           "F-KD01: \(fn) body must not use .mappedIfSafe — the SBOM-hash-binds-content invariant requires fd-anchored reads")
            XCTAssertFalse(b.contains("FileHandle(forReadingFrom:"),
                           "F-KD01: \(fn) body must not use FileHandle(forReadingFrom:) — same symlink-follow hazard as Data(contentsOf:)")
        }
    }

    /// F-KD02 (HIGH) — NativeAuditChainAnchor.loadAuxCertificateData
    /// must route through `readSection7Anchored`.
    func testFFKD02_loadAuxCertificateData_uses_fd_based_pattern() throws {
        guard let url = locateRepoSource("apple_native/JARVISMacCockpitService/NativeAuditChainAnchor.swift") else {
            XCTFail("F-KD02: could not locate NativeAuditChainAnchor.swift from #file=\(#file)")
            return
        }
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(src.contains("F-KD02"),
                      "F-KD02 patch marker must remain in source so future refactors don't silently re-open the symlink/TOCTOU window")

        guard let rawBody = balancedBraceBody(of: "func loadAuxCertificateData", in: src) else {
            XCTFail("F-KD02: could not locate body of loadAuxCertificateData in NativeAuditChainAnchor.swift")
            return
        }
        let b = stripSwiftComments(rawBody)
        XCTAssertTrue(b.contains("readSection7Anchored"),
                      "F-KD02: loadAuxCertificateData body must read §7 file via readSection7Anchored helper")
        XCTAssertFalse(b.contains("Data(contentsOf:"),
                       "F-KD02: loadAuxCertificateData body must not call Data(contentsOf:)")
        XCTAssertFalse(b.contains(".mappedIfSafe"),
                       "F-KD02: loadAuxCertificateData body must not use .mappedIfSafe")
        XCTAssertFalse(b.contains("FileHandle(forReadingFrom:"),
                       "F-KD02: loadAuxCertificateData body must not use FileHandle(forReadingFrom:)")
    }

    /// F-KD03 (HIGH) — every §7 reader must verify the containing
    /// directory's mode (0700) + uid (operator) before opening the leaf.
    /// Verification lives in `SecureFileRead.swift`'s
    /// `openSection7Anchored`; patched readers must funnel through it.
    func testFFKD03_parent_directory_verified_in_section7_readers() throws {
        guard let helperURL = locateRepoSource("apple_native/JARVISMacCockpit/SecureFileRead.swift") else {
            XCTFail("F-KD03: could not locate SecureFileRead.swift from #file=\(#file)")
            return
        }
        let helperSrc = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helperSrc.contains("F-KD03"),
                      "F-KD03 patch marker must remain in SecureFileRead.swift")

        // The helper itself must encode the parent-dir mode + uid invariant.
        XCTAssertTrue(helperSrc.contains("requireParentMode"),
                      "F-KD03: SecureFileReadPolicy must expose requireParentMode (parent-dir mode check)")
        XCTAssertTrue(helperSrc.contains("requireParentUID"),
                      "F-KD03: SecureFileReadPolicy must expose requireParentUID (parent-dir uid check)")
        XCTAssertTrue(helperSrc.contains("fstat("),
                      "F-KD03: helper must fstat(parentFd) — not lstat(path) — to enforce parent-dir invariants TOCTOU-safely")
        XCTAssertTrue(helperSrc.contains("S_IFDIR") || helperSrc.contains("isDirectory"),
                      "F-KD03: helper must verify the resolved parent is actually a directory inode")

        // Each runtime §7 reader file must call into the helper.
        let runtimeReaders: [(rel: String, finding: String)] = [
            ("apple_native/JARVISMacCockpitService/NativeBirthCertificateVerifier.swift", "F-KD01"),
            ("apple_native/JARVISMacCockpitService/NativeAuditChainAnchor.swift",        "F-KD02"),
            ("apple_native/JARVISMacCockpitService/NativeColdRootPin.swift",             "F-KD03"),
            ("apple_native/JARVISMacCockpitService/OperatorPresence.swift",              "F-KD03"),
        ]
        for (rel, finding) in runtimeReaders {
            guard let url = locateRepoSource(rel) else {
                XCTFail("F-KD03: could not locate \(rel)")
                continue
            }
            let src = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(src.contains("readSection7Anchored") || src.contains("openSection7Anchored"),
                          "F-KD03/\(finding): \(rel) must invoke the shared §7 reader helper so the parent-dir verify cannot be bypassed")
        }
    }

    /// F-KD04 (HIGH) — every §7 reader must walk path components via
    /// openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC) rather than relying on
    /// O_NOFOLLOW at the leaf only. realpath() canonicalises legitimate
    /// pre-existing symlinks (e.g. /var → /private/var); the subsequent
    /// component walk then rejects any newly-injected symlink.
    func testFFKD04_section7_readers_use_per_component_openat_walk() throws {
        guard let helperURL = locateRepoSource("apple_native/JARVISMacCockpit/SecureFileRead.swift") else {
            XCTFail("F-KD04: could not locate SecureFileRead.swift from #file=\(#file)")
            return
        }
        let helperSrc = try String(contentsOf: helperURL, encoding: .utf8)

        XCTAssertTrue(helperSrc.contains("F-KD04"),
                      "F-KD04 patch marker must remain in SecureFileRead.swift")

        // Positive structural gates: helper performs realpath + openat walk.
        XCTAssertTrue(helperSrc.contains("realpath("),
                      "F-KD04: helper must realpath() the parent path to canonicalise legitimate pre-existing symlinks before walking")
        XCTAssertTrue(helperSrc.contains("openat("),
                      "F-KD04: helper must walk components via openat() rather than absolute open()")
        XCTAssertTrue(helperSrc.contains("O_NOFOLLOW"),
                      "F-KD04: helper must pass O_NOFOLLOW at every walk step so an injected symlink raises ELOOP")
        XCTAssertTrue(helperSrc.contains("O_DIRECTORY"),
                      "F-KD04: helper must pass O_DIRECTORY when opening intermediate components")
        XCTAssertTrue(helperSrc.contains("O_CLOEXEC"),
                      "F-KD04: helper must pass O_CLOEXEC so dirfds don't leak across exec()")
        XCTAssertTrue(helperSrc.contains("openSection7Anchored") && helperSrc.contains("readSection7Anchored"),
                      "F-KD04: helper must expose both openSection7Anchored (handle) and readSection7Anchored (Data) entry points")

        // Negative gate: no patched runtime reader may bypass the helper
        // with a bare `Data(contentsOf:` or `FileHandle(forReadingFrom:`.
        let patched: [String] = [
            "apple_native/JARVISMacCockpitService/NativeBirthCertificateVerifier.swift",
            "apple_native/JARVISMacCockpitService/NativeAuditChainAnchor.swift",
            "apple_native/JARVISMacCockpitService/NativeColdRootPin.swift",
            "apple_native/JARVISMacCockpitService/OperatorPresence.swift",
        ]
        for rel in patched {
            guard let url = locateRepoSource(rel) else {
                XCTFail("F-KD04: could not locate \(rel)")
                continue
            }
            let rawSrc = try String(contentsOf: url, encoding: .utf8)
            let src = stripSwiftComments(rawSrc)
            XCTAssertFalse(src.contains(".mappedIfSafe"),
                           "F-KD04: \(rel) must not use .mappedIfSafe — that bypasses the helper's component walk")
            XCTAssertFalse(src.contains("Data(contentsOf:"),
                           "F-KD04: \(rel) must not call Data(contentsOf:) — leaf O_NOFOLLOW alone leaves intermediate symlinks followed")
        }
    }

    // ── α.3 F-KE02 / F-KE03 ──────────────────────────────────────────────
    //
    // Source-level + behavioral tests for audit-chain integrity and
    // UF_APPEND defense-in-depth in SecureFileWrite.swift +
    // AuditChainVerify.swift. See α.3 gate doc for full threat-model note;
    // recap: UF_APPEND is owner-clearable defense-in-depth, primary integrity
    // is the hash-chain walk. SF_APPEND in-threat-model coverage = α.3.1.

    /// F-KE03: both audit writers MUST call fchflags(…, …) with UF_APPEND
    /// after the post-write fsync to arm the append-only flag.
    func testFFKE03_audit_writers_set_UF_APPEND_after_create() throws {
        let rel = "apple_native/JARVISMacCockpit/SecureFileWrite.swift"
        guard let url = locateRepoSource(rel) else {
            XCTFail("F-KE03: could not locate \(rel)"); return
        }
        let rawSrc = try String(contentsOf: url, encoding: .utf8)
        let src = stripSwiftComments(rawSrc)
        let bounded = balancedBraceBody(of: "func appendBoundedAuditRecord", in: src) ?? ""
        let chained = balancedBraceBody(of: "func appendChainedAuditRecord", in: src) ?? ""
        XCTAssertFalse(bounded.isEmpty, "F-KE03: could not extract appendBoundedAuditRecord body")
        XCTAssertFalse(chained.isEmpty, "F-KE03: could not extract appendChainedAuditRecord body")
        for (name, body) in [("appendBoundedAuditRecord", bounded), ("appendChainedAuditRecord", chained)] {
            XCTAssertTrue(body.contains("Darwin.fchflags(fdFile"),
                          "F-KE03: \(name) must call fchflags(fdFile, …) to arm UF_APPEND post-fsync")
            XCTAssertTrue(body.contains("UInt32(UF_APPEND)"),
                          "F-KE03: \(name) must OR UF_APPEND into the new flags value")
        }
    }

    /// F-KE03: both audit writers MUST fstat the file on open and check
    /// st_flags & UF_APPEND as a defense-in-depth tripwire.
    func testFFKE03_audit_writers_verify_UF_APPEND_on_open() throws {
        let rel = "apple_native/JARVISMacCockpit/SecureFileWrite.swift"
        guard let url = locateRepoSource(rel) else {
            XCTFail("F-KE03: could not locate \(rel)"); return
        }
        let rawSrc = try String(contentsOf: url, encoding: .utf8)
        let src = stripSwiftComments(rawSrc)
        let bounded = balancedBraceBody(of: "func appendBoundedAuditRecord", in: src) ?? ""
        let chained = balancedBraceBody(of: "func appendChainedAuditRecord", in: src) ?? ""
        for (name, body) in [("appendBoundedAuditRecord", bounded), ("appendChainedAuditRecord", chained)] {
            XCTAssertTrue(body.contains("Darwin.fstat(fdFile"),
                          "F-KE03: \(name) must fstat(fdFile) on open to inspect st_flags")
            XCTAssertTrue(body.contains("st_flags & UInt32(UF_APPEND)"),
                          "F-KE03: \(name) must test st_flags & UF_APPEND on the open fstat result")
            XCTAssertTrue(body.contains("audit_uf_append_missing"),
                          "F-KE03: \(name) must emit the audit_uf_append_missing tripwire when UF_APPEND was cleared on pre-existing file")
        }
    }

    /// F-KE03: writer opens MUST NOT use O_TRUNC. The chain's append-only
    /// discipline is incompatible with truncation at open.
    func testFFKE03_audit_writers_use_O_APPEND_no_O_TRUNC() throws {
        let rel = "apple_native/JARVISMacCockpit/SecureFileWrite.swift"
        guard let url = locateRepoSource(rel) else {
            XCTFail("F-KE03: could not locate \(rel)"); return
        }
        let rawSrc = try String(contentsOf: url, encoding: .utf8)
        let src = stripSwiftComments(rawSrc)
        let bounded = balancedBraceBody(of: "func appendBoundedAuditRecord", in: src) ?? ""
        let chained = balancedBraceBody(of: "func appendChainedAuditRecord", in: src) ?? ""
        for (name, body) in [("appendBoundedAuditRecord", bounded), ("appendChainedAuditRecord", chained)] {
            XCTAssertTrue(body.contains("O_APPEND"),
                          "F-KE03: \(name) must open with O_APPEND")
            XCTAssertFalse(body.contains("O_TRUNC"),
                           "F-KE03: \(name) MUST NOT pass O_TRUNC — would zero the chain on every reopen")
        }
    }

    /// F-KE02: behavioral — empty data + requireNonEmpty=true must throw .empty
    /// with the `audit_chain_truncate_detected` tag.
    func testFFKE02_verifyAuditChain_rejects_empty_when_required() {
        XCTAssertThrowsError(try AuditChainVerify.verify(Data(), requireNonEmpty: true)) { err in
            guard let e = err as? AuditChainVerifyError else {
                XCTFail("expected AuditChainVerifyError, got \(err)"); return
            }
            guard case .empty = e else {
                XCTFail("expected .empty, got \(e)"); return
            }
            XCTAssertEqual(e.auditEventTag, "audit_chain_truncate_detected")
        }
        // And requireNonEmpty=false on empty returns nil (legitimate fresh-creation).
        XCTAssertNil(try? AuditChainVerify.verify(Data(), requireNonEmpty: false) as Any?)
    }

    /// F-KE02: behavioral — a chain whose first record has a non-genesis
    /// prev_sha must be rejected.
    func testFFKE02_verifyAuditChain_rejects_corrupted_genesis() {
        // Build a single record with a non-zero prev_sha — fake hash but
        // self-consistent sha so we exercise the genesis check, not the sha
        // recompute check.
        let badPrev = String(repeating: "f", count: 64)
        let payload: [String: Any] = ["event": "x", "ts": 1, "prev_sha": badPrev, "seq": 1]
        let preSha = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let sha = SHA256.hash(data: preSha).map { String(format: "%02x", $0) }.joined()
        var record = payload
        record["sha"] = sha
        var line = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        line.append(0x0A)

        XCTAssertThrowsError(try AuditChainVerify.verify(line, requireNonEmpty: false)) { err in
            guard let e = err as? AuditChainVerifyError else {
                XCTFail("expected AuditChainVerifyError"); return
            }
            guard case .genesisPrevShaMismatch = e else {
                XCTFail("expected .genesisPrevShaMismatch, got \(e)"); return
            }
            XCTAssertEqual(e.auditEventTag, "audit_chain_genesis_corrupted")
        }
    }

    /// F-KE02: behavioral — a chain with a broken intermediate link (record
    /// N's prev_sha != record N-1's sha) must be rejected.
    func testFFKE02_verifyAuditChain_rejects_broken_link() {
        func buildRecord(prevSha: String, seq: Int) -> Data {
            let payload: [String: Any] = ["event": "x", "ts": 1, "prev_sha": prevSha, "seq": seq]
            let pre = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let sha = SHA256.hash(data: pre).map { String(format: "%02x", $0) }.joined()
            var rec = payload
            rec["sha"] = sha
            return try! JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys])
        }

        let r1 = buildRecord(prevSha: AuditChainVerify.chainGenesisPrevSha, seq: 1)
        // Broken link: r2.prev_sha is all "a" instead of r1.sha.
        let r2 = buildRecord(prevSha: String(repeating: "a", count: 64), seq: 2)
        var data = Data()
        data.append(r1); data.append(0x0A)
        data.append(r2); data.append(0x0A)

        XCTAssertThrowsError(try AuditChainVerify.verify(data, requireNonEmpty: false)) { err in
            guard let e = err as? AuditChainVerifyError else {
                XCTFail("expected AuditChainVerifyError"); return
            }
            guard case .prevShaMismatch = e else {
                XCTFail("expected .prevShaMismatch, got \(e)"); return
            }
            XCTAssertEqual(e.auditEventTag, "audit_chain_broken_link")
        }
    }

    /// F-KE02: source pin — appendChainedAuditRecord MUST call
    /// AuditChainVerify.verify under LOCK_EX before computing the next record.
    func testFFKE02_appendChainedAuditRecord_uses_verifyAuditChain() throws {
        let rel = "apple_native/JARVISMacCockpit/SecureFileWrite.swift"
        guard let url = locateRepoSource(rel) else {
            XCTFail("F-KE02: could not locate \(rel)"); return
        }
        let rawSrc = try String(contentsOf: url, encoding: .utf8)
        let src = stripSwiftComments(rawSrc)
        let body = balancedBraceBody(of: "func appendChainedAuditRecord", in: src) ?? ""
        XCTAssertFalse(body.isEmpty, "F-KE02: could not extract appendChainedAuditRecord body")
        XCTAssertTrue(body.contains("AuditChainVerify.verify"),
                      "F-KE02: appendChainedAuditRecord must call AuditChainVerify.verify under LOCK_EX")
        XCTAssertTrue(body.contains("chainIntegrity"),
                      "F-KE02: appendChainedAuditRecord must translate AuditChainVerifyError to NativeSecurityAuditError.chainIntegrity")
        // Negative gate: must NOT fall back to the old fixed-window tail-scrape
        // pattern that trusted the last-line sha without verifying records 1..N-1.
        XCTAssertFalse(body.contains("lastIndex(of: 0x0A)"),
                       "F-KE02: trailing-newline tail-scrape pattern must be removed — superseded by AuditChainVerify.verify full-chain walk")
    }
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
