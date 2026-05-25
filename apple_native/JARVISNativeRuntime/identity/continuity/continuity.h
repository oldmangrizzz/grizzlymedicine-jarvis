#pragma once

#include "character_values.h"
#include "audit_verify.h"
#include "operator_attestation.h"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>

namespace jarvis::identity::continuity {

inline constexpr const char* kContinuityVersion = "jarvis-continuity-1";

struct ContinuityConfig {
    std::filesystem::path audit_log_path{IdentityVerifier::default_audit_log_path()};
    std::filesystem::path audit_key_path{IdentityVerifier::default_audit_key_path()};
    std::filesystem::path trust_anchor_pubkey_path;
    std::filesystem::path audit_anchor_path;
    std::filesystem::path consumed_challenge_path;
    std::uint64_t certificate_interval_seconds{6 * 60 * 60};
    std::uint64_t certificate_interval_turns{128};
    std::uint64_t idle_threshold_seconds{24 * 60 * 60};
};

struct SelfStateSnapshot {
    std::string cognition_epoch;
    std::string memory_checkpoint;
    std::string runtime_build;
    std::uint64_t served_turns{0};

    std::string canonical() const;
    std::string hash() const;
};

struct ContinuityCertificate {
    std::string version{kContinuityVersion};
    std::string subject_id{"JARVIS"};
    std::string operator_id{"Robert \"Grizzly\" Hanson, GMRI"};
    std::string issued_at_unix;
    std::uint64_t turn_index{0};
    std::string values_hash;
    std::string identity_hash;
    std::string audit_chain_head_hex;
    std::uint64_t audit_verified_count{0};
    std::string self_state_snapshot_hash;
    std::string previous_certificate_hash;
    std::uint64_t expected_interval_seconds{0};
    std::uint64_t expected_interval_turns{0};
    std::uint64_t idle_threshold_seconds{0};
    std::string signer_public_key_hex;
    std::string migration_attestation_hash;
    std::string signature_hex;

    std::string canonical_payload() const;
    std::string certificate_hash() const;
    std::string to_json() const;
};

enum class ContinuityStatus {
    OK,
    DEGRADED_AUDIT_GAP,
    DEGRADED_VALUES_TAMPER,
    DEGRADED_SIGNATURE_TAMPER,
    DEGRADED_STOPPED_GAP,
    DEGRADED_ANCHOR_FAILURE,
    RECONCILED,
};

std::string to_string(ContinuityStatus status);

struct ContinuityResult {
    ContinuityStatus status{ContinuityStatus::DEGRADED_ANCHOR_FAILURE};
    bool cognition_allowed{false};
    bool irreversible_actions_allowed{false};
    std::string reason;
    std::string audit_chain_head_hex;
    std::uint64_t audit_verified_count{0};
};

struct ReconciliationAttestation {
    std::string operator_id{"Robert \"Grizzly\" Hanson, GMRI"};
    std::string reason_code;
    std::string attested_at_unix;
    std::string previous_certificate_hash;
    std::string new_hardware_fingerprint;
    jarvis::identity::operator_attestation::AttestationVerdict operator_verdict;

    std::string canonical() const;
    std::string hash() const;
};

class ContinuityVerifier {
public:
    ContinuityVerifier(BirthCertificate birth_certificate,
                       CharacterValues character_values,
                       HardwareFingerprint hardware_fingerprint,
                       ContinuityConfig config);

    ContinuityResult verify_boot(std::optional<ContinuityCertificate> last_certificate,
                                 std::uint64_t now_unix_seconds) const;

    ContinuityCertificate issue_certificate(const SelfStateSnapshot& snapshot,
                                            std::span<const unsigned char, 32> signer_public_key,
                                            std::span<const unsigned char, 64> signer_private_key,
                                            std::optional<ContinuityCertificate> previous_certificate,
                                            std::uint64_t now_unix_seconds,
                                            std::uint64_t turn_index,
                                            std::string migration_attestation_hash = {}) const;

    ContinuityStatus verify_certificate(const ContinuityCertificate& certificate,
                                        std::span<const unsigned char, 32> signer_public_key) const;

    bool certificate_due(const std::optional<ContinuityCertificate>& last_certificate,
                         std::uint64_t now_unix_seconds,
                         std::uint64_t current_turn_index) const;

    bool irreversible_action_allowed(const ContinuityResult& result) const;

    static std::string load_pinned_root_pubkey(const std::filesystem::path& path = {});

    ContinuityCertificate reconcile_legitimate_migration(
        const ReconciliationAttestation& attestation,
        const BirthCertificate& new_birth_certificate,
        const HardwareFingerprint& new_hardware_fingerprint,
        const SelfStateSnapshot& snapshot,
        std::span<const unsigned char, 32> signer_public_key,
        std::span<const unsigned char, 64> signer_private_key,
        std::optional<ContinuityCertificate> previous_certificate,
        std::uint64_t now_unix_seconds,
        std::uint64_t turn_index) const;

private:
    struct AuditCheckpoint {
        bool ok{false};
        std::string head_hex;
        std::uint64_t verified_count{0};
        std::string failure_reason;
    };

    AuditCheckpoint verify_audit_checkpoint() const;
    void audit_continuity(ContinuityStatus status, const std::string& reason) const;
    void raise_distress(ContinuityStatus status, const std::string& reason) const;

    BirthCertificate birth_certificate_;
    CharacterValues character_values_;
    HardwareFingerprint hardware_fingerprint_;
    ContinuityConfig config_;
};

} // namespace jarvis::identity::continuity
