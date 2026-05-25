#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "beliefstore.h"

#include <unordered_set>

using jarvis::BeliefStore;
using jarvis::SourceType;

TEST_CASE("BeliefStore recalls active operator/document/inference beliefs and abstains on model noise", "[beliefstore]") {
    BeliefStore store;
    REQUIRE(store.assert_belief("sky", "color", "blue", SourceType::Operator) == 1);
    REQUIRE(store.assert_belief("mars", "color", "red", SourceType::Document) == 2);
    REQUIRE(store.assert_belief("earth", "type", "rocky_planet", SourceType::Inference) == 3);
    REQUIRE(store.assert_belief("nebula", "structure", "gaseous", SourceType::Model) == 4);

    REQUIRE(store.recall("sky", "color") == "blue");
    REQUIRE(store.recall("mars", "color") == "red");
    REQUIRE(store.recall("earth", "type") == "rocky_planet");
    REQUIRE_FALSE(store.recall("nebula", "structure").has_value());
}

TEST_CASE("BeliefStore abstains below confidence threshold instead of guessing", "[beliefstore][abstention]") {
    BeliefStore store;
    store.assert_belief("lowconf", "prop", "val", SourceType::Inference, "", 0.15);
    auto result = store.query("lowconf", "prop");
    REQUIRE(result.abstained);
    REQUIRE_FALSE(result.result.has_value());

    store.assert_belief("borderline", "prop", "val", SourceType::Inference, "", 0.35);
    REQUIRE(store.recall("borderline", "prop") == "val");
    REQUIRE_FALSE(store.recall("borderline", "prop", 0.90).has_value());
}

TEST_CASE("BeliefStore keeps origin memories out of world-fact recall", "[beliefstore][origin]") {
    BeliefStore store;
    store.assert_belief("JARVIS", "origin", "StarkTower", SourceType::Operator, "", std::nullopt, std::nullopt, "origin");
    REQUIRE_FALSE(store.recall("JARVIS", "origin").has_value());
    REQUIRE(store.recall_origin("JARVIS", "origin") == std::vector<std::string>{"StarkTower"});
}

TEST_CASE("BeliefStore stronger-source revision demotes rather than deletes", "[beliefstore][revision]") {
    BeliefStore store;
    const int old_id = store.assert_belief("mars", "color", "red", SourceType::Document);
    auto rec = store.revise("mars", "color", "blue", SourceType::Operator);
    REQUIRE(rec.flipped);
    REQUIRE(rec.reason == "new evidence cleared hysteresis; incumbent demoted");
    REQUIRE(rec.demoted_edge_ids == std::vector<int>{old_id});
    REQUIRE(store.recall("mars", "color") == "blue");

    auto edges = store.all_edges();
    bool red_trace_survived = false;
    for (const auto& edge : edges) {
        if (edge.id == old_id && edge.object == "red" && edge.quarantined && edge.confidence == Catch::Approx(0.05)) {
            red_trace_survived = true;
        }
    }
    REQUIRE(red_trace_survived);
}

TEST_CASE("BeliefStore weaker source and below-hysteresis revisions are held aside", "[beliefstore][revision]") {
    BeliefStore store;
    store.assert_belief("sky", "color", "blue", SourceType::Operator);
    auto weak = store.revise("sky", "color", "green", SourceType::Model);
    REQUIRE_FALSE(weak.flipped);
    REQUIRE(weak.reason == "below hysteresis margin; held aside, active belief unchanged");
    REQUIRE(store.recall("sky", "color") == "blue");

    store.assert_belief("planet", "mass", "5.97e24", SourceType::Document, "", 0.80);
    auto near = store.revise("planet", "mass", "5.90e24", SourceType::Document, "", 0.69);
    REQUIRE_FALSE(near.flipped);
    REQUIRE(store.recall("planet", "mass") == "5.97e24");
}

TEST_CASE("BeliefStore corroborates quarantined belief and preserves charge orthogonality", "[beliefstore][corroboration][charge]") {
    BeliefStore store;
    int eid = store.assert_belief("nebula", "structure", "gaseous", SourceType::Model, "", std::nullopt, std::nullopt, "real", 0.8);
    REQUIRE_FALSE(store.recall("nebula", "structure").has_value());
    REQUIRE(store.set_charge(eid, 0.3));
    REQUIRE(store.corroborate("nebula", "structure", "gaseous", SourceType::Document));
    REQUIRE(store.recall("nebula", "structure") == "gaseous");
    auto detail = store.recall_detail("nebula", "structure");
    REQUIRE(detail.has_value());
    REQUIRE(detail->charge == Catch::Approx(0.3));
    REQUIRE(detail->confidence == Catch::Approx(0.80));
}

TEST_CASE("BeliefStore consolidate resolves active contradictions by top score", "[beliefstore][consolidate]") {
    BeliefStore store;
    store.assert_belief("door", "state", "open", SourceType::Operator, "", 0.80, false);
    store.assert_belief("door", "state", "closed", SourceType::Operator, "", 0.95, false);
    store.assert_belief("door", "state", "jammed", SourceType::Document, "", 0.99, false);

    REQUIRE(store.detect_contradictions().size() == 1);
    auto summary = store.consolidate();
    REQUIRE(summary.contradictions_resolved == 2);
    REQUIRE(summary.quarantined_aged == 0);
    REQUIRE(store.recall("door", "state") == "closed");
    REQUIRE(store.detect_contradictions().empty());
}

TEST_CASE("BeliefStore stores tuple hypervectors through the linked HDC kernel", "[beliefstore][hdc]") {
    BeliefStore store;
    store.assert_belief("sky", "color", "blue", SourceType::Operator);
    auto detail = store.recall_detail("sky", "color");
    REQUIRE(detail.has_value());
    REQUIRE(detail->tuple_hv.size() == 1024U * sizeof(float));
}
