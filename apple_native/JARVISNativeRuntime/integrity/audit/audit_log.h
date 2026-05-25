#pragma once

// ─────────────────────────────────────────────────────────────────────────────
// audit_log.h — JARVIS Tamper-Evident Audit Log
//
// This log records JARVIS's operational integrity. It cannot be silently
// disabled. Tampering with the on-disk file breaks the HMAC chain detectably.
//
// Design guarantees:
//   • Append-only: no delete/truncate/disable API exists on this class.
//   • Durable: every append is fsynced before returning.
//   • Chain-verifiable: any tampered, deleted, inserted, or reordered entry
//     breaks the HMAC chain at exactly that sequence position.
//   • Thread-safe: any thread may call append() concurrently.
//   • Rotation-spanning: the chain continues across file rotations by
//     carrying the previous file's final own_hash into the new file's first
//     entry's prev_hash.
//   • Fail-closed reload: openLog() and reloadStateFromDiskLocked() perform a
//     full chain walk with HMAC verification.  Any truncation, mutation, or
//     gap throws AuditChainTruncatedError immediately — refuse to append.
//
// Storage format:
//   ~/.jarvis/audit.log (mode 0600)
//   Each record: [ 4-byte LE uint32 payload_length | payload_length bytes JSON ]
//   JSON payload contains all AuditEvent fields with hashes as lowercase hex.
//
// HMAC key:
//   Supplied by the Swift Secure Enclave bridge as locked process memory.
//
// HMAC canonical input (schema_version = 1, legacy on-disk records):
//   sequence_id (LE uint64) ||
//   timestamp_ns (LE int64) ||
//   len(event_kind)(LE uint32) || event_kind ||
//   len(actor)(LE uint32)      || actor      ||
//   len(subject)(LE uint32)    || subject     ||
//   len(outcome)(LE uint32)    || outcome     ||
//   len(reason)(LE uint32)     || reason      ||
//   len(redacted_metadata)(LE uint32) || redacted_metadata ||
//   prev_hash (32 bytes)
//
// HMAC canonical input (schema_version = 2, all new records):
//   ... same as above through redacted_metadata ...
//   key_version (LE uint32)          ← NEW: epoch of SE-derived HMAC key
//   prev_hash (32 bytes)
//
// Schema migration for existing on-disk audit logs:
//   Old records (schema_version absent from JSON or "sv":1) use the v1 format
//   when verifying their HMAC.  New records written by this version always use
//   schema_version=2.  Mixed files are fully supported: verify_chain() calls
//   computeHmac(key, *ev) which dispatches on ev->schema_version.
//
//   If the operator performs a fresh ceremony (log is fresh), no migration is
//   needed — all records will be schema_version=2 from the start.  For an
//   existing live log: old records verify with v1 rules; new records appended
//   after this upgrade verify with v2 rules.  There is no in-place rewrite.
//
// PIPE_BUF on macOS is 512 bytes (per getconf PIPE_BUF). O_APPEND atomic only for writes ≤ PIPE_BUF.
// With schema_version=2 fields, the fixed per-record overhead grows by ~36 bytes.
// Maximum organ name length is bounded by the allowlist; longest is "operator_attestation" (20 chars).
// ─────────────────────────────────────────────────────────────────────────────

#include "audit_event.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <fcntl.h>
#include <functional>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <system_error>
#include <unordered_set>
#include <vector>

#include <unistd.h>

namespace jarvis::security::memory {
void ensure_sodium_initialized();
void lock_no_swap(void* ptr, std::size_t len);
}

