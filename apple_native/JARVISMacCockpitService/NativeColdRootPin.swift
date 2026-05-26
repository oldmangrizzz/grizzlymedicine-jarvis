// NativeColdRootPin — V4R R11d F-C01
//
// External trust anchor for the cold-root Ed25519 public key.
//
// Why this exists: prior to R11d, the runtime BC verifier checked the BC
// signature against the `coldRootPublicKeyHex` field read from inside the
// BC itself — a self-signed certificate that any attacker with file-write
// on ~/.jarvis/identity/birth_certificate.json could re-mint with a fresh
// keypair. R11c APT walk classified this as CRITICAL: silent voice-identity
// substitution, undetectable to the operator.
//
// This module is the externally-stored trust anchor the BC verifier compares
// the in-cert pubkey against. Lookup order, per R11d F-C01:
//   1. Keychain item (service: "org.grizzlymedicine.jarvis.cold-root",
//      account: "public-key-v1", local device only, when unlocked)
//   2. File pin: ~/.jarvis/identity/cold_root_public.key (mode 0600, 32 raw bytes)
//   3. Throw .coldRootNotPinned — boot fails closed (AGENTS.md §3).
//
// The ceremony writes BOTH the Keychain item and the file pin. The file pin
// is the cold-recovery path when the Keychain is wiped (system reset,
// Keychain Access drag-delete, etc).
//
// Test harnesses can override the file pin path and Keychain service suffix
// via JARVIS_COLD_ROOT_PIN_FILE / JARVIS_COLD_ROOT_KEYCHAIN_SUFFIX env vars,
// but only when the binary is built with -D JARVIS_INSECURE_PATHS (test
// target only — production builds never consult these envs).

import Foundation
import Security

enum NativeColdRootPinError: Error, LocalizedError {
    case coldRootNotPinned(reason: String)
    case pinFileMalformed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .coldRootNotPinned(let r):
            return "no externally-pinned cold root trust anchor available: \(r)"
        case .pinFileMalformed(let p, let r):
            return "cold root pin file at \(p) malformed: \(r)"
        }
    }
}

enum NativeColdRootPin {
    /// Canonical Keychain service identifier for the cold-root public key.
    /// MUST match the value used by CeremonyOrchestrator at pinning time.
    static let canonicalKeychainService = "org.grizzlymedicine.jarvis.cold-root"
    static let canonicalKeychainAccount = "public-key-v1"

    /// Canonical on-disk pin path (cold-recovery fallback for the Keychain item).
    static let canonicalPinFilePath = "~/.jarvis/identity/cold_root_public.key"

    /// Expected raw byte length for an Ed25519 public key.
    static let publicKeyByteLength = 32

