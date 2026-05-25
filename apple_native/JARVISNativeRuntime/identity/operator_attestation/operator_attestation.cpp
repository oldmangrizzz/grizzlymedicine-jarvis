#include "operator_attestation.h"

#include "audit_event.h"
#include "memory_security.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <utility>

#include <pwd.h>
#include <sodium.h>
#include <unistd.h>

namespace jarvis::identity::operator_attestation {
namespace {

void ensure_sodium() {
    jarvis::security::memory::ensure_sodium_initialized();
}

std::string current_unix_seconds() {
    using namespace std::chrono;
    return std::to_string(duration_cast<seconds>(system_clock::now().time_since_epoch()).count());
}

std::string json_escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[7];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

std::string random_hex(std::size_t bytes) {
    ensure_sodium();
    std::vector<unsigned char> buffer(bytes);
    randombytes_buf(buffer.data(), buffer.size());
    return hex_encode(buffer);
}

bool safe_equal(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    return sodium_memcmp(a.data(), b.data(), a.size()) == 0;
}

std::filesystem::path home_directory_or_throw() {
    if (const char* home = std::getenv("HOME"); home && *home) return home;
    if (const passwd* pw = ::getpwuid(::getuid()); pw && pw->pw_dir && *pw->pw_dir) return pw->pw_dir;
    throw std::runtime_error("cannot resolve HOME for JARVIS operator-attestation audit path");
}

std::filesystem::path default_audit_path(std::string_view filename) {
    return home_directory_or_throw() / ".jarvis" / "audit" / std::string(filename);
}

std::string metadata_json(const AttestationChallenge& c, std::string_view) {
    return std::string("{\"cid\":\"") + json_escape(c.challenge_id.substr(0, 16))
        + "\",\"op\":\"" + to_string(c.operation_type) + "\"}";
}

} // namespace

std::string to_string(OperationType type) {
    switch (type) {
        case OperationType::re_anchor_ceremony: return "re_anchor_ceremony";
        case OperationType::disable_defense_layer: return "disable_defense_layer";
        case OperationType::modify_character_values: return "modify_character_values";
        case OperationType::authorize_voice_weight_change: return "authorize_voice_weight_change";
        case OperationType::authorize_hardware_migration: return "authorize_hardware_migration";
        case OperationType::emergency_mode_bypass: return "emergency_mode_bypass";
        case OperationType::irreversible_external_action: return "irreversible_external_action";
    }
    return "irreversible_external_action";
}

std::optional<OperationType> operation_type_from_string(std::string_view value) {
    if (value == "re_anchor_ceremony") return OperationType::re_anchor_ceremony;
    if (value == "disable_defense_layer") return OperationType::disable_defense_layer;
    if (value == "modify_character_values") return OperationType::modify_character_values;
    if (value == "authorize_voice_weight_change") return OperationType::authorize_voice_weight_change;
    if (value == "authorize_hardware_migration") return OperationType::authorize_hardware_migration;
    if (value == "emergency_mode_bypass") return OperationType::emergency_mode_bypass;
    if (value == "irreversible_external_action") return OperationType::irreversible_external_action;
    return std::nullopt;
}

bool requires_operator_attestation(OperationType) noexcept {
    return true;
}

std::string EnrolledOperatorKey::fingerprint() const {
    return "sha256:" + sha256_hex(public_key_hex);
}

std::string EnrolledOperatorKey::to_json() const {
    return std::string("{")
        + "\"operator_id\":\"" + json_escape(operator_id) + "\","
        + "\"public_key_hex\":\"" + json_escape(public_key_hex) + "\","
        + "\"enrolled_at_unix\":\"" + json_escape(enrolled_at_unix) + "\","
        + "\"fingerprint\":\"" + fingerprint() + "\""
        + "}";
}

std::string AttestationChallenge::canonical_payload() const {
    return std::string("{")
        + "\"challenge_id\":\"" + json_escape(challenge_id) + "\","
        + "\"expires_at_unix\":" + std::to_string(expires_at_unix) + ","
        + "\"issued_at_unix\":" + std::to_string(issued_at_unix) + ","
        + "\"nonce_hex\":\"" + json_escape(nonce_hex) + "\","
        + "\"operation_description\":\"" + json_escape(operation_description) + "\","
        + "\"operation_type\":\"" + to_string(operation_type) + "\","
        + "\"operator_id\":\"" + json_escape(operator_id) + "\","
        + "\"operator_key_fingerprint\":\"" + json_escape(operator_key_fingerprint) + "\","
        + "\"subject_digest\":\"" + json_escape(subject_digest) + "\","
        + "\"version\":\"" + json_escape(version) + "\""
        + "}";
}

std::string AttestationChallenge::to_json() const {
    return canonical_payload();
}

std::string to_string(AttestationStatus status) {
    switch (status) {
        case AttestationStatus::valid: return "valid";
        case AttestationStatus::invalid_signature: return "invalid_signature";
        case AttestationStatus::expired_challenge: return "expired_challenge";
        case AttestationStatus::wrong_operation: return "wrong_operation";
        case AttestationStatus::unknown_challenge: return "unknown_challenge";
        case AttestationStatus::operator_key_not_enrolled: return "operator_key_not_enrolled";
        case AttestationStatus::malformed_response: return "malformed_response";
        case AttestationStatus::rate_limited: return "rate_limited";
    }
    return "malformed_response";
}

OperatorAttestationKeypair OperatorKeyEnrollmentCeremony::generate_test_operator_keypair() {
    ensure_sodium();
    OperatorAttestationKeypair keypair;
    crypto_sign_keypair(keypair.public_key.data(), keypair.private_key.data());
    return keypair;
}

EnrolledOperatorKey OperatorKeyEnrollmentCeremony::enroll_operator_public_key(
    std::span<const unsigned char, 32> operator_public_key,
    std::string operator_id,
    std::string enrolled_at_unix) {
    EnrolledOperatorKey key;
    key.operator_id = std::move(operator_id);
    key.public_key_hex = hex_encode(operator_public_key);
    key.enrolled_at_unix = enrolled_at_unix.empty() ? current_unix_seconds() : std::move(enrolled_at_unix);
    return key;
}

AttestationService::AttestationService(EnrolledOperatorKey enrolled_key,
                                       std::filesystem::path audit_log_path,
                                       std::filesystem::path audit_key_path,
                                       AttestationPolicy policy)
    : enrolled_key_(std::move(enrolled_key)),
      policy_(policy),
      audit_log_(audit_log_path.string()) {
    (void)audit_key_path;
    if (enrolled_key_.public_key_hex.empty()) {
        audit_("operator_key", jarvis::audit::Outcome::FAIL, "operator_key_not_enrolled");
        throw std::invalid_argument("operator attestation key is not enrolled");
    }
    if (policy_.max_challenges_per_window == 0 || policy_.challenge_ttl.count() <= 0 || policy_.rate_limit_window.count() <= 0) {
        throw std::invalid_argument("invalid attestation policy");
    }
}

ChallengeIssueResult AttestationService::issue_challenge(const SensitiveOperation& operation) {
    const auto now = now_unix_();
    AttestationChallenge c;
    c.operator_id = enrolled_key_.operator_id;
    c.operation_type = operation.type;
    c.operation_description = operation.description;
    c.subject_digest = operation.subject_digest.empty() ? ("sha256:" + sha256_hex(operation.description)) : operation.subject_digest;
    c.issued_at_unix = now;
    c.expires_at_unix = now + policy_.challenge_ttl.count();
    c.nonce_hex = random_hex(32);
    c.operator_key_fingerprint = enrolled_key_.fingerprint();
    c.challenge_id = sha256_hex(c.nonce_hex + to_string(c.operation_type) + std::to_string(c.issued_at_unix) + c.subject_digest);

    if (rate_limited_(now)) {
        audit_("attestation_challenge", jarvis::audit::Outcome::DENIED, "attestation_rate_limited", metadata_json(c, enrolled_key_.fingerprint()));
        return {false, c, "attestation_rate_limited"};
    }
    issued_timestamps_.push_back(now);
    outstanding_[c.challenge_id] = c;
    audit_("attestation_challenge", jarvis::audit::Outcome::DEFERRED, "attestation_challenge_issued", metadata_json(c, enrolled_key_.fingerprint()));
    return {true, c, "attestation_challenge_issued"};
}

AttestationVerdict AttestationService::verify_response(const AttestationResponse& response,
                                                       const SensitiveOperation& expected_operation) {
    const auto found = outstanding_.find(response.challenge_id);
    if (found == outstanding_.end()) {
        audit_("attestation_response", jarvis::audit::Outcome::DENIED, "unknown_challenge");
        return {AttestationStatus::unknown_challenge, "unknown_challenge"};
    }

    const AttestationChallenge c = found->second;
    auto deny = [&](AttestationStatus status, std::string reason) {
        audit_("attestation_response", jarvis::audit::Outcome::DENIED, reason, metadata_json(c, enrolled_key_.fingerprint()));
        return AttestationVerdict{status, std::move(reason), c.operation_description, c.subject_digest, c.challenge_id, c.issued_at_unix};
    };

    if (response.operation_type != expected_operation.type || c.operation_type != expected_operation.type) {
        return deny(AttestationStatus::wrong_operation, "wrong_operation");
    }
    const std::string expected_subject = expected_operation.subject_digest.empty()
        ? ("sha256:" + sha256_hex(expected_operation.description))
        : expected_operation.subject_digest;
    if (!safe_equal(c.operation_description, expected_operation.description) || !safe_equal(c.subject_digest, expected_subject)) {
        return deny(AttestationStatus::wrong_operation, "wrong_operation_material_mismatch");
    }
    if (now_unix_() > c.expires_at_unix) {
        outstanding_.erase(found);
        return deny(AttestationStatus::expired_challenge, "expired_challenge");
    }
    if (!safe_equal(c.operator_key_fingerprint, enrolled_key_.fingerprint())) {
        return deny(AttestationStatus::operator_key_not_enrolled, "operator_key_mismatch");
    }

    std::vector<unsigned char> pub;
    std::vector<unsigned char> sig;
    try {
        pub = hex_decode(enrolled_key_.public_key_hex);
        sig = hex_decode(response.signature_hex);
    } catch (...) {
        return deny(AttestationStatus::malformed_response, "malformed_response");
    }
    if (pub.size() != crypto_sign_PUBLICKEYBYTES || sig.size() != crypto_sign_BYTES) {
        return deny(AttestationStatus::malformed_response, "malformed_response");
    }

    const std::string payload = c.canonical_payload();
    const int rc = crypto_sign_verify_detached(sig.data(),
        reinterpret_cast<const unsigned char*>(payload.data()),
        static_cast<unsigned long long>(payload.size()),
        pub.data());
    if (rc != 0) {
        return deny(AttestationStatus::invalid_signature, "invalid_signature");
    }

    outstanding_.erase(found);
    audit_("attestation_response", jarvis::audit::Outcome::ALLOWED, "operator_attestation_valid", metadata_json(c, enrolled_key_.fingerprint()));
    return {AttestationStatus::valid, "operator_attestation_valid", c.operation_description, c.subject_digest, c.challenge_id, c.issued_at_unix};
}

std::optional<AttestationChallenge> AttestationService::challenge(std::string_view challenge_id) const {
    const auto it = outstanding_.find(std::string(challenge_id));
    if (it == outstanding_.end()) return std::nullopt;
    return it->second;
}

void AttestationService::set_clock_for_test(std::function<std::int64_t()> clock) {
    clock_ = std::move(clock);
}

std::filesystem::path AttestationService::default_audit_log_path() {
    return default_audit_path("operator_attestation.jsonl");
}

std::filesystem::path AttestationService::default_audit_key_path() {
    return default_audit_path("operator_attestation.key");
}

std::int64_t AttestationService::now_unix_() const {
    if (clock_) return clock_();
    using namespace std::chrono;
    return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}

bool AttestationService::rate_limited_(std::int64_t now) {
    const auto cutoff = now - policy_.rate_limit_window.count();
    while (!issued_timestamps_.empty() && issued_timestamps_.front() <= cutoff) {
        issued_timestamps_.pop_front();
    }
    return issued_timestamps_.size() >= policy_.max_challenges_per_window;
}

void AttestationService::audit_(const std::string& subject,
                                const std::string& outcome,
                                const std::string& reason,
                                const std::string& metadata) {
    jarvis::audit::AuditEvent event;
    event.event_kind = jarvis::audit::EventKind::AUTHORITY_GATE;
    event.actor = jarvis::audit::Actor::OPERATOR;
    event.subject = "sha256:" + sha256_hex(subject);
    event.outcome = outcome;
    event.reason = reason;
    event.redacted_metadata = metadata;
    event.organ = "operator_attestation";
    audit_log_.append(event);
}

ChallengeIssueResult AttestationGate::request_attestation(OperationType type,
                                                          std::string description,
                                                          std::string subject_digest) {
    return service_.issue_challenge({type, std::move(description), std::move(subject_digest)});
}

AttestationVerdict AttestationGate::require_attestation(const AttestationResponse& response,
                                                        OperationType type,
                                                        std::string description,
                                                        std::string subject_digest) {
    return service_.verify_response(response, {type, std::move(description), std::move(subject_digest)});
}

ChallengeIssueResult AttestationGate::require_reanchor_confirmation(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::re_anchor_ceremony, std::move(description), std::move(subject_digest));
}

