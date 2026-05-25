#include "soak_harness.h"

#include <catch2/catch_test_macros.hpp>

TEST_CASE("JARVIS Phase 7 soak fault-injection run", "[soak][phase7]") {
    auto config = jarvis::tests::soak::config_from_environment();
    auto result = jarvis::tests::soak::run_soak(config);
    jarvis::tests::soak::write_reports(result, config);

    INFO("report: " << result.operator_report_path);
    INFO("gaps: " << result.gaps_path);
    INFO("violations: " << result.invariant_violations.size());
    INFO("gaps filed: " << result.gaps.size());

    REQUIRE(result.completed);
    REQUIRE(result.invariant_violations.empty());
    if (config.fail_on_gap) {
        REQUIRE(result.gaps.empty());
    }
}