    /// Load the pinned cold-root public key. Lookup order: Keychain, then file.
    /// Throws `.coldRootNotPinned` if neither source yields a 32-byte key.
    ///
    /// `env` is supplied for testability and for the F-C02 compile-flag-gated
    /// override path; production binaries pass nothing and the canonical
    /// paths are used unconditionally.
    static func loadPinnedColdRootPublicKey(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Data {
        // 1) Keychain lookup.
        let keychainService = resolveKeychainService(env: env)
        if let kcData = loadFromKeychain(service: keychainService, account: canonicalKeychainAccount) {
            guard kcData.count == publicKeyByteLength else {
                throw NativeColdRootPinError.pinFileMalformed(
                    path: "keychain:\(keychainService)/\(canonicalKeychainAccount)",
                    reason: "keychain item is \(kcData.count) bytes, expected \(publicKeyByteLength)"
                )
            }
            return kcData
        }

        // 2) File pin lookup — §7 discipline (R11f F-D02 + F-D03, extended in
        // R11l α.2 F-KD03 + F-KD04).
        //
        // R11f closed the leaf-only gaps:
        //   - open(... O_NOFOLLOW | O_CLOEXEC) refuses leaf symlinks at the fd
        //   - fstat enforces regular-file + uid==getuid() + mode==0600
        //
        // R11l α.2 extends the discipline via the shared SecureFileRead helper:
        //   - realpath() + per-component openat(O_NOFOLLOW) walk closes
        //     F-KD04 (intermediate symlinks like ~/.jarvis -> /tmp/attacker)
        //   - parent dir mode==0700 + uid==operator closes F-KD03
        //     (attacker chmods identity dir to 0755 + plants 0600 leaf)
        //   - expectedSize: 32 enforces fixed Ed25519 pubkey byte length
        // Identical pattern now used by NativeBirthCertificateVerifier,
        // OperatorPresence, and NativeAuditChainAnchor.
        let pinPath = resolvePinFilePath(env: env)
        var policy = SecureFileReadPolicy()
        policy.expectedSize = publicKeyByteLength
        do {
            let data = try readSection7Anchored(path: pinPath, policy: policy)
            return data
        } catch let err as SecureFileReadError {
            switch err.reason {
            case .absent:
                // Fall through to fail-closed below.
                break
            case .symlinkRefused:
                auditSafely("cold_root_pin_file_check_failed", fields: [
                    "path": pinPath,
                    "reason": "symlink_refused",
                    "severity": "CRITICAL",
                ])
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "symlink_refused (ELOOP under O_NOFOLLOW walk)"
                )
            case let .parentModeMismatch(actual, expected):
                auditSafely("cold_root_pin_file_check_failed", fields: [
                    "path": pinPath,
                    "reason": "parent_mode_mismatch",
                    "expected_parent_mode": String(expected, radix: 8),
                    "actual_parent_mode": String(actual, radix: 8),
                    "severity": "CRITICAL",
                ])
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "parent_mode_mismatch:expected=\(String(expected, radix: 8)):actual=\(String(actual, radix: 8))"
                )
            case let .parentUIDMismatch(actual, expected):
                auditSafely("cold_root_pin_file_check_failed", fields: [
                    "path": pinPath,
                    "reason": "parent_uid_mismatch",
                    "expected_parent_uid": String(expected),
                    "actual_parent_uid": String(actual),
                    "severity": "CRITICAL",
                ])
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "parent_uid_mismatch:expected=\(expected):actual=\(actual)"
                )
            case let .leafNotRegular(mode):
                auditSafely("cold_root_pin_file_check_failed", fields: [
                    "path": pinPath,
                    "reason": "not_regular_file",
                    "mode": String(mode, radix: 8),
                    "severity": "CRITICAL",
                ])
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "not_regular_file:mode=\(String(mode, radix: 8))"
                )
            case let .leafUIDMismatch(actual, expected):
                auditSafely("cold_root_pin_file_check_failed", fields: [
                    "path": pinPath,
                    "reason": "uid_mismatch",
                    "expected_uid": String(expected),
                    "actual_uid": String(actual),
                    "severity": "CRITICAL",
                ])
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "uid_mismatch:actual=\(actual):expected=\(expected)"
                )
            case let .leafModeMismatch(actual, expected):
                auditSafely("cold_root_pin_file_check_failed", fields: [
                    "path": pinPath,
                    "reason": "mode_mismatch",
                    "expected_mode": String(expected, radix: 8),
                    "actual_mode": String(actual, radix: 8),
                    "severity": "CRITICAL",
                ])
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "mode_mismatch:expected=\(String(expected, radix: 8)):actual=\(String(actual, radix: 8))"
                )
            case let .leafSizeMismatch(actual, expected):
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: "size_mismatch:actual=\(actual):expected=\(expected)"
                )
            default:
                throw NativeColdRootPinError.pinFileMalformed(
                    path: pinPath,
                    reason: err.description
                )
            }
        } catch {
            throw NativeColdRootPinError.pinFileMalformed(
                path: pinPath,
                reason: "unexpected: \(error.localizedDescription)"
            )
        }

        // 3) Fail closed.
        throw NativeColdRootPinError.coldRootNotPinned(
            reason: "neither Keychain (service: \(keychainService)) nor file pin (\(pinPath)) is populated; the ceremony must seed at least one before any cockpit boot"
        )
    }

    /// Test/ceremony hook: write the pin to BOTH Keychain and file pin path.
    /// On any failure, returns false and the caller decides whether to retry.
    /// Production callers (CeremonyOrchestrator) treat a false return as a
    /// ceremony hard-fail; tests use it for setup.
    @discardableResult
    static func sealPinnedColdRootPublicKey(
        _ publicKey: Data,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard publicKey.count == publicKeyByteLength else { return false }
        let keychainOK = writeToKeychain(
            service: resolveKeychainService(env: env),
            account: canonicalKeychainAccount,
            data: publicKey
        )
        let fileOK = writePinFile(publicKey, path: resolvePinFilePath(env: env))
        return keychainOK && fileOK
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

    private static func resolvePinFilePath(env: [String: String]) -> String {
        // R11d F-C02: routed through the shared NativeInsecurePathOverride
        // helper so override consumption fires `insecure_path_override_active`
        // exactly once per process per (envVar, value) pair.
        return NativeInsecurePathOverride.resolve(
            envVar: "JARVIS_COLD_ROOT_PIN_FILE",
            canonicalPath: canonicalPinFilePath,
            env: env
        )
    }

    private static func expandHome(_ path: String, env: [String: String]) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        #if DEBUG && JARVIS_INSECURE_PATHS
        let home = env["JARVIS_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #endif
        guard path.count > 1 else { return home }
        return URL(fileURLWithPath: home).appendingPathComponent(String(path.dropFirst(2))).path
    }

    // MARK: - Keychain primitives

    private static func loadFromKeychain(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    private static func writeToKeychain(service: String, account: String, data: Data) -> Bool {
        // Remove any prior item under this (service, account) so updates are clean.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - File pin primitives

    private static func writePinFile(_ data: Data, path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
            return true
        } catch {
            return false
        }
    }

    /// Test-only teardown: remove pin from Keychain and file (does not throw).
    /// Safe to call on missing pins. Honours env overrides only when built
    /// with -D JARVIS_INSECURE_PATHS.
    static func unsealForTest(env: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG && JARVIS_INSECURE_PATHS
        let service = resolveKeychainService(env: env)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: canonicalKeychainAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let path = resolvePinFilePath(env: env)
        try? FileManager.default.removeItem(atPath: path)
        #endif
    }

    // R11f F-D02 + F-D03: audit emission helper. Wraps NativeSecurityAudit.record
    // in do/catch because the pin load path must NOT throw out of audit-write
    // failure — audit is a secondary diagnostic; the primary deny decision
    // (throw .pinFileMalformed) is returned regardless of audit success.
    private static func auditSafely(_ event: String, fields: [String: Any]) {
        do { try NativeSecurityAudit.record(event, fields: fields) }
        catch { fputs("JARVIS audit write failed for \(event): \(error)\n", stderr) } // [audit-log: discard on I/O failure; secondary diagnostic path]
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
