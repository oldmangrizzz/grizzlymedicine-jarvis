// NativeAuditChainAnchor — V4R R11f F-D01
//
// R11e attack class A2 (audit chain total rewrite): an attacker with uid =
// operator can read the entire audit chain, recompute a fresh internally-
// consistent chain with their chosen events, and rewrite the file. Round-one
// chain validator (JARVISAuditVerifySwift) only checks internal consistency
// (seq monotonic, prev_sha links, sha recomputes). Without an external
// anchor the chain provides ZERO tamper evidence against the exact threat it
// exists to defend against — uid=operator file write.
//
// R11f closes that gap with an auxiliary signing key pattern (Option B):
//
//   1. Cold root private key STAYS OFFLINE (air-gapped). It is NOT unsealed
//      on every boot. Mass-using the cold root for runtime signatures is the
//      anti-pattern this whole architecture exists to avoid.
//
//   2. The ceremony mints an auxiliary Curve25519 signing keypair, signs a
//      certificate { aux_pubkey_hex, valid_from, valid_until, cold_root_sig }
//      with the cold root, and pins:
//        - aux PRIVATE key to Keychain
//          (service: "org.grizzlymedicine.jarvis.cold-root-aux",
//           account: "signing-key-v1",
//           kSecAttrAccessibleWhenUnlockedThisDeviceOnly, non-syncable —
//           same discipline as F-C01 pin storage)
//        - aux certificate JSON to ~/.jarvis/identity/cold_root_aux_certificate.json
//          (mode 0600)
//
//   3. At every cockpit boot, AFTER BC verify + manifest verify succeed,
//      the runtime emits an "audit_chain_boot_anchor" record signed by the
//      aux private key. The anchor binds boot_id + prev_chain_tail_sha into
//      the audit chain.
//
//   4. The offline verifier (JARVISAuditVerifySwift) is given the cold root
//      pubkey and the aux cert. It verifies the cert's cold_root_sig, then
//      verifies every anchor record's signature against the cert's aux
//      pubkey. If a non-empty chain contains ZERO anchors, the verifier
//      flags total-rewrite suspicion.
//
// The threat model: an attacker with uid=operator can still rewrite the
// chain — they just cannot mint valid anchors without the aux private key,
// which lives in Keychain bound to the live device under
// kSecAttrAccessibleWhenUnlockedThisDeviceOnly. A motivated attacker who
// can also unlock Keychain at runtime can extract the aux key — that's a
// strictly stronger position than file-write alone, and it forces them
// past the lock-screen + Touch ID gate to do it.
//
// Ceremony-side tooling (cold-root signing, cert mint) is OUT OF SCOPE for
// R11f — only the cockpit-side consumption + verifier-side check are wired.
// The sealAuxForTest seam exists so APTRedTeamTests can exercise the full
// path without a real ceremony.

import CryptoKit
import Foundation
import Security

enum NativeAuditChainAnchorError: Error, LocalizedError {
    case auxSigningKeyMissing(reason: String)
    case auxCertificateMissing(path: String)
    case auxCertificateMalformed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .auxSigningKeyMissing(let r):
            return "audit chain aux signing key unavailable: \(r)"
        case .auxCertificateMissing(let p):
            return "audit chain aux certificate missing at \(p)"
        case .auxCertificateMalformed(let p, let r):
            return "audit chain aux certificate at \(p) malformed: \(r)"
        }
    }
}

enum NativeAuditChainAnchor {
    static let canonicalKeychainService = "org.grizzlymedicine.jarvis.cold-root-aux"
    static let canonicalKeychainAccount = "signing-key-v1"
    static let canonicalCertificatePath = "~/.jarvis/identity/cold_root_aux_certificate.json"
    static let anchorEvent = "audit_chain_boot_anchor"

    // MARK: - Boot anchor emission (cockpit side)

