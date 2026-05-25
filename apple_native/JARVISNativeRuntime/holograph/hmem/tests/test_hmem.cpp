#include <catch2/catch_test_macros.hpp>

#include "hmem.h"

#include <algorithm>
#include <optional>
#include <vector>

using jarvis::SourceType;
using jarvis::hmem::HMemRouter;
using jarvis::hmem::MemoryStore;
using jarvis::hmem::MemoryTier;

TEST_CASE("HMemRouter routes short-term memory", "[hmem][route]") {
    HMemRouter router(256, 3);
    const int id = router.write_short_term("urgent operator instruction", "turn-1", 0.9);
    auto decision = router.route("operator instruction");
    REQUIRE_FALSE(decision.abstained);
    REQUIRE(decision.tier == MemoryTier::ShortTerm);
    REQUIRE(decision.record_ids == std::vector<int>{id});
}

TEST_CASE("HMemRouter routes working memory", "[hmem][route]") {
    HMemRouter router(256, 3);
    const int id = router.write_working("scratchpad route planning", "work-1", 0.9);
    auto decision = router.route("route planning");
    REQUIRE_FALSE(decision.abstained);
    REQUIRE(decision.tier == MemoryTier::Working);
    REQUIRE(decision.record_ids == std::vector<int>{id});
}

TEST_CASE("HMemRouter routes long-term memory through hierarchy", "[hmem][route]") {
    HMemRouter router(256, 3, 3, 2);
    const int a = router.write_long_term("Paris summer episodic memory", "doc-a", 0.9);
    router.write_long_term("London corporation workplace memory", "doc-b", 0.9);
    router.write_long_term("Rome conference meeting memory", "doc-c", 0.9);
    router.build_hierarchy();

    auto decision = router.route("Paris summer");
    REQUIRE_FALSE(decision.abstained);
    REQUIRE(decision.tier == MemoryTier::LongTerm);
    REQUIRE(decision.total_leaves == 3);
    REQUIRE_FALSE(decision.graph_leaf_ids.empty());
    REQUIRE(std::find(decision.record_ids.begin(), decision.record_ids.end(), a) != decision.record_ids.end());
}

TEST_CASE("HMemRouter routes belief queries and propagates abstention", "[hmem][belief]") {
    HMemRouter router(256, 3);
    router.beliefs().assert_belief("sky", "color", "blue", SourceType::Operator);
    router.beliefs().assert_belief("nebula", "structure", "gaseous", SourceType::Model);

    auto active = router.route("sky color");
    REQUIRE_FALSE(active.abstained);
    REQUIRE(active.tier == MemoryTier::Belief);
    REQUIRE(active.belief_result.has_value());
    REQUIRE(active.belief_result->result == std::optional<std::string>{"blue"});

    auto quarantined = router.route("nebula structure");
    REQUIRE(quarantined.abstained);
    REQUIRE(quarantined.tier == MemoryTier::Belief);
    REQUIRE(quarantined.belief_result.has_value());
    REQUIRE(quarantined.belief_result->abstained);
    REQUIRE_FALSE(quarantined.abstention_reason.empty());
}

TEST_CASE("HMemRouter consolidation promotes tiers and consolidates beliefs", "[hmem][consolidate]") {
    HMemRouter router(256, 3, 3, 2);
    router.write_short_term("new salient trace", "turn-new", 0.9);
    router.write_working("active working trace", "work-active", 0.9);
    router.beliefs().assert_belief("sector", "threat", "low", SourceType::Document, "", 0.55, false);
    router.beliefs().assert_belief("sector", "threat", "high", SourceType::Document, "", 0.80, false);

    auto summary = router.consolidate();
    REQUIRE(summary.short_to_working == 1);
    REQUIRE(summary.working_to_long == 2);
    REQUIRE(router.size(MemoryTier::ShortTerm) == 0);
    REQUIRE(router.size(MemoryTier::Working) == 0);
    REQUIRE(router.size(MemoryTier::LongTerm) == 2);
    REQUIRE(summary.beliefs.contradictions_resolved == 1);
    REQUIRE(router.beliefs().recall("sector", "threat") == std::optional<std::string>{"high"});
}

TEST_CASE("MemoryStore consolidation oracle path preserves recall block and idempotency count", "[hmem][memorystore]") {
    MemoryStore store(256, 4);
    REQUIRE(store.consolidate_text("JARVIS monitors network traffic and anomalous patterns.", "session-a-1") == 1);
    REQUIRE(store.consolidate_text("The operator instructed JARVIS to maintain defensive posture.", "session-a-2") == 2);
    REQUIRE(store.consolidate_text("JARVIS detected elevated threat level in the eastern sector.", "session-a-3") == 2);
    REQUIRE(store.n_memories() == 6);
    REQUIRE(store.consolidate_text("JARVIS monitors network traffic and anomalous patterns.", "session-a-1") == 1);

    const std::string expected =
        "[recalled memory — relevant prior context, injected by the continuity layer]\n"
        "- (session-a-1) JARVIS monitors network traffic and anomalous patterns.\n"
        "- (session-a-2) The operator instructed JARVIS to maintain defensive posture.\n"
        "- (session-a-3) JARVIS detected elevated threat level in the eastern sector.\n"
        "- JARVIS monitor network traffic";
    REQUIRE(store.recall("threat level", 4) == expected);
}
