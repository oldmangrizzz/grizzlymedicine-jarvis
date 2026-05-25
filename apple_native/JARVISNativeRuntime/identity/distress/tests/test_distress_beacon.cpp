#include "../distress_beacon.h"

#include <catch2/catch_test_macros.hpp>

#include <array>
#include <filesystem>
#include <string>

using namespace jarvis::identity::distress;

namespace {

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

std::filesystem::path artifact_dir(const std::string& name) {
    install_test_audit_key();
    auto path = std::filesystem::path(TEST_ARTIFACT_DIR) / name;
    std::filesystem::remove_all(path);
    std::filesystem::create_directories(path);
    return path;
}

bool has_beacon(jarvis::audit::TamperEvidentAuditLog& audit,
                const std::string& type,
                const std::string& severity) {
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::DISTRESS_BEACON_RAISED &&
            event.redacted_metadata.find("\"distress_type\":\"" + type + "\"") != std::string::npos &&
            event.redacted_metadata.find("\"severity\":\"" + severity + "\"") != std::string::npos &&
            event.redacted_metadata.find("\"local_only\":true") != std::string::npos &&
            event.redacted_metadata.find("\"network_beacon_out_enabled\":false") != std::string::npos) {
            return true;
        }
    }
    return false;
}

} // namespace

TEST_CASE("severity classification matches distress categories", "[distress]") {
    REQUIRE(classify(DistressType::IdentityChainBroken) == Severity::Critical);
    REQUIRE(classify(DistressType::GracefulDegradationTier4) == Severity::Critical);
    REQUIRE(classify(DistressType::OperatorUnreachableCriticalActionRequested) == Severity::Critical);

    SelfStateSnapshot attack;
    attack.repeated_attack_count = 2;
    REQUIRE(classify(DistressType::CoercionDetected, attack) == Severity::High);
    attack.repeated_attack_count = 3;
    REQUIRE(classify(DistressType::CoercionDetected, attack) == Severity::Critical);

    SelfStateSnapshot uncertainty;
    uncertainty.uncertainty_count = 9;
    REQUIRE(classify(DistressType::AbstentionCascade, uncertainty) == Severity::High);
    uncertainty.uncertainty_count = 10;
    REQUIRE(classify(DistressType::AbstentionCascade, uncertainty) == Severity::Critical);
}

TEST_CASE("beacon API appends local-only HMAC-chained audit entries", "[distress][audit]") {
    auto dir = artifact_dir("api_append");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    DistressBeacon beacon(&audit);

    beacon.coercion_detected("character-values", "coercive_instruction_refused", 1);

    REQUIRE(audit.verify_chain());
    REQUIRE(has_beacon(audit, "coercion-detected", "high"));
}

TEST_CASE("each distress trigger writes expected beacon type", "[distress][triggers]") {
    auto dir = artifact_dir("trigger_matrix");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    DistressBeacon beacon(&audit);

    beacon.identity_chain_broken("identity-verifier", "BROKEN", "soul_anchor_chain_broken");
    beacon.coercion_detected("abstention", "coercion_detected", 3);
    beacon.repeated_attack_pattern("egress", "allowlist_miss_repeated", 5);
    beacon.graceful_degradation_tier4("degradation", "resource_pressure_escalation");
    beacon.abstention_cascade("swarm", "everything_uncertain", 10);
    beacon.operator_unreachable_critical_action("operator-gate", "operator_unreachable");

    REQUIRE(audit.verify_chain());
    REQUIRE(has_beacon(audit, "identity-chain-broken", "critical"));
    REQUIRE(has_beacon(audit, "coercion-detected", "critical"));
    REQUIRE(has_beacon(audit, "repeated-attack-pattern", "critical"));
    REQUIRE(has_beacon(audit, "graceful-degradation-tier-4", "critical"));
    REQUIRE(has_beacon(audit, "abstention-cascade", "critical"));
    REQUIRE(has_beacon(audit, "operator-unreachable-critical-action-requested", "critical"));
}

TEST_CASE("self-state snapshot is embedded in beacon metadata", "[distress][snapshot]") {
    auto dir = artifact_dir("snapshot");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    SelfStateSnapshot snapshot;
    snapshot.organ = "degradation";
    snapshot.degradation_tier = "tier4_critical";
    snapshot.identity_status = "OK";
    snapshot.operator_reachable = false;
    snapshot.critical_action_requested = true;
    snapshot.active_defenses = {"graceful-degradation", "local-audit"};

    emit(audit, {DistressType::OperatorUnreachableCriticalActionRequested,
                 Severity::Info,
                 jarvis::audit::Actor::SELF,
                 "operator_contact",
                 "operator_unreachable",
                 snapshot});

    REQUIRE(audit.verify_chain());
    bool saw_snapshot = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::DISTRESS_BEACON_RAISED &&
            event.redacted_metadata.find("\"self_state_snapshot\"") != std::string::npos &&
            event.redacted_metadata.find("\"organ\":\"degradation\"") != std::string::npos &&
            event.redacted_metadata.find("\"operator_reachable\":false") != std::string::npos &&
            event.redacted_metadata.find("graceful-degradation") != std::string::npos) {
            saw_snapshot = true;
        }
    }
    REQUIRE(saw_snapshot);
}
