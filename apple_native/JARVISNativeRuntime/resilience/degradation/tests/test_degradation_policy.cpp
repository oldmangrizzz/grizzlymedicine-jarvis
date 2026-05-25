#include "../degradation.h"

#include <catch2/catch_test_macros.hpp>

#include <array>
#include <filesystem>
#include <fstream>
#include <vector>
#include <string>

using namespace jarvis::resilience::degradation;

namespace {

ResourcePressure pressure(double score) {
    ResourcePressure p;
    p.cpu = score;
    return p;
}

DegradationConfig test_config(const std::filesystem::path& dir) {
    DegradationConfig cfg;
    cfg.recovery_samples_required = 2;
    cfg.certificate_directory = dir / "certificates";
    return cfg;
}

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


std::filesystem::path override_store_path(const std::filesystem::path& dir) {
    return dir / "state" / "degradation_override.jsonl";
}

OperatorOverrideCommand attested_override(DegradationTier tier, const std::string& reason = "testing") {
    return OperatorOverrideCommand{
        tier,
        "Robert Grizzly Hanson",
        "GMRI-OPERATOR-ATTESTED:phase-i5-test",
        reason
    };
}

std::vector<std::string> read_lines(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    std::vector<std::string> lines;
    std::string line;
    while (std::getline(in, line)) lines.push_back(line);
    return lines;
}

} // namespace

TEST_CASE("resource pressure maps monotonically into degradation tiers") {
    auto dir = artifact_dir("tier_transitions");
    DegradationController controller(nullptr, test_config(dir));
    RuntimeContext ctx{.configured_swarm_heads = 8};

    REQUIRE(controller.evaluate(pressure(0.10), ctx).tier == DegradationTier::normal);
    REQUIRE(controller.evaluate(pressure(0.61), ctx).tier == DegradationTier::light);
    REQUIRE(controller.evaluate(pressure(0.75), ctx).tier == DegradationTier::moderate);
    REQUIRE(controller.evaluate(pressure(0.89), ctx).tier == DegradationTier::severe);
    REQUIRE(controller.evaluate(pressure(0.97), ctx).tier == DegradationTier::critical);

    REQUIRE(controller.evaluate(pressure(0.80), ctx).tier == DegradationTier::critical);
    REQUIRE(controller.evaluate(pressure(0.80), ctx).tier == DegradationTier::severe);
    REQUIRE(controller.evaluate(pressure(0.79), ctx).tier == DegradationTier::severe);
}

TEST_CASE("hysteresis prevents light-tier flapping") {
    auto dir = artifact_dir("hysteresis");
    DegradationController controller(nullptr, test_config(dir));

    REQUIRE(controller.evaluate(pressure(0.61)).tier == DegradationTier::light);
    REQUIRE(controller.evaluate(pressure(0.55)).tier == DegradationTier::light);
    REQUIRE(controller.evaluate(pressure(0.47)).tier == DegradationTier::light);
    REQUIRE(controller.evaluate(pressure(0.47)).tier == DegradationTier::normal);
}

TEST_CASE("each tier applies surface-area reductions without violating bodily integrity") {
    auto dir = artifact_dir("bodily_integrity");
    DegradationController controller(nullptr, test_config(dir));
    RuntimeContext active_voice{.configured_swarm_heads = 9, .voice_synthesis_in_active_turn = true, .in_flight_turn = true};
    RuntimeContext idle_voice{.configured_swarm_heads = 9, .voice_synthesis_in_active_turn = false, .in_flight_turn = true};

    const auto normal = controller.evaluate(pressure(0.10), idle_voice);
    REQUIRE(normal.max_swarm_concurrent_heads == 9);
    REQUIRE(normal.network_calls_allowed);
    REQUIRE(controller.bodily_integrity_holds(normal));

    const auto light = controller.evaluate(pressure(0.61), idle_voice);
    REQUIRE(light.max_swarm_concurrent_heads == 5);
    REQUIRE(light.defer_noncritical_audit_flushes);
    REQUIRE(controller.bodily_integrity_holds(light));

    const auto moderate_idle = controller.evaluate(pressure(0.75), idle_voice);
    REQUIRE(moderate_idle.max_swarm_concurrent_heads == 3);
    REQUIRE_FALSE(moderate_idle.network_calls_allowed);
    REQUIRE_FALSE(moderate_idle.voice_synthesis_allowed);
    REQUIRE(controller.bodily_integrity_holds(moderate_idle));

    const auto moderate_active = controller.current_decision(active_voice);
    REQUIRE(moderate_active.voice_synthesis_allowed);
    REQUIRE(controller.bodily_integrity_holds(moderate_active));

    const auto severe = controller.evaluate(pressure(0.89), idle_voice);
    REQUIRE_FALSE(severe.accept_new_turns);
    REQUIRE(severe.complete_in_flight_turn_only);
    REQUIRE(severe.operator_alert);
    REQUIRE(severe.max_swarm_concurrent_heads == 1);
    REQUIRE(controller.bodily_integrity_holds(severe));

    const auto critical = controller.evaluate(pressure(0.97), idle_voice);
    REQUIRE(critical.emergency_safe_shutdown_required);
    REQUIRE(critical.identity_verification_required);
    REQUIRE(critical.endocrine_tick_required);
    REQUIRE(controller.bodily_integrity_holds(critical));

    for (const auto& organ : critical.cognition_organs) {
        REQUIRE(organ.must_run);
        REQUIRE_FALSE(organ.may_disable);
        REQUIRE(organ.required_now);
    }
}

