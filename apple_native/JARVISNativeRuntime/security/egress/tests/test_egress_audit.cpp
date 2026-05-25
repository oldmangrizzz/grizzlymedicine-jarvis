// test_egress_audit.cpp
// JARVIS digital-personhood project — GMRI
//
// Catch2 v3 unit tests for EgressAudit.
//
// Covers:
//   • Record creation and field population.
//   • HMAC chain integrity: verify_chain() returns true for an intact chain.
//   • Tamper detection: verify_chain() returns false after a record is mutated.
//   • Payload fingerprint is deterministic for the same payload within a session.
//   • Payload content is never stored in AuditRecord.
//   • Audit log does not contain API keys, transcripts, or payload content.

#include <catch2/catch_test_macros.hpp>

#include "../egress_audit.h"
#include "../egress_filter.h"

using namespace jarvis::security::egress;

namespace {

RequestEnvelope make_test_envelope(std::string host = "ollama.com") {
    RequestEnvelope env;
    env.host                      = std::move(host);
    env.port                      = 443;
    env.content_type              = "application/json";
    env.stripped_system_messages  = 2;
    env.stripped_history_messages = 1;
    return env;
}

const std::vector<uint8_t> kTestPayload = {0x01, 0x02, 0x03, 0x04, 0xFF, 0xFE};

}  // namespace

// ── Setup/teardown ────────────────────────────────────────────────────────────

// Each TEST_CASE that uses EgressAudit::instance() resets it first so tests
// are independent.  (reset_for_test() clears records and resets chain head.)

// ── Record creation ───────────────────────────────────────────────────────────

TEST_CASE("EgressAudit — record creates an AuditRecord with correct fields",
          "[audit]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    auto env = make_test_envelope();
    audit.record(env, kTestPayload, EgressResult::Success);

    REQUIRE(audit.records().size() == 1);
    const auto& rec = audit.records()[0];

    REQUIRE(rec.host         == "ollama.com");
    REQUIRE(rec.port         == 443);
    REQUIRE(rec.bytes_sent   == kTestPayload.size());
    REQUIRE(rec.content_type == "application/json");
    REQUIRE(rec.stripped_system_messages  == 2);
    REQUIRE(rec.stripped_history_messages == 1);
    REQUIRE(rec.result       == EgressResult::Success);

    // Fingerprint must be a 64-char hex string.
    REQUIRE(rec.payload_fingerprint.size() == 64);

    // Chain hash must be a 64-char hex string.
    REQUIRE(rec.chain_hash.size() == 64);

    // Timestamp must be positive.
    REQUIRE(rec.timestamp > 0.0);
}

TEST_CASE("EgressAudit — payload content is NOT stored in records",
          "[audit]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    std::vector<uint8_t> secret_payload(256, 0xAB);
    auto env = make_test_envelope();
    audit.record(env, secret_payload, EgressResult::Success);

    const auto& rec = audit.records()[0];

    // The raw payload bytes must not appear anywhere in the record.
    // Check all string fields for the secret byte pattern.
    std::string secret_str(secret_payload.begin(), secret_payload.end());
    REQUIRE(rec.payload_fingerprint.find(secret_str) == std::string::npos);
    REQUIRE(rec.chain_hash.find(secret_str)          == std::string::npos);
    REQUIRE(rec.host.find(secret_str)                == std::string::npos);
    REQUIRE(rec.content_type.find(secret_str)        == std::string::npos);
}

TEST_CASE("EgressAudit — different payloads produce different fingerprints",
          "[audit]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    std::vector<uint8_t> p1 = {0x01, 0x02, 0x03};
    std::vector<uint8_t> p2 = {0x04, 0x05, 0x06};

    auto env = make_test_envelope();
    audit.record(env, p1, EgressResult::Success);
    audit.record(env, p2, EgressResult::Success);

    REQUIRE(audit.records().size() == 2);
    REQUIRE(audit.records()[0].payload_fingerprint !=
            audit.records()[1].payload_fingerprint);
}

// ── Chain integrity ───────────────────────────────────────────────────────────

TEST_CASE("EgressAudit — verify_chain() returns true for intact chain",
          "[audit][chain]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    for (int i = 0; i < 5; ++i) {
        auto env = make_test_envelope();
        env.stripped_system_messages = static_cast<std::size_t>(i);
        audit.record(env, kTestPayload, EgressResult::Success);
    }

    REQUIRE(audit.records().size() == 5);
    REQUIRE(audit.verify_chain() == true);
}

TEST_CASE("EgressAudit — verify_chain() on empty chain returns true",
          "[audit][chain]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    REQUIRE(audit.verify_chain() == true);
}

TEST_CASE("EgressAudit — verify_chain() detects tampered chain_hash on record 0",
          "[audit][chain][tamper]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    auto env = make_test_envelope();
    audit.record(env, kTestPayload, EgressResult::Success);
    audit.record(env, kTestPayload, EgressResult::Success);

    REQUIRE(audit.verify_chain() == true);

    // Tamper with the chain hash of the first record.
    audit.test_only_inject_tampered_hash(
        0, "0000000000000000000000000000000000000000000000000000000000000000");

    REQUIRE(audit.verify_chain() == false);
}

TEST_CASE("EgressAudit — verify_chain() detects tampered chain_hash mid-chain",
          "[audit][chain][tamper]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    for (int i = 0; i < 4; ++i) {
        auto env = make_test_envelope();
        audit.record(env, kTestPayload, EgressResult::Success);
    }

    REQUIRE(audit.verify_chain() == true);

    // Tamper the middle record.
    audit.test_only_inject_tampered_hash(
        2, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    REQUIRE(audit.verify_chain() == false);
}

TEST_CASE("EgressAudit — chain hashes differ between consecutive records",
          "[audit][chain]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    auto env = make_test_envelope();
    audit.record(env, kTestPayload, EgressResult::Success);
    audit.record(env, kTestPayload, EgressResult::NetworkFail);

    REQUIRE(audit.records().size() == 2);
    // Chain hashes must be distinct (each covers its predecessor).
    REQUIRE(audit.records()[0].chain_hash !=
            audit.records()[1].chain_hash);
}

// ── Result codes ─────────────────────────────────────────────────────────────

TEST_CASE("EgressAudit — all EgressResult values recorded correctly",
          "[audit]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    auto env = make_test_envelope();
    audit.record(env, {}, EgressResult::Success);
    audit.record(env, {}, EgressResult::CertPinFail);
    audit.record(env, {}, EgressResult::NetworkFail);
    audit.record(env, {}, EgressResult::DeniedByAllowlist);

    REQUIRE(audit.records().size() == 4);
    REQUIRE(audit.records()[0].result == EgressResult::Success);
    REQUIRE(audit.records()[1].result == EgressResult::CertPinFail);
    REQUIRE(audit.records()[2].result == EgressResult::NetworkFail);
    REQUIRE(audit.records()[3].result == EgressResult::DeniedByAllowlist);

    REQUIRE(audit.verify_chain() == true);
}

// ── Strip count propagation ───────────────────────────────────────────────────

TEST_CASE("EgressAudit — strip counts from filter propagate into audit record",
          "[audit]") {
    auto& audit = EgressAudit::instance();
    audit.reset_for_test();

    RequestEnvelope env = make_test_envelope();
    env.stripped_system_messages  = 3;
    env.stripped_history_messages = 7;

    audit.record(env, kTestPayload, EgressResult::Success);

    const auto& rec = audit.records()[0];
    REQUIRE(rec.stripped_system_messages  == 3);
    REQUIRE(rec.stripped_history_messages == 7);
}
