#include "continuity.h"

#include "audit_event.h"
#include "audit_log.h"
#include "distress_beacon.h"
#include "memory_security.h"
#include "trust_envelope.h"

#include <charconv>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <set>
#include <stdexcept>
#include <vector>

#include <fcntl.h>
#include <pwd.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <sodium.h>

namespace jarvis::identity::continuity {
namespace {

void ensure_sodium() {
    jarvis::security::memory::ensure_sodium_initialized();
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
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

std::uint64_t parse_u64(const std::string& s) {
    std::uint64_t value = 0;
    const auto* first = s.data();
    const auto* last = s.data() + s.size();
    auto [ptr, ec] = std::from_chars(first, last, value);
    if (ec != std::errc{} || ptr != last) throw std::invalid_argument("invalid unsigned integer");
    return value;
}

bool safe_equal(const std::string& a, const std::string& b) {
    ensure_sodium();
    if (a.size() != b.size()) return false;
    return sodium_memcmp(a.data(), b.data(), a.size()) == 0;
}

std::string audit_hash_hex(const std::array<std::uint8_t, 32>& bytes) {
    return hex_encode(std::span<const unsigned char>(bytes.data(), bytes.size()));
}

std::filesystem::path home_directory_or_throw() {
    if (const char* home = std::getenv("HOME"); home && *home) return home;
    if (const passwd* pw = ::getpwuid(::getuid()); pw && pw->pw_dir && *pw->pw_dir) return pw->pw_dir;
    throw std::runtime_error("cannot resolve HOME for JARVIS continuity trust path");
}

std::filesystem::path default_anchor_root_path() {
    return home_directory_or_throw() / ".jarvis" / "trust" / "anchor_root.pub";
}

std::filesystem::path default_audit_anchor_path() {
    return home_directory_or_throw() / ".jarvis" / "trust" / "audit_anchor.json";
}

std::filesystem::path default_consumed_challenge_path() {
    return home_directory_or_throw() / ".jarvis" / "state" / "consumed_challenges.jsonl";
}

void ensure_parent_dir(const std::filesystem::path& path) {
    const auto parent = path.parent_path();
    if (parent.empty()) return;
    std::filesystem::create_directories(parent);
    ::chmod(parent.c_str(), 0700);
}

std::string challenge_field(const std::string& line, const std::string& key) {
    const std::string needle = "\"" + key + "\":\"";
    const auto pos = line.find(needle);
    if (pos == std::string::npos) return {};
    const auto start = pos + needle.size();
    const auto end = line.find('"', start);
    if (end == std::string::npos) return {};
    return line.substr(start, end - start);
}

// Not an audit-chain key: this per-store HMAC key only authenticates local consumed-challenge replay markers.
std::array<unsigned char, 32> load_or_create_challenge_key(const std::filesystem::path& path) {
    ensure_parent_dir(path);
    const auto key_path = path.string() + ".key";
    std::array<unsigned char, 32> key{};
    int fd = ::open(key_path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (fd >= 0) {
        const ssize_t n = ::read(fd, key.data(), key.size());
        ::close(fd);
        if (n != static_cast<ssize_t>(key.size())) throw std::runtime_error("consumed challenge HMAC key corrupt");
        return key;
    }
    ensure_sodium();
    randombytes_buf(key.data(), key.size());
    fd = ::open(key_path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) throw std::runtime_error("consumed challenge HMAC key create failed");
    const ssize_t n = ::write(fd, key.data(), key.size());
    if (::fsync(fd) != 0) { ::close(fd); throw std::runtime_error("consumed challenge HMAC key fsync failed"); }
    ::close(fd);
    if (n != static_cast<ssize_t>(key.size())) throw std::runtime_error("consumed challenge HMAC key write incomplete");
    return key;
}

std::string challenge_canonical(const std::string& challenge_id, const std::string& operation, const std::string& subject, std::int64_t issued_at, const std::string& prev_hmac) {
    return "challenge_id=" + challenge_id + "\nissued_at=" + std::to_string(issued_at) + "\noperation=" + operation + "\nprev_hmac=" + prev_hmac + "\nsubject=" + subject + "\n";
}

std::string challenge_hmac(const std::array<unsigned char, 32>& key, const std::string& canonical) {
    ensure_sodium();
    std::array<unsigned char, crypto_auth_hmacsha256_BYTES> out{};
    crypto_auth_hmacsha256(out.data(), reinterpret_cast<const unsigned char*>(canonical.data()), canonical.size(), key.data());
    return hex_encode(std::span<const unsigned char>(out.data(), out.size()));
}

bool consume_challenge_once(const std::filesystem::path& path,
                            const jarvis::identity::operator_attestation::AttestationVerdict& verdict) {
    if (verdict.bound_challenge_id.empty()) return false;
    const auto key = load_or_create_challenge_key(path);
    std::set<std::string> consumed;
    std::string prev(64, '0');
    {
        std::ifstream in(path);
        std::string line;
        while (std::getline(in, line)) {
            if (line.empty()) continue;
            const auto challenge = challenge_field(line, "challenge_id");
            const auto operation = challenge_field(line, "operation");
            const auto subject = challenge_field(line, "subject");
            const auto prev_hmac = challenge_field(line, "prev_hmac");
            const auto hmac = challenge_field(line, "hmac");
            const auto issued_raw = challenge_field(line, "issued_at");
            if (challenge.empty() || operation.empty() || subject.empty() || prev_hmac.empty() || hmac.empty() || issued_raw.empty()) throw std::runtime_error("consumed challenge chain malformed");
            if (prev_hmac != prev) throw std::runtime_error("consumed challenge chain prev_hmac mismatch");
            const auto issued = std::stoll(issued_raw);
            if (challenge_hmac(key, challenge_canonical(challenge, operation, subject, issued, prev_hmac)) != hmac) throw std::runtime_error("consumed challenge chain forged line");
            consumed.insert(challenge);
            prev = hmac;
        }
    }
    if (consumed.contains(verdict.bound_challenge_id)) return false;
    ensure_parent_dir(path);
    int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) throw std::runtime_error("consumed challenge chain open failed");
    if (flock(fd, LOCK_EX) != 0) { ::close(fd); throw std::runtime_error("consumed challenge chain lock failed"); }
    const auto hmac = challenge_hmac(key, challenge_canonical(verdict.bound_challenge_id, verdict.bound_operation, verdict.bound_subject, verdict.bound_issued_at, prev));
    const std::string line = std::string("{\"challenge_id\":\"") + verdict.bound_challenge_id +
        "\",\"hmac\":\"" + hmac +
        "\",\"issued_at\":\"" + std::to_string(verdict.bound_issued_at) +
        "\",\"operation\":\"" + verdict.bound_operation +
        "\",\"prev_hmac\":\"" + prev +
        "\",\"subject\":\"" + verdict.bound_subject + "\"}\n";
    if (line.size() > 512) { flock(fd, LOCK_UN); ::close(fd); throw std::runtime_error("consumed challenge chain record exceeds PIPE_BUF"); }
    const char* data = line.data();
    std::size_t remaining = line.size();
    while (remaining > 0) {
        ssize_t n = ::write(fd, data, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            flock(fd, LOCK_UN); ::close(fd); throw std::runtime_error("consumed challenge chain append failed");
        }
        data += n;
        remaining -= static_cast<std::size_t>(n);
    }
    if (::fsync(fd) != 0) { flock(fd, LOCK_UN); ::close(fd); throw std::runtime_error("consumed challenge chain fsync failed"); }
    flock(fd, LOCK_UN);
    ::close(fd);
    return true;
}

bool valid_migration_verdict(const jarvis::identity::operator_attestation::AttestationVerdict& verdict,
                             const std::string& new_machine_uuid,
                             std::uint64_t now_unix_seconds) {
    constexpr std::uint64_t kPastFreshnessSeconds = 5 * 60;
    constexpr std::uint64_t kFutureJitterSeconds = 1;
    if (!verdict.allowed()) return false;
    if (verdict.bound_operation != "continuity_migration") return false;
    if (verdict.bound_subject != new_machine_uuid) return false;
    if (verdict.bound_challenge_id.empty()) return false;
    if (verdict.monotonic_at) {
        const auto delta = std::chrono::steady_clock::now() - *verdict.monotonic_at;
        return delta >= -std::chrono::seconds(kFutureJitterSeconds) &&
               delta <= std::chrono::seconds(kPastFreshnessSeconds);
    }
    if (verdict.bound_issued_at < 0) return false;
    const auto issued = static_cast<std::uint64_t>(verdict.bound_issued_at);
    return issued + kPastFreshnessSeconds >= now_unix_seconds && issued <= now_unix_seconds + kFutureJitterSeconds;
}

std::string sign_payload(std::string_view payload, std::span<const unsigned char, 64> private_key) {
    ensure_sodium();
    std::array<unsigned char, crypto_sign_BYTES> sig{};
    crypto_sign_detached(sig.data(), nullptr,
                         reinterpret_cast<const unsigned char*>(payload.data()),
                         static_cast<unsigned long long>(payload.size()),
                         private_key.data());
    return hex_encode(std::span<const unsigned char>(sig.data(), sig.size()));
}

bool verify_payload_signature(std::string_view payload,
                              const std::string& signature_hex,
                              std::span<const unsigned char, 32> public_key) {
    try {
        ensure_sodium();
        const auto sig = hex_decode(signature_hex);
        if (sig.size() != crypto_sign_BYTES) return false;
        return crypto_sign_verify_detached(sig.data(),
                                           reinterpret_cast<const unsigned char*>(payload.data()),
                                           static_cast<unsigned long long>(payload.size()),
                                           public_key.data()) == 0;
    } catch (...) {
        return false;
    }
}

std::string continuity_metadata(ContinuityStatus, const std::string&) {
    return "{}";
}

std::string load_enveloped_root_pubkey(const std::filesystem::path& path, const std::string& trusted_root_public_key_hex) {
    const auto root_payload = jarvis::audit::verify_trust_envelope_file(path, trusted_root_public_key_hex);
    if (root_payload.size() != crypto_sign_PUBLICKEYBYTES) throw std::runtime_error("TrustEnvelopeInvalid: anchor_root payload must be 32 bytes");
    return hex_encode(std::span<const unsigned char>(root_payload.data(), root_payload.size()));
}

} // namespace

std::string SelfStateSnapshot::canonical() const {
    return std::string("{")
        + "\"cognition_epoch\":\"" + json_escape(cognition_epoch) + "\","
        + "\"memory_checkpoint\":\"" + json_escape(memory_checkpoint) + "\","
        + "\"runtime_build\":\"" + json_escape(runtime_build) + "\","
        + "\"served_turns\":" + std::to_string(served_turns)
        + "}";
}

std::string SelfStateSnapshot::hash() const {
    return sha256_hex(canonical());
}

std::string ContinuityCertificate::canonical_payload() const {
    return std::string("{")
        + "\"audit_chain_head\":\"" + json_escape(audit_chain_head_hex) + "\","
        + "\"audit_verified_count\":" + std::to_string(audit_verified_count) + ","
        + "\"expected_interval_seconds\":" + std::to_string(expected_interval_seconds) + ","
        + "\"expected_interval_turns\":" + std::to_string(expected_interval_turns) + ","
        + "\"identity_hash\":\"" + json_escape(identity_hash) + "\","
        + "\"idle_threshold_seconds\":" + std::to_string(idle_threshold_seconds) + ","
        + "\"issued_at\":\"" + json_escape(issued_at_unix) + "\","
        + "\"migration_attestation_hash\":\"" + json_escape(migration_attestation_hash) + "\","
        + "\"operator_id\":\"" + json_escape(operator_id) + "\","
        + "\"previous_certificate_hash\":\"" + json_escape(previous_certificate_hash) + "\","
        + "\"self_state_snapshot_hash\":\"" + json_escape(self_state_snapshot_hash) + "\","
        + "\"signer_public_key\":\"" + json_escape(signer_public_key_hex) + "\","
        + "\"subject_id\":\"" + json_escape(subject_id) + "\","
        + "\"turn_index\":" + std::to_string(turn_index) + ","
        + "\"v\":\"" + json_escape(version) + "\","
        + "\"values_hash\":\"" + json_escape(values_hash) + "\""
        + "}";
}

std::string ContinuityCertificate::certificate_hash() const {
    return sha256_hex(canonical_payload());
}

std::string ContinuityCertificate::to_json() const {
    return std::string("{")
        + "\"payload\":" + canonical_payload() + ","
        + "\"signature\":\"" + json_escape(signature_hex) + "\""
        + "}";
}

std::string to_string(ContinuityStatus status) {
    switch (status) {
        case ContinuityStatus::OK: return "OK";
        case ContinuityStatus::DEGRADED_AUDIT_GAP: return "DEGRADED_AUDIT_GAP";
        case ContinuityStatus::DEGRADED_VALUES_TAMPER: return "DEGRADED_VALUES_TAMPER";
        case ContinuityStatus::DEGRADED_SIGNATURE_TAMPER: return "DEGRADED_SIGNATURE_TAMPER";
        case ContinuityStatus::DEGRADED_STOPPED_GAP: return "DEGRADED_STOPPED_GAP";
        case ContinuityStatus::DEGRADED_ANCHOR_FAILURE: return "DEGRADED_ANCHOR_FAILURE";
        case ContinuityStatus::RECONCILED: return "RECONCILED";
    }
    return "DEGRADED_ANCHOR_FAILURE";
}

std::string ReconciliationAttestation::canonical() const {
    return std::string("{")
        + "\"attested_at\":\"" + json_escape(attested_at_unix) + "\","
        + "\"new_hardware_fingerprint\":\"" + json_escape(new_hardware_fingerprint) + "\","
        + "\"operator_verdict_challenge\":\"" + json_escape(operator_verdict.bound_challenge_id) + "\","
        + "\"operator_verdict_operation\":\"" + json_escape(operator_verdict.bound_operation) + "\","
        + "\"operator_verdict_status\":\"" + json_escape(jarvis::identity::operator_attestation::to_string(operator_verdict.status)) + "\","
        + "\"operator_verdict_subject\":\"" + json_escape(operator_verdict.bound_subject) + "\","
        + "\"operator_id\":\"" + json_escape(operator_id) + "\","
        + "\"previous_certificate_hash\":\"" + json_escape(previous_certificate_hash) + "\","
        + "\"reason_code\":\"" + json_escape(reason_code) + "\""
        + "}";
}

std::string ReconciliationAttestation::hash() const {
    return sha256_hex(canonical());
}

ContinuityVerifier::ContinuityVerifier(BirthCertificate birth_certificate,
                                       CharacterValues character_values,
                                       HardwareFingerprint hardware_fingerprint,
                                       ContinuityConfig config)
    : birth_certificate_(std::move(birth_certificate)),
      character_values_(std::move(character_values)),
      hardware_fingerprint_(std::move(hardware_fingerprint)),
      config_(std::move(config)) {
    if (config_.trust_anchor_pubkey_path.empty()) config_.trust_anchor_pubkey_path = default_anchor_root_path();
    if (config_.audit_anchor_path.empty()) config_.audit_anchor_path = default_audit_anchor_path();
    if (config_.consumed_challenge_path.empty()) config_.consumed_challenge_path = default_consumed_challenge_path();
}

std::string ContinuityVerifier::load_pinned_root_pubkey(const std::filesystem::path& path) {
    const auto anchor_path = path.empty() ? default_anchor_root_path() : path;
    int fd = jarvis::audit::path_policy_open_read(anchor_path);
    std::array<unsigned char, 32> key{};
    ssize_t n = ::read(fd, key.data(), key.size());
    char extra = 0;
    ssize_t more = ::read(fd, &extra, 1);
    ::close(fd);
    if (n != static_cast<ssize_t>(key.size()) || more != 0) {
        throw std::runtime_error("pinned Soul Anchor root public key must be exactly 32 raw bytes: " + anchor_path.string());
    }
    return hex_encode(std::span<const unsigned char>(key.data(), key.size()));
}

ContinuityVerifier::AuditCheckpoint ContinuityVerifier::verify_audit_checkpoint() const {
    AuditCheckpoint checkpoint;
    jarvis::audit::AuditVerifier verifier(config_.audit_log_path);
    jarvis::audit::VerifyResult result;
    try {
        const auto anchor = jarvis::audit::AuditVerifier::load_trust_anchor(config_.audit_anchor_path, birth_certificate_.root_public_key_hex);
        result = verifier.verify(anchor);
    } catch (const std::exception& ex) {
        checkpoint.failure_reason = ex.what();
        return checkpoint;
    }
    checkpoint.verified_count = result.verified_count;
    if (result.status != jarvis::audit::VerifyStatus::PASS) {
        checkpoint.failure_reason = result.verdict;
        return checkpoint;
    }
    checkpoint.ok = true;
    for (jarvis::audit::AuditLogIterator it(config_.audit_log_path), end; it != end; ++it) {
        checkpoint.head_hex = audit_hash_hex(it->own_hash);
    }
    return checkpoint;
}

void ContinuityVerifier::audit_continuity(ContinuityStatus status, const std::string& reason) const {
    jarvis::audit::TamperEvidentAuditLog log(config_.audit_log_path.string());
    jarvis::audit::AuditEvent event;
    event.event_kind = jarvis::audit::EventKind::IDENTITY_CHECK;
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "continuity";
    event.outcome = status == ContinuityStatus::OK || status == ContinuityStatus::RECONCILED
        ? jarvis::audit::Outcome::PASS
        : jarvis::audit::Outcome::FAIL;
    event.reason = reason;
    event.redacted_metadata = continuity_metadata(status, reason);
    event.organ = "continuity";
    log.append(event);
}

void ContinuityVerifier::raise_distress(ContinuityStatus status, const std::string& reason) const {
    jarvis::audit::TamperEvidentAuditLog log(config_.audit_log_path.string());
    jarvis::identity::distress::DistressEvent event;
    event.type = jarvis::identity::distress::DistressType::IdentityChainBroken;
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "identity_continuity";
    event.reason = "continuity_break";
    event.snapshot.organ = "identity/continuity";
    event.snapshot.identity_status = to_string(status);
    event.snapshot.degradation_tier = "continuity_degraded";
    event.snapshot.critical_action_requested = true;
    event.snapshot.active_defenses = {"irreversible-action-refusal", "local-audit", "p7-distress-beacon"};
    event.snapshot.additional_redacted_json = continuity_metadata(status, reason);
    jarvis::identity::distress::emit(log, std::move(event));
}

ContinuityResult ContinuityVerifier::verify_boot(std::optional<ContinuityCertificate> last_certificate,
                                                 std::uint64_t now_unix_seconds) const {
    ContinuityResult result;
    std::string pinned_root;
    try {
        pinned_root = load_enveloped_root_pubkey(config_.trust_anchor_pubkey_path, birth_certificate_.root_public_key_hex);
    } catch (const std::exception& ex) {
        result.status = ContinuityStatus::DEGRADED_ANCHOR_FAILURE;
        result.reason = std::string("soul_anchor_root_trust_failure: ") + ex.what();
        audit_continuity(result.status, result.reason);
        raise_distress(result.status, result.reason);
        return result;
    }
    const auto anchor_status = SoulAnchor::verify_birth_certificate(birth_certificate_, character_values_, hardware_fingerprint_, pinned_root);
    if (anchor_status == IdentityStatus::TAMPERED) {
        result.status = ContinuityStatus::DEGRADED_VALUES_TAMPER;
        result.reason = "values_hash_or_hardware_mismatch_against_soul_anchor";
        audit_continuity(result.status, result.reason);
        raise_distress(result.status, result.reason);
        return result;
    }
    if (anchor_status != IdentityStatus::OK) {
        result.status = ContinuityStatus::DEGRADED_ANCHOR_FAILURE;
        result.reason = "soul_anchor_signature_or_schema_failure";
        audit_continuity(result.status, result.reason);
        raise_distress(result.status, result.reason);
        return result;
    }

    const auto audit = verify_audit_checkpoint();
    result.audit_chain_head_hex = audit.head_hex;
    result.audit_verified_count = audit.verified_count;
    if (!audit.ok) {
        result.status = ContinuityStatus::DEGRADED_AUDIT_GAP;
        result.reason = "audit_chain_gap:" + audit.failure_reason;
        audit_continuity(result.status, "audit_chain_gap");
        raise_distress(result.status, result.reason);
        return result;
    }

    if (last_certificate) {
        std::vector<unsigned char> pub;
        try {
            pub = hex_decode(last_certificate->signer_public_key_hex);
        } catch (...) {
            result.status = ContinuityStatus::DEGRADED_SIGNATURE_TAMPER;
            result.reason = "continuity_certificate_public_key_invalid";
            audit_continuity(result.status, result.reason);
            raise_distress(result.status, result.reason);
            return result;
        }
        if (pub.size() != crypto_sign_PUBLICKEYBYTES ||
            verify_certificate(*last_certificate, std::span<const unsigned char, 32>(pub.data(), pub.size())) != ContinuityStatus::OK) {
            result.status = ContinuityStatus::DEGRADED_SIGNATURE_TAMPER;
            result.reason = "continuity_certificate_signature_failed";
            audit_continuity(result.status, result.reason);
            raise_distress(result.status, result.reason);
            return result;
        }
        if (audit.verified_count < last_certificate->audit_verified_count) {
            result.status = ContinuityStatus::DEGRADED_AUDIT_GAP;
            result.reason = "audit_chain_shorter_than_last_continuity_checkpoint";
            audit_continuity(result.status, result.reason);
            raise_distress(result.status, result.reason);
            return result;
        }
        if (!safe_equal(last_certificate->values_hash, character_values_.values_hash())) {
            result.status = ContinuityStatus::DEGRADED_VALUES_TAMPER;
            result.reason = "continuity_certificate_values_hash_differs_from_anchor";
            audit_continuity(result.status, result.reason);
            raise_distress(result.status, result.reason);
            return result;
        }
        try {
            const std::uint64_t issued = parse_u64(last_certificate->issued_at_unix);
            if (now_unix_seconds > issued && now_unix_seconds - issued > config_.idle_threshold_seconds) {
                result.status = ContinuityStatus::DEGRADED_STOPPED_GAP;
                result.reason = "continuity_certificate_idle_threshold_exceeded";
                audit_continuity(result.status, result.reason);
                raise_distress(result.status, result.reason);
                return result;
            }
        } catch (...) {
            result.status = ContinuityStatus::DEGRADED_SIGNATURE_TAMPER;
            result.reason = "continuity_certificate_timestamp_invalid";
            audit_continuity(result.status, result.reason);
            raise_distress(result.status, result.reason);
            return result;
        }
    }

    result.status = ContinuityStatus::OK;
    result.cognition_allowed = true;
    result.irreversible_actions_allowed = true;
    result.reason = "continuity_verified_before_cognition";
    audit_continuity(result.status, result.reason);
    return result;
}

ContinuityCertificate ContinuityVerifier::issue_certificate(const SelfStateSnapshot& snapshot,
                                                            std::span<const unsigned char, 32> signer_public_key,
                                                            std::span<const unsigned char, 64> signer_private_key,
                                                            std::optional<ContinuityCertificate> previous_certificate,
                                                            std::uint64_t now_unix_seconds,
                                                            std::uint64_t turn_index,
                                                            std::string migration_attestation_hash) const {
    const auto pinned_root = load_enveloped_root_pubkey(config_.trust_anchor_pubkey_path, birth_certificate_.root_public_key_hex);
    const auto identity_status = SoulAnchor::verify_birth_certificate(birth_certificate_, character_values_, hardware_fingerprint_, pinned_root);
    if (identity_status != IdentityStatus::OK) {
        audit_continuity(identity_status == IdentityStatus::TAMPERED ? ContinuityStatus::DEGRADED_VALUES_TAMPER : ContinuityStatus::DEGRADED_ANCHOR_FAILURE,
                         "refusing_continuity_certificate_anchor_not_verified");
        throw std::runtime_error("refusing to issue continuity certificate while Soul Anchor is not verified");
    }
    const auto audit = verify_audit_checkpoint();
    if (!audit.ok) throw std::runtime_error("refusing to issue continuity certificate while audit chain is broken: " + audit.failure_reason);
    ContinuityCertificate cert;
    cert.issued_at_unix = std::to_string(now_unix_seconds);
    cert.turn_index = turn_index;
    cert.values_hash = character_values_.values_hash();
    cert.identity_hash = character_values_.identity_hash();
    cert.audit_chain_head_hex = audit.head_hex;
    cert.audit_verified_count = audit.verified_count;
    cert.self_state_snapshot_hash = snapshot.hash();
    cert.previous_certificate_hash = previous_certificate ? previous_certificate->certificate_hash() : "genesis";
    cert.expected_interval_seconds = config_.certificate_interval_seconds;
    cert.expected_interval_turns = config_.certificate_interval_turns;
    cert.idle_threshold_seconds = config_.idle_threshold_seconds;
    cert.signer_public_key_hex = hex_encode(signer_public_key);
    cert.migration_attestation_hash = std::move(migration_attestation_hash);
    cert.signature_hex = sign_payload(cert.canonical_payload(), signer_private_key);
    audit_continuity(ContinuityStatus::OK, "continuity_certificate_issued");
    return cert;
}

ContinuityStatus ContinuityVerifier::verify_certificate(const ContinuityCertificate& certificate,
                                                        std::span<const unsigned char, 32> signer_public_key) const {
    if (certificate.version != kContinuityVersion || certificate.subject_id != "JARVIS") {
        return ContinuityStatus::DEGRADED_SIGNATURE_TAMPER;
    }
    if (!safe_equal(certificate.values_hash, character_values_.values_hash()) ||
        !safe_equal(certificate.identity_hash, character_values_.identity_hash()) ||
        !safe_equal(certificate.signer_public_key_hex, hex_encode(signer_public_key))) {
        return ContinuityStatus::DEGRADED_VALUES_TAMPER;
    }
    return verify_payload_signature(certificate.canonical_payload(), certificate.signature_hex, signer_public_key)
        ? ContinuityStatus::OK
        : ContinuityStatus::DEGRADED_SIGNATURE_TAMPER;
}

bool ContinuityVerifier::certificate_due(const std::optional<ContinuityCertificate>& last_certificate,
                                         std::uint64_t now_unix_seconds,
                                         std::uint64_t current_turn_index) const {
    if (!last_certificate) return true;
    try {
        const auto issued = parse_u64(last_certificate->issued_at_unix);
        if (now_unix_seconds >= issued + config_.certificate_interval_seconds) return true;
    } catch (...) {
        return true;
    }
    return current_turn_index >= last_certificate->turn_index + config_.certificate_interval_turns;
}

bool ContinuityVerifier::irreversible_action_allowed(const ContinuityResult& result) const {
    return result.status == ContinuityStatus::OK && result.irreversible_actions_allowed;
}

ContinuityCertificate ContinuityVerifier::reconcile_legitimate_migration(
    const ReconciliationAttestation& attestation,
    const BirthCertificate& new_birth_certificate,
    const HardwareFingerprint& new_hardware_fingerprint,
    const SelfStateSnapshot& snapshot,
    std::span<const unsigned char, 32> signer_public_key,
    std::span<const unsigned char, 64> signer_private_key,
    std::optional<ContinuityCertificate> previous_certificate,
    std::uint64_t now_unix_seconds,
    std::uint64_t turn_index) const {
    if (attestation.operator_id != "Robert \"Grizzly\" Hanson, GMRI" ||
        attestation.reason_code.empty() || attestation.attested_at_unix.empty() ||
        !valid_migration_verdict(attestation.operator_verdict, new_hardware_fingerprint.machine_uuid, now_unix_seconds)) {
        audit_continuity(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_operator_verdict_invalid");
        raise_distress(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_operator_verdict_invalid");
        throw std::runtime_error("cryptographic operator verdict is required for continuity reconciliation");
    }
    if (!consume_challenge_once(config_.consumed_challenge_path, attestation.operator_verdict)) {
        audit_continuity(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_operator_verdict_replayed");
        raise_distress(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_operator_verdict_replayed");
        throw std::runtime_error("continuity migration operator verdict was already consumed or could not be persisted");
    }
    if (previous_certificate && !safe_equal(attestation.previous_certificate_hash, previous_certificate->certificate_hash())) {
        audit_continuity(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_previous_certificate_mismatch");
        raise_distress(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_previous_certificate_mismatch");
        throw std::runtime_error("reconciliation previous certificate hash mismatch");
    }
    if (!safe_equal(attestation.new_hardware_fingerprint, new_hardware_fingerprint.canonical())) {
        audit_continuity(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_hardware_attestation_mismatch");
        raise_distress(ContinuityStatus::DEGRADED_SIGNATURE_TAMPER, "reconciliation_hardware_attestation_mismatch");
        throw std::runtime_error("reconciliation hardware attestation mismatch");
    }
    const auto pinned_root = load_enveloped_root_pubkey(config_.trust_anchor_pubkey_path, new_birth_certificate.root_public_key_hex);
    const auto identity_status = SoulAnchor::verify_birth_certificate(new_birth_certificate, character_values_, new_hardware_fingerprint, pinned_root);
    if (identity_status != IdentityStatus::OK) {
        audit_continuity(ContinuityStatus::DEGRADED_ANCHOR_FAILURE, "reconciliation_new_anchor_invalid");
        raise_distress(ContinuityStatus::DEGRADED_ANCHOR_FAILURE, "reconciliation_new_anchor_invalid");
        throw std::runtime_error("reconciliation new birth certificate does not verify");
    }
    audit_continuity(ContinuityStatus::RECONCILED, "operator_attested_legitimate_migration");
    ContinuityVerifier migrated(new_birth_certificate, character_values_, new_hardware_fingerprint, config_);
    return migrated.issue_certificate(snapshot, signer_public_key, signer_private_key, previous_certificate,
                                      now_unix_seconds, turn_index, attestation.hash());
}

} // namespace jarvis::identity::continuity
