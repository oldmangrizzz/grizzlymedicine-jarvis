#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include "sage.h"

#include <nlohmann/json.hpp>

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using Catch::Approx;
using json = nlohmann::json;
using jarvis::sage::HoloGraph;

namespace {
std::vector<json> load_sage_records() {
    const std::filesystem::path path = std::filesystem::path(SAGE_ORACLE_DIR) / "api_traces.jsonl";
    std::ifstream in(path);
    REQUIRE(in.good());
    std::vector<json> records;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto rec = json::parse(line);
        if (rec.value("section", "") == "sage") records.push_back(std::move(rec));
    }
    return records;
}
}

TEST_CASE("SAGE matches SAGE-relevant oracle traces", "[sage][oracle]") {
    auto records = load_sage_records();
    REQUIRE(records.size() == 14);

    HoloGraph hg(512, 8, 3);
    int matched = 0;
    for (const auto& rec : records) {
        const std::string fn = rec.at("function").get<std::string>();
        const auto& args = rec.at("args");
        const auto& ret = rec.at("retval");
        if (fn == "HoloGraph.ingest_text") {
            auto triples = hg.ingest_text(args.at("text").get<std::string>(), args.at("anchor").get<std::string>());
            REQUIRE(triples.size() == ret.at("n_triples").get<std::size_t>());
            for (std::size_t i = 0; i < triples.size(); ++i) {
                REQUIRE(triples[i].head == ret.at("triples")[i].at("head").get<std::string>());
                REQUIRE(triples[i].relation == ret.at("triples")[i].at("relation").get<std::string>());
                REQUIRE(triples[i].tail == ret.at("triples")[i].at("tail").get<std::string>());
            }
            ++matched;
        } else if (fn == "HoloGraph.summary") {
            auto s = hg.summary();
            REQUIRE(s.entities == ret.at("entities").get<int>());
            REQUIRE(s.edges == ret.at("edges").get<int>());
            REQUIRE(s.classes == ret.at("classes").get<int>());
            REQUIRE(s.kernel_dim == ret.at("kernel_dim").get<int>());
            ++matched;
        } else if (fn == "HoloGraph.build_hierarchy") {
            auto h = hg.build_hierarchy(args.at("max_layer").get<int>(), args.at("node_cap").get<int>());
            hg.enable_hierarchy_routing(true, 3);
            REQUIRE(h.entities == ret.at("entities").get<int>());
            ++matched;
        } else if (fn == "HoloGraph.read") {
            auto out = hg.read(args.at("query").get<std::string>());
            REQUIRE(out.activated_ids == ret.at("activated_ids").get<std::vector<int>>());
            REQUIRE(out.activated_ids.size() == ret.at("n_activated").get<std::size_t>());
            REQUIRE(out.supporting_documents.size() == ret.at("n_supporting_docs").get<std::size_t>());
            for (std::size_t i = 0; i < out.supporting_documents.size(); ++i) {
                REQUIRE(out.supporting_documents[i].first == ret.at("supporting_docs")[i][0].get<std::string>());
                REQUIRE(out.supporting_documents[i].second == ret.at("supporting_docs")[i][1].get<std::string>());
            }
            REQUIRE(out.activated_subgraph_edges.size() == ret.at("n_edges").get<std::size_t>());
            for (auto it = ret.at("final_activation").begin(); it != ret.at("final_activation").end(); ++it) {
                int id = std::stoi(it.key());
                REQUIRE(out.final_activation.at(id) == Approx(it.value().get<double>()).margin(1e-12));
            }
            ++matched;
        } else if (fn == "HoloGraph.feedback") {
            auto fb = hg.feedback(args.at("query").get<std::string>());
            REQUIRE(fb.total_reward == Approx(ret.at("total_reward").get<double>()));
            REQUIRE(fb.reward.deductive == Approx(ret.at("reward_deductive").get<double>()));
            REQUIRE(fb.reward.recall == Approx(ret.at("reward_recall").get<double>()));
            REQUIRE(fb.reward.precision == Approx(ret.at("reward_precision").get<double>()));
            REQUIRE(fb.reward.answer == Approx(ret.at("reward_answer").get<double>()));
            REQUIRE(fb.reward.repetition_rate == Approx(ret.at("reward_repetition_rate").get<double>()));
            REQUIRE(fb.reward.format_bonus == Approx(ret.at("reward_format_bonus").get<double>()));
            REQUIRE(fb.reward.task_reward() == Approx(ret.at("task_reward").get<double>()));
            REQUIRE(std::string("FeedbackEvent") == ret.at("type").get<std::string>());
            ++matched;
        }
    }
    REQUIRE(matched == 14);
}
