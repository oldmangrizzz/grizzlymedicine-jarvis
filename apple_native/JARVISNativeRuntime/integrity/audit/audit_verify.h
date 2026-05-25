#pragma once

// ─────────────────────────────────────────────────────────────────────────────
// audit_verify.h — JARVIS audit log offline verification tool
//
// Provides both:
//   (a) A C++ API usable by other runtime components.
//   (b) The jarvis-audit-verify CLI binary (built from audit_verify_main.cpp).
//
// The verifier reads the audit log and the bridge-installed Secure-Enclave-derived
// HMAC key, replays the HMAC chain, and reports PASS or FAIL-AT-SEQUENCE-N with a human-readable explanation of
// what a chain break means.
// ─────────────────────────────────────────────────────────────────────────────

#include "audit_event.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace jarvis::audit {

// ── Verification result ───────────────────────────────────────────────────────

enum class VerifyStatus {
    PASS,           // Chain holds throughout the file.
    FAIL_HMAC,      // HMAC mismatch at break_at_sequence.
    FAIL_PREV_HASH, // prev_hash linkage broken at break_at_sequence.
    FAIL_SEQUENCE,  // Sequence ID discontinuity at break_at_sequence.
    FAIL_TRUNCATED, // File is truncated mid-record.
    FAIL_EMPTY,     // File contains no records.
    FAIL_IO,        // Could not open or read the file.
    FAIL_KEY,       // Could not load the key file.
};

struct TrustAnchor {
    uint64_t start_sequence_id{0};
    std::array<uint8_t, 32> start_prev_hash{};
    std::array<uint8_t, 32> key_fingerprint{};
};

struct VerifyResult {
    VerifyStatus status{VerifyStatus::FAIL_EMPTY};

    // Sequence ID where the chain first breaks. Zero if status == PASS.
    uint64_t break_at_sequence{0};

    // Total records successfully verified before the break point.
    uint64_t verified_count{0};

    // Total records read from the file (including the broken one, if any).
    uint64_t total_read{0};

    // Human-readable one-line verdict for operator display.
    std::string verdict;

    // Full explanation including what the break means (multiple lines).
    std::string explanation;
};

// ── AuditVerifier class ───────────────────────────────────────────────────────

class AuditVerifier {
public:
    explicit AuditVerifier(std::filesystem::path log_path);

    // Run full verification and return the result. The no-arg overload is only
    // for genesis logs; long-term verification must pass a ceremony-pinned anchor.
    VerifyResult verify() const;
    VerifyResult verify(const TrustAnchor& anchor) const;

    static TrustAnchor load_trust_anchor(const std::filesystem::path& path, std::string_view trusted_root_public_key_hex = {});
    static std::array<uint8_t, 32> key_fingerprint(const std::array<uint8_t, 32>& key);

    // Print a human-readable report to stdout.
    // Returns 0 if PASS, 1 if FAIL.
    int printReport(bool verbose = false) const;

private:
    std::filesystem::path log_path_;
};

} // namespace jarvis::audit
