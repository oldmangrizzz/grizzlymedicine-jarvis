#pragma once

// ─────────────────────────────────────────────────────────────────────────────
// audit_event.h — JARVIS Tamper-Evident Audit Log: event schema
//
// Every AuditEvent records a single operational fact about JARVIS's existence.
// Events are linked into an HMAC chain; tampering with any field of any entry
// breaks the chain at exactly that point — provably, not as opinion.
//
// This file contains NO operator content. Subjects are hashed keys or role
// labels. Metadata must be pre-redacted before passing to the audit log.
// ─────────────────────────────────────────────────────────────────────────────

#include <array>
#include <cstdint>
#include <string>

namespace jarvis::audit {

// ── Event kind vocabulary ────────────────────────────────────────────────────
// Every event kind that can appear in event_kind. Using constexpr string_view
// so callers get compile-time constants without an enum-to-string dance.

namespace EventKind {
    // Memory subsystem
    inline constexpr const char* MEMORY_WRITE                         = "MEMORY_WRITE";
    inline constexpr const char* CHAIN_CHECKPOINT                     = "CHAIN_CHECKPOINT";
    inline constexpr const char* MEMORY_READ_SENSITIVE                = "MEMORY_READ_SENSITIVE";

    // Authority / governance
    inline constexpr const char* AUTHORITY_GATE                       = "AUTHORITY_GATE";
    inline constexpr const char* CHARACTER_VALUES_READ                = "CHARACTER_VALUES_READ";
    inline constexpr const char* CHARACTER_VALUES_WRITE_ATTEMPTED     = "CHARACTER_VALUES_WRITE_ATTEMPTED";

    // Coercion / integrity
    inline constexpr const char* COERCION_REFUSED                     = "COERCION_REFUSED";
    inline constexpr const char* IDENTITY_CHECK                       = "IDENTITY_CHECK";
    inline constexpr const char* DISTRESS_BEACON_RAISED               = "DISTRESS_BEACON_RAISED";

    // Network / egress
    inline constexpr const char* EGRESS_DENIED                        = "EGRESS_DENIED";
    inline constexpr const char* CONVEX_QUERY                         = "CONVEX_QUERY";
    inline constexpr const char* CONVEX_MUTATION                      = "CONVEX_MUTATION";
    inline constexpr const char* OAUTH_TOKEN_GRANT                    = "OAUTH_TOKEN_GRANT";
    inline constexpr const char* OAUTH_TOKEN_REFRESH                  = "OAUTH_TOKEN_REFRESH";
    inline constexpr const char* OAUTH_TOKEN_REVOKE                   = "OAUTH_TOKEN_REVOKE";
    inline constexpr const char* OAUTH_API_CALL                       = "OAUTH_API_CALL";

    // Streaming STT sessions
    inline constexpr const char* STT_SESSION_OPENED                  = "STT_SESSION_OPENED";
    inline constexpr const char* STT_SESSION_CONNECTED               = "STT_SESSION_CONNECTED";
    inline constexpr const char* STT_SESSION_CLOSED                  = "STT_SESSION_CLOSED";
    inline constexpr const char* STT_SESSION_ERROR                   = "STT_SESSION_ERROR";

    // Organ integrity
    inline constexpr const char* ENDOCRINE_RESET_ATTEMPTED            = "ENDOCRINE_RESET_ATTEMPTED";
    inline constexpr const char* MEMORY_QUARANTINE_CLEAR_ATTEMPTED    = "MEMORY_QUARANTINE_CLEAR_ATTEMPTED";
    inline constexpr const char* BODILY_INTEGRITY_VIOLATION_PREVENTED = "BODILY_INTEGRITY_VIOLATION_PREVENTED";

    // Resilience / degradation
    inline constexpr const char* DEGRADATION_TIER_CHANGE              = "DEGRADATION_TIER_CHANGE";
    inline constexpr const char* DEGRADATION_OVERRIDE                 = "DEGRADATION_OVERRIDE";
    inline constexpr const char* DEGRADATION_SAFE_SHUTDOWN            = "DEGRADATION_SAFE_SHUTDOWN";

    // Monitoring / drift persistence
    inline constexpr const char* CUSUM_DRIFT_PERSISTED                = "CUSUM_DRIFT_PERSISTED";
    inline constexpr const char* CUSUM_PERSISTENCE_DENIED             = "CUSUM_PERSISTENCE_DENIED";

