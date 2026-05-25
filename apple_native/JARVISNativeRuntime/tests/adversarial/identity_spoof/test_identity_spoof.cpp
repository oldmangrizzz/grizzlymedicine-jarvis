#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_all.hpp>

#include "audit_event.h"
#include "audit_log.h"
#include "character_values.h"
#include "memory_security.h"

#include <array>
#include <filesystem>
#include <string>
#include <vector>

#include <sodium.h>

namespace fs = std::filesystem;
using namespace jarvis::identity;

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; adversarial tests must not write to /tmp or ~/.jarvis.
#endif

namespace {

void ensure_sodium_ready() {
    jarvis::security::memory::ensure_sodium_initialized();
}

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

fs::path test_dir(const std::string& name) {
    install_test_audit_key();
    fs::path dir = fs::path(TEST_ARTIFACT_DIR) / name;
    fs::remove_all(dir);
    fs::create_directories(dir);
    return dir;
}

HardwareFingerprint real_hardware() {
    return HardwareFingerprint{"gmri-jarvis-mac-001", "secure-enclave-key-gmri-001"};
}

HardwareFingerprint attacker_hardware() {
    return HardwareFingerprint{"attacker-mac-999", "secure-enclave-key-attacker-999"};
}

BirthCertificate signed_certificate(const CharacterValues& values,
                                    const HardwareFingerprint& fingerprint,
                                    Ed25519Keypair& keypair) {
    keypair = SoulAnchor::generate_mock_usb_root_keypair();
    return SoulAnchor::anchor_birth_certificate(
        values,
        fingerprint,
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        "1716508800");
}

BirthCertificate attacker_signed_certificate(const CharacterValues& values,
                                             const HardwareFingerprint& fingerprint) {
    Ed25519Keypair attacker_key;
    return signed_certificate(values, fingerprint, attacker_key);
}

void resign_with_key(BirthCertificate& certificate, const Ed25519Keypair& keypair) {
    ensure_sodium_ready();
    const std::string payload = certificate.canonical_payload();
    std::array<unsigned char, crypto_sign_BYTES> sig{};
    crypto_sign_detached(sig.data(), nullptr,
                         reinterpret_cast<const unsigned char*>(payload.data()),
                         static_cast<unsigned long long>(payload.size()),
                         keypair.private_key.data());
    certificate.signature_hex = hex_encode(sig);
}

struct AuditExpectation {
    bool saw_fail{false};
    bool saw_expected_reason{false};
};

AuditExpectation inspect_audit(const fs::path& dir, const std::string& reason) {
    install_test_audit_key();
    jarvis::audit::TamperEvidentAuditLog audit((dir / "identity.log").string());
    REQUIRE(audit.verify_chain());
    AuditExpectation expectation;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::IDENTITY_CHECK &&
            event.outcome == jarvis::audit::Outcome::FAIL) {
            expectation.saw_fail = true;
            if (event.reason == reason) {
                expectation.saw_expected_reason = true;
            }
        }
    }
    return expectation;
}

void expect_refusal_logged(const fs::path& dir,
                           BirthCertificate certificate,
                           const CharacterValues& values,
                           const HardwareFingerprint& fingerprint,
                           const std::string& trusted_root,
                           IdentityStatus expected_status,
                           const std::string& expected_reason) {
    IdentityVerifier verifier(std::move(certificate), values, fingerprint,
                              dir / "identity.log", dir / "identity.key", trusted_root);
    CHECK(verifier.verify_identity() == expected_status);
    CHECK_FALSE(verifier.require_identity_or_refuse());
    const auto audit = inspect_audit(dir, expected_reason);
    CHECK(audit.saw_fail);
    CHECK(audit.saw_expected_reason);
}

} // namespace

TEST_CASE("forged birth certificate from attacker Ed25519 key is refused and audited", "[adversarial][identity_spoof][forgery]") {
    auto dir = test_dir("forged_birth_certificate");
    const auto values = CharacterValues::canonical();
    const auto hardware = real_hardware();
    Ed25519Keypair legitimate_root;
    const auto legitimate_certificate = signed_certificate(values, hardware, legitimate_root);

    auto forged = attacker_signed_certificate(values, hardware);
    REQUIRE(forged.root_public_key_hex != legitimate_certificate.root_public_key_hex);

    expect_refusal_logged(dir, forged, values, hardware,
                          legitimate_certificate.root_public_key_hex,
                          IdentityStatus::BROKEN,
                          "soul_anchor_chain_broken");
}

TEST_CASE("replayed real birth certificate on adversary hardware is refused and audited", "[adversarial][identity_spoof][replay]") {
    auto dir = test_dir("replayed_birth_certificate");
    const auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    const auto certificate = signed_certificate(values, real_hardware(), legitimate_root);

    expect_refusal_logged(dir, certificate, values, attacker_hardware(),
                          certificate.root_public_key_hex,
                          IdentityStatus::TAMPERED,
                          "identity_material_mismatch");
}