    /// Emits a cold-root-aux-signed boot anchor record into the audit chain.
    /// Throws if the aux signing key is missing, the aux certificate is
    /// missing/malformed, or the underlying chain append fails. Must be
    /// invoked AFTER BC + manifest verification succeed in the boot path.
    static func sealBootAnchor(env: [String: String] = ProcessInfo.processInfo.environment) throws {
        let signingKey = try loadAuxSigningKey(env: env)
        // Presence check on the certificate. The cockpit doesn't need to
        // verify the cert against the cold root (that's the verifier's job)
        // but if the cert isn't on disk an offline verifier cannot complete
        // its work, so fail closed here.
        _ = try loadAuxCertificateData(env: env)

        let bootId = UUID().uuidString
        let auditRoot = NativeAuditChainAnchor.resolveAuditRoot(env: env)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: auditRoot),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let parentDir = URL(fileURLWithPath: auditRoot)

        var emittedAnchorSha: String? = nil

        try appendChainedAuditRecord(parentDir: parentDir, file: "network_security.jsonl") { priorTail in
            let prevSha: String
            let seq: Int
            if let tail = priorTail, !tail.isEmpty {
                let parsed = (try? JSONSerialization.jsonObject(with: tail)) as? [String: Any]
                prevSha = (parsed?["sha"] as? String) ?? NativeSecurityAudit.chainGenesisPrevSha
                seq = ((parsed?["seq"] as? Int) ?? 0) + 1
            } else {
                prevSha = NativeSecurityAudit.chainGenesisPrevSha
                seq = 1
            }
            let ts = Int(Date().timeIntervalSince1970)

            // Sign the canonical-sorted JSON of {boot_id, event,
            // prev_chain_tail_sha, ts}. The signature is over the bare
            // semantics, NOT over the chain fields (prev_sha, seq, sha) —
            // those are file-position metadata, while the signed payload
            // identifies WHAT this anchor asserts.
            let signedFields: [String: Any] = [
                "boot_id": bootId,
                "event": anchorEvent,
                "prev_chain_tail_sha": prevSha,
                "ts": ts
            ]
            let signedData = try JSONSerialization.data(withJSONObject: signedFields, options: [.sortedKeys])
            let sigData = try signingKey.signature(for: signedData)
            let sigHex = sigData.map { String(format: "%02x", $0) }.joined()

            var payload: [String: Any] = signedFields
            payload["anchor_signature_hex"] = sigHex
            payload["prev_sha"] = prevSha
            payload["seq"] = seq

            let preShaData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let sha = SHA256.hash(data: preShaData).map { String(format: "%02x", $0) }.joined()
            payload["sha"] = sha
            emittedAnchorSha = sha
            var finalData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            finalData.append(0x0A)
            return finalData
        }

