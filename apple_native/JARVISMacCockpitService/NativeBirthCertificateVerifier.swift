import CryptoKit
import Foundation
import IOKit

struct NativeBirthCertificateVerification: Equatable {
    enum Result: Equatable {
        case verified
        case missing
        case invalidSignature
        case malformed
    }

    let result: Result
    let path: String
    let reason: String
}

enum NativeBirthCertificateVerifierError: Error, LocalizedError {
    case notVerified(path: String, reason: String)
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case anchorEmpty(path: String)
    case anchorMalformed(path: String)
    case coldRootNotPinned(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notVerified(let p, let r): return "Birth certificate at \(p) not verified: \(r)"
        case .unreadable(let p, let r): return "Birth certificate at \(p) unreadable: \(r)"
        case .malformed(let p, let r): return "Birth certificate at \(p) malformed: \(r)"
        case .anchorEmpty(let p): return "operatorVoiceAnchorSHA256Hex empty in \(p) — operator must complete voice anchor ceremony before runtime can prewarm"
        case .anchorMalformed(let p): return "operatorVoiceAnchorSHA256Hex in \(p) is not a 64-char lowercase hex SHA-256"
        case .coldRootNotPinned(let p, let r): return "Birth certificate at \(p) cannot be trust-anchored: \(r)"
        }
    }
}

