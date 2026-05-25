// egress_audit.h
// JARVIS digital-personhood project — GMRI
//
// Structured, tamper-evident audit log for every outbound JARVIS request.
//
// Design:
//   • Every outbound request produces exactly one AuditRecord.
//   • Records are written to the RedactingLogger (structured JSON-L) and
//     stored in-memory for chain verification.
//   • HMAC chain: each record carries a chain_hash computed as
//       H(n) = HMAC-SHA256(chain_key, H(n-1) || canonical_record(n))
//     Breaking (silently deleting or modifying) any record is detectable by
//     verify_chain().
//   • Payload fingerprint: HMAC-SHA256(fingerprint_key, raw_payload_bytes).
//     The operator can re-compute this offline if they retain the payload.
//     The log itself never contains the payload.
//
// What is NEVER logged:
//   • Payload content (message bodies, audio, completions).
//   • API keys or bearer tokens.
//   • Operator transcripts, Soul Anchor content, system prompts.
//
// What IS logged (safe):
//   • Timestamp (Unix seconds, fractional).
//   • Host (network destination — not operator content per logger conventions).
//   • Port (always 443).
//   • Bytes-sent count (size integer, not content).
//   • Content-type string.
//   • Count of stripped system messages.
//   • Count of stripped history messages.
//   • Payload fingerprint (HMAC hex — correlatable by operator, not reversible).
//   • Result (success/cert-pin-fail/network-fail/denied-by-allowlist).
//   • Chain hash.
//
// C++20; depends on OpenSSL::Crypto and jarvis_redacting_logger.

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "egress_filter.h"  // RequestEnvelope

namespace jarvis::security::egress {

// ── EgressResult ──────────────────────────────────────────────────────────────

enum class EgressResult : uint8_t {
    Success,
    CertPinFail,
    NetworkFail,
    DeniedByAllowlist,
};

[[nodiscard]] constexpr const char* egress_result_cstr(EgressResult r) noexcept {
    switch (r) {
        case EgressResult::Success:            return "success";
        case EgressResult::CertPinFail:        return "cert-pin-fail";
        case EgressResult::NetworkFail:        return "network-fail";
        case EgressResult::DeniedByAllowlist:  return "denied-by-allowlist";
    }
    return "unknown";
}

// ── AuditRecord ───────────────────────────────────────────────────────────────

struct AuditRecord {
    double      timestamp{0.0};          ///< Unix epoch seconds (fractional)
    std::string host;                    ///< cleartext destination host
    uint16_t    port{443};
    std::size_t bytes_sent{0};           ///< wire payload size in bytes
    std::string content_type;
    std::size_t stripped_system_messages{0};
    std::size_t stripped_history_messages{0};

    /// hex(HMAC-SHA256(fingerprint_key, raw_payload_bytes))
    /// Never derived from content directly — only the operator holding the
    /// key can correlate fingerprints to payloads.
    std::string payload_fingerprint;

    EgressResult result{EgressResult::Success};

    /// hex(HMAC-SHA256(chain_key, prev_chain_hash || canonical_serialise(*this)))
    /// Covers all fields above; excludes chain_hash itself.
    std::string chain_hash;
};

// ── EgressAudit ───────────────────────────────────────────────────────────────

class EgressAudit {
public:
    // ── Singleton ─────────────────────────────────────────────────────────────
    static EgressAudit& instance();

    // ── Record ────────────────────────────────────────────────────────────────

    /// Create and store an AuditRecord, emit it via RedactingLogger, and
    /// advance the HMAC chain.
    ///
    /// \param filtered_envelope  The envelope AFTER EgressFilter::filter()
    ///                           has run.  Provides host, port, content_type,
    ///                           and the stripped_* counts.
    /// \param payload_bytes      Raw wire bytes that were (or would be) sent.
    ///                           Only the size and HMAC fingerprint are retained;
    ///                           the bytes themselves are not stored.
    /// \param result             Outcome of the transmission attempt.
    void record(const RequestEnvelope& filtered_envelope,
                std::span<const uint8_t> payload_bytes,
                EgressResult result);

    // ── Chain verification ────────────────────────────────────────────────────

    /// Recompute the HMAC chain from scratch and compare to stored hashes.
    /// Returns true if the chain is intact (no tampering detected).
    /// Returns false if any record has been modified or deleted.
    [[nodiscard]] bool verify_chain() const;

    // ── Inspection ────────────────────────────────────────────────────────────

    [[nodiscard]] const std::vector<AuditRecord>& records() const noexcept {
        return records_;
    }

    // ── Test support ──────────────────────────────────────────────────────────

    /// Clear all stored records and reset the chain.
    /// For unit testing only — do NOT call in production.
    void reset_for_test();

    /// Overwrite the chain_hash of record at `idx` with `corrupted_hash`.
    /// For chain-tamper unit testing only.
    void test_only_inject_tampered_hash(std::size_t idx,
                                         std::string_view corrupted_hash);

private:
    EgressAudit();  // generates random HMAC keys

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// Compute the fingerprint HMAC for a payload.
    std::string compute_fingerprint(std::span<const uint8_t> payload) const;

    /// Compute chain_hash for an entry given the previous chain hash.
    /// `entry.chain_hash` must be empty / ignored when this is called.
    std::string compute_chain_hash(const std::string&  prev_hash,
                                   const AuditRecord&  entry) const;

    /// Canonical serialisation of all non-chain-hash fields of an entry
    /// (stable ordering, no whitespace ambiguity).
    static std::string serialise_for_chain(const AuditRecord& entry);

    // ── State ─────────────────────────────────────────────────────────────────

    std::array<uint8_t, 32> fingerprint_key_;  ///< per-session random key
    std::array<uint8_t, 32> chain_key_;        ///< per-session random key
    std::string             genesis_hash_;     ///< random initial chain value
    std::string             last_chain_hash_;

    std::vector<AuditRecord> records_;
    mutable std::mutex       mutex_;
};

}  // namespace jarvis::security::egress