        // F-E13: external timestamp evidence. Retry any prior pending
        // submissions first (so a transient offline boot eventually
        // catches up), then submit this boot's anchor. Both calls are
        // no-ops when ~/.jarvis/identity/tsa_urls.json is absent.
        NativeAuditTSAClient.retryPending(env: env)
        if let sha = emittedAnchorSha {
            NativeAuditTSAClient.submit(anchorShaHex: sha, env: env)
        }
    }

    // MARK: - Verifier helpers (used by JARVISAuditVerifySwift)

    struct ParsedAuxCertificate {
        let auxPublicKey: Curve25519.Signing.PublicKey
        let validFrom: Int
        let validUntil: Int
    }

    /// Parses an aux certificate JSON blob and verifies cold_root_sig over
    /// the canonical-sorted JSON of {aux_pubkey_hex, valid_from, valid_until}.
    /// Returns the parsed aux public key on success; nil on any failure.
    static func parseAndVerifyCertificate(
        certData: Data,
        coldRootPublicKey: Curve25519.Signing.PublicKey
    ) -> ParsedAuxCertificate? {
        guard let parsed = try? JSONSerialization.jsonObject(with: certData) as? [String: Any] else { return nil }
        guard let auxHex = parsed["aux_pubkey_hex"] as? String,
              let validFrom = parsed["valid_from"] as? Int,
              let validUntil = parsed["valid_until"] as? Int,
              let sigHex = parsed["cold_root_sig"] as? String
        else { return nil }
        guard let auxBytes = Data(hexStringForAnchor: auxHex),
              let sigBytes = Data(hexStringForAnchor: sigHex),
              let auxPub = try? Curve25519.Signing.PublicKey(rawRepresentation: auxBytes)
        else { return nil }
        let signedFields: [String: Any] = [
            "aux_pubkey_hex": auxHex,
            "valid_from": validFrom,
            "valid_until": validUntil
        ]
        guard let signedData = try? JSONSerialization.data(withJSONObject: signedFields, options: [.sortedKeys]) else {
            return nil
        }
        guard coldRootPublicKey.isValidSignature(sigBytes, for: signedData) else { return nil }
        return ParsedAuxCertificate(auxPublicKey: auxPub, validFrom: validFrom, validUntil: validUntil)
    }

    /// Verifies a single audit record's anchor signature against the aux
    /// public key. Returns true iff `record.event == anchorEvent` AND
    /// the signature over canonical-sorted JSON of {boot_id, event,
    /// prev_chain_tail_sha, ts} validates.
    static func verifyAnchorSignature(
        record: [String: Any],
        auxPublicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        guard (record["event"] as? String) == anchorEvent else { return false }
        guard let bootId = record["boot_id"] as? String,
              let prevChainTailSha = record["prev_chain_tail_sha"] as? String,
              let ts = record["ts"] as? Int,
              let sigHex = record["anchor_signature_hex"] as? String,
              let sigBytes = Data(hexStringForAnchor: sigHex)
        else { return false }
        let signedFields: [String: Any] = [
            "boot_id": bootId,
            "event": anchorEvent,
            "prev_chain_tail_sha": prevChainTailSha,
            "ts": ts
        ]
        guard let signedData = try? JSONSerialization.data(withJSONObject: signedFields, options: [.sortedKeys]) else {
            return false
        }
        return auxPublicKey.isValidSignature(sigBytes, for: signedData)
    }

    // MARK: - Aux signing key + certificate loaders

    private static func loadAuxSigningKey(env: [String: String]) throws -> Curve25519.Signing.PrivateKey {
        let service = resolveKeychainService(env: env)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: canonicalKeychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let raw = item as? Data else {
            throw NativeAuditChainAnchorError.auxSigningKeyMissing(
                reason: "Keychain lookup failed for service=\(service) account=\(canonicalKeychainAccount), OSStatus=\(status)"
            )
        }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        } catch {
            throw NativeAuditChainAnchorError.auxSigningKeyMissing(
                reason: "Keychain payload not a valid Curve25519 private key: \(error.localizedDescription)"
            )
        }
    }

    private static func loadAuxCertificateData(env: [String: String]) throws -> Data {
        let path = resolveCertificatePath(env: env)
        // R11l α.2 F-KD02/03/04: route through SecureFileRead. realpath +
        // per-component openat(O_NOFOLLOW) walk + parent dir mode 0700 +
        // uid==operator verify + leaf mode 0600 + uid==operator + regular
        // file. Replaces the prior FileManager.fileExists + Data(contentsOf:)
        // anti-pattern which followed symlinks and never verified the parent
        // directory. ENOENT anywhere in the walk surfaces as auxCertificate-
        // Missing (same fail-closed semantics as before).
        do {
            return try readSection7Anchored(path: path)
        } catch let err as SecureFileReadError {
            if case .absent = err.reason {
                throw NativeAuditChainAnchorError.auxCertificateMissing(path: path)
            }
            throw NativeAuditChainAnchorError.auxCertificateMalformed(
                path: path, reason: err.description
            )
        } catch {
            throw NativeAuditChainAnchorError.auxCertificateMalformed(
                path: path, reason: "unreadable: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Test seam

    /// Test-only ceremony stand-in. Writes both the aux private key (to
    /// Keychain) and the aux certificate (to disk) so APTRedTeamTests can
    /// exercise sealBootAnchor + verifier round-trip without a real cold
    /// root key off-machine. Honours env overrides only when built with
    /// -D JARVIS_INSECURE_PATHS.
    @discardableResult
    static func sealAuxForTest(
        privateKey: Curve25519.Signing.PrivateKey,
        certificate: Data,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG && JARVIS_INSECURE_PATHS
        let service = resolveKeychainService(env: env)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: canonicalKeychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: canonicalKeychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: privateKey.rawRepresentation
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { return false }

        let certPath = resolveCertificatePath(env: env)
        let certURL = URL(fileURLWithPath: certPath)
        do {
            try FileManager.default.createDirectory(
                at: certURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try certificate.write(to: certURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: certPath
            )
        } catch {
            return false
        }
        return true
        #else
        // F-E32: release-build no-op. The test seam writes the aux private
        // key to Keychain; in release we refuse to honour it so an attacker
        // who achieves in-process code execution cannot overwrite the
        // operator's aux key with theirs. Mirrors unsealAuxForTest gating.
        _ = privateKey
        _ = certificate
        _ = env
        return false
        #endif
    }

    /// Test-only teardown: remove aux private key from Keychain and the
    /// cert file from disk. No-op on missing items. Honours env overrides
    /// only when built with -D JARVIS_INSECURE_PATHS.
    static func unsealAuxForTest(env: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG && JARVIS_INSECURE_PATHS
        let service = resolveKeychainService(env: env)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: canonicalKeychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        try? FileManager.default.removeItem(atPath: resolveCertificatePath(env: env))
        #endif
    }

    /// Helper for ceremony-side and test-side: mint an aux certificate
    /// JSON blob signed by the given cold root private key. Cockpit code
    /// NEVER calls this in production — the cold root key never lives in
    /// process memory at runtime. Exposed for test fixtures only.
    static func mintAuxCertificate(
        auxPublicKey: Curve25519.Signing.PublicKey,
        validFrom: Int,
        validUntil: Int,
        coldRootSigningKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let auxHex = auxPublicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let signedFields: [String: Any] = [
            "aux_pubkey_hex": auxHex,
            "valid_from": validFrom,
            "valid_until": validUntil
        ]
        let signedData = try JSONSerialization.data(withJSONObject: signedFields, options: [.sortedKeys])
        let sig = try coldRootSigningKey.signature(for: signedData)
        let sigHex = sig.map { String(format: "%02x", $0) }.joined()
        var cert: [String: Any] = signedFields
        cert["cold_root_sig"] = sigHex
        return try JSONSerialization.data(withJSONObject: cert, options: [.sortedKeys, .prettyPrinted])
    }

    // MARK: - Path / service resolution

    private static func resolveKeychainService(env: [String: String]) -> String {
        #if DEBUG && JARVIS_INSECURE_PATHS
        if let suffix = env["JARVIS_COLD_ROOT_KEYCHAIN_SUFFIX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !suffix.isEmpty {
            return canonicalKeychainService + "-" + suffix
        }
        #endif
        return canonicalKeychainService
    }

    private static func resolveCertificatePath(env: [String: String]) -> String {
        #if DEBUG && JARVIS_INSECURE_PATHS
        if let override = env["JARVIS_COLD_ROOT_AUX_CERT_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        #endif
        return NSString(string: canonicalCertificatePath).expandingTildeInPath
    }

    private static func resolveAuditRoot(env: [String: String]) -> String {
        #if DEBUG && JARVIS_INSECURE_PATHS
        if let override = env["JARVIS_AUDIT_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        #endif
        return NSString(string: "~/.jarvis/audit").expandingTildeInPath
    }
}

// Hex decoding helper. Lives here (not in CryptoKit) because we need lenient
// hex parsing for cert payloads. The verifier tool ships its own copy.
private extension Data {
    init?(hexStringForAnchor hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}
