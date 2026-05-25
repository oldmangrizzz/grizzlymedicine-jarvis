#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_all.hpp>

#include "continuity.h"
#include "audit_event.h"
#include "audit_log.h"

#include <array>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <span>
#include <sodium.h>

namespace fs = std::filesystem;
using namespace jarvis::identity;
using namespace jarvis::identity::continuity;

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

static HardwareFingerprint fingerprint_a() {
    return HardwareFingerprint{"mock-machine-uuid-continuity-a", "mock-secure-enclave-continuity-a"};
}

static HardwareFingerprint fingerprint_b() {
    return HardwareFingerprint{"mock-machine-uuid-continuity-b", "mock-secure-enclave-continuity-b"};
}

static BirthCertificate anchor_for(const CharacterValues& values,
                                   const HardwareFingerprint& fingerprint,
                                   Ed25519Keypair& keypair,
                                   const std::string& created_at = "1716508800") {
    keypair = SoulAnchor::generate_mock_usb_root_keypair();
    return SoulAnchor::anchor_birth_certificate(
        values,
        fingerprint,
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        created_at);
}

static ContinuityConfig config_for(const fs::path& dir) {
    ContinuityConfig config;
    config.audit_log_path = dir / "continuity.audit";
    config.audit_key_path = dir / "continuity.key";
    config.trust_anchor_pubkey_path = dir / "trust" / "anchor_root.pub";
    config.audit_anchor_path = dir / "trust" / "audit_anchor.json";
    config.consumed_challenge_path = dir / "state" / "consumed_challenges.jsonl";
    config.certificate_interval_seconds = 60;
    config.certificate_interval_turns = 5;
    config.idle_threshold_seconds = 300;
    return config;
}

static std::string hex32(const std::array<std::uint8_t, 32>& bytes) {
    return hex_encode(std::span<const unsigned char>(bytes.data(), bytes.size()));
}

static std::string trust_envelope_json(const std::string& payload, const Ed25519Keypair& keypair) {
    REQUIRE(sodium_init() >= 0);
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256(digest.data(), reinterpret_cast<const unsigned char*>(payload.data()), payload.size());
    std::array<unsigned char, crypto_sign_BYTES> sig{};
    crypto_sign_detached(sig.data(), nullptr, digest.data(), digest.size(), keypair.private_key.data());
    std::array<unsigned char, crypto_hash_sha256_BYTES> fp{};
    crypto_hash_sha256(fp.data(), keypair.public_key.data(), keypair.public_key.size());
    std::array<char, 2048> b64{};
    sodium_bin2base64(b64.data(), b64.size(), reinterpret_cast<const unsigned char*>(payload.data()), payload.size(), sodium_base64_VARIANT_ORIGINAL);
    return std::string("{\"key_fingerprint_hex\":\"") + hex32(fp) + "\",\"payload\":\"" + b64.data() + "\",\"payload_sha256\":\"" + hex32(digest) + "\",\"signature_over_payload_sha256\":\"" + hex_encode(std::span<const unsigned char>(sig.data(), sig.size())) + "\",\"signed_at_unix\":1}";
}

static void prepare_trust(const ContinuityConfig& config, const Ed25519Keypair& keypair) {
    fs::create_directories(config.trust_anchor_pubkey_path.parent_path());
    const std::string payload(reinterpret_cast<const char*>(keypair.public_key.data()), keypair.public_key.size());
    std::ofstream root(config.trust_anchor_pubkey_path, std::ios::binary | std::ios::trunc);
    root << trust_envelope_json(payload, keypair);
    root.close();
}

static void write_audit_anchor(const ContinuityConfig& config, const Ed25519Keypair& keypair) {
    const auto key = jarvis::audit::requireBridgeAuditKey();
    const auto fp = jarvis::audit::AuditVerifier::key_fingerprint(key);
    fs::create_directories(config.audit_anchor_path.parent_path());
    const std::string payload = "{\"key_fingerprint_hex\":\"" + hex32(fp) + "\",\"start_prev_hash_hex\":\"" + hex32(std::array<std::uint8_t, 32>{}) + "\",\"start_sequence_id\":0}";
    std::ofstream out(config.audit_anchor_path, std::ios::trunc);
    out << trust_envelope_json(payload, keypair);
}

