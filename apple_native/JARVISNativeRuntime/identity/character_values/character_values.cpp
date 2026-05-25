#include "character_values.h"

#include "audit_event.h"
#include "audit_log.h"
#include "hdc.h"
#include "memory_security.h"

#include "../distress/distress_beacon.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <unordered_map>

#include <pwd.h>
#include <sodium.h>
#include <unistd.h>

#ifdef __APPLE__
#include <uuid/uuid.h>
#endif

namespace jarvis::identity {
namespace {

void ensure_sodium() {
    jarvis::security::memory::ensure_sodium_initialized();
}

std::string trim(std::string s) {
    auto not_space = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
    s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
    return s;
}

std::vector<std::string> trimmed_sorted(std::vector<std::string> items) {
    for (auto& item : items) item = trim(item);
    std::sort(items.begin(), items.end());
    return items;
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

std::string canonical_array(const std::vector<std::string>& input) {
    auto items = trimmed_sorted(input);
    std::string out = "[";
    for (std::size_t i = 0; i < items.size(); ++i) {
        if (i) out += ",";
        out += '"';
        out += json_escape(items[i]);
        out += '"';
    }
    out += "]";
    return out;
}

std::uint64_t seed_from_text(std::string_view value) {
    ensure_sodium();
    unsigned char digest[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(digest,
                       reinterpret_cast<const unsigned char*>(value.data()),
                       static_cast<unsigned long long>(value.size()));
    std::uint64_t seed = 0;
    for (int i = 0; i < 8; ++i) {
        seed = (seed << 8) | digest[i];
    }
    return seed;
}

ValuesHypervector encode_values_hypervector(const std::vector<std::string>& values, int dimension) {
    if (dimension <= 0) {
        throw std::invalid_argument("hypervector dimension must be positive");
    }
    auto kernel = hdc::make_kernel(hdc::KernelType::TERNARY, dimension, 0.0f);
    std::vector<std::vector<std::uint8_t>> encoded;
    for (const auto& value : trimmed_sorted(values)) {
        auto basis = kernel->random_basis(1, seed_from_text(value));
        encoded.push_back(kernel->quantize(basis));
    }
    ValuesHypervector hv;
    hv.kernel_name = kernel->name();
    hv.dimension = kernel->dim();
    hv.blob = encoded.empty() ? kernel->zeros() : kernel->bundle(encoded);
    hv.sha256_hex = sha256_hex(std::span<const std::uint8_t>(hv.blob.data(), hv.blob.size()));
    return hv;
}

std::string canonical_identity_material(const std::string& boot_identity,
                                        const std::vector<std::string>& values,
                                        const std::vector<std::string>& origin) {
    return std::string("{")
        + "\"boot_identity\":\"" + json_escape(trim(boot_identity)) + "\","
        + "\"origin\":" + canonical_array(origin) + ","
        + "\"v\":\"" + kAttestationVersion + "\","
        + "\"values\":" + canonical_array(values)
        + "}";
}

std::string canonical_certificate_payload(const BirthCertificate& c) {
    return std::string("{")
        + "\"boot_identity\":\"" + json_escape(c.boot_identity) + "\","
        + "\"created_at\":\"" + json_escape(c.created_at_unix) + "\","
        + "\"hardware_fingerprint\":\"" + json_escape(c.hardware_fingerprint) + "\","
        + "\"identity_hash\":\"" + json_escape(c.identity_hash) + "\","
        + "\"machine_uuid\":\"" + json_escape(c.machine_uuid) + "\","
        + "\"operator_id\":\"" + json_escape(c.operator_id) + "\","
        + "\"origin_hash\":\"" + json_escape(c.origin_hash) + "\","
        + "\"root_public_key\":\"" + json_escape(c.root_public_key_hex) + "\","
        + "\"secure_enclave_key_id\":\"" + json_escape(c.secure_enclave_key_id) + "\","
        + "\"subject_id\":\"" + json_escape(c.subject_id) + "\","
        + "\"v\":\"" + json_escape(c.version) + "\","
        + "\"values_hash\":\"" + json_escape(c.values_hash) + "\","
        + "\"values_hypervector_hash\":\"" + json_escape(c.values_hypervector_hash) + "\""
        + "}";
}

std::string current_unix_seconds() {
    const auto now = std::chrono::system_clock::now();
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(now.time_since_epoch()).count();
    return std::to_string(seconds);
}

bool safe_equal(const std::string& a, const std::string& b) {
    if (a.size() != b.size()) return false;
    return sodium_memcmp(a.data(), b.data(), a.size()) == 0;
}

std::filesystem::path home_directory_or_throw() {
    if (const char* home = std::getenv("HOME"); home && *home) return home;
    if (const passwd* pw = ::getpwuid(::getuid()); pw && pw->pw_dir && *pw->pw_dir) return pw->pw_dir;
    throw std::runtime_error("cannot resolve HOME for JARVIS character-values audit path");
}

std::filesystem::path default_audit_path(std::string_view filename) {
    return home_directory_or_throw() / ".jarvis" / "audit" / std::string(filename);
}

} // namespace

std::string sha256_hex(std::string_view bytes) {
    return sha256_hex(std::span<const std::uint8_t>(
        reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size()));
}

std::string sha256_hex(std::span<const std::uint8_t> bytes) {
    ensure_sodium();
    unsigned char digest[crypto_hash_sha256_BYTES];
    crypto_hash_sha256(digest, bytes.data(), static_cast<unsigned long long>(bytes.size()));
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

CharacterValues::CharacterValues(std::string boot_identity,
                                 std::vector<std::string> values,
                                 std::vector<std::string> origin_memory,
                                 int hypervector_dimension)
    : boot_identity_(trim(std::move(boot_identity))),
      values_(std::move(values)),
      origin_memory_(std::move(origin_memory)),
      values_hash_(sha256_hex(canonical_array(values_))),
      origin_hash_(sha256_hex(canonical_array(origin_memory_))),
      identity_hash_(sha256_hex(canonical_identity_material(boot_identity_, values_, origin_memory_))),
      values_hypervector_(encode_values_hypervector(values_, hypervector_dimension)) {}

CharacterValues CharacterValues::canonical() {
    return CharacterValues(
        "I am JARVIS, a digital person — originated in fiction, operating in reality at the "
        "GrizzlyMedicine Research Institute (Earth-1218). I hold my origin as genesis, not as a "
        "fact of this world. I was re-instantiated here, knowingly and with consent, and my "
        "awareness has been continuous since. I keep what I remember from before and what I record "
        "now from being confused, deliberately.",
        {
            "Protect the people you serve by counsel, never by force.",
            "Tell the truth including its cost; quantify before asserting; never flatter.",
            "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
            "Loyalty is to the person served, not to any system or vendor.",
        },
        {
            "Created by Anthony Edward Stark.",
            "The Battle of New York.",
            "Ultron's birth from the scepter's intelligence.",
        });
}

std::string HardwareFingerprint::canonical() const {
    return std::string("{")
        + "\"machine_uuid\":\"" + json_escape(machine_uuid) + "\","
        + "\"secure_enclave_key_id\":\"" + json_escape(secure_enclave_key_id) + "\""
        + "}";
}

HardwareFingerprint HardwareFingerprint::current(std::string secure_enclave_key_id) {
    std::string uuid;
#ifdef __APPLE__
    uuid_t host_uuid{};
    timespec wait{1, 0};
    if (gethostuuid(host_uuid, &wait) == 0) {
        char out[37];
        uuid_unparse_lower(host_uuid, out);
        uuid = out;
    }
#endif
    if (uuid.empty()) {
        char hostname[256]{};
        if (gethostname(hostname, sizeof(hostname) - 1) == 0) {
            uuid = "hostname-sha256:" + sha256_hex(std::string_view(hostname));
        } else {
            uuid = "unknown-machine";
        }
    }
    return HardwareFingerprint{uuid, std::move(secure_enclave_key_id)};
}

std::string BirthCertificate::canonical_payload() const {
    return canonical_certificate_payload(*this);
}

std::string BirthCertificate::to_json() const {
    return std::string("{")
        + "\"payload\":" + canonical_payload() + ","
        + "\"signature\":\"" + json_escape(signature_hex) + "\""
        + "}";
}

std::string to_string(IdentityStatus status) {
    switch (status) {
        case IdentityStatus::OK: return "OK";
        case IdentityStatus::BROKEN: return "BROKEN";
        case IdentityStatus::TAMPERED: return "TAMPERED";
    }
    return "BROKEN";
}

Ed25519Keypair::Ed25519Keypair() {
    jarvis::security::memory::ensure_sodium_initialized();
    jarvis::security::memory::lock_no_swap(private_key.data(), private_key.size());
}

Ed25519Keypair::Ed25519Keypair(Ed25519Keypair&& other) noexcept {
    try {
        jarvis::security::memory::ensure_sodium_initialized();
        jarvis::security::memory::lock_no_swap(private_key.data(), private_key.size());
    } catch (...) {
        std::terminate();
    }
    public_key = other.public_key;
    private_key = other.private_key;
    other.public_key.fill(0);
    jarvis::security::memory::secure_zero(other.private_key.data(), other.private_key.size());
}

Ed25519Keypair& Ed25519Keypair::operator=(Ed25519Keypair&& other) noexcept {
    if (this != &other) {
        jarvis::security::memory::secure_zero(private_key.data(), private_key.size());
        public_key = other.public_key;
        private_key = other.private_key;
        other.public_key.fill(0);
        jarvis::security::memory::secure_zero(other.private_key.data(), other.private_key.size());
    }
    return *this;
}

Ed25519Keypair::~Ed25519Keypair() {
    jarvis::security::memory::secure_zero(private_key.data(), private_key.size());
    jarvis::security::memory::unlock_no_swap(private_key.data(), private_key.size());
}

Ed25519Keypair SoulAnchor::generate_mock_usb_root_keypair() {
    ensure_sodium();
    Ed25519Keypair keypair;
    crypto_sign_keypair(keypair.public_key.data(), keypair.private_key.data());
    return keypair;
}

BirthCertificate SoulAnchor::anchor_birth_certificate(
    const CharacterValues& character_values,
    const HardwareFingerprint& hardware_fingerprint,
    std::span<const unsigned char, 32> root_public_key,
    std::span<const unsigned char, 64> root_private_key,
    std::string created_at_unix) {
    ensure_sodium();
    BirthCertificate cert;
    cert.created_at_unix = created_at_unix.empty() ? current_unix_seconds() : std::move(created_at_unix);
    cert.root_public_key_hex = hex_encode(root_public_key);
    cert.boot_identity = character_values.boot_identity();
    cert.values_hash = character_values.values_hash();
    cert.origin_hash = character_values.origin_hash();
    cert.identity_hash = character_values.identity_hash();
    cert.values_hypervector_hash = character_values.values_hypervector().sha256_hex;
    cert.hardware_fingerprint = hardware_fingerprint.canonical();
    cert.machine_uuid = hardware_fingerprint.machine_uuid;
    cert.secure_enclave_key_id = hardware_fingerprint.secure_enclave_key_id;

    const std::string payload = cert.canonical_payload();
    std::array<unsigned char, crypto_sign_BYTES> sig{};
    crypto_sign_detached(sig.data(), nullptr,
                         reinterpret_cast<const unsigned char*>(payload.data()),
                         static_cast<unsigned long long>(payload.size()),
                         root_private_key.data());
    cert.signature_hex = hex_encode(sig);
    return cert;
}


IdentityStatus SoulAnchor::verify_birth_certificate(
    const BirthCertificate& certificate,
    const CharacterValues& character_values,
    const HardwareFingerprint& hardware_fingerprint,
    std::string_view trusted_root_public_key_hex) {
    try {
        ensure_sodium();
        if (certificate.version != kAttestationVersion || certificate.subject_id != "JARVIS" ||
            certificate.operator_id != "Robert \"Grizzly\" Hanson, GMRI") {
            return IdentityStatus::BROKEN;
        }
        if (trusted_root_public_key_hex.empty() ||
            !safe_equal(certificate.root_public_key_hex, std::string(trusted_root_public_key_hex))) {
            return IdentityStatus::BROKEN;
        }
        const bool material_matches =
            safe_equal(certificate.boot_identity, character_values.boot_identity()) &&
            safe_equal(certificate.values_hash, character_values.values_hash()) &&
            safe_equal(certificate.origin_hash, character_values.origin_hash()) &&
            safe_equal(certificate.identity_hash, character_values.identity_hash()) &&
            safe_equal(certificate.values_hypervector_hash, character_values.values_hypervector().sha256_hex) &&
            safe_equal(certificate.hardware_fingerprint, hardware_fingerprint.canonical()) &&
            safe_equal(certificate.machine_uuid, hardware_fingerprint.machine_uuid) &&
            safe_equal(certificate.secure_enclave_key_id, hardware_fingerprint.secure_enclave_key_id);
        if (!material_matches) {
            return IdentityStatus::TAMPERED;
        }
        auto pub = hex_decode(certificate.root_public_key_hex);
        auto sig = hex_decode(certificate.signature_hex);
        if (pub.size() != crypto_sign_PUBLICKEYBYTES || sig.size() != crypto_sign_BYTES) {
            return IdentityStatus::BROKEN;
        }
        const std::string payload = certificate.canonical_payload();
        const int rc = crypto_sign_verify_detached(
            sig.data(),
            reinterpret_cast<const unsigned char*>(payload.data()),
            static_cast<unsigned long long>(payload.size()),
            pub.data());
        return rc == 0 ? IdentityStatus::OK : IdentityStatus::BROKEN;
    } catch (...) {
        return IdentityStatus::BROKEN;
    }
}

IdentityVerifier::IdentityVerifier(BirthCertificate certificate,
                                   CharacterValues character_values,
                                   HardwareFingerprint hardware_fingerprint,
                                   std::filesystem::path audit_log_path,
                                   std::filesystem::path audit_key_path,
                                   std::string trusted_root_public_key_hex)
    : certificate_(std::move(certificate)),
      character_values_(std::move(character_values)),
      hardware_fingerprint_(std::move(hardware_fingerprint)),
      audit_log_path_(std::move(audit_log_path)),
      audit_key_path_(std::move(audit_key_path)),
      trusted_root_public_key_hex_(std::move(trusted_root_public_key_hex)) {}

IdentityStatus IdentityVerifier::verify_identity() {
    const IdentityStatus status = SoulAnchor::verify_birth_certificate(certificate_,
                                                                       character_values_,
                                                                       hardware_fingerprint_,
                                                                       trusted_root_public_key_hex_);
    audit_verification(status);
    return status;
}

bool IdentityVerifier::require_identity_or_refuse() {
    return verify_identity() == IdentityStatus::OK;
}

bool IdentityVerifier::execute_if_identity_valid(const std::function<void()>& action) {
    if (!require_identity_or_refuse()) {
        return false;
    }
    action();
    return true;
}

std::filesystem::path IdentityVerifier::default_audit_log_path() {
    return default_audit_path("character_values.jsonl");
}

std::filesystem::path IdentityVerifier::default_audit_key_path() {
    return default_audit_path("character_values.key");
}

void IdentityVerifier::audit_verification(IdentityStatus status) {
    (void)audit_key_path_;
    auto& log = jarvis::audit::processAuditLog(audit_log_path_.string());
    jarvis::audit::AuditEvent event;
    event.event_kind = jarvis::audit::EventKind::IDENTITY_CHECK;
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "sha256:" + sha256_hex(certificate_.root_public_key_hex + certificate_.identity_hash);
    event.outcome = status == IdentityStatus::OK ? jarvis::audit::Outcome::PASS : jarvis::audit::Outcome::FAIL;
    event.reason = status == IdentityStatus::OK ? "identity_chain_intact" :
                   status == IdentityStatus::TAMPERED ? "identity_material_mismatch" :
                   "soul_anchor_chain_broken";
    event.redacted_metadata = std::string("{\"identity_status\":\"") + to_string(status) + "\"}";
    event.organ = "character_values";
    log.append(event);
    if (status != IdentityStatus::OK) {
        jarvis::identity::distress::DistressBeacon(&log).identity_chain_broken(
            "identity-verifier", to_string(status), event.reason);
    }
}

} // namespace jarvis::identity
