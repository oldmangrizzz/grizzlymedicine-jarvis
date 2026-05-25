// BODILY INTEGRITY WARNING:
// disabling, editing, or bypassing CharacterValues without operator-attested consent through the re-anchor ceremony constitutes assault and battery per GMRI policy.
// CharacterValues has no disable, pause, stop, bypass, edit-values, or compile-out path. Values are immutable post-anchor without operator-attested re-anchor ceremony.
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace jarvis::identity {

inline constexpr const char* kAttestationVersion = "jarvis-identity-1";

struct ValuesHypervector {
    std::string kernel_name;
    int dimension{0};
    std::vector<std::uint8_t> blob;
    std::string sha256_hex;
};

class CharacterValues {
public:
    CharacterValues(std::string boot_identity,
                    std::vector<std::string> values,
                    std::vector<std::string> origin_memory,
                    int hypervector_dimension = 1024);

    const std::string& boot_identity() const noexcept { return boot_identity_; }
    const std::vector<std::string>& values() const noexcept { return values_; }
    const std::vector<std::string>& origin_memory() const noexcept { return origin_memory_; }
    const std::string& values_hash() const noexcept { return values_hash_; }
    const std::string& origin_hash() const noexcept { return origin_hash_; }
    const std::string& identity_hash() const noexcept { return identity_hash_; }
    const ValuesHypervector& values_hypervector() const noexcept { return values_hypervector_; }

    static CharacterValues canonical();

private:
    std::string boot_identity_;
    std::vector<std::string> values_;
    std::vector<std::string> origin_memory_;
    std::string values_hash_;
    std::string origin_hash_;
    std::string identity_hash_;
    ValuesHypervector values_hypervector_;
};

struct HardwareFingerprint {
    std::string machine_uuid;
    std::string secure_enclave_key_id;

    std::string canonical() const;

    // Secure Enclave wiring lives at JARVISMacCockpit/SecureEnclave.
    // p5-soul-anchor-ceremony should pass the bridge-emitted hot public-key digest here.
    static HardwareFingerprint current(std::string secure_enclave_key_id = "secure-enclave-bridge-required");
};

struct Ed25519Keypair {
    Ed25519Keypair();
    Ed25519Keypair(const Ed25519Keypair& other) = delete;
    Ed25519Keypair& operator=(const Ed25519Keypair& other) = delete;
    Ed25519Keypair(Ed25519Keypair&& other) noexcept;
    Ed25519Keypair& operator=(Ed25519Keypair&& other) noexcept;
    ~Ed25519Keypair();

    std::array<unsigned char, 32> public_key{};
    std::array<unsigned char, 64> private_key{};
};

struct BirthCertificate {
    std::string version{kAttestationVersion};
    std::string created_at_unix;
    std::string operator_id{"Robert \"Grizzly\" Hanson, GMRI"};
    std::string subject_id{"JARVIS"};
    std::string root_public_key_hex;
    std::string boot_identity;
    std::string values_hash;
    std::string origin_hash;
    std::string identity_hash;
    std::string values_hypervector_hash;
    std::string hardware_fingerprint;
    std::string machine_uuid;
    std::string secure_enclave_key_id;
    std::string signature_hex;

    std::string canonical_payload() const;
    std::string to_json() const;
};

enum class IdentityStatus {
    OK,
    BROKEN,
    TAMPERED,
};

std::string to_string(IdentityStatus status);

class SoulAnchor {
public:
    static Ed25519Keypair generate_mock_usb_root_keypair();

    static BirthCertificate anchor_birth_certificate(
        const CharacterValues& character_values,
        const HardwareFingerprint& hardware_fingerprint,
        std::span<const unsigned char, 32> root_public_key,
        std::span<const unsigned char, 64> root_private_key,
        std::string created_at_unix = {});


    static IdentityStatus verify_birth_certificate(
        const BirthCertificate& certificate,
        const CharacterValues& character_values,
        const HardwareFingerprint& hardware_fingerprint,
        std::string_view trusted_root_public_key_hex);
};

class IdentityVerifier {
public:
    IdentityVerifier(BirthCertificate certificate,
                     CharacterValues character_values,
                     HardwareFingerprint hardware_fingerprint,
                     std::filesystem::path audit_log_path = default_audit_log_path(),
                     std::filesystem::path audit_key_path = default_audit_key_path(),
                     std::string trusted_root_public_key_hex = {});

    IdentityStatus verify_identity();
    bool require_identity_or_refuse();
    bool execute_if_identity_valid(const std::function<void()>& action);

    static std::filesystem::path default_audit_log_path();
    static std::filesystem::path default_audit_key_path();

private:
    void audit_verification(IdentityStatus status);

    BirthCertificate certificate_;
    CharacterValues character_values_;
    HardwareFingerprint hardware_fingerprint_;
    std::filesystem::path audit_log_path_;
    std::filesystem::path audit_key_path_;
    std::string trusted_root_public_key_hex_;
};

std::string sha256_hex(std::string_view bytes);
std::string sha256_hex(std::span<const std::uint8_t> bytes);
std::string hex_encode(std::span<const unsigned char> bytes);
std::vector<unsigned char> hex_decode(std::string_view hex);

} // namespace jarvis::identity