namespace jarvis::audit {

class AuditRecordTooLarge final : public std::runtime_error {
public:
    explicit AuditRecordTooLarge(const std::string& reason) : std::runtime_error(reason) {}
};

class AuditKeyMissingError final : public std::runtime_error {
public:
    explicit AuditKeyMissingError(const std::string& reason) : std::runtime_error(reason) {}
};

// Thrown when openLog() or reloadStateFromDiskLocked() detects a truncation,
// HMAC mismatch, sequence gap, or chain-link break in the on-disk file.
// §2 fail-closed: no silent fallback.  Operator performs attested recovery.
class AuditChainTruncatedError final : public std::runtime_error {
public:
    explicit AuditChainTruncatedError(const std::string& reason) : std::runtime_error(reason) {}
};

// Thrown when append() receives an AuditEvent whose organ field is not in
// kAllowedOrgans or contains chars outside [a-zA-Z0-9_.-].
class AuditIllegalOrganError final : public std::runtime_error {
public:
    explicit AuditIllegalOrganError(const std::string& reason) : std::runtime_error(reason) {}
};

// Stable bridge-key API: Swift/C++ ceremony code must install the 32-byte
// Secure-Enclave-derived audit HMAC key before constructing runtime audit logs.
void installBridgeAuditKey(const uint8_t* key, size_t key_len);
void clearBridgeAuditKeyForTesting();
[[nodiscard]] bool bridgeAuditKeyAvailable();
[[nodiscard]] std::array<uint8_t, 32> requireBridgeAuditKey();

// ── Iterator for sequential read ──────────────────────────────────────────────

class AuditLogIterator {
public:
    using value_type        = AuditEvent;
    using difference_type   = std::ptrdiff_t;
    using iterator_category = std::input_iterator_tag;

    AuditLogIterator() = default; // end sentinel

    // Reading constructor — opens the file and reads the first entry.
    explicit AuditLogIterator(std::filesystem::path path);

    const AuditEvent& operator*()  const { return current_; }
    const AuditEvent* operator->() const { return &current_; }

    AuditLogIterator& operator++();

    bool operator==(const AuditLogIterator& rhs) const {
        return done_ == rhs.done_;
    }
    bool operator!=(const AuditLogIterator& rhs) const {
        return !(*this == rhs);
    }

private:
    void readNext();

    int fd_{-1};
    AuditEvent current_{};
    bool done_{true};
};

// ── TamperEvidentAuditLog ────────────────────────────────────────────────────

class TamperEvidentAuditLog {
public:
    // ── Construction ─────────────────────────────────────────────────────────
    // path: absolute path to the audit log file. "~" is expanded.
    // key/key_len: 32-byte HMAC key already unsealed/derived by the bridge.
    // The path-only overload requires installBridgeAuditKey() to have supplied
    // that bridge key; otherwise it throws AuditKeyMissingError.
    // The log file is opened O_CREAT | O_APPEND (mode 0600) and a LOG_OPENED event is appended.
    explicit TamperEvidentAuditLog(
        std::string path,
        const uint8_t* key,
        size_t key_len
    );

    explicit TamperEvidentAuditLog(
        std::string path = "~/.jarvis/audit.log"
    );

    ~TamperEvidentAuditLog();

    // Non-copyable, non-movable: the log owns an open file descriptor.
    TamperEvidentAuditLog(const TamperEvidentAuditLog&)            = delete;
    TamperEvidentAuditLog& operator=(const TamperEvidentAuditLog&) = delete;
    TamperEvidentAuditLog(TamperEvidentAuditLog&&)                 = delete;
    TamperEvidentAuditLog& operator=(TamperEvidentAuditLog&&)      = delete;

    // ── Append ────────────────────────────────────────────────────────────────
    // Thread-safe. Sets e.sequence_id, e.timestamp_ns (if 0), e.prev_hash, and
    // e.own_hash before writing. Synchronously fsyncs — durability is required.
    // Rotates the log file if it has reached kRotationBytes.
    void append(AuditEvent e);

    // ── Verification ──────────────────────────────────────────────────────────
    // Reads every entry in the current log file and verifies the HMAC chain.
    // Returns true iff the chain holds from the first entry to the last.
    // Does NOT modify any state.
    bool verify_chain() const;