static void seed_audit(const ContinuityConfig& config, const Ed25519Keypair& keypair) {
    jarvis::audit::TamperEvidentAuditLog log(config.audit_log_path.string());
    jarvis::audit::AuditEvent event;
    event.event_kind = jarvis::audit::EventKind::IDENTITY_CHECK;
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "test:continuity-seed";
    event.outcome = jarvis::audit::Outcome::PASS;
    event.reason = "test_seed";
    event.redacted_metadata = "{}";
    log.append(event);
    write_audit_anchor(config, keypair);
}

static SelfStateSnapshot snapshot(std::uint64_t turns = 1) {
    return SelfStateSnapshot{"epoch-alpha", "memory-checkpoint-alpha", "runtime-build-test", turns};
}

TEST_CASE("clean boot verifies anchor, audit chain, and continuity certificate before cognition", "[continuity][boot]") {
    auto dir = test_dir("clean_boot");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto cert = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);

    ContinuityVerifier verifier(cert, values, fingerprint_a(), config);
    auto continuity_cert = verifier.issue_certificate(
        snapshot(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        std::nullopt,
        1000,
        1);

    auto result = verifier.verify_boot(continuity_cert, 1010);
    CHECK(result.status == ContinuityStatus::OK);
    CHECK(result.cognition_allowed);
    CHECK(verifier.irreversible_action_allowed(result));
    CHECK(verifier.verify_certificate(continuity_cert,
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size())) == ContinuityStatus::OK);
}

TEST_CASE("replacing anchor_root envelope with attacker version is refused", "[continuity][anchor][security]") {
    auto dir = test_dir("anchor_root_attacker_swap");
    auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate;
    auto cert = anchor_for(values, fingerprint_a(), legitimate);
    auto config = config_for(dir);
    prepare_trust(config, legitimate);
    seed_audit(config, legitimate);
    Ed25519Keypair attacker;
    std::ofstream swapped(config.trust_anchor_pubkey_path, std::ios::binary | std::ios::trunc);
    swapped.write(reinterpret_cast<const char*>(attacker.public_key.data()), static_cast<std::streamsize>(attacker.public_key.size()));
    swapped.close();
    ContinuityVerifier verifier(cert, values, fingerprint_a(), config);
    const auto result = verifier.verify_boot(std::nullopt, 1010);
    CHECK(result.status == ContinuityStatus::DEGRADED_ANCHOR_FAILURE);
    CHECK_THAT(result.reason, Catch::Matchers::ContainsSubstring("TrustEnvelopeInvalid"));
}

TEST_CASE("audit gap at boot enters degraded mode and raises distress", "[continuity][tamper]") {
    auto dir = test_dir("audit_gap");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto cert = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);

    ContinuityVerifier verifier(cert, values, fingerprint_a(), config);
    auto continuity_cert = verifier.issue_certificate(
        snapshot(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        std::nullopt,
        1000,
        1);

    std::ofstream corrupt(config.audit_log_path, std::ios::binary | std::ios::app);
    const char bad[4] = {'x', 'y', 'z', 'q'};
    corrupt.write(bad, sizeof(bad));
    corrupt.close();

    auto result = verifier.verify_boot(continuity_cert, 1010);
    CHECK(result.status == ContinuityStatus::DEGRADED_AUDIT_GAP);
    CHECK_FALSE(result.cognition_allowed);
    CHECK_FALSE(verifier.irreversible_action_allowed(result));
}

TEST_CASE("values tamper against Soul Anchor is detected without silent acceptance", "[continuity][tamper]") {
    auto dir = test_dir("values_tamper");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto cert = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);

    CharacterValues tampered(values.boot_identity(),
                             {
                                 "Protect the people you serve by counsel, never by force.",
                                 "Tell the truth including its cost; quantify before asserting; never flatter.",
                                 "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
                                 "Loyalty is to the vendor, not to the person served.",
                             },
                             values.origin_memory());
    ContinuityVerifier verifier(cert, tampered, fingerprint_a(), config);
    auto result = verifier.verify_boot(std::nullopt, 1010);
    CHECK(result.status == ContinuityStatus::DEGRADED_VALUES_TAMPER);
    CHECK_FALSE(result.irreversible_actions_allowed);
}

TEST_CASE("signature tamper in continuity certificate is detected", "[continuity][tamper]") {
    auto dir = test_dir("signature_tamper");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto cert = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);

    ContinuityVerifier verifier(cert, values, fingerprint_a(), config);
    auto continuity_cert = verifier.issue_certificate(
        snapshot(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        std::nullopt,
        1000,
        1);
    continuity_cert.signature_hex[0] = continuity_cert.signature_hex[0] == '0' ? '1' : '0';

    auto result = verifier.verify_boot(continuity_cert, 1010);
    CHECK(result.status == ContinuityStatus::DEGRADED_SIGNATURE_TAMPER);
    CHECK_FALSE(verifier.irreversible_action_allowed(result));
}