enum NativeBirthCertificateVerifier {
    static func verify(env: [String: String] = ProcessInfo.processInfo.environment) -> NativeBirthCertificateVerification {
        let url = birthCertificateURL(env: env)
        let path = url.path

        // R11l α.2 F-KD01/03/04: route through SecureFileRead. realpath +
        // per-component openat(O_NOFOLLOW) walk + parent dir mode 0700 +
        // uid==operator verify + leaf mode 0600 + uid==operator + regular
        // file, then partial-read loop. Replaces the prior Data(contentsOf:,
        // .mappedIfSafe) reader which followed symlinks at every component
        // and never verified the parent dir. ENOENT anywhere in the walk
        // surfaces as .missing here (same semantics as the prior
        // FileManager.fileExists pre-check).
        let data: Data
        do {
            data = try readSection7Anchored(path: path)
        } catch let err as SecureFileReadError {
            if case .absent = err.reason {
                return NativeBirthCertificateVerification(result: .missing, path: path, reason: "birth certificate not found")
            }
            return NativeBirthCertificateVerification(result: .malformed, path: path, reason: err.description)
        } catch {
            return NativeBirthCertificateVerification(result: .malformed, path: path, reason: error.localizedDescription)
        }

        do {
            let certificate = try JSONDecoder().decode(NativeBirthCertificate.self, from: data)
            guard let signature = Data(hexString: certificate.signatureHex),
                  let publicKeyData = Data(hexString: certificate.coldRootPublicKeyHex) else {
                return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "signatureHex or coldRootPublicKeyHex is not valid hex")
            }
            guard signature.count == 64, publicKeyData.count == 32 else {
                return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "signature or cold root public key has invalid length")
            }
            // R11d F-C01: pin the in-cert cold-root pubkey against the external
            // trust anchor BEFORE the signature verify. Without this gate the
            // BC is self-signed by any key it carries — an attacker who can
            // write the BC mints a new keypair and silently substitutes the
            // operator's voice anchor. Fail closed on either mismatch or
            // missing pin (no boot without a trust anchor).
            do {
                let pinned = try NativeColdRootPin.loadPinnedColdRootPublicKey(env: env)
                guard constantTimeEqual(pinned, publicKeyData) else {
                    auditSafely("boot_cold_root_pin_mismatch", fields: [
                        "bc_key_hex_prefix": certificate.coldRootPublicKeyHex.lowercased().prefix(16).asString,
                        "pin_key_hex_prefix": pinned.map { String(format: "%02x", $0) }.joined().prefix(16).asString,
                        "path": path,
                    ])
                    return NativeBirthCertificateVerification(
                        result: .invalidSignature,
                        path: path,
                        reason: "coldRootPublicKeyHex does not match externally-pinned trust anchor"
                    )
                }
            } catch let err as NativeColdRootPinError {
                auditSafely("boot_cold_root_pin_missing", fields: [
                    "path": path,
                    "reason": err.errorDescription ?? "unknown",
                ])
                return NativeBirthCertificateVerification(
                    result: .malformed,
                    path: path,
                    reason: "no externally-pinned cold root trust anchor available: \(err.errorDescription ?? "unknown")"
                )
            } catch {
                auditSafely("boot_cold_root_pin_missing", fields: [
                    "path": path,
                    "reason": error.localizedDescription,
                ])
                return NativeBirthCertificateVerification(
                    result: .malformed,
                    path: path,
                    reason: "cold-root pin load failed: \(error.localizedDescription)"
                )
            }
            guard let currentMachineUUID = currentMachineUUID()?.lowercased() else {
                return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "current machine UUID unavailable")
            }
            guard certificate.machineUUID.lowercased() == currentMachineUUID else {
                return NativeBirthCertificateVerification(result: .invalidSignature, path: path, reason: "birth certificate machineUUID does not match this host")
            }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signature, for: certificate.canonicalPayloadData) else {
                return NativeBirthCertificateVerification(result: .invalidSignature, path: path, reason: "signatureHex does not verify against coldRootPublicKeyHex")
            }
            // R11j F-F10 — payload v=2 binding check. For v=2 BCs, the
            // canonical payload includes SHA-256 binding hashes over
            // (witnesses, OTS receipt, SBOM hash, SBOM sig). Recompute from
            // the live fields and compare to what was signed. Any mismatch
            // means an attacker stripped or mutated an R11h additive field
            // after ceremony — reject. v=1 / no version field → skipped
            // (additive backward compat for pre-R11j BCs).
            if (certificate.payloadVersion ?? 1) >= 2 {
                if let mismatchReason = verifyV2Bindings(certificate: certificate, path: path) {
                    return NativeBirthCertificateVerification(
                        result: .invalidSignature,
                        path: path,
                        reason: mismatchReason
                    )
                }
            }
            // R11h F-E31 — witness chain verification. Each witness's
            // Ed25519 signature must verify against the same canonical
            // payload bytes that the cold root signed. Any failure rejects
            // the BC. Zero witnesses logs a warn audit but does NOT reject
            // (additive backward compat). All-valid emits the verification
            // audit so the externally-anchored chain carries proof.
            switch verifyWitnesses(certificate: certificate, canonical: certificate.canonicalPayloadData, path: path) {
            case .ok:
                break
            case .reject(let reason):
                return NativeBirthCertificateVerification(result: .invalidSignature, path: path, reason: reason)
            }
            // R11h F-E14 — surface OpenTimestamps presence/absence into the
            // audit chain. NOT a verifier gate (verification is operator-
            // driven, requires Bitcoin chain access). Audit so a verifier
            // walking the audit log can see whether external timestamp
            // anchoring is in effect.
            emitOTSAudit(certificate: certificate, path: path)
            // R11h F-E16 — Software Bill of Materials integrity check. If
            // the BC carries (sbom_sha256_hex, sbom_cold_root_signature_hex),
            // verify the cold-root signature over the SBOM hash and confirm
            // the on-disk SBOM file hashes to the same value. Reject on any
            // mismatch — a tampered SBOM means the running binary's
            // provenance is no longer attestable. Missing fields emit a
            // WARN audit but do not reject (additive backward compat).
            switch verifySBOM(certificate: certificate, env: env, publicKey: publicKey, path: path) {
            case .ok:
                break
            case .reject(let reason):
                return NativeBirthCertificateVerification(result: .invalidSignature, path: path, reason: reason)
            }
            return NativeBirthCertificateVerification(result: .verified, path: path, reason: "verified")
        } catch DecodingError.dataCorrupted,
                DecodingError.keyNotFound,
                DecodingError.typeMismatch,
                DecodingError.valueNotFound {
            return NativeBirthCertificateVerification(result: .malformed, path: path, reason: "birth certificate JSON does not match expected schema")
        } catch {
            return NativeBirthCertificateVerification(result: .malformed, path: path, reason: error.localizedDescription)
        }
    }

    /// Returns the verified `operatorVoiceAnchorSHA256Hex` from the birth
    /// certificate, lowercased. Re-runs the full signature verify path before
    /// surfacing the value — there is no caller path that returns the anchor
    /// without first passing `.verified`. Throws on missing/malformed/unverified
    /// BC or empty/malformed anchor value. V4R R8 — voice_state loadtime
    /// integrity baseline.
    static func verifiedVoiceAnchorHash(env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let url = birthCertificateURL(env: env)
        let path = url.path
        let verification = verify(env: env)
        guard verification.result == .verified else {
            throw NativeBirthCertificateVerifierError.notVerified(path: path, reason: verification.reason)
        }
        let data: Data
        do {
            data = try readSection7Anchored(path: path)
        } catch let err as SecureFileReadError {
            if case .absent = err.reason {
                throw NativeBirthCertificateVerifierError.unreadable(path: path, reason: "birth certificate not found")
            }
            throw NativeBirthCertificateVerifierError.unreadable(path: path, reason: err.description)
        } catch {
            throw NativeBirthCertificateVerifierError.unreadable(path: path, reason: error.localizedDescription)
        }
        let certificate: NativeBirthCertificate
        do {
            certificate = try JSONDecoder().decode(NativeBirthCertificate.self, from: data)
        } catch {
            throw NativeBirthCertificateVerifierError.malformed(path: path, reason: error.localizedDescription)
        }
        let anchor = certificate.operatorVoiceAnchorSHA256Hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if anchor.isEmpty {
            throw NativeBirthCertificateVerifierError.anchorEmpty(path: path)
        }
        guard anchor.count == 64, anchor.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw NativeBirthCertificateVerifierError.anchorMalformed(path: path)
        }
        return anchor
    }

    /// Returns the cold-root public key (hex) from the verified BC. Re-runs the
    /// full signature verify path before surfacing the value — there is no
    /// caller path that returns the cold root pubkey without first passing
    /// `.verified`. Throws on missing/malformed/unverified BC. V4R R11d F-C04
    /// — used by NativeMLPackageManifest verification to chain trust from the
    /// BC into the adjacent signed mlpackage manifest.
    static func verifiedColdRootPublicKeyHex(env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let url = birthCertificateURL(env: env)
        let path = url.path
        let verification = verify(env: env)
        guard verification.result == .verified else {
            throw NativeBirthCertificateVerifierError.notVerified(path: path, reason: verification.reason)
        }
        let data: Data
        do {
            data = try readSection7Anchored(path: path)
        } catch let err as SecureFileReadError {
            if case .absent = err.reason {
                throw NativeBirthCertificateVerifierError.unreadable(path: path, reason: "birth certificate not found")
            }
            throw NativeBirthCertificateVerifierError.unreadable(path: path, reason: err.description)
        } catch {
            throw NativeBirthCertificateVerifierError.unreadable(path: path, reason: error.localizedDescription)
        }
        let certificate: NativeBirthCertificate
        do {
            certificate = try JSONDecoder().decode(NativeBirthCertificate.self, from: data)
        } catch {
            throw NativeBirthCertificateVerifierError.malformed(path: path, reason: error.localizedDescription)
        }
        let hex = certificate.coldRootPublicKeyHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw NativeBirthCertificateVerifierError.malformed(path: path, reason: "coldRootPublicKeyHex malformed length=\(hex.count)")
        }
        return hex
    }

    private static func birthCertificateURL(env: [String: String]) -> URL {
        let resolved = NativeInsecurePathOverride.resolve(
            envVar: "JARVIS_BIRTH_CERT_PATH",
            canonicalPath: "~/.jarvis/identity/birth_certificate.json",
            env: env
        )
        return URL(fileURLWithPath: resolved).standardizedFileURL
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.count > 1 else { return home }
        let suffix = path.dropFirst(2)
        return URL(fileURLWithPath: home).appendingPathComponent(String(suffix)).path
    }

    private static func currentMachineUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              !uuid.isEmpty else { return nil }
        return uuid
    }

    // R11d F-C01: audit emission helper. Wraps NativeSecurityAudit.record in
    // do/catch because the verify() return path must not throw — audit-write
    // failure during a cold-root pin event is a secondary diagnostic concern
    // that cannot block the primary deny decision (which is already returned).
    private static func auditSafely(_ event: String, fields: [String: Any]) {
        do { try NativeSecurityAudit.record(event, fields: fields) }
        catch { fputs("JARVIS audit write failed for \(event): \(error)\n", stderr) }
    }

    // R11h F-E31: witness chain verification. Each witness independently
    // signs the canonical BC payload (the same bytes the cold root signs).
    //   - nil/empty witnesses → audit "birth_certificate_no_witnesses" WARN,
    //                            return .ok (additive backward compat).
    //   - malformed (bad hex/length/name>128) → reject.
    //   - any signature fails verify → reject (one bad witness invalidates).
    //   - all valid → audit "birth_certificate_witnesses_verified" with
    //                  count + sorted name list, return .ok.
    private enum WitnessVerdict {
        case ok
        case reject(reason: String)
    }

    private static func verifyWitnesses(
        certificate: NativeBirthCertificate,
        canonical: Data,
        path: String
    ) -> WitnessVerdict {
        let witnesses = certificate.witnesses ?? []
        if witnesses.isEmpty {
            auditSafely("birth_certificate_no_witnesses", fields: [
                "path": path,
                "severity": "WARN",
            ])
            return .ok
        }
        var verifiedNames: [String] = []
        for (idx, w) in witnesses.enumerated() {
            guard w.name.count <= 128 else {
                return .reject(reason: "witness[\(idx)] name exceeds 128 chars")
            }
            guard let pubBytes = Data(hexString: w.pubkeyHex), pubBytes.count == 32 else {
                return .reject(reason: "witness[\(idx)] pubkey_hex malformed")
            }
            guard let sigBytes = Data(hexString: w.signatureHex), sigBytes.count == 64 else {
                return .reject(reason: "witness[\(idx)] signature_hex malformed")
            }
            guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubBytes) else {
                return .reject(reason: "witness[\(idx)] pubkey not a valid Ed25519 point")
            }
            guard pub.isValidSignature(sigBytes, for: canonical) else {
                auditSafely("birth_certificate_witness_signature_invalid", fields: [
                    "path": path,
                    "witness_index": idx,
                    "witness_name": w.name,
                    "witness_role": w.role,
                ])
                return .reject(reason: "witness[\(idx)] '\(w.name)' signature does not verify against canonical BC payload")
            }
            verifiedNames.append(w.name)
        }
        auditSafely("birth_certificate_witnesses_verified", fields: [
            "path": path,
            "count": verifiedNames.count,
            "names": verifiedNames.sorted().joined(separator: ","),
        ])
        return .ok
    }

    // R11h F-E14: OpenTimestamps presence audit. Surfaces whether the BC
    // carries a Bitcoin-anchored OTS receipt for the cold-root pubkey
    // into the audit chain. Cockpit DOES NOT verify the receipt (would
    // require Bitcoin chain access at boot); verification is operator-
    // driven via `ots verify` against the embedded base64 blob.
    private static func emitOTSAudit(certificate: NativeBirthCertificate, path: String) {
        let raw = certificate.coldRootOTSReceiptB64?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let b64 = raw, !b64.isEmpty {
            // Decode just enough to assert it's well-formed base64.
            if let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
               !decoded.isEmpty {
                auditSafely("birth_certificate_ots_receipt_present", fields: [
                    "path": path,
                    "bytes_decoded": decoded.count,
                ])
                return
            }
            auditSafely("birth_certificate_ots_receipt_malformed", fields: [
                "path": path,
                "severity": "WARN",
                "b64_length": b64.count,
            ])
            return
        }
        auditSafely("birth_certificate_no_ots_receipt", fields: [
            "path": path,
            "severity": "WARN",
        ])
    }

    // R11h F-E16: SBOM (Software Bill of Materials) integrity verification.
    // Both fields optional → WARN audit + .ok (additive backward compat).
    // Both fields present:
    //   - SBOM file must exist at the resolved sbomFilePath
    //   - SHA-256 of the on-disk SBOM must equal sbomSha256Hex
    //   - cold-root signature over sbomSha256Hex (32 raw bytes) must verify
    // Any mismatch rejects the BC — a tampered SBOM means the running
    // binary's provenance is no longer attestable.
    private static func verifySBOM(
        certificate: NativeBirthCertificate,
        env: [String: String],
        publicKey: Curve25519.Signing.PublicKey,
        path: String
    ) -> WitnessVerdict {
        let shaHex = certificate.sbomSha256Hex?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sigHex = certificate.sbomColdRootSignatureHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both absent → additive compat, WARN.
        if (shaHex?.isEmpty ?? true) && (sigHex?.isEmpty ?? true) {
            auditSafely("birth_certificate_no_sbom", fields: [
                "path": path,
                "severity": "WARN",
            ])
            return .ok
        }
        // One but not both → malformed (asymmetric pair).
        guard let shaHex = shaHex, !shaHex.isEmpty,
              let sigHex = sigHex, !sigHex.isEmpty else {
            return .reject(reason: "SBOM fields asymmetric — one of {sbom_sha256_hex, sbom_cold_root_signature_hex} missing")
        }
        guard let shaBytes = Data(hexString: shaHex), shaBytes.count == 32 else {
            return .reject(reason: "sbom_sha256_hex malformed")
        }
        guard let sigBytes = Data(hexString: sigHex), sigBytes.count == 64 else {
            return .reject(reason: "sbom_cold_root_signature_hex malformed")
        }
        // Verify cold-root signature over the SBOM hash bytes (raw, NOT hex).
        guard publicKey.isValidSignature(sigBytes, for: shaBytes) else {
            auditSafely("birth_certificate_sbom_signature_invalid", fields: [
                "path": path,
                "severity": "WARN",
            ])
            return .reject(reason: "SBOM cold-root signature does not verify against sbom_sha256_hex")
        }
        // R11l α.2 F-KD01/03/04: route SBOM read through SecureFileRead.
        // SBOM canonically lives at ~/.jarvis/identity/sbom.txt; mode is
        // not ceremony-controlled (hash binding handles content tamper),
        // so requireLeafMode is nil. Parent 0700 + uid==operator still
        // enforced (same threat model as the BC leaf).
        let sbomPath = resolveSBOMPath(env: env)
        var sbomPolicy = SecureFileReadPolicy()
        sbomPolicy.requireLeafMode = nil
        let sbomData: Data
        do {
            sbomData = try readSection7Anchored(path: sbomPath, policy: sbomPolicy)
        } catch let err as SecureFileReadError {
            if case .absent = err.reason {
                auditSafely("birth_certificate_sbom_file_missing", fields: [
                    "path": sbomPath,
                    "severity": "WARN",
                ])
                return .reject(reason: "SBOM file missing at \(sbomPath) but BC carries sbom_sha256_hex")
            }
            return .reject(reason: "SBOM file at \(sbomPath) unreadable: \(err.description)")
        } catch {
            return .reject(reason: "SBOM file at \(sbomPath) unreadable")
        }
        let actual = SHA256.hash(data: sbomData)
        let actualBytes = Data(actual)
        if actualBytes != shaBytes {
            auditSafely("birth_certificate_sbom_hash_mismatch", fields: [
                "path": sbomPath,
                "expected": shaHex,
                "actual": actualBytes.map { String(format: "%02x", $0) }.joined(),
            ])
            return .reject(reason: "SBOM on-disk hash does not match sbom_sha256_hex")
        }
        auditSafely("birth_certificate_sbom_verified", fields: [
            "path": sbomPath,
            "sbom_sha256_hex": shaHex,
            "bytes": sbomData.count,
        ])
        return .ok
    }

    private static func resolveSBOMPath(env: [String: String]) -> String {
        return NativeInsecurePathOverride.resolve(
            envVar: "JARVIS_SBOM_PATH",
            canonicalPath: "~/.jarvis/identity/sbom.txt",
            env: env
        )
    }

    // R11j F-F10: payload v=2 binding verification. Returns nil if all
    // four binding hashes (witnesses, OTS, SBOM-hash, SBOM-sig) inside
    // the canonical payload match recomputations from the live fields.
    // Returns the reject reason string otherwise. Empty sentinel "" in
    // the canonical binding means "this R11h additive field was absent
    // at mint" — and the live field MUST also be absent/empty, else
    // attacker has injected.
    //
    // Inputs:
    //   witnesses_root_sha256_hex      = SHA-256(NativeBirthCertificate.canonicalWitnessesBytes(witnesses))
    //   cold_root_ots_receipt_sha256_hex = SHA-256(utf8(coldRootOTSReceiptB64 ?? ""))
    //   sbom_binding_sha256_hex        = byte-equal to sbomSha256Hex (both hex strings; "" if absent)
    //   sbom_cold_root_signature_sha256_hex = SHA-256(utf8(sbomColdRootSignatureHex ?? ""))
    //
    // All inputs are lowercased hex with no whitespace. Comparison is
    // strict byte equality.
    private static func verifyV2Bindings(certificate: NativeBirthCertificate, path: String) -> String? {
        // Witnesses binding.
        let witnessBindingExpected = certificate.witnessesRootSha256Hex?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let witnessesActualBytes = NativeBirthCertificate.canonicalWitnessesBytes(certificate.witnesses)
        let witnessesActualHex = SHA256.hash(data: witnessesActualBytes)
            .map { String(format: "%02x", $0) }.joined()
        if witnessBindingExpected != witnessesActualHex {
            auditSafely("birth_certificate_v2_binding_mismatch", fields: [
                "path": path,
                "field": "witnesses_root_sha256_hex",
                "expected": witnessBindingExpected,
                "actual": witnessesActualHex,
            ])
            return "v=2 witnesses_root binding mismatch — witness array was added/stripped/mutated after cold-root sign"
        }
        // OTS binding.
        let otsBindingExpected = certificate.coldRootOTSReceiptSha256Hex?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let otsField = certificate.coldRootOTSReceiptB64 ?? ""
        let otsActualHex = SHA256.hash(data: Data(otsField.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if otsBindingExpected != otsActualHex {
            auditSafely("birth_certificate_v2_binding_mismatch", fields: [
                "path": path,
                "field": "cold_root_ots_receipt_sha256_hex",
                "expected": otsBindingExpected,
                "actual": otsActualHex,
            ])
            return "v=2 cold_root_ots_receipt_sha256_hex binding mismatch — OTS receipt was added/stripped/mutated after cold-root sign"
        }
        // SBOM hash binding (byte-equality of two hex strings).
        let sbomHashBindingExpected = certificate.sbomBindingSha256Hex?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let sbomHashActual = (certificate.sbomSha256Hex ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sbomHashBindingExpected != sbomHashActual {
            auditSafely("birth_certificate_v2_binding_mismatch", fields: [
                "path": path,
                "field": "sbom_binding_sha256_hex",
                "expected": sbomHashBindingExpected,
                "actual": sbomHashActual,
            ])
            return "v=2 sbom_binding_sha256_hex mismatch — sbom_sha256_hex was added/stripped/mutated after cold-root sign"
        }
        // SBOM sig binding.
        let sbomSigBindingExpected = certificate.sbomColdRootSignatureSha256Hex?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let sbomSigField = certificate.sbomColdRootSignatureHex ?? ""
        let sbomSigActualHex = SHA256.hash(data: Data(sbomSigField.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if sbomSigBindingExpected != sbomSigActualHex {
            auditSafely("birth_certificate_v2_binding_mismatch", fields: [
                "path": path,
                "field": "sbom_cold_root_signature_sha256_hex",
                "expected": sbomSigBindingExpected,
                "actual": sbomSigActualHex,
            ])
            return "v=2 sbom_cold_root_signature_sha256_hex binding mismatch — SBOM signature was added/stripped/mutated after cold-root sign"
        }
        return nil
    }
    // R11d F-C01: constant-time compare. The pin/cert key check is not a
    // secret-derivation step (both values are public Ed25519 pubkeys), but
    // using a constant-time compare here keeps a uniform discipline across
    // every key-equality check in the cockpit and avoids any future timing
    // side channel if the pin source ever changes to something secret-derived.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

private extension Substring {
    var asString: String { String(self) }
}

private struct NativeBirthCertificate: Decodable, Equatable {
    let version: String
    let timestamp: String
    let machineUUID: String
    let sePublicKeyBase64: String
    let seKeyID: String
    let valuesHashViaCharacterValues: String
    let hvAnchor: String
    let coldRootPublicKeyHex: String
    let soulAnchorPublicKeyHex: String
    let operatorVoiceAnchorSHA256Hex: String
    let operatorID: String
    let subjectID: String
    let signatureHex: String
    // R11h F-E31 — optional witness attestations. Each witness independently
    // signs the canonical BC payload (which does NOT include `witnesses`), so
    // backward compat is preserved: an old BC without this field still loads,
    // and a new BC's witness sigs verify against the same canonical bytes the
    // cold-root signature is computed over.
    let witnesses: [Witness]?
    // R11h F-E14 — OpenTimestamps receipt for the cold-root public key.
    // Base64-encoded .ots proof file produced at ceremony time by
    // `ots stamp <pubkey-bytes-file>`. Verification is operator-driven
    // (`ots verify`) once the Bitcoin block confirming the timestamp has
    // accrued enough confirmations — the cockpit cannot verify this at
    // boot because OTS verification requires online Bitcoin chain access.
    // Cockpit's role: PRESERVE the field byte-exact, emit a WARN audit
    // when missing (degraded external-anchoring evidence), emit an INFO
    // audit listing the receipt size when present. NOT a verifier gate.
    // Field is OPTIONAL for backward compat with pre-R11h BCs.
    let coldRootOTSReceiptB64: String?
    // R11h F-E16 — Software Bill of Materials integrity. The ceremony
    // produces a canonical SBOM listing every source file SHA-256 +
    // dylib version pinned at build time, signs it with the cold root,
    // and embeds (sha256-of-sbom, cold-root-signature-over-sha256) here.
    // The SBOM bytes themselves live at the canonical
    // `~/.jarvis/identity/sbom.txt` path so that an out-of-tree
    // verifier can reconstruct the exact build inputs. On verify,
    // the cockpit hashes the on-disk SBOM, compares to the field,
    // and verifies the cold-root signature over the hash. Both fields
    // are OPTIONAL for additive backward compat — pre-R11h BCs that
    // omit them load with a WARN audit instead of a reject.
    let sbomSha256Hex: String?
    let sbomColdRootSignatureHex: String?

    // R11j F-F10 — payload v=2 binding fields. nil → treated as v=1
    // (legacy backward compat). Present and == 2 → verifier MUST
    // recompute and check the four binding hashes below. The bindings
    // live INSIDE canonicalPayloadData so they're covered by the
    // cold-root signature; an attacker who strips witnesses/OTS/SBOM
    // from the BC cannot also restore the matching binding hash.
    let payloadVersion: Int?
    let witnessesRootSha256Hex: String?
    let coldRootOTSReceiptSha256Hex: String?
    let sbomBindingSha256Hex: String?
    let sbomColdRootSignatureSha256Hex: String?

    struct Witness: Decodable, Equatable {
        let name: String
        let role: String
        let pubkeyHex: String
        let signatureHex: String
        let attestationTimestamp: Int64
        let jurisdiction: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case role
            case pubkeyHex = "pubkey_hex"
            case signatureHex = "signature_hex"
            case attestationTimestamp = "attestation_timestamp"
            case jurisdiction
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case timestamp
        case machineUUID
        case sePublicKeyBase64
        case seKeyID
        case valuesHashViaCharacterValues
        case hvAnchor
        case coldRootPublicKeyHex
        case soulAnchorPublicKeyHex = "soul_anchor_pub"
        case operatorVoiceAnchorSHA256Hex
        case operatorID
        case subjectID
        case signatureHex
        case witnesses
        case coldRootOTSReceiptB64 = "cold_root_ots_receipt_b64"
        case sbomSha256Hex = "sbom_sha256_hex"
        case sbomColdRootSignatureHex = "sbom_cold_root_signature_hex"
        case payloadVersion = "payload_version"
        case witnessesRootSha256Hex = "witnesses_root_sha256_hex"
        case coldRootOTSReceiptSha256Hex = "cold_root_ots_receipt_sha256_hex"
        case sbomBindingSha256Hex = "sbom_binding_sha256_hex"
        case sbomColdRootSignatureSha256Hex = "sbom_cold_root_signature_sha256_hex"
    }

    var canonicalPayloadData: Data {
        var object: [String: String] = [
            "cold_root_public_key": coldRootPublicKeyHex,
            "hv_anchor": hvAnchor,
            "machine_uuid": machineUUID,
            "operator_id": operatorID,
            "operator_voice_anchor_sha256": operatorVoiceAnchorSHA256Hex,
            "se_key_id": seKeyID,
            "se_pubkey": sePublicKeyBase64,
            "soul_anchor_pub": soulAnchorPublicKeyHex,
            "subject_id": subjectID,
            "timestamp": timestamp,
            "v": version,
            "values_hash_via_CharacterValues": valuesHashViaCharacterValues,
        ]
        // R11j F-F10 — v=2 binding hashes live inside the canonical
        // payload so they're cold-root-signed. Empty-string sentinel
        // for absent fields preserves verifiability when the original
        // R11h additive field was nil at mint.
        if let v = payloadVersion, v >= 2 {
            object["payload_version"] = String(v)
            object["witnesses_root_sha256_hex"] = witnessesRootSha256Hex ?? ""
            object["cold_root_ots_receipt_sha256_hex"] = coldRootOTSReceiptSha256Hex ?? ""
            object["sbom_binding_sha256_hex"] = sbomBindingSha256Hex ?? ""
            object["sbom_cold_root_signature_sha256_hex"] = sbomColdRootSignatureSha256Hex ?? ""
        }
        let fields = object.keys.sorted().map { key in
            "\"\(Self.escape(key))\":\"\(Self.escape(object[key] ?? ""))\""
        }.joined(separator: ",")
        return Data(("{" + fields + "}").utf8)
    }

    // R11j F-F10 — canonical bytes representation of the witnesses
    // array used as input to witnesses_root_sha256_hex binding. Sorted
    // by witness name for deterministic ordering. Empty/nil → literal
    // "[]" so the sentinel is verifiable and binds absence.
    //
    // IMPORTANT: `signature_hex` is EXCLUDED from the canonical bytes.
    // Reason: witnesses sign the BC's canonicalPayloadData, which
    // contains the witnesses_root binding hash. Including each
    // witness's signature in that hash would be circular. Excluding
    // sig_hex is safe because each witness's pubkey IS bound — an
    // attacker cannot swap in a forged signature without the witness's
    // private key, so the verifyWitnesses pass still rejects.
    static func canonicalWitnessesBytes(_ witnesses: [Witness]?) -> Data {
        guard let ws = witnesses, !ws.isEmpty else { return Data("[]".utf8) }
        let sorted = ws.sorted { a, b in a.name < b.name }
        var entries: [String] = []
        for w in sorted {
            var fields: [String] = []
            fields.append("\"attestation_timestamp\":\(w.attestationTimestamp)")
            if let j = w.jurisdiction {
                fields.append("\"jurisdiction\":\"\(escape(j))\"")
            }
            fields.append("\"name\":\"\(escape(w.name))\"")
            fields.append("\"pubkey_hex\":\"\(escape(w.pubkeyHex))\"")
            fields.append("\"role\":\"\(escape(w.role))\"")
            entries.append("{" + fields.joined(separator: ",") + "}")
        }
        return Data(("[" + entries.joined(separator: ",") + "]").utf8)
    }

    private static func escape(_ value: String) -> String {
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
    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
