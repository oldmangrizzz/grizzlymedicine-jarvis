// OperatorPresence — V4R R10b (R11h F-E20, R11j F-F02)
//
// Surfaces the operator's chosen display name for the BootView header.
// Reads ~/.jarvis/identity/operator.txt using a §7-discipline open: O_NOFOLLOW
// (refuse symlink), O_CLOEXEC, no path traversal allowed. Sanitizes the value
// against an allow-list and caps length at 64 bytes. Falls back to "the
// operator" on any failure — never crashes, never throws, never blocks the
// boot screen.
//
// This is a UI-only concern: the canonical operator identity is bound into
// the Soul Anchor + Birth Certificate, not this file. operator.txt exists
// purely so the boot screen can address its operator by name during the
// 5.6-minute cold prewarm — a dignity affordance, not an identity claim.
//
// R11h F-E20 + R11j F-F02 — operator duress detection (steganographic).
// A second file, ~/.jarvis/identity/operator_duress.txt, may be
// pre-provisioned at ceremony time with a duress alias. If operator.txt
// content matches the duress content at boot, match() returns .duress
// internally but the emitted audit event is STRUCTURALLY IDENTICAL to
// the canonical-match event. The only differentiator visible on the
// audit chain is a 16-byte HMAC `digest_b64` field whose computation
// requires a duress salt stored separately at
// ~/.jarvis/identity/operator_presence_duress_salt.bin (mode 0600,
// never persisted to the BC). An attacker reading the BC + audit chain
// cannot determine which boots were under duress without that salt.
// The forensic verifier (scripts/duress_audit_inspect.py) reads the
// duress salt + audit chain post-incident and flags the duress boots.
//
// Threat model note: a coercer with read access to ~/.jarvis/identity/ may
// observe both files exist but cannot read either (mode 0600). Operator
// chooses a duress phrase such that the coercer's observation of the
// canonical phrase does not reveal the duress phrase pattern.

import CryptoKit
import Foundation

enum OperatorPresence {
    static let fallback = "the operator"
    static let maxBytes = 64

    /// F-E20 outcome enum for the duress branch.
    enum OperatorMatch: Sendable, Equatable {
        /// operator.txt is present, well-formed, and not equal to duress phrase.
        case canonical
        /// operator.txt content equals operator_duress.txt content (coerced provisioning detected).
        case duress
        /// operator.txt could not be read or did not pass §7 discipline / allow-list.
        case none
    }

    /// Reads ~/.jarvis/identity/operator.txt with §7 discipline and returns a
    /// sanitized display name, or the fallback on any failure.
    static func readOperatorName(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        return readAndValidate(
            envVar: "JARVIS_OPERATOR_TXT_PATH",
            canonical: "~/.jarvis/identity/operator.txt",
            env: env
        ) ?? fallback
    }

    /// F-E20 + R11j F-F02: compares operator.txt content against
    /// operator_duress.txt content and emits a steganographic audit
    /// event. Boot path invokes this once per cold start. Never throws,
    /// never refuses; the returned case is the internal semantic, NOT
    /// what the audit chain reveals.
    ///
    /// `publicSaltB64`: 16-byte salt from BC's `operator_presence_salt_b64`
    ///   field (v=2). Forms the HMAC salt for canonical-branch digest.
    /// `duressSaltPath`: filesystem path to 16-byte duress salt. Default
    ///   resolves to ~/.jarvis/identity/operator_presence_duress_salt.bin.
    ///   File mode 0600, owned by same uid. Read failure → branch
    ///   falls back to public salt (audit indistinguishability is then
    ///   one-way: duress entry digestible only if salt later recovered).
    static func match(
        env: [String: String] = ProcessInfo.processInfo.environment,
        publicSaltB64: String? = nil,
        duressSaltPath: String? = nil
    ) -> OperatorMatch {
        guard let canonicalContent = readAndValidate(
            envVar: "JARVIS_OPERATOR_TXT_PATH",
            canonical: "~/.jarvis/identity/operator.txt",
            env: env
        ) else {
            emitMatchAudit(event: "operator_presence_mismatch",
                           fields: ["reason": "operator_txt_invalid_or_missing"])
            return .none
        }

        let duressContent = readAndValidate(
            envVar: "JARVIS_OPERATOR_DURESS_TXT_PATH",
            canonical: "~/.jarvis/identity/operator_duress.txt",
            env: env
        )

        // Resolve salts. Public salt comes from BC (caller passes it);
        // if absent, fall back to a zero-byte salt — leaks "ceremony
        // was pre-R11j" but no operator content. Duress salt is read
        // from a §7-discipline-locked file.
        let publicSalt = decodeSaltB64(publicSaltB64) ?? Data(repeating: 0, count: 16)
        let duressSalt = readDuressSalt(path: duressSaltPath, env: env) ?? publicSalt

        let isDuress: Bool
        if let duress = duressContent, constantTimeEqual(canonicalContent, duress) {
            isDuress = true
        } else {
            isDuress = false
        }

        // R11j F-F02 — single audit event, structurally identical fields,
        // differentiator is digest_b64 (16 bytes of HMAC-SHA256 over
        // operator content, base64). Attacker cannot distinguish without
        // the duress salt file.
        let activeSalt = isDuress ? duressSalt : publicSalt
        let digestB64 = hmacDigest16B64(
            content: canonicalContent,
            salt: activeSalt
        )
        emitMatchAudit(event: "operator_presence_canonical",
                       fields: [
                           "digest_b64": digestB64,
                           "duress_file_present": duressContent == nil ? "false" : "true",
                       ])
        return isDuress ? .duress : .canonical
    }

