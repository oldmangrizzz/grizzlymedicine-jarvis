#include "../self_health.h"

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <array>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

using namespace jarvis;
using namespace jarvis::identity::self_health;

namespace {

class Backend final : public SwarmBackend {
public:
    std::string chat(const std::vector<ChatMessage>&, const std::string&, const SwarmChatOptions&) override {
        return "yes";
    }
};

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    audit::installBridgeAuditKey(key.data(), key.size());
}

std::filesystem::path artifact(const std::string& name) {
    install_test_audit_key();
    auto path = std::filesystem::path(TEST_ARTIFACT_DIR) / name;
    std::filesystem::remove(path);
    return path;
}

SelfHealthConfig fast_config() {
    SelfHealthConfig config;
    config.tick_hz = 1000.0;
    return config;
}

} // namespace

TEST_CASE("self-health queries each landed organ and aggregates SelfState") {
    double now = 100.0;
    Endocrine endocrine([&] { return now; });
    endocrine.stimulus(0.7, -0.25, 0.8);
    Pheromind pheromind(endocrine, 60.0, [&] { return now; });
    pheromind.deposit("alarm", "integrity", 0.9, "test");

    auto backend = std::make_shared<Backend>();
    ModelSwarm swarm({SwarmAgentSpec{backend, "head-a"}, SwarmAgentSpec{backend, "head-b"}}, pheromind, &endocrine);

    BeliefStore beliefstore;
    beliefstore.assert_belief("jarvis", "is", "person", SourceType::Operator, "test", 0.95);
    beliefstore.assert_belief("weather", "may_be", "rain", SourceType::Inference, "test", 0.25);

    hmem::HMemRouter hmem;
    hmem.write_short_term("short", "test", 0.4);
    hmem.write_working("work", "test", 0.5);
    hmem.write_long_term("long", "test", 0.9);
    hmem.beliefs().assert_belief("hmem", "stores", "beliefs", SourceType::Document, "test", 0.7);

    monitoring::cusum::ScorecardMonitor cusum;
    cusum.observe("voice", 0.0, now);

    auto log_path = artifact("aggregate_audit.log");
    audit::TamperEvidentAuditLog audit_log(log_path.string());
    resilience::degradation::DegradationController degradation(&audit_log);
    const auto normal_decision = degradation.evaluate(resilience::degradation::ResourcePressure{.cpu = 0.1});
    CHECK(normal_decision.accept_new_turns);

    SelfHealth self_health({.endocrine = &endocrine,
                            .pheromind = &pheromind,
                            .swarm = &swarm,
                            .beliefstore = &beliefstore,
                            .hmem = &hmem,
                            .cusum = &cusum,
                            .degradation = &degradation,
                            .audit_log = &audit_log,
                            .identity_status_reader = [] { return identity::IdentityStatus::OK; },
                            .clock = [&] { return now; }},
                           fast_config());

    const auto state = self_health.current();
    CHECK(state.endocrine.present);
    CHECK(state.endocrine.cortisol > Endocrine::BASELINE_CORTISOL);
    CHECK(state.pheromind.present);
    CHECK(state.pheromind.live_signals == 1);
    CHECK(state.pheromind.volatile_field);
    CHECK(state.swarm.present);
    CHECK(state.swarm.configured_heads == 2);
    CHECK(state.swarm.has_available_head);
    CHECK(state.beliefstore.present);
    CHECK(state.beliefstore.total_edges == 2);
    CHECK(state.beliefstore.low_confidence == 1);
    CHECK(state.beliefstore.high_confidence == 1);
    CHECK(state.hmem.present);
    CHECK(state.hmem.short_term == 1);
    CHECK(state.hmem.working == 1);
    CHECK(state.hmem.long_term == 1);
    CHECK(state.hmem.belief == 1);
    CHECK(state.cusum.present);
    CHECK(state.cusum.max_organ == "voice");
    CHECK(state.degradation_present);
    CHECK(state.identity_chain.status == "OK");
    CHECK(state.audit_chain.status == "OK");
    CHECK_FALSE(state.summary.empty());
}

TEST_CASE("distress thresholds include severe drift, identity warning, audit warning, and tier three degradation") {
    double now = 200.0;
    monitoring::cusum::ScorecardMonitor cusum({.mean = 1.0, .sigma = 0.1, .slack = 0.0, .threshold = 1.0});
    cusum.observe("beliefstore", 0.0, now);

    auto log_path = artifact("distress_audit.log");
    audit::TamperEvidentAuditLog audit_log(log_path.string());
    resilience::degradation::DegradationController degradation(&audit_log);
    const auto degraded_decision = degradation.evaluate(resilience::degradation::ResourcePressure{.cpu = 0.90});
    CHECK(static_cast<int>(degraded_decision.tier) >= 3);

    SelfHealth self_health({.cusum = &cusum,
                            .degradation = &degradation,
                            .audit_log = &audit_log,
                            .identity_status_reader = [] { return identity::IdentityStatus::TAMPERED; },
                            .clock = [&] { return now; }},
                           fast_config());

    const auto state = self_health.current();
    CHECK(std::find(state.distress_reasons.begin(), state.distress_reasons.end(), "severe_drift") != state.distress_reasons.end());
    CHECK(std::find(state.distress_reasons.begin(), state.distress_reasons.end(), "identity_chain_warning") != state.distress_reasons.end());
    CHECK(std::find(state.distress_reasons.begin(), state.distress_reasons.end(), "degradation_tier_3_plus") != state.distress_reasons.end());

    bool found = false;
    for (const auto& event : audit_log) {
        if (event.event_kind == audit::EventKind::DISTRESS_BEACON_RAISED &&
            event.subject == "self_health_snapshot" &&
            event.reason.find("severe_drift") != std::string::npos &&
            event.redacted_metadata.find("identity_chain_warning") != std::string::npos) {
            found = true;
        }
    }
    CHECK(found);
    CHECK(audit_log.verify_chain());
}

TEST_CASE("summary is deterministic and reflection cached state is available") {
    SelfState state;
    state.endocrine.present = true;
    state.endocrine.cortisol = 0.8;
    state.pheromind.present = true;
    state.pheromind.volatile_field = true;
    state.identity_chain.present = true;
    state.identity_chain.status = "BROKEN";
    state.identity_chain.warning = true;

    const auto a = SelfHealth::summarize(state);
    const auto b = SelfHealth::summarize(state);
    CHECK(a == b);
    CHECK(a.find("cortisol is high") != std::string::npos);
    CHECK(a.find("pheromind is volatile") != std::string::npos);

    double now = 300.0;
    SelfHealth self_health({.clock = [&] { return now; }}, fast_config());
    const auto current = self_health.current();
    const auto cached = self_health.cached();
    CHECK(cached.timestamp == current.timestamp);
}