ChallengeIssueResult AttestationGate::require_character_values_modification(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::modify_character_values, std::move(description), std::move(subject_digest));
}

ChallengeIssueResult AttestationGate::require_defense_layer_disable(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::disable_defense_layer, std::move(description), std::move(subject_digest));
}

ChallengeIssueResult AttestationGate::require_voice_weight_change(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::authorize_voice_weight_change, std::move(description), std::move(subject_digest));
}

ChallengeIssueResult AttestationGate::require_hardware_migration(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::authorize_hardware_migration, std::move(description), std::move(subject_digest));
}

ChallengeIssueResult AttestationGate::require_emergency_mode_bypass(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::emergency_mode_bypass, std::move(description), std::move(subject_digest));
}

ChallengeIssueResult AttestationGate::require_irreversible_external_action(std::string description, std::string subject_digest) {
    return request_attestation(OperationType::irreversible_external_action, std::move(description), std::move(subject_digest));
}

AttestationResponse sign_challenge_for_test(const AttestationChallenge& challenge,
                                            std::span<const unsigned char, 64> operator_private_key) {
    ensure_sodium();
    const std::string payload = challenge.canonical_payload();
    std::array<unsigned char, crypto_sign_BYTES> sig{};
    crypto_sign_detached(sig.data(), nullptr,
                         reinterpret_cast<const unsigned char*>(payload.data()),
                         static_cast<unsigned long long>(payload.size()),
                         operator_private_key.data());
    return {challenge.challenge_id, challenge.operation_type, hex_encode(sig)};
}

std::string sha256_hex(std::string_view bytes) {
    ensure_sodium();
    unsigned char digest[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(digest,
                       reinterpret_cast<const unsigned char*>(bytes.data()),
                       static_cast<unsigned long long>(bytes.size()));
    return hex_encode(std::span<const unsigned char>(digest, crypto_hash_sha256_BYTES));
}

std::string hex_encode(std::span<const unsigned char> bytes) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (auto b : bytes) {
        out.push_back(hex[(b >> 4) & 0x0f]);
        out.push_back(hex[b & 0x0f]);
    }
    return out;
}

std::vector<unsigned char> hex_decode(std::string_view hex) {
    if (hex.size() % 2 != 0) throw std::invalid_argument("hex string has odd length");
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    std::vector<unsigned char> out;
    out.reserve(hex.size() / 2);
    for (std::size_t i = 0; i < hex.size(); i += 2) {
        int hi = nibble(hex[i]);
        int lo = nibble(hex[i + 1]);
        if (hi < 0 || lo < 0) throw std::invalid_argument("invalid hex character");
        out.push_back(static_cast<unsigned char>((hi << 4) | lo));
    }
    return out;
}

} // namespace jarvis::identity::operator_attestation