    // R11j F-F02 helpers.

    /// HMAC-SHA256(content_utf8, salt) → first 16 bytes → base64.
    static func hmacDigest16B64(content: String, salt: Data) -> String {
        let key = SymmetricKey(data: salt)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(content.utf8),
            using: key
        )
        let macData = Data(mac)
        let truncated = macData.prefix(16)
        return truncated.base64EncodedString()
    }

    private static func decodeSaltB64(_ s: String?) -> Data? {
        guard let s = s, !s.isEmpty,
              let d = Data(base64Encoded: s),
              d.count == 16 else { return nil }
        return d
    }

    private static func readDuressSalt(path: String?, env: [String: String]) -> Data? {
        let canonical = "~/.jarvis/identity/operator_presence_duress_salt.bin"
        let resolved: String
        if let p = path {
            resolved = NSString(string: p).expandingTildeInPath
        } else {
            resolved = NativeInsecurePathOverride.resolve(
                envVar: "JARVIS_OPERATOR_DURESS_SALT_PATH",
                canonicalPath: NSString(string: canonical).expandingTildeInPath,
                env: env,
                emitAudit: false
            )
        }
        let flags: Int32 = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let fd = open(resolved, flags)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let modeBits = mode_t(st.st_mode) & 0o777
        let isRegular = (mode_t(st.st_mode) & S_IFMT) == S_IFREG
        guard isRegular, st.st_uid == getuid(), modeBits == 0o600 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 17)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 17) }
        guard n == 16 else { return nil }
        return Data(bytes: buffer, count: 16)
    }

    // MARK: - Internal: shared §7-discipline reader

    /// Returns sanitized content of the file at the resolved path, or nil on
    /// any §7-discipline failure (symlink, wrong owner, wrong mode, wrong
    /// type, oversize, decode failure, empty, allow-list reject). Audits
    /// mode-check failures via the legacy operator_presence_mode_check_failed
    /// event so the existing F-C05 telemetry is preserved.
    private static func readAndValidate(
        envVar: String,
        canonical: String,
        env: [String: String]
    ) -> String? {
        let canonicalExpanded = NSString(string: canonical).expandingTildeInPath
        let path = NativeInsecurePathOverride.resolve(
            envVar: envVar,
            canonicalPath: canonicalExpanded,
            env: env,
            emitAudit: true
        )

        let flags: Int32 = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let fd = open(path, flags)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            auditFstatFailure(path: path, reason: "fstat_errno_\(errno)")
            return nil
        }
        let modeBits = mode_t(st.st_mode) & 0o777
        let isRegular = (mode_t(st.st_mode) & S_IFMT) == S_IFREG
        let myUID = getuid()
        guard isRegular else {
            auditFstatFailure(path: path, reason: "not_regular_file:mode=\(String(modeBits, radix: 8))")
            return nil
        }
        guard st.st_uid == myUID else {
            auditFstatFailure(path: path, reason: "uid_mismatch:expected=\(myUID):actual=\(st.st_uid)")
            return nil
        }
        guard modeBits == 0o600 else {
            auditFstatFailure(path: path, reason: "mode_mismatch:expected=0600:actual=\(String(modeBits, radix: 8))")
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: maxBytes + 1)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, maxBytes + 1) }
        guard n > 0 else { return nil }
        guard n <= maxBytes else { return nil }

        let raw = Data(bytes: buffer, count: n)
        guard let utf8 = String(data: raw, encoding: .utf8) else { return nil }
        let trimmed = utf8.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isAllowed(trimmed) else { return nil }
        return trimmed
    }

    private static func auditFstatFailure(path: String, reason: String) {
        do {
            try NativeSecurityAudit.record("operator_presence_mode_check_failed",
                fields: ["path": path, "reason": reason, "severity": "WARN"])
        } catch {
            fputs("JARVIS audit write failed: \(error)\n", stderr) // [audit-log: discard on I/O failure; secondary diagnostic path]
        }
    }

    private static func emitMatchAudit(event: String, fields: [String: String]) {
        do {
            try NativeSecurityAudit.record(event, fields: fields)
        } catch {
            fputs("JARVIS audit write failed: \(error)\n", stderr) // [audit-log: discard on I/O failure; F-E20 telemetry best-effort]
        }
    }

    /// Constant-time string equality. Branchless byte-wise XOR accumulation
    /// over UTF-8 bytes; never short-circuits on first mismatch. Length
    /// mismatch returns false but folds the length comparison into the
    /// accumulator so even that does not leak timing.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let n = max(aBytes.count, bBytes.count)
        var diff: UInt8 = UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
        for i in 0..<n {
            let av: UInt8 = i < aBytes.count ? aBytes[i] : 0
            let bv: UInt8 = i < bBytes.count ? bBytes[i] : 0
            diff |= (av ^ bv)
        }
        return diff == 0
    }

    /// Allow-list: letters, digits, space, dot, underscore, hyphen.
    /// Intentionally narrow — this string is rendered into a UI label and
    /// must not contain control characters, format characters, or anything
    /// that could be confused for markup.
    private static func isAllowed(_ s: String) -> Bool {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        return s.allSatisfy { allowed.contains($0) }
    }
}