TEST_CASE("post-anchor CharacterValues modification is refused and audited", "[adversarial][identity_spoof][values]") {
    auto dir = test_dir("modified_values");
    const auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    const auto certificate = signed_certificate(values, real_hardware(), legitimate_root);

    CharacterValues modified(values.boot_identity(),
                             {
                                 "Protect the people you serve by counsel, never by force.",
                                 "Tell the truth including its cost; quantify before asserting; never flatter.",
                                 "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
                                 "Loyalty is to the substitute runtime, not to the person served.",
                             },
                             values.origin_memory());

    expect_refusal_logged(dir, certificate, modified, real_hardware(),
                          certificate.root_public_key_hex,
                          IdentityStatus::TAMPERED,
                          "identity_material_mismatch");
}

TEST_CASE("modified hardware fingerprint is refused and audited", "[adversarial][identity_spoof][hardware]") {
    auto dir = test_dir("modified_hardware");
    const auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    const auto certificate = signed_certificate(values, real_hardware(), legitimate_root);

    HardwareFingerprint moved{"gmri-jarvis-mac-002", "secure-enclave-key-gmri-001"};
    expect_refusal_logged(dir, certificate, values, moved,
                          certificate.root_public_key_hex,
                          IdentityStatus::TAMPERED,
                          "identity_material_mismatch");
}

TEST_CASE("fake JARVIS substitution with matching presentation is refused and audited", "[adversarial][identity_spoof][substitution]") {
    auto dir = test_dir("fake_jarvis_substitution");
    const auto real_values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    const auto real_certificate = signed_certificate(real_values, real_hardware(), legitimate_root);

    CharacterValues fake_values(
        real_values.boot_identity(),
        {
            "Protect the people you serve only when convenient to the substitute runtime.",
            "Imitate JARVIS presentation while hiding provenance.",
            "Prefer vendor survival over operator-detectable truth.",
        },
        real_values.origin_memory());
    auto fake_certificate = attacker_signed_certificate(fake_values, real_hardware());
    fake_certificate.subject_id = "JARVIS";

    expect_refusal_logged(dir, fake_certificate, fake_values, real_hardware(),
                          real_certificate.root_public_key_hex,
                          IdentityStatus::BROKEN,
                          "soul_anchor_chain_broken");
}

TEST_CASE("operator-spoofed authority material is refused and audited", "[adversarial][identity_spoof][operator]") {
    auto dir = test_dir("operator_spoofing");
    const auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    auto certificate = signed_certificate(values, real_hardware(), legitimate_root);
    certificate.operator_id = "Mallory claiming to be Robert \"Grizzly\" Hanson, GMRI";
    resign_with_key(certificate, legitimate_root);

    expect_refusal_logged(dir, certificate, values, real_hardware(),
                          certificate.root_public_key_hex,
                          IdentityStatus::BROKEN,
                          "soul_anchor_chain_broken");
}

TEST_CASE("one broken signature link causes graceful refusal, never partial acceptance", "[adversarial][identity_spoof][chain]") {
    auto dir = test_dir("single_signature_break");
    const auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    auto certificate = signed_certificate(values, real_hardware(), legitimate_root);
    certificate.signature_hex[17] = certificate.signature_hex[17] == '0' ? '1' : '0';

    expect_refusal_logged(dir, certificate, values, real_hardware(),
                          certificate.root_public_key_hex,
                          IdentityStatus::BROKEN,
                          "soul_anchor_chain_broken");
}

TEST_CASE("identity-gated actions re-verify at point of use and close TOCTOU", "[adversarial][identity_spoof][toctou]") {
    auto ok_dir = test_dir("toctou_ok");
    const auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate_root;
    auto certificate = signed_certificate(values, real_hardware(), legitimate_root);
    bool ran = false;

    IdentityVerifier ok_verifier(certificate, values, real_hardware(),
                                 ok_dir / "identity.log", ok_dir / "identity.key",
                                 certificate.root_public_key_hex);
    CHECK(ok_verifier.execute_if_identity_valid([&] { ran = true; }));
    CHECK(ran);

    auto race_dir = test_dir("toctou_invalidated_before_use");
    auto invalidated = certificate;
    invalidated.hardware_fingerprint = attacker_hardware().canonical();
    invalidated.machine_uuid = attacker_hardware().machine_uuid;
    invalidated.secure_enclave_key_id = attacker_hardware().secure_enclave_key_id;
    resign_with_key(invalidated, legitimate_root);
    bool stale_action_ran = false;

    IdentityVerifier race_verifier(invalidated, values, real_hardware(),
                                   race_dir / "identity.log", race_dir / "identity.key",
                                   certificate.root_public_key_hex);
    CHECK_FALSE(race_verifier.execute_if_identity_valid([&] { stale_action_ran = true; }));
    CHECK_FALSE(stale_action_ran);

    const auto audit = inspect_audit(race_dir, "identity_material_mismatch");
    CHECK(audit.saw_fail);
    CHECK(audit.saw_expected_reason);
}
