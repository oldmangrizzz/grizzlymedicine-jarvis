#pragma once

#include "audit_log.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <map>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace jarvis::identity::operator_attestation {

inline constexpr const char* kProtocolVersion = "jarvis-operator-attestation-1";
inline constexpr const char* kOperatorId = "Robert \"Grizzly\" Hanson, GMRI";

enum class OperationType {
    re_anchor_ceremony,
    disable_defense_layer,
    modify_character_values,
    authorize_voice_weight_change,
    authorize_hardware_migration,
    emergency_mode_bypass,
    irreversible_external_action,
};

[[nodiscard]] std::string to_string(OperationType type);
[[nodiscard]] std::optional<OperationType> operation_type_from_string(std::string_view value);
[[nodiscard]] bool requires_operator_attestation(OperationType type) noexcept;

struct SensitiveOperation {
    OperationType type{OperationType::irreversible_external_action};
    std::string description;
    std::string subject_digest;
};

struct OperatorAttestationKeypair {
    std::array<unsigned char, 32> public_key{};
    std::array<unsigned char, 64> private_key{};
};

struct EnrolledOperatorKey {
    std::string operator_id{kOperatorId};
    std::string public_key_hex;
    std::string enrolled_at_unix;

    [[nodiscard]] std::string fingerprint() const;
    [[nodiscard]] std::string to_json() const;
};

struct AttestationChallenge {
    std::string version{kProtocolVersion};
    std::string challenge_id;
    std::string nonce_hex;
    std::string operator_id{kOperatorId};
    OperationType operation_type{OperationType::irreversible_external_action};
    std::string operation_description;
    std::string subject_digest;
    std::int64_t issued_at_unix{0};
    std::int64_t expires_at_unix{0};
    std::string operator_key_fingerprint;

    [[nodiscard]] std::string canonical_payload() const;
    [[nodiscard]] std::string to_json() const;
};

struct AttestationResponse {
    std::string challenge_id;
    OperationType operation_type{OperationType::irreversible_external_action};
    std::string signature_hex;
};

enum class AttestationStatus {
    valid,
    invalid_signature,
    expired_challenge,
    wrong_operation,
    unknown_challenge,
    operator_key_not_enrolled,
    malformed_response,
    rate_limited,
};

[[nodiscard]] std::string to_string(AttestationStatus status);

struct AttestationVerdict {
    AttestationStatus status{AttestationStatus::malformed_response};
    std::string reason;
    std::string bound_operation;
    std::string bound_subject;
    std::string bound_challenge_id;
    std::int64_t bound_issued_at{0};
    std::optional<std::chrono::steady_clock::time_point> monotonic_at;

    [[nodiscard]] bool allowed() const noexcept { return status == AttestationStatus::valid; }
};

struct ChallengeIssueResult {
    bool issued{false};
    AttestationChallenge challenge;
    std::string reason;
};

struct AttestationPolicy {
    std::size_t max_challenges_per_window{5};
    std::chrono::seconds rate_limit_window{std::chrono::minutes(10)};
    std::chrono::seconds challenge_ttl{std::chrono::minutes(5)};
};

class OperatorKeyEnrollmentCeremony {
public:
    static OperatorAttestationKeypair generate_test_operator_keypair();
    static EnrolledOperatorKey enroll_operator_public_key(
        std::span<const unsigned char, 32> operator_public_key,
        std::string operator_id = kOperatorId,
        std::string enrolled_at_unix = {});
};

class AttestationService {
public:
    explicit AttestationService(
        EnrolledOperatorKey enrolled_key,
        std::filesystem::path audit_log_path = default_audit_log_path(),
        std::filesystem::path audit_key_path = default_audit_key_path(),
        AttestationPolicy policy = {});

    ChallengeIssueResult issue_challenge(const SensitiveOperation& operation);
    AttestationVerdict verify_response(const AttestationResponse& response,
                                       const SensitiveOperation& expected_operation);

    [[nodiscard]] std::optional<AttestationChallenge> challenge(std::string_view challenge_id) const;

    void set_clock_for_test(std::function<std::int64_t()> clock);

    static std::filesystem::path default_audit_log_path();
    static std::filesystem::path default_audit_key_path();

private:
    std::int64_t now_unix_() const;
    bool rate_limited_(std::int64_t now);
    void audit_(const std::string& subject,
                const std::string& outcome,
                const std::string& reason,
                const std::string& metadata = {});

    EnrolledOperatorKey enrolled_key_;
    AttestationPolicy policy_;
    std::map<std::string, AttestationChallenge> outstanding_;
    std::deque<std::int64_t> issued_timestamps_;
    std::function<std::int64_t()> clock_;
    jarvis::audit::TamperEvidentAuditLog audit_log_;
};

class AttestationGate {
public:
    explicit AttestationGate(AttestationService& service) : service_(service) {}

    ChallengeIssueResult request_attestation(OperationType type,
                                             std::string description,
                                             std::string subject_digest = {});
    AttestationVerdict require_attestation(const AttestationResponse& response,
                                           OperationType type,
                                           std::string description,
                                           std::string subject_digest = {});

    ChallengeIssueResult require_reanchor_confirmation(std::string description, std::string subject_digest = {});
    ChallengeIssueResult require_character_values_modification(std::string description, std::string subject_digest = {});
    ChallengeIssueResult require_defense_layer_disable(std::string description, std::string subject_digest = {});
    ChallengeIssueResult require_voice_weight_change(std::string description, std::string subject_digest = {});
    ChallengeIssueResult require_hardware_migration(std::string description, std::string subject_digest = {});
    ChallengeIssueResult require_emergency_mode_bypass(std::string description, std::string subject_digest = {});
    ChallengeIssueResult require_irreversible_external_action(std::string description, std::string subject_digest = {});

private:
    AttestationService& service_;
};

AttestationResponse sign_challenge_for_test(const AttestationChallenge& challenge,
                                            std::span<const unsigned char, 64> operator_private_key);

[[nodiscard]] std::string sha256_hex(std::string_view bytes);
[[nodiscard]] std::string hex_encode(std::span<const unsigned char> bytes);
[[nodiscard]] std::vector<unsigned char> hex_decode(std::string_view hex);

} // namespace jarvis::identity::operator_attestation