    // ── Iteration ─────────────────────────────────────────────────────────────
    // Read-only sequential iteration over the current log file.
    AuditLogIterator begin() const;
    AuditLogIterator end()   const;

    // ── Diagnostics ──────────────────────────────────────────────────────────
    std::filesystem::path log_path()  const { return log_path_; }
    uint64_t              next_seq()  const;

    // ── Limits ───────────────────────────────────────────────────────────────
    static constexpr uint64_t kRotationBytes = 100ULL * 1024 * 1024; // 100 MB
    static constexpr uint32_t kMaxAtomicRecordBytes = 512; // PIPE_BUF confirmed by getconf PIPE_BUF
    static constexpr uint64_t kPipeBufAtomicBytes = 512;
    static constexpr uint32_t kAtomicRecordBytes = 512;
    // Current schema version written by append().  Old records on disk may have
    // schema_version=1; see audit_log.h header for migration notes.
    static constexpr uint32_t kCurrentSchemaVersion = 2;
    // Checkpoint every N records to bound reload chain-walk cost.
    // A checkpoint record (EventKind::CHAIN_CHECKPOINT) pins (sequence_id, hmac)
    // so reload can start from the most recent verified checkpoint.
    // Stub: checkpoint writes not yet implemented; constant reserved.
    static constexpr uint32_t kCheckpointInterval = 1024;

    // ── Organ allowlist ───────────────────────────────────────────────────────
    // append() rejects records whose organ is not in this set.
    // All organ names must match [a-zA-Z0-9_.-].
    // To add a new organ: (1) add it here, (2) set AuditEvent::organ in the
    // caller, (3) add a test case.
    static const std::unordered_set<std::string> kAllowedOrgans;

    // ── HMAC helpers (also used by audit_verify) ──────────────────────────────

    // Compute HMAC-SHA256(key, canonical_bytes(event)).
    // canonical_bytes dispatches on e.schema_version:
    //
    //   v1 (legacy):
    //     sequence_id (LE uint64) ||
    //     timestamp_ns (LE int64) ||
    //     len(event_kind)(LE uint32) || event_kind ||
    //     len(actor)(LE uint32)      || actor      ||
    //     len(subject)(LE uint32)    || subject     ||
    //     len(outcome)(LE uint32)    || outcome     ||
    //     len(reason)(LE uint32)     || reason      ||
    //     len(redacted_metadata)(LE uint32) || redacted_metadata ||
    //     prev_hash (32 bytes)
    //
    //   v2 (current, all new records):
    //     ... identical through redacted_metadata ...
    //     key_version (LE uint32)    ← epoch of SE-derived HMAC key
    //     prev_hash (32 bytes)
    //
    // own_hash is excluded from the input in both versions.
    static std::array<uint8_t, 32> computeHmac(
        const std::array<uint8_t, 32>& key,
        const AuditEvent& e
    );

    // Serialise event to JSON payload (including own_hash).
    static std::string serialiseEvent(const AuditEvent& e);

    // Deserialise event from JSON payload. Returns nullopt on parse error.
    static std::optional<AuditEvent> deserialiseEvent(const std::string& json);

private:
    void openLog();
    void rotateLog();
    void reloadStateFromDiskLocked();
    void writeRecordLocked(const std::string& payload);
    void ensureDir(const std::filesystem::path& p);

    std::filesystem::path log_path_;

    mutable std::mutex mutex_;
    int fd_{-1};

    std::array<uint8_t, 32> key_{};
    std::array<uint8_t, 32> last_hash_{};  // own_hash of last appended entry
    uint64_t                next_seq_{0};
    uint64_t                file_bytes_{0};
};

// Process-wide audit log registry. Callers that append repeatedly should use
// this singleton so JARVIS's integrity chain is not reopened for every event.
TamperEvidentAuditLog& processAuditLog(
    std::string path = "~/.jarvis/audit.log"
);

} // namespace jarvis::audit