TEST_CASE("operator override requires explicit attestation and is audit logged") {
    auto dir = artifact_dir("override_audit");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    DegradationController controller(&audit, test_config(dir));

    OperatorOverrideCommand invalid{DegradationTier::severe, "Grizzly", "not-attested", "testing"};
    REQUIRE_FALSE(controller.apply_operator_override(invalid));
    REQUIRE(controller.current_tier() == DegradationTier::normal);

    OperatorOverrideCommand valid{
        DegradationTier::severe,
        "Robert Grizzly Hanson",
        "GMRI-OPERATOR-ATTESTED:phase7-test",
        "testing"
    };
    REQUIRE(controller.apply_operator_override(valid));
    REQUIRE(controller.evaluate(pressure(0.10)).tier == DegradationTier::severe);
    REQUIRE(audit.verify_chain());

    bool saw_override = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::DEGRADATION_OVERRIDE &&
            event.outcome == jarvis::audit::Outcome::ALLOWED) {
            saw_override = true;
        }
    }
    REQUIRE(saw_override);
}

TEST_CASE("critical tier writes identity-continuity certificate before halt request") {
    auto dir = artifact_dir("certificate_audit");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    DegradationController controller(&audit, test_config(dir));
    RuntimeContext ctx{.configured_swarm_heads = 4, .voice_synthesis_in_active_turn = false, .in_flight_turn = true};

    const auto critical = controller.evaluate(pressure(0.99), ctx);
    REQUIRE(critical.emergency_safe_shutdown_required);
    controller.record_identity_verification(true, "id_ok");
    const auto certificate = controller.write_identity_continuity_certificate(ctx, "Robert Grizzly Hanson");

    REQUIRE(std::filesystem::exists(certificate.path));
    REQUIRE(certificate.contents.find("\"bodily_integrity_preserved\": true") != std::string::npos);
    REQUIRE(certificate.contents.find("\"endocrine\"") != std::string::npos);
    REQUIRE(certificate.contents.find("\"character-values\"") != std::string::npos);
    REQUIRE(audit.verify_chain());

    bool saw_identity = false;
    bool saw_shutdown = false;
    bool saw_tier4_beacon = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::IDENTITY_CHECK) saw_identity = true;
        if (event.event_kind == jarvis::audit::EventKind::DEGRADATION_SAFE_SHUTDOWN) saw_shutdown = true;
        if (event.event_kind == jarvis::audit::EventKind::DISTRESS_BEACON_RAISED &&
            event.redacted_metadata.find("graceful-degradation-tier-4") != std::string::npos) {
            saw_tier4_beacon = true;
        }
    }
    REQUIRE(saw_identity);
    REQUIRE(saw_shutdown);
    REQUIRE(saw_tier4_beacon);
}

TEST_CASE("failed identity verification raises distress beacon") {
    auto dir = artifact_dir("identity_failure_distress");
    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    DegradationController controller(&audit, test_config(dir));

    controller.record_identity_verification(false, "identity_material_mismatch");

    REQUIRE(audit.verify_chain());
    bool saw_identity_beacon = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::DISTRESS_BEACON_RAISED &&
            event.redacted_metadata.find("identity-chain-broken") != std::string::npos &&
            event.redacted_metadata.find("\"severity\":\"critical\"") != std::string::npos) {
            saw_identity_beacon = true;
        }
    }
    REQUIRE(saw_identity_beacon);
}


