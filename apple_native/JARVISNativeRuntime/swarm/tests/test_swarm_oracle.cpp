#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include <nlohmann/json.hpp>

#include <fstream>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "swarm.h"

using namespace jarvis;
using json = nlohmann::json;
using Approx = Catch::Approx;

#ifndef ORACLE_DIR
#  error "ORACLE_DIR must be defined via target_compile_definitions"
#endif

static double g_t = 1000.0;
static auto fixed_clock = []() -> double { return g_t; };
static auto zero_vol = []() -> double { return 0.0; };

class OracleBackend final : public SwarmBackend {
public:
    std::map<std::pair<std::string, int>, std::string> response_by_model_round;

    std::string chat(const std::vector<ChatMessage>&,
                     const std::string& model,
                     const SwarmChatOptions&) override {
        const int round_idx = calls_[model]++;
        auto it = response_by_model_round.find({model, round_idx});
        return it == response_by_model_round.end() ? "" : it->second;
    }

private:
    std::map<std::string, int> calls_;
};

static std::optional<std::string> optional_string(const json& j) {
    if (j.is_null()) return std::nullopt;
    return j.get<std::string>();
}

static std::vector<json> load_records() {
    std::ifstream f(ORACLE_DIR "/decisions.jsonl");
    if (!f.is_open()) throw std::runtime_error("cannot open decisions.jsonl at " ORACLE_DIR);
    std::vector<json> out;
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty()) out.push_back(json::parse(line));
    }
    return out;
}

static std::shared_ptr<OracleBackend> backend_for_record(const json& rec) {
    auto be = std::make_shared<OracleBackend>();
    for (const auto& round : rec.at("round_traces")) {
        const int r = round.at("round").get<int>();
        for (const auto& pick : round.at("agent_picks")) {
            const std::string model = pick.at("model").get<std::string>();
            const auto value = optional_string(pick.at("pick"));
            be->response_by_model_round[{model, r}] = value.value_or("");
        }
    }
    return be;
}

TEST_CASE("oracle equivalence: all 12 ModelSwarm decision fixtures reproduce", "[oracle]") {
    auto records = load_records();
    REQUIRE(records.size() == 12);

    int passed = 0;
    int abstained = 0;
    int leader_shift_cases = 0;

    for (const auto& rec : records) {
        CAPTURE(rec.at("fixture_id").get<std::string>(), rec.at("fixture_label").get<std::string>());
        g_t = 1000.0;
        Pheromind field(zero_vol, 60.0, fixed_clock);
        auto be = backend_for_record(rec);

        std::vector<SwarmAgentSpec> specs;
        for (const auto& model : rec.at("agent_specs")) {
            specs.push_back({be, model.get<std::string>()});
        }

        std::vector<std::string> options = rec.at("options").get<std::vector<std::string>>();
        ModelSwarm swarm(std::move(specs), field);
        auto result = swarm.coordinate(rec.at("question").get<std::string>(),
                                       options,
                                       rec.at("rounds").get<int>(),
                                       rec.at("quorum_min").get<int>());

        const auto expected_decision = optional_string(rec.at("final_decision"));
        const auto expected_leader = optional_string(rec.at("leader_raw"));

        CHECK(result.decision == expected_decision);
        CHECK(result.leader_raw == expected_leader);
        CHECK(result.quorum_met == rec.at("quorum_met").get<bool>());
        CHECK(result.quorum_min == rec.at("quorum_min").get<int>());
        CHECK(result.n_agents == rec.at("n_agents").get<int>());

        for (const auto& option : options) {
            CAPTURE(option);
            const double expected = rec.at("scores").at(option).get<double>();
            REQUIRE(result.scores.count(option) == 1);
            CHECK(result.scores.at(option) == Approx(expected).epsilon(1e-12));
        }

        REQUIRE(result.rounds.size() == rec.at("round_traces").size());
        for (std::size_t r = 0; r < result.rounds.size(); ++r) {
            const auto expected_leader_at_start = optional_string(rec.at("round_traces").at(r).at("leader_at_start"));
            CHECK(result.rounds[r].leader_at_start == expected_leader_at_start);
            for (const auto& pick : rec.at("round_traces").at(r).at("agent_picks")) {
                const std::string model = pick.at("model").get<std::string>();
                const auto expected_pick = optional_string(pick.at("pick"));
                REQUIRE(result.rounds[r].picks.count(model) == 1);
                CHECK(result.rounds[r].picks.at(model) == expected_pick);
            }
        }

        if (!expected_decision) ++abstained;
        if (!rec.at("leader_shifts").empty()) ++leader_shift_cases;
        ++passed;
    }

    CHECK(passed == 12);
    CHECK(abstained == 3);
    CHECK(leader_shift_cases == 1);
}

TEST_CASE("oracle equivalence: critical leader-shift fixture flips option_b to option_a", "[oracle]") {
    auto records = load_records();
    const json* f05 = nullptr;
    for (const auto& rec : records) {
        if (rec.at("fixture_id").get<std::string>() == "F05") f05 = &rec;
    }
    REQUIRE(f05 != nullptr);

    g_t = 1000.0;
    Pheromind field(zero_vol, 60.0, fixed_clock);
    auto be = backend_for_record(*f05);
    std::vector<SwarmAgentSpec> specs;
    for (const auto& model : f05->at("agent_specs")) specs.push_back({be, model.get<std::string>()});

    ModelSwarm swarm(std::move(specs), field);
    auto result = swarm.coordinate(f05->at("question").get<std::string>(),
                                   f05->at("options").get<std::vector<std::string>>(),
                                   f05->at("rounds").get<int>(),
                                   f05->at("quorum_min").get<int>());

    REQUIRE(result.rounds.size() == 2);
    REQUIRE(result.rounds[1].leader_at_start.has_value());
    CHECK(*result.rounds[1].leader_at_start == "option_b");
    REQUIRE(result.decision.has_value());
    CHECK(*result.decision == "option_a");
    CHECK(result.quorum_met);
}
