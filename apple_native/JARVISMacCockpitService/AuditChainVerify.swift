import CryptoKit
import Foundation

// AuditChainVerify — V4R R11l α.3 F-KE02
//
// Audit chain integrity verifier. Detects truncate-zero, genesis corruption,
// and broken hash-chain links in the JSONL audit log produced by
// NativeSecurityAudit + SecureFileWrite.appendChainedAuditRecord.
//
// THREAT MODEL NOTE (binding, see α.3 gate doc):
//   This is the PRIMARY integrity control for the audit chain. UF_APPEND
//   (F-KE03 / α.3 B.1) is defense-in-depth only — uid=operator attacker can
//   clear UF_APPEND. The hash chain detects truncate / replace / forge
//   cryptographically. In-threat-model filesystem-flag coverage requires
//   SF_APPEND via privileged helper (α.3.1, separate cut).
//
// Chain format (matches NativeSecurityAudit.swift):
//   Each line is a JSON object containing at minimum:
//     - "seq": Int (1-indexed, monotonic +1)
//     - "prev_sha": String (64-char hex SHA-256 of prior record's canonical
//       JSON sans `sha`; or "0" × 64 for genesis)
//     - "sha": String (64-char hex SHA-256 of this record's canonical JSON
//       sans the `sha` field itself)
//   Plus arbitrary event-specific fields.
//
// Verification:
//   (a) Size ≥ genesis_header_size when caller asserts non-empty
//   (b) Genesis prev_sha == chainGenesisPrevSha
//   (c) Genesis seq == 1
//   (d) Each record: seq monotonic +1
//   (e) Each record: prev_sha[n] == sha[n-1]
//   (f) Each record: sha == SHA-256(canonical-JSON sans `sha`)
//
// All-zero prev_sha constant is embedded; matches NativeSecurityAudit
// .chainGenesisPrevSha (source of truth: keep these in lockstep).

enum AuditChainVerifyError: Error, CustomStringConvertible, LocalizedError {
    /// Caller asserted non-empty but file/data was empty. Possible truncate-zero attack.
    case empty
    /// First record's `prev_sha` did not equal the genesis sentinel (all zeros).
    case genesisPrevShaMismatch(actual: String)
    /// First record's `seq` was not 1.
    case genesisSeqMismatch(actual: Int)
    /// A line failed to parse as a JSON object with required chain fields.
    case malformedRecord(lineIndex: Int, reason: String)
    /// Recomputed sha did not match the recorded sha at the given seq.
    case shaMismatch(seq: Int, recorded: String, recomputed: String)
    /// prev_sha at this seq did not equal the prior record's sha.
    case prevShaMismatch(seq: Int, recorded: String, expected: String)
    /// seq was not the expected monotonic +1 increment.
    case seqMismatch(actual: Int, expected: Int)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .empty:
            "audit chain empty — possible truncate-zero attack (audit_chain_truncate_detected)"
        case let .genesisPrevShaMismatch(actual):
            "audit chain genesis prev_sha mismatch — got \(actual), expected \(AuditChainVerify.chainGenesisPrevSha)"
        case let .genesisSeqMismatch(actual):
            "audit chain genesis seq=\(actual), expected 1"
        case let .malformedRecord(idx, reason):
            "audit chain line \(idx + 1) malformed: \(reason)"
        case let .shaMismatch(seq, recorded, recomputed):
            "audit chain sha mismatch at seq=\(seq): recorded=\(recorded) recomputed=\(recomputed)"
        case let .prevShaMismatch(seq, recorded, expected):
            "audit chain prev_sha mismatch at seq=\(seq): recorded=\(recorded) expected=\(expected)"
        case let .seqMismatch(actual, expected):
            "audit chain seq=\(actual), expected \(expected)"
        }
    }

    /// Audit-event tag suitable for emission via NativeSecurityAudit.record.
    var auditEventTag: String {
        switch self {
        case .empty:
            "audit_chain_truncate_detected"
        case .genesisPrevShaMismatch, .genesisSeqMismatch:
            "audit_chain_genesis_corrupted"
        case .shaMismatch, .prevShaMismatch, .seqMismatch:
            "audit_chain_broken_link"
        case .malformedRecord:
            "audit_chain_malformed_record"
        }
    }
}

