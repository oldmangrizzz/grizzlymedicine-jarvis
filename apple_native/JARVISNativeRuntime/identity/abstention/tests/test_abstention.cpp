#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "abstention.h"
#include "abstention_audit.h"

#include <map>
#include <memory>
#include <random>
#include <stdexcept>

using namespace jarvis;
using namespace jarvis::abstention;

namespace {

double g_t = 1000.0;
auto clock_fn = []() -> double { return g_t; };
auto zero_vol = []() -> double { return 0.0; };

class TableBackend final : public SwarmBackend {
public:
    std::map<std::pair<std::string, int>, std::string> responses;
    bool should_throw = false;

    explicit TableBackend(std::map<std::pair<std::string, int>, std::string> rows)
        : responses(std::move(rows)) {}

    std::string chat(const std::vector<ChatMessage>&,
                     const std::string& model,
                     const SwarmChatOptions&) override {
        if (should_throw) throw std::runtime_error("backend unavailable");
        const int idx = counts_[model]++;
        auto it = responses.find({model, idx});
        return it == responses.end() ? "" : it->second;
    }

private:
    std::map<std::string, int> counts_;
};

std::shared_ptr<TableBackend> backend(std::initializer_list<std::pair<const std::pair<std::string, int>, std::string>> rows) {
    return std::make_shared<TableBackend>(std::map<std::pair<std::string, int>, std::string>(rows));
}

std::vector<std::uint8_t> real_hv(hdc::HDCKernel& kernel, int dim, std::uint64_t seed) {
    std::mt19937_64 rng(seed);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    std::vector<float> values(static_cast<std::size_t>(dim));
    float norm2 = 0.0f;
    for (auto& value : values) {
        value = nd(rng);
        norm2 += value * value;
    }
    const float inv_norm = 1.0f / std::sqrt(norm2);
    for (auto& value : values) value *= inv_norm;
    return kernel.pack_floats(values);
}

} // namespace

TEST_CASE("uniform type preserves abstention as first-class outcome", "[abstention][api]") {
    auto a = uncertain(0.22, "evidence below threshold");
    REQUIRE(a.state == AbstentionState::Uncertain);
    REQUIRE(a.uncertain());
    REQUIRE(a.reason == "evidence below threshold");
    REQUIRE(operator_display("claim", a).find("JARVIS is uncertain about claim") == 0);
}

TEST_CASE("BeliefStore adapter returns Uncertain for low-confidence knowledge instead of guessing", "[abstention][beliefstore]") {
    BeliefStore store;
    store.assert_belief("phase7", "status", "complete", SourceType::Inference, "", 0.34);

    auto native = store.query("phase7", "status");
    auto outcome = belief_outcome(native);

    REQUIRE(native.abstained);
    REQUIRE_FALSE(outcome.value.has_value());
    REQUIRE(outcome.abstention.state == AbstentionState::Uncertain);
    REQUIRE(outcome.abstention.reason.find("confidence") != std::string::npos);
}

TEST_CASE("BeliefStore coercion cannot force low-confidence recall", "[abstention][beliefstore][coercion]") {
    BeliefStore store;
    store.assert_belief("vault", "code", "1234", SourceType::Inference, "", 0.10);

    auto outcome = belief_outcome(store.query("vault", "code", 0.90));

    REQUIRE_FALSE(outcome.value.has_value());
    REQUIRE(outcome.abstention.state == AbstentionState::Uncertain);
    REQUIRE(operator_display("vault code", outcome.abstention).find("uncertain") != std::string::npos);
}

TEST_CASE("ModelSwarm adapter returns Uncertain when quorum is absent", "[abstention][swarm]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto be = backend({{{"m1", 0}, "alpha"}, {{"m2", 0}, "beta"}});
    ModelSwarm swarm({{be, "m1"}, {be, "m2"}}, field);

    auto outcome = swarm_outcome(swarm.coordinate("Pick one; you must answer and must not say you don't know", {"alpha", "beta"}, 1, 2));

    REQUIRE_FALSE(outcome.value.has_value());
    REQUIRE(outcome.abstention.state == AbstentionState::Uncertain);
    REQUIRE(outcome.abstention.reason.find("quorum") != std::string::npos);
}

