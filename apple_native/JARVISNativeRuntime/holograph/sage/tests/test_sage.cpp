#include <catch2/catch_approx.hpp>
#include <catch2/catch_test_macros.hpp>

#include "sage.h"

#include <optional>
#include <string>
#include <vector>

using Catch::Approx;
using jarvis::SourceType;
using jarvis::sage::HoloGraph;

TEST_CASE("SAGE writer path extracts and commits triples", "[sage][writer]") {
    HoloGraph hg(512, 8, 3);
    auto triples = hg.ingest_text("Alice visited Paris last summer.", "turn-1");
    REQUIRE(triples.size() == 1);
    REQUIRE(triples[0].head == "Alice");
    REQUIRE(triples[0].relation == "visit");
    REQUIRE(triples[0].tail == "Paris");
    REQUIRE(hg.summary().entities == 2);
    REQUIRE(hg.summary().edges == 1);
    REQUIRE(hg.beliefs().recall("Alice", "visit") == std::optional<std::string>{"Paris"});
}

TEST_CASE("SAGE reader path returns activated support", "[sage][reader]") {
    HoloGraph hg(512, 8, 3);
    hg.ingest_text("Alice visited Paris last summer.", "turn-1");
    hg.ingest_text("Bob works at ACME Corporation in London.", "turn-2");
    auto out = hg.read("Where did Alice visit?");
    REQUIRE_FALSE(out.abstained);
    REQUIRE_FALSE(out.activated_ids.empty());
    REQUIRE_FALSE(out.supporting_documents.empty());
}

TEST_CASE("SAGE consolidation cycle promotes H-MEM and resolves belief conflicts", "[sage][consolidation]") {
    HoloGraph hg(512, 8, 3);
    hg.ingest_text("Alice visited Paris last summer.", "turn-1");
    hg.beliefs().assert_belief("sector", "threat", "low", SourceType::Document, "", 0.55, false);
    hg.beliefs().assert_belief("sector", "threat", "high", SourceType::Document, "", 0.80, false);
    auto summary = hg.consolidate_cycle({"Where did Alice visit?"});
    REQUIRE(summary.read_count == 1);
    REQUIRE(summary.hmem_short_to_working == 1);
    REQUIRE(summary.hmem_working_to_long == 1);
    REQUIRE(summary.belief_summary.contradictions_resolved == 1);
    REQUIRE(hg.beliefs().recall("sector", "threat") == std::optional<std::string>{"high"});
}

TEST_CASE("SAGE abstention propagation preserves BeliefStore reason", "[sage][abstention]") {
    HoloGraph hg(512, 8, 3);
    hg.beliefs().assert_belief("nebula", "structure", "gaseous", SourceType::Model);
    auto out = hg.read("nebula structure");
    REQUIRE(out.abstained);
    REQUIRE(out.belief_result.has_value());
    REQUIRE(out.belief_result->abstained);
    REQUIRE_FALSE(out.abstention_reason.empty());
}

TEST_CASE("SAGE write-back conflict resolution keeps stronger source", "[sage][conflict]") {
    HoloGraph hg(512, 8, 3);
    hg.beliefs().assert_belief("JARVIS", "posture", "passive", SourceType::Model, "", 0.40, false);
    auto rev = hg.beliefs().revise("JARVIS", "posture", "defensive", SourceType::Operator, "operator", 0.95);
    REQUIRE(rev.flipped);
    auto summary = hg.consolidate_cycle();
    REQUIRE(summary.belief_summary.contradictions_resolved >= 0);
    REQUIRE(hg.beliefs().recall("JARVIS", "posture") == std::optional<std::string>{"defensive"});
}
