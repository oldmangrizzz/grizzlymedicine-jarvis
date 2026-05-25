// OperatorErrorCode.swift
// Side-channel hardening: operator-facing error codes, UI-safe messages, and
// audit-detail redaction chokepoint.
//
// RULE: Only `operatorMessage(_:)` may appear in UI-facing strings.
//       Raw `error.localizedDescription` must flow through `auditDetail(_:)`
//       before reaching any audit log writer.

import CryptoKit
import Foundation

// ─── Operator error codes ─────────────────────────────────────────────────────

public enum OperatorErrorCode: String, Sendable {
    case writeFailed             = "WRITE_FAILED"
    case verifyFailed            = "VERIFY_FAILED"
    case bindFailed              = "BIND_FAILED"
    case ceremonyArtifactMissing = "CEREMONY_ARTIFACT_MISSING"
    case usbUnavailable          = "USB_UNAVAILABLE"
    case voiceAnchorRejected     = "VOICE_ANCHOR_REJECTED"
    case auditChainBroken        = "AUDIT_CHAIN_BROKEN"
    case seUnavailable           = "SE_UNAVAILABLE"
    case networkRefused          = "NETWORK_REFUSED"
    case internalError           = "INTERNAL_ERROR"
}

/// Returns a single-line, UI-safe, operator-toned message for the given error code.
/// Contains no paths, errnos, internal state, or stack frames.
public func operatorMessage(_ code: OperatorErrorCode) -> String {
    switch code {
    case .writeFailed:             return "Write refused: WRITE_FAILED."
    case .verifyFailed:            return "Verification refused: VERIFY_FAILED."
    case .bindFailed:              return "Bind refused: BIND_FAILED."
    case .ceremonyArtifactMissing: return "Ceremony artifact absent: CEREMONY_ARTIFACT_MISSING."
    case .usbUnavailable:          return "USB path unavailable: USB_UNAVAILABLE."
    case .voiceAnchorRejected:     return "Voice anchor refused: VOICE_ANCHOR_REJECTED."
    case .auditChainBroken:        return "Audit chain integrity failure: AUDIT_CHAIN_BROKEN."
    case .seUnavailable:           return "Secure Enclave unreachable: SE_UNAVAILABLE."
    case .networkRefused:          return "Network connection refused: NETWORK_REFUSED."
    case .internalError:           return "Internal failure: INTERNAL_ERROR."
    }
}

// ─── Path/tag fingerprinting ──────────────────────────────────────────────────

/// Returns the first 8 hex characters of the SHA-256 digest of the input string.
/// Use this to include a correlatable fingerprint in audit fields without exposing
/// raw file paths, key tags, or other PII.
func sha256prefix8(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
}

// ─── Audit-detail redaction chokepoint ───────────────────────────────────────

/// Sanitise a raw error or detail string before it reaches an audit log writer.
///
/// Default behaviour (redacted): replaces every POSIX absolute path token
/// (`/…`) with `[path:<fp8>]` where `<fp8>` is the sha256-prefix-8 fingerprint.
/// This lets audit readers correlate events without learning the path.
///
/// Pass `unredacted: true` **only** from explicitly authorised internal paths
/// (e.g. a sealed audit sink with no console or UI output).
func auditDetail(_ s: String, unredacted: Bool = false) -> String {
    guard !unredacted else { return s }
    var result = s
    // Scan whitespace-delimited tokens; replace those that look like absolute paths.
    // Delimiters are generous to catch paths embedded in sentences or key=value pairs.
    let delimiters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"',:;()[]{}|"))
    let tokens = s.components(separatedBy: delimiters)
    var replaced = Set<String>()
    for token in tokens {
        guard !token.isEmpty, !replaced.contains(token) else { continue }
        // Strip trailing punctuation to isolate the path itself.
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"',:;.()[]{}|"))
        guard stripped.hasPrefix("/"), stripped.count > 1 else { continue }
        result = result.replacingOccurrences(of: stripped, with: "[path:\(sha256prefix8(stripped))]")
        replaced.insert(stripped)
    }
    return result
}
