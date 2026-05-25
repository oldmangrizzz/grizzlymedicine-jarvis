#include "operator_attestation.h"
#include "audit_event.h"
#include "audit_log.h"

#include <catch2/catch_test_macros.hpp>

#include <array>
#include <filesystem>
#include <string>

using namespace jarvis::identity::operator_attestation;
namespace fs = std::filesystem;

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; tests must not write to /tmp or ~/.jarvis.
#endif

namespace {

fs::path test_dir(const std::string& name) {
    fs::path d = fs::path(TEST_ARTIFACT_DIR) / name;
    fs::remove_all(d);
    fs::create_directories(d);
    return d;
}

struct Fixture {
    fs::path dir;
    OperatorAttestationKeypair keypair;
    EnrolledOperatorKey enrolled;
    AttestationPolicy policy;

    explicit Fixture(std::string name) : dir(test_dir(name)) {
        std::array<std::uint8_t, 32> audit_key{};
        audit_key.fill(0xA7);
        jarvis::audit::installBridgeAuditKey(audit_key.data(), audit_key.size());
        keypair = OperatorKeyEnrollmentCeremony::generate_test_operator_keypair();
        enrolled = OperatorKeyEnrollmentCeremony::enroll_operator_public_key(
            std::span<const unsigned char, 32>(keypair.public_key.data(), keypair.public_key.size()),
            kOperatorId,
            "1716508800");
        policy.challenge_ttl = std::chrono::seconds(60);
        policy.rate_limit_window = std::chrono::seconds(60);
        policy.max_challenges_per_window = 5;
    }

    AttestationService service() const {
        return AttestationService(enrolled, dir / "attestation.log", dir / "attestation.key", policy);
    }
};

SensitiveOperation values_operation() {
    return {OperationType::modify_character_values,
            "Modify CharacterValues canonical value set after birth anchor",
            "sha256:character-values-test"};
}

bool audit_contains(const fs::path& dir, const std::string& reason, const std::string& outcome = {}) {
    jarvis::audit::TamperEvidentAuditLog audit((dir / "attestation.log").string());
    REQUIRE(audit.verify_chain());
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::AUTHORITY_GATE &&
            event.reason == reason && (outcome.empty() || event.outcome == outcome)) {
            return true;
        }
    }
    return false;
}

} // namespace

TEST_CASE("valid operator attestation verifies and audits allowed outcome") {
    Fixture f("valid");
    auto service = f.service();
    service.set_clock_for_test([] { return 1000; });
    const auto op = values_operation();

    auto issued = service.issue_challenge(op);
    REQUIRE(issued.issued);
    auto response = sign_challenge_for_test(issued.challenge,
        std::span<const unsigned char, 64>(f.keypair.private_key.data(), f.keypair.private_key.size()));

    auto verdict = service.verify_response(response, op);
    REQUIRE(verdict.allowed());
    REQUIRE(verdict.status == AttestationStatus::valid);
    REQUIRE_FALSE(service.challenge(issued.challenge.challenge_id).has_value());
    REQUIRE(audit_contains(f.dir, "operator_attestation_valid", jarvis::audit::Outcome::ALLOWED));
}

TEST_CASE("invalid signature is denied and audited") {
    Fixture f("invalid_signature");
    auto service = f.service();
    service.set_clock_for_test([] { return 1000; });
    const auto op = values_operation();
    auto issued = service.issue_challenge(op);
    REQUIRE(issued.issued);

    auto response = sign_challenge_for_test(issued.challenge,
        std::span<const unsigned char, 64>(f.keypair.private_key.data(), f.keypair.private_key.size()));
    response.signature_hex[0] = response.signature_hex[0] == '0' ? '1' : '0';

    auto verdict = service.verify_response(response, op);
    REQUIRE_FALSE(verdict.allowed());
    REQUIRE(verdict.status == AttestationStatus::invalid_signature);
    REQUIRE(audit_contains(f.dir, "invalid_signature", jarvis::audit::Outcome::DENIED));
}

TEST_CASE("expired challenge is denied") {
    Fixture f("expired");
    auto service = f.service();
    std::int64_t now = 1000;
    service.set_clock_for_test([&] { return now; });
    const auto op = values_operation();
    auto issued = service.issue_challenge(op);
    REQUIRE(issued.issued);
    auto response = sign_challenge_for_test(issued.challenge,
        std::span<const unsigned char, 64>(f.keypair.private_key.data(), f.keypair.private_key.size()));

    now = 1061;
    auto verdict = service.verify_response(response, op);
    REQUIRE_FALSE(verdict.allowed());
    REQUIRE(verdict.status == AttestationStatus::expired_challenge);
    REQUIRE(audit_contains(f.dir, "expired_challenge", jarvis::audit::Outcome::DENIED));
}

TEST_CASE("wrong operation material is denied") {
    Fixture f("wrong_operation");
    auto service = f.service();
    service.set_clock_for_test([] { return 1000; });
    const auto op = values_operation();
    auto issued = service.issue_challenge(op);
    REQUIRE(issued.issued);
    auto response = sign_challenge_for_test(issued.challenge,
        std::span<const unsigned char, 64>(f.keypair.private_key.data(), f.keypair.private_key.size()));

    SensitiveOperation wrong{OperationType::irreversible_external_action,
                             "Send irreversible third-party API mutation",
                             "sha256:external-action"};
    auto verdict = service.verify_response(response, wrong);
    REQUIRE_FALSE(verdict.allowed());
    REQUIRE(verdict.status == AttestationStatus::wrong_operation);
    REQUIRE(audit_contains(f.dir, "wrong_operation", jarvis::audit::Outcome::DENIED));
}

TEST_CASE("challenge issuance is rate limited") {
    Fixture f("rate_limit");
    f.policy.max_challenges_per_window = 2;
    auto service = f.service();
    service.set_clock_for_test([] { return 1000; });
    const auto op = values_operation();

    REQUIRE(service.issue_challenge(op).issued);
    REQUIRE(service.issue_challenge(op).issued);
    auto denied = service.issue_challenge(op);
    REQUIRE_FALSE(denied.issued);
    REQUIRE(denied.reason == "attestation_rate_limited");
    REQUIRE(audit_contains(f.dir, "attestation_rate_limited", jarvis::audit::Outcome::DENIED));
}

TEST_CASE("gate exposes every minimum sensitive operation hook") {
    Fixture f("hooks");
    f.policy.max_challenges_per_window = 10;
    auto service = f.service();
    service.set_clock_for_test([] { return 1000; });
    AttestationGate gate(service);

    REQUIRE(gate.require_reanchor_confirmation("Re-anchor JARVIS post-birth identity", "sha256:reanchor").issued);
    REQUIRE(gate.require_defense_layer_disable("Temporarily allow a cloud endpoint", "sha256:defense").issued);
    REQUIRE(gate.require_character_values_modification("Modify CharacterValues", "sha256:values").issued);
    REQUIRE(gate.require_voice_weight_change("Authorize voice weight change", "sha256:voice").issued);
    REQUIRE(gate.require_hardware_migration("Authorize migration to new hardware", "sha256:hardware").issued);
    REQUIRE(gate.require_emergency_mode_bypass("Authorize emergency-mode operation bypassing refusal", "sha256:emergency").issued);
    REQUIRE(gate.require_irreversible_external_action("Authorize irreversible third-party API side effect", "sha256:external").issued);
}