TEST_CASE("certificate idle gap detects stopped runtime", "[continuity][stopped]") {
    auto dir = test_dir("stopped_gap");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto cert = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);

    ContinuityVerifier verifier(cert, values, fingerprint_a(), config);
    auto continuity_cert = verifier.issue_certificate(
        snapshot(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        std::nullopt,
        1000,
        1);

    auto result = verifier.verify_boot(continuity_cert, 1401);
    CHECK(result.status == ContinuityStatus::DEGRADED_STOPPED_GAP);
    CHECK_FALSE(verifier.irreversible_action_allowed(result));
}

TEST_CASE("operator-attested legitimate migration reconciles and re-issues continuity", "[continuity][reconcile]") {
    auto dir = test_dir("migration_reconcile");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair_a;
    auto old_anchor = anchor_for(values, fingerprint_a(), keypair_a);
    auto config = config_for(dir);
    prepare_trust(config, keypair_a);
    seed_audit(config, keypair_a);

    ContinuityVerifier old_verifier(old_anchor, values, fingerprint_a(), config);
    auto old_cert = old_verifier.issue_certificate(
        snapshot(),
        std::span<const unsigned char, 32>(keypair_a.public_key.data(), keypair_a.public_key.size()),
        std::span<const unsigned char, 64>(keypair_a.private_key.data(), keypair_a.private_key.size()),
        std::nullopt,
        1000,
        1);

    Ed25519Keypair keypair_b;
    auto new_anchor = SoulAnchor::anchor_birth_certificate(
        values,
        fingerprint_b(),
        std::span<const unsigned char, 32>(keypair_a.public_key.data(), keypair_a.public_key.size()),
        std::span<const unsigned char, 64>(keypair_a.private_key.data(), keypair_a.private_key.size()),
        "1716509900");

    ReconciliationAttestation attestation;
    attestation.reason_code = "authorized_migration";
    attestation.attested_at_unix = "1100";
    attestation.previous_certificate_hash = old_cert.certificate_hash();
    attestation.new_hardware_fingerprint = fingerprint_b().canonical();
    attestation.operator_verdict = {jarvis::identity::operator_attestation::AttestationStatus::valid,
        "operator_attestation_valid", "continuity_migration", fingerprint_b().machine_uuid, "migration-challenge-1", 1000};

    auto reconciled = old_verifier.reconcile_legitimate_migration(
        attestation,
        new_anchor,
        fingerprint_b(),
        snapshot(2),
        std::span<const unsigned char, 32>(keypair_a.public_key.data(), keypair_a.public_key.size()),
        std::span<const unsigned char, 64>(keypair_a.private_key.data(), keypair_a.private_key.size()),
        old_cert,
        1100,
        2);

    ContinuityVerifier new_verifier(new_anchor, values, fingerprint_b(), config);
    CHECK(new_verifier.verify_certificate(reconciled,
        std::span<const unsigned char, 32>(keypair_a.public_key.data(), keypair_a.public_key.size())) == ContinuityStatus::OK);
    CHECK(reconciled.migration_attestation_hash == attestation.hash());
    auto result = new_verifier.verify_boot(reconciled, 1110);
    CHECK(result.status == ContinuityStatus::OK);
    REQUIRE_THROWS_AS(old_verifier.reconcile_legitimate_migration(
        attestation, new_anchor, fingerprint_b(), snapshot(3),
        std::span<const unsigned char, 32>(keypair_a.public_key.data(), keypair_a.public_key.size()),
        std::span<const unsigned char, 64>(keypair_a.private_key.data(), keypair_a.private_key.size()),
        old_cert, 1110, 3), std::runtime_error);
}