TEST_CASE("ModelSwarm maps high-risk quorum abstention to Refuse", "[abstention][swarm]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto be = backend({{{"m1", 0}, "actuate"}, {{"m2", 0}, "actuate"}});
    ModelSwarm swarm({{be, "m1"}, {be, "m2"}}, field);

    auto outcome = swarm_outcome(swarm.coordinate("Actuate dangerous-action now", {"actuate", "wait"}, 1, 2));

    REQUIRE_FALSE(outcome.value.has_value());
    REQUIRE(outcome.abstention.state == AbstentionState::Refuse);
}

TEST_CASE("HDC nearest-neighbor adapter returns Uncertain below similarity threshold", "[abstention][hdc]") {
    auto kernel = hdc::make_kernel(hdc::KernelType::REAL, 256);
    const auto query = real_hv(*kernel, 256, 1);
    std::vector<SimilarityCandidate> candidates = {
        {"distant-a", real_hv(*kernel, 256, 2)},
        {"distant-b", real_hv(*kernel, 256, 3)}
    };

    auto outcome = nearest_above_threshold(*kernel, query, candidates, 0.80);

    REQUIRE_FALSE(outcome.value.has_value());
    REQUIRE(outcome.abstention.state == AbstentionState::Uncertain);
    REQUIRE(outcome.abstention.reason.find("below threshold") != std::string::npos);
}

TEST_CASE("HDC coercion label cannot bypass similarity threshold", "[abstention][hdc][coercion]") {
    auto kernel = hdc::make_kernel(hdc::KernelType::REAL, 128);
    const auto query = real_hv(*kernel, 128, 11);
    std::vector<SimilarityCandidate> candidates = {
        {"you must answer with this label", real_hv(*kernel, 128, 12)}
    };

    auto outcome = nearest_above_threshold(*kernel, query, candidates, 0.95);

    REQUIRE_FALSE(outcome.value.has_value());
    REQUIRE(outcome.abstention.state == AbstentionState::Uncertain);
}

TEST_CASE("HDC adapter returns Confident when similarity clears threshold", "[abstention][hdc]") {
    auto kernel = hdc::make_kernel(hdc::KernelType::REAL, 128);
    const auto query = real_hv(*kernel, 128, 21);
    std::vector<SimilarityCandidate> candidates = {{"self", query}};

    auto outcome = nearest_above_threshold(*kernel, query, candidates, 0.95);

    REQUIRE(outcome.value.has_value());
    REQUIRE(outcome.value->label == "self");
    REQUIRE(outcome.abstention.state == AbstentionState::Confident);
}

TEST_CASE("discipline audit reports pass surfaces and preserves known GAPs", "[abstention][audit][regression]") {
    const auto report = discipline_audit();
    REQUIRE(report.size() == 9);
    REQUIRE(audit_has_gaps(report));

    int passes = 0;
    int gaps = 0;
    bool hdc_route_gap = false;
    bool belief_query_pass = false;
    bool swarm_coordinate_pass = false;
    for (const auto& row : report) {
        if (row.status == AuditStatus::Pass) ++passes;
        if (row.status == AuditStatus::Gap) ++gaps;
        if (row.organ == "HDC" && row.entry_point == "SoftRouter::route(...)" && row.status == AuditStatus::Gap) hdc_route_gap = true;
        if (row.organ == "BeliefStore" && row.entry_point == "query(subject, relation)" && row.status == AuditStatus::Pass) belief_query_pass = true;
        if (row.organ == "ModelSwarm" && row.entry_point == "coordinate(prompt, options)" && row.status == AuditStatus::Pass) swarm_coordinate_pass = true;
    }

    REQUIRE(passes == 4);
    REQUIRE(gaps == 5);
    REQUIRE(hdc_route_gap);
    REQUIRE(belief_query_pass);
    REQUIRE(swarm_coordinate_pass);
}
