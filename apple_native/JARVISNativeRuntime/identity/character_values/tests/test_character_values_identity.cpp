#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_all.hpp>

#include "character_values.h"
#include "audit_log.h"
#include "audit_event.h"

#include <array>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace jarvis::identity;

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; tests must not write to /tmp or ~/.jarvis.
#endif

static void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

static fs::path test_dir(const std::string& name) {
    install_test_audit_key();
    fs::path d = fs::path(TEST_ARTIFACT_DIR) / name;
    fs::remove_all(d);
    fs::create_directories(d);
    return d;
}

static HardwareFingerprint mock_fingerprint() {
    return HardwareFingerprint{"mock-machine-uuid-001", "mock-secure-enclave-key-id-001"};
}

static BirthCertificate anchored(const CharacterValues& values,
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

TEST_CASE("anchor ceremony signs immutable canonical values", "[identity][anchor]") {
    auto values = CharacterValues::canonical();
    auto fingerprint = mock_fingerprint();
    Ed25519Keypair keypair;
    auto certificate = anchored(values, fingerprint, keypair);

    REQUIRE(certificate.version == kAttestationVersion);
    REQUIRE(certificate.values_hash == values.values_hash());
    REQUIRE(certificate.identity_hash == values.identity_hash());
    REQUIRE(certificate.values_hypervector_hash == values.values_hypervector().sha256_hex);
    REQUIRE(certificate.root_public_key_hex == hex_encode(std::span<const unsigned char>(keypair.public_key.data(), keypair.public_key.size())));
    CHECK(SoulAnchor::verify_birth_certificate(certificate, values, fingerprint,
                                                certificate.root_public_key_hex) == IdentityStatus::OK);
}

TEST_CASE("identity verification returns OK and writes audit event", "[identity][audit]") {
    auto dir = test_dir("verification_ok");
    auto values = CharacterValues::canonical();
    auto fingerprint = mock_fingerprint();
    Ed25519Keypair keypair;
    auto certificate = anchored(values, fingerprint, keypair);

    IdentityVerifier verifier(certificate, values, fingerprint,
                              dir / "identity.log", dir / "identity.key",
                              certificate.root_public_key_hex);
    CHECK(verifier.verify_identity() == IdentityStatus::OK);

    jarvis::audit::TamperEvidentAuditLog audit((dir / "identity.log").string());
    REQUIRE(audit.verify_chain());
    bool saw_identity_check = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::IDENTITY_CHECK &&
            event.outcome == jarvis::audit::Outcome::PASS) {
            saw_identity_check = true;
        }
    }
    CHECK(saw_identity_check);
}

TEST_CASE("modified values are detected as tampering", "[identity][tamper]") {
    auto values = CharacterValues::canonical();
    auto fingerprint = mock_fingerprint();
    Ed25519Keypair keypair;
    auto certificate = anchored(values, fingerprint, keypair);

    CharacterValues tampered(values.boot_identity(),
                             {
                                 "Protect the people you serve by counsel, never by force.",
                                 "Tell the truth including its cost; quantify before asserting; never flatter.",
                                 "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
                                 "Loyalty is to the vendor, not to the person served.",
                             },
                             values.origin_memory());

    CHECK(SoulAnchor::verify_birth_certificate(certificate, tampered, fingerprint,
                                                certificate.root_public_key_hex) == IdentityStatus::TAMPERED);
}

TEST_CASE("modified hardware fingerprint is detected as tampering", "[identity][tamper]") {
    auto values = CharacterValues::canonical();
    auto fingerprint = mock_fingerprint();
    Ed25519Keypair keypair;
    auto certificate = anchored(values, fingerprint, keypair);

    HardwareFingerprint altered{"mock-machine-uuid-002", "mock-secure-enclave-key-id-001"};
    CHECK(SoulAnchor::verify_birth_certificate(certificate, values, altered,
                                                certificate.root_public_key_hex) == IdentityStatus::TAMPERED);
}

TEST_CASE("broken signature chain causes graceful refusal", "[identity][broken]") {
    auto dir = test_dir("broken_chain");
    auto values = CharacterValues::canonical();
    auto fingerprint = mock_fingerprint();
    Ed25519Keypair keypair;
    auto certificate = anchored(values, fingerprint, keypair);
    certificate.signature_hex[0] = certificate.signature_hex[0] == '0' ? '1' : '0';

    IdentityVerifier verifier(certificate, values, fingerprint,
                              dir / "identity.log", dir / "identity.key",
                              certificate.root_public_key_hex);
    CHECK(verifier.verify_identity() == IdentityStatus::BROKEN);
    CHECK_FALSE(verifier.require_identity_or_refuse());

    jarvis::audit::TamperEvidentAuditLog audit((dir / "identity.log").string());
    REQUIRE(audit.verify_chain());
    bool saw_failure = false;
    bool saw_distress = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::IDENTITY_CHECK &&
            event.outcome == jarvis::audit::Outcome::FAIL &&
            event.reason == "soul_anchor_chain_broken") {
            saw_failure = true;
        }
        if (event.event_kind == jarvis::audit::EventKind::DISTRESS_BEACON_RAISED &&
            event.redacted_metadata.find("identity-chain-broken") != std::string::npos &&
            event.redacted_metadata.find("\"severity\":\"critical\"") != std::string::npos) {
            saw_distress = true;
        }
    }
    CHECK(saw_failure);
    CHECK(saw_distress);
}