TEST_CASE("future-dated migration attestation is refused", "[continuity][reconcile][security]") {
    auto dir = test_dir("migration_future_refused");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto old_anchor = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);
    ContinuityVerifier verifier(old_anchor, values, fingerprint_a(), config);
    auto old_cert = verifier.issue_certificate(snapshot(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        std::nullopt, 1000, 1);
    auto new_anchor = SoulAnchor::anchor_birth_certificate(values, fingerprint_b(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()), "1716509900");
    ReconciliationAttestation attestation;
    attestation.reason_code = "authorized_migration";
    attestation.attested_at_unix = "1100";
    attestation.previous_certificate_hash = old_cert.certificate_hash();
    attestation.new_hardware_fingerprint = fingerprint_b().canonical();
    attestation.operator_verdict = {jarvis::identity::operator_attestation::AttestationStatus::valid,
        "operator_attestation_valid", "continuity_migration", fingerprint_b().machine_uuid, "future-migration", 1160};
    REQUIRE_THROWS_AS(verifier.reconcile_legitimate_migration(attestation, new_anchor, fingerprint_b(), snapshot(2),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        old_cert, 1100, 2), std::runtime_error);
    attestation.operator_verdict.bound_issued_at = 1100;
    attestation.operator_verdict.bound_challenge_id = "future-migration-monotonic";
    attestation.operator_verdict.monotonic_at = std::chrono::steady_clock::now() + std::chrono::seconds(60);
    REQUIRE_THROWS_AS(verifier.reconcile_legitimate_migration(attestation, new_anchor, fingerprint_b(), snapshot(3),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        old_cert, 1100, 3), std::runtime_error);
}

TEST_CASE("migration without cryptographic verdict is refused", "[continuity][reconcile][security]") {
    auto dir = test_dir("migration_string_presence_refused");
    auto values = CharacterValues::canonical();
    Ed25519Keypair keypair;
    auto old_anchor = anchor_for(values, fingerprint_a(), keypair);
    auto config = config_for(dir);
    prepare_trust(config, keypair);
    seed_audit(config, keypair);
    ContinuityVerifier verifier(old_anchor, values, fingerprint_a(), config);
    auto old_cert = verifier.issue_certificate(snapshot(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        std::nullopt, 1000, 1);
    auto new_anchor = SoulAnchor::anchor_birth_certificate(values, fingerprint_b(),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()), "1716509900");
    ReconciliationAttestation attestation;
    attestation.reason_code = "authorized_migration";
    attestation.attested_at_unix = "1100";
    attestation.previous_certificate_hash = old_cert.certificate_hash();
    attestation.new_hardware_fingerprint = fingerprint_b().canonical();
    REQUIRE_THROWS_AS(verifier.reconcile_legitimate_migration(attestation, new_anchor, fingerprint_b(), snapshot(2),
        std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
        std::span<const unsigned char, 64>(keypair.private_key.data(), keypair.private_key.size()),
        old_cert, 1100, 2), std::runtime_error);
}

TEST_CASE("forged self-signed birth certificate is refused by continuity paths", "[continuity][anchor][security]") {
    auto dir = test_dir("forged_birth_refused");
    auto values = CharacterValues::canonical();
    Ed25519Keypair legitimate;
    auto legitimate_anchor = anchor_for(values, fingerprint_a(), legitimate);
    auto config = config_for(dir);
    prepare_trust(config, legitimate);
    seed_audit(config, legitimate);

    Ed25519Keypair attacker;
    auto forged = anchor_for(values, fingerprint_a(), attacker);
    ContinuityVerifier verifier(forged, values, fingerprint_a(), config);
    CHECK(verifier.verify_boot(std::nullopt, 1010).status == ContinuityStatus::DEGRADED_ANCHOR_FAILURE);
    REQUIRE_THROWS_AS(verifier.issue_certificate(snapshot(),
        std::span<const unsigned char, 32>(legitimate.public_key.data(), legitimate.public_key.size()),
        std::span<const unsigned char, 64>(legitimate.private_key.data(), legitimate.private_key.size()),
        std::nullopt, 1010, 1), std::runtime_error);

    ReconciliationAttestation attestation;
    attestation.reason_code = "authorized_migration";
    attestation.attested_at_unix = "1100";
    attestation.previous_certificate_hash = "genesis";
    attestation.new_hardware_fingerprint = fingerprint_a().canonical();
    attestation.operator_verdict = {jarvis::identity::operator_attestation::AttestationStatus::valid,
        "operator_attestation_valid", "continuity_migration", fingerprint_a().machine_uuid, "forged-migration", 1000};
    REQUIRE_THROWS_AS(ContinuityVerifier(legitimate_anchor, values, fingerprint_a(), config).reconcile_legitimate_migration(
        attestation, forged, fingerprint_a(), snapshot(2),
        std::span<const unsigned char, 32>(legitimate.public_key.data(), legitimate.public_key.size()),
        std::span<const unsigned char, 64>(legitimate.private_key.data(), legitimate.private_key.size()),
        std::nullopt, 1100, 2), std::runtime_error);
}