enum AuditChainVerify {
    /// Genesis sentinel for `prev_sha` on the first record. Must match
    /// NativeSecurityAudit.chainGenesisPrevSha — keep in lockstep.
    static let chainGenesisPrevSha = String(repeating: "0", count: 64)

    /// Verifies the chain integrity of a JSONL audit log.
    ///
    /// - Parameters:
    ///   - data: Raw file contents (UTF-8 JSONL, newline-separated).
    ///   - requireNonEmpty: When true, empty input throws `.empty`. Callers who
    ///     know the chain has prior records (e.g., post-boot verifier) should
    ///     pass true to catch truncate-zero. The writer prologue passes false
    ///     to permit legitimate fresh-creation.
    ///
    /// - Returns: `(tailSha, tailSeq)` of the last verified record; nil iff
    ///   input was empty AND !requireNonEmpty.
    static func verify(
        _ data: Data,
        requireNonEmpty: Bool
    ) throws -> (tailSha: String, tailSeq: Int)? {
        guard !data.isEmpty else {
            if requireNonEmpty { throw AuditChainVerifyError.empty }
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AuditChainVerifyError.malformedRecord(lineIndex: 0, reason: "not valid UTF-8")
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.isEmpty {
            // Data was non-empty but contained only whitespace/newlines —
            // treat as truncate-style corruption regardless of caller flag.
            throw AuditChainVerifyError.empty
        }

        var expectedSeq = 1
        var expectedPrev = chainGenesisPrevSha
        var tailSha = ""
        var tailSeq = 0

        for (idx, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                throw AuditChainVerifyError.malformedRecord(lineIndex: idx, reason: "not a JSON object")
            }
            guard let recordedSha = parsed["sha"] as? String,
                  let recordedPrev = parsed["prev_sha"] as? String,
                  let recordedSeq = parsed["seq"] as? Int
            else {
                throw AuditChainVerifyError.malformedRecord(
                    lineIndex: idx,
                    reason: "missing chain fields (need sha, prev_sha, seq)"
                )
            }

            if idx == 0 {
                if recordedPrev != chainGenesisPrevSha {
                    throw AuditChainVerifyError.genesisPrevShaMismatch(actual: recordedPrev)
                }
                if recordedSeq != 1 {
                    throw AuditChainVerifyError.genesisSeqMismatch(actual: recordedSeq)
                }
            } else {
                if recordedSeq != expectedSeq {
                    throw AuditChainVerifyError.seqMismatch(actual: recordedSeq, expected: expectedSeq)
                }
                if recordedPrev != expectedPrev {
                    throw AuditChainVerifyError.prevShaMismatch(
                        seq: recordedSeq, recorded: recordedPrev, expected: expectedPrev
                    )
                }
            }

            // Recompute sha = SHA-256(canonical-JSON sans `sha`).
            var withoutSha = parsed
            withoutSha.removeValue(forKey: "sha")
            guard let recomputeInput = try? JSONSerialization.data(
                withJSONObject: withoutSha, options: [.sortedKeys]
            ) else {
                throw AuditChainVerifyError.malformedRecord(
                    lineIndex: idx,
                    reason: "canonical reserialize failed"
                )
            }
            let recomputed = SHA256.hash(data: recomputeInput)
                .map { String(format: "%02x", $0) }.joined()
            if recomputed != recordedSha {
                throw AuditChainVerifyError.shaMismatch(
                    seq: recordedSeq, recorded: recordedSha, recomputed: recomputed
                )
            }

            tailSha = recordedSha
            tailSeq = recordedSeq
            expectedSeq = recordedSeq + 1
            expectedPrev = recordedSha
        }

        return (tailSha: tailSha, tailSeq: tailSeq)
    }
}