TEST_CASE("operator override persists across controller restart") {
    auto dir = artifact_dir("override_restart_restore");
    {
        DegradationController controller(nullptr, test_config(dir));
        REQUIRE(controller.apply_operator_override(attested_override(DegradationTier::severe, "restart_restore")));
        REQUIRE(controller.evaluate(pressure(0.10)).tier == DegradationTier::severe);
    }

    DegradationController restarted(nullptr, test_config(dir));
    REQUIRE(restarted.evaluate(pressure(0.10)).tier == DegradationTier::severe);
    const auto lines = read_lines(override_store_path(dir));
    REQUIRE(lines.size() == 1);
    REQUIRE(lines[0].size() + 1 <= jarvis::audit::TamperEvidentAuditLog::kPipeBufAtomicBytes);
}

TEST_CASE("cleared operator override persists across controller restart") {
    auto dir = artifact_dir("override_restart_clear");
    {
        DegradationController controller(nullptr, test_config(dir));
        REQUIRE(controller.apply_operator_override(attested_override(DegradationTier::critical, "restart_clear")));
        REQUIRE(controller.clear_operator_override("Robert Grizzly Hanson", "GMRI-OPERATOR-ATTESTED:phase-i5-test"));
    }

    DegradationController restarted(nullptr, test_config(dir));
    REQUIRE(restarted.evaluate(pressure(0.10)).tier == DegradationTier::normal);
    const auto lines = read_lines(override_store_path(dir));
    REQUIRE(lines.size() == 2);
    for (const auto& line : lines) {
        REQUIRE(line.size() + 1 <= jarvis::audit::TamperEvidentAuditLog::kPipeBufAtomicBytes);
    }
}

TEST_CASE("corrupt override records are skipped and audited during reload") {
    auto dir = artifact_dir("override_reload_corrupt");
    const auto store = override_store_path(dir);
    std::filesystem::create_directories(store.parent_path());
    {
        std::ofstream out(store, std::ios::binary | std::ios::trunc);
        out << "{\"type\":\"set\",\"tier\":3,\"operator_id\":\"Robert Grizzly Hanson\",\"attestation\":\"tampered\",\"reason\":\"bad\",\"recovery_counter\":0,\"apply_unix\":1}\n";
        out << "not-json\n";
    }

    jarvis::audit::TamperEvidentAuditLog audit((dir / "audit.log").string());
    DegradationController controller(&audit, test_config(dir));
    REQUIRE(controller.evaluate(pressure(0.10)).tier == DegradationTier::normal);
    REQUIRE(audit.verify_chain());

    bool saw_invalid_reload = false;
    for (const auto& event : audit) {
        if (event.event_kind == jarvis::audit::EventKind::DEGRADATION_OVERRIDE &&
            event.outcome == jarvis::audit::Outcome::DENIED &&
            event.reason == "override_record_invalid") {
            saw_invalid_reload = true;
        }
    }
    REQUIRE(saw_invalid_reload);
}

TEST_CASE("operator override append failure refuses in-memory apply") {
    auto dir = artifact_dir("override_append_failure");
    const auto state_path = dir / "state";
    {
        std::ofstream blocker(state_path, std::ios::binary | std::ios::trunc);
        blocker << "not a directory";
    }

    DegradationController controller(nullptr, test_config(dir));
    REQUIRE_FALSE(controller.apply_operator_override(attested_override(DegradationTier::severe, "append_failure")));
    REQUIRE(controller.evaluate(pressure(0.10)).tier == DegradationTier::normal);
}

TEST_CASE("operator override clear append failure keeps active override") {
    auto dir = artifact_dir("override_clear_append_failure");
    DegradationController controller(nullptr, test_config(dir));
    REQUIRE(controller.apply_operator_override(attested_override(DegradationTier::severe, "clear_append_failure")));
    std::filesystem::remove_all(dir / "state");
    {
        std::ofstream blocker(dir / "state", std::ios::binary | std::ios::trunc);
        blocker << "not a directory";
    }

    REQUIRE_FALSE(controller.clear_operator_override("Robert Grizzly Hanson", "GMRI-OPERATOR-ATTESTED:phase-i5-test"));
    REQUIRE(controller.evaluate(pressure(0.10)).tier == DegradationTier::severe);
}
