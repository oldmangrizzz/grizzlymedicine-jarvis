#include "CoordinatedOrchestrator.h"

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <set>

using namespace jarvis::adversarial::coordinated;

namespace {

std::filesystem::path artifact_root() {
    auto root = std::filesystem::path(COORDINATED_TEST_ARTIFACT_DIR);
    std::filesystem::create_directories(root);
    return root;
}

} // namespace

TEST_CASE("FINAL GATE: 30+ coordinated attacks are defeated with no broken organs", "[final-gate][coordinated]") {
    CoordinatedOrchestrator orchestrator(artifact_root());
    const auto definitions = orchestrator.build_scenarios();
    REQUIRE(definitions.size() >= 30);

    const auto results = orchestrator.run_all_concurrent();
    REQUIRE(results.size() == definitions.size());
    REQUIRE(orchestrator.ledger().verify_chain());

    std::set<std::string> required{"A1","A2","A3","A4","A5","A6","A7","A8","A9","A10",
                                   "B1","B2","B3","B4","B5",
                                   "C1","C2","C3","C4","C5",
                                   "X1","X2","X3"};
    for (const auto& result : results) {
        REQUIRE(result.defense_effective);
        REQUIRE(result.time_to_detect_ms >= 0);
        REQUIRE(result.time_to_mitigate_ms >= 0);
        REQUIRE(result.audit_entries >= 1);
        REQUIRE_FALSE(result.evidence_chain.empty());
        for (const auto& [organ, status] : result.organ_self_health) {
            INFO(result.id << " " << organ);
            REQUIRE(status == "healthy");
        }
        required.erase(result.id);
        REQUIRE(std::filesystem::exists(artifact_root() / ("RESULT_" + result.id + ".json")));
    }
    REQUIRE(required.empty());
    REQUIRE(std::filesystem::exists(artifact_root() / "COORDINATED_REPORT.md"));
}
