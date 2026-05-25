#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include <cmath>
#include <map>
#include <stdexcept>

#include "swarm.h"

using namespace jarvis;
using Approx = Catch::Approx;

static double g_t = 1000.0;
static auto clock_fn = []() -> double { return g_t; };
static auto zero_vol = []() -> double { return 0.0; };

class TableBackend final : public SwarmBackend {
public:
    std::map<std::pair<std::string, int>, std::string> responses;
    SwarmChatOptions last_options;
    std::vector<ChatMessage> last_messages;
    bool should_throw = false;

    explicit TableBackend(std::map<std::pair<std::string, int>, std::string> r)
        : responses(std::move(r)) {}

    std::string chat(const std::vector<ChatMessage>& messages,
                     const std::string& model,
                     const SwarmChatOptions& options) override {
        if (should_throw) throw std::runtime_error("backend unavailable");
        last_options = options;
        last_messages = messages;
        const int idx = counts[model]++;
        auto it = responses.find({model, idx});
        return it == responses.end() ? "" : it->second;
    }

private:
    std::map<std::string, int> counts;
};

static std::shared_ptr<TableBackend> backend(std::initializer_list<std::pair<const std::pair<std::string, int>, std::string>> rows) {
    return std::make_shared<TableBackend>(std::map<std::pair<std::string, int>, std::string>(rows));
}

TEST_CASE("agent behavior: asks backend and deposits exact recruit signal", "[unit]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto be = backend({{{"m1", 0}, "epinephrine"}});
    ModelSwarm swarm({{be, "m1"}}, field);

    auto result = swarm.coordinate("First-line drug?", {"epinephrine", "diphenhydramine"}, 1, 1);

    REQUIRE(result.decision.has_value());
    REQUIRE(*result.decision == "epinephrine");
    REQUIRE(field.sense("recruit", "epinephrine") == Approx(0.34).epsilon(1e-12));
    REQUIRE(be->last_messages.size() == 2);
    REQUIRE(be->last_messages[1].content.find("Question: First-line drug?") != std::string::npos);
}

TEST_CASE("agent behavior: ambiguous or failing backend abstains", "[unit]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto ambiguous = backend({{{"m1", 0}, "alpha or beta"}});
    auto failing = backend({{{"m2", 0}, "alpha"}});
    failing->should_throw = true;

    ModelSwarm swarm({{ambiguous, "m1"}, {failing, "m2"}}, field);
    auto result = swarm.coordinate("Tie?", {"alpha", "beta"}, 1, 2);

    REQUIRE_FALSE(result.decision.has_value());
    REQUIRE_FALSE(result.quorum_met);
    REQUIRE(result.rounds[0].picks.at("m1") == std::nullopt);
    REQUIRE(result.rounds[0].picks.at("m2") == std::nullopt);
}

TEST_CASE("quorum: threshold decision without central router", "[unit]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto be = backend({
        {{"a1", 0}, "go"}, {{"a2", 0}, "go"}, {{"a3", 0}, "wait"}
    });
    ModelSwarm swarm({{be, "a1"}, {be, "a2"}, {be, "a3"}}, field);

    auto result = swarm.coordinate("Proceed?", {"go", "wait"}, 1, 2);

    REQUIRE(result.decision.has_value());
    REQUIRE(*result.decision == "go");
    REQUIRE(result.quorum_met);
    REQUIRE(field.quorum("recruit", "go", 2, 0.0));
}

TEST_CASE("abstention discipline: no quorum means no forced winner", "[unit]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto be = backend({{{"m1", 0}, "alpha"}, {{"m2", 0}, "beta"}});
    ModelSwarm swarm({{be, "m1"}, {be, "m2"}}, field);

    auto result = swarm.coordinate("Pick?", {"alpha", "beta"}, 1, 2);

    REQUIRE_FALSE(result.decision.has_value());
    REQUIRE(result.leader_raw.has_value());
    REQUIRE(*result.leader_raw == "alpha");
    REQUIRE_FALSE(result.quorum_met);
}

TEST_CASE("leader shift: agents read prior Pheromind leaning in next round", "[unit]") {
    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, clock_fn);
    auto be = backend({
        {{"e1", 0}, "option_b"}, {{"e1", 1}, "option_b"},
        {{"e2", 0}, "option_b"}, {{"e2", 1}, "option_a"},
        {{"e3", 0}, "option_b"}, {{"e3", 1}, "option_a"},
        {{"e4", 0}, "option_a"}, {{"e4", 1}, "option_a"},
        {{"e5", 0}, "option_a"}, {{"e5", 1}, "option_a"}
    });
    ModelSwarm swarm({{be, "e1"}, {be, "e2"}, {be, "e3"}, {be, "e4"}, {be, "e5"}}, field);

    auto result = swarm.coordinate("Emerging protocol?", {"option_a", "option_b", "option_c"}, 2, 3);

    REQUIRE(result.rounds[0].leader_at_start == std::nullopt);
    REQUIRE(result.rounds[1].leader_at_start.has_value());
    REQUIRE(*result.rounds[1].leader_at_start == "option_b");
    REQUIRE(result.decision.has_value());
    REQUIRE(*result.decision == "option_a");
}

TEST_CASE("endocrine coupling: cortisol constrains, dopamine explores, adrenaline cheapens", "[unit]") {
    g_t = 1000.0;
    Endocrine endo(clock_fn);
    Pheromind field(endo, 60.0, clock_fn);
    auto be = backend({{{"m1", 0}, "yes"}});
    ModelSwarm swarm({{be, "m1"}}, field, &endo);

    endo.on_success(1.0);
    endo.on_threat(0.8);
    auto result = swarm.coordinate("Continue?", {"yes", "no"}, 1, 1);

    REQUIRE(result.decision.has_value());
    REQUIRE(be->last_options.temperature >= 0.05);
    REQUIRE(be->last_options.temperature <= 0.9);
    REQUIRE(be->last_options.num_predict < 12);

    field.deposit("trail", "route", 1.0, "seed");
    g_t = 1060.0;
    REQUIRE(field.sense("trail", "route") < std::exp(-1.0));
}

TEST_CASE("normalization and option matching mirror Python", "[unit]") {
    REQUIRE(swarm_norm(" IM thigh ") == "im_thigh");
    REQUIRE(swarm_norm("CPR-first") == "cpr_first");
    REQUIRE(swarm_match_option("Answer: IM", {"IM", "IV"}).value() == "IM");
    REQUIRE_FALSE(swarm_match_option("alpha or beta", {"alpha", "beta"}).has_value());
    REQUIRE(swarm_match_option("CPR_first\n", {"CPR_first", "epinephrine"}).value() == "CPR_first");
}