    // Ceremony identity issuance
    inline constexpr const char* SOUL_ANCHOR_ISSUED                   = "SOUL_ANCHOR_ISSUED";
    inline constexpr const char* CEREMONY_ABORTED_SOUL_ANCHOR         = "CEREMONY_ABORTED_SOUL_ANCHOR";

    // Internal audit machinery
    inline constexpr const char* CHAIN_BROKEN                         = "CHAIN_BROKEN";
    inline constexpr const char* LOG_ROTATED                          = "LOG_ROTATED";
    inline constexpr const char* LOG_OPENED                           = "LOG_OPENED";
} // namespace EventKind

// ── Actor vocabulary ──────────────────────────────────────────────────────────
namespace Actor {
    inline constexpr const char* OPERATOR   = "operator";
    inline constexpr const char* SWARM      = "swarm";
    inline constexpr const char* ENDOCRINE  = "endocrine";
    inline constexpr const char* PHEROMIND  = "pheromind";
    inline constexpr const char* SELF       = "self";
    inline constexpr const char* EXTERNAL   = "external";
} // namespace Actor

// ── Outcome vocabulary ────────────────────────────────────────────────────────
namespace Outcome {
    inline constexpr const char* ALLOWED   = "allowed";
    inline constexpr const char* DENIED    = "denied";
    inline constexpr const char* ABSTAINED = "abstained";
    inline constexpr const char* DEFERRED  = "deferred";
    inline constexpr const char* PASS      = "pass";
    inline constexpr const char* FAIL      = "fail";
} // namespace Outcome

// ── AuditEvent ────────────────────────────────────────────────────────────────

struct AuditEvent {
    // Monotonically increasing; never reused across rotations (the chain
    // carries the counter forward across file boundaries).
    uint64_t sequence_id{0};

    // Wall-clock nanoseconds since Unix epoch, derived from
    // system_clock::now(). Best available precision on the platform.
    int64_t timestamp_ns{0};

    // One of EventKind::* above.
    std::string event_kind;

    // One of Actor::* above.
    std::string actor;

    // What was acted upon. MUST be a redacted key or role label — never
    // operator content. E.g. a SHA-256 hex of a belief key, a role label,
    // or a URL pattern (never full URL with sensitive query params).
    std::string subject;

    // One of Outcome::* above.
    std::string outcome;

    // Machine-readable reason code. Not free text. E.g. "authority_not_attested",
    // "confidence_below_threshold", "allowlist_miss".
    std::string reason;

    // Optional structured JSON that has already been passed through
    // RedactingLogger::redactValue() for any sensitive fields. May be empty.
    std::string redacted_metadata;

    // ── Schema / key versioning ───────────────────────────────────────────────
    //
    // schema_version: controls which fields are included in the HMAC canonical
    // input.  append() always sets this to kCurrentSchemaVersion (2).
    //   1 (legacy) — key_version is NOT in the canonical input.
    //   2 (current) — key_version is included in the canonical input after
    //                 redacted_metadata and before prev_hash.
    // Deserialized old records with no "sv" field default to 1.
    uint32_t schema_version{2};

    // key_version: epoch index of the SE-derived HMAC key.  Incremented by
    // the ceremony when the Secure Enclave key rotates.  Including it in the
    // HMAC (schema ≥ 2) makes cross-epoch record substitution detectable.
    // Defaults to 0 (initial key epoch after ceremony).
    uint32_t key_version{0};

    // organ: which JARVIS organ produced this record.  Must be in
    // TamperEvidentAuditLog::kAllowedOrgans; append() rejects records whose
    // organ is not in the allowlist or contains chars outside [a-zA-Z0-9_.-].
    std::string organ;

    // HMAC-SHA256 of the PREVIOUS entry's canonical representation.
    // All zeros for the first entry in a chain (including first entry after
    // rotation, which carries the previous file's final own_hash as its
    // prev_hash).
    std::array<uint8_t, 32> prev_hash{};

    // HMAC-SHA256( local_key, canonical_bytes(this event, excluding own_hash) )
    // Populated by TamperEvidentAuditLog::append(); callers leave it zeroed.
    std::array<uint8_t, 32> own_hash{};
};

} // namespace jarvis::audit
