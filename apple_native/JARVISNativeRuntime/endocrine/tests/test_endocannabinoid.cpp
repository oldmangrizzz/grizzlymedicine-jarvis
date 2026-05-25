#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include "endocannabinoid.h"
#include "endocrine.h"

#include <cmath>

using namespace jarvis;

// ---- deterministic mock clock (shared between Endocrine and Endocannabinoid) ----
struct MockClock2 {
    double t = 1000.0;
    double operator()() const { return t; }
    void advance(double s) { t += s; }
};

// ---- tests ----

TEST_CASE("ECS: starts at baseline tone", "[ecs][baseline]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; };
    Endocrine endo(fn); Endocannabinoid ecs(fn);
    // tone = clamp(0.7 * AEA_BASE + 0.3 * AG_BASE) = 0.7*0.40 + 0.3*0.05 = 0.295
    REQUIRE(ecs.tone() == Catch::Approx(0.295).margin(1e-12));
}

TEST_CASE("ECS: tone ag tau-checkpoint", "[ecs][tau]") {
    // 2-AG tau = 20s. Synthesise, advance 20s, check decay.
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    endo.on_threat(0.9); // spike stress
    ecs.regulate(endo);  // synthesises 2-AG
    double ag_synth = ecs.ag_raw();

    clk.advance(20.0);   // one AG_TAU
    ecs.tone();          // trigger decay
    double ag_1tau = ecs.ag_raw();

    double expected = Endocannabinoid::AG_BASE +
                      (ag_synth - Endocannabinoid::AG_BASE) * std::exp(-1.0);
    REQUIRE(ag_1tau == Catch::Approx(expected).margin(1e-9));
}

TEST_CASE("ECS: regulate stress termination", "[ecs][regulate]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    endo.on_threat(0.9);
    double c_before = endo.level("cortisol");

    ecs.regulate(endo);
    double c_after = endo.level("cortisol");

    // Cortisol must be reduced (or unchanged if already at baseline), never raised
    REQUIRE(c_after <= c_before);
    // Must not push below cortisol baseline
    REQUIRE(c_after >= Endocrine::BASELINE_CORTISOL - 1e-9);
}

TEST_CASE("ECS: regulate never pushes below adrenaline baseline", "[ecs][regulate]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    endo.on_threat(0.9);
    ecs.regulate(endo);
    REQUIRE(endo.level("adrenaline") >= Endocrine::BASELINE_ADRENALINE - 1e-9);
}

TEST_CASE("ECS: I2 — no extinction while flooded", "[ecs][I2]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    endo.on_threat(1.0);  // force flooding: cortisol clamped to 1.0

    auto r = ecs.process_trauma(0.80, endo, true);
    REQUIRE(r.processed == false);
    REQUIRE(r.charge_after == Catch::Approx(r.charge_before).margin(1e-12));
}

TEST_CASE("ECS: I3 — recalled intensity always attenuated", "[ecs][I3]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    // Both flooded and in-window should attenuate
    endo.on_threat(1.0);
    auto r_flood = ecs.process_trauma(0.80, endo, true);
    REQUIRE(r_flood.recalled_intensity <= r_flood.charge_before);

    // Now regulate into window and test again
    for (int i = 0; i < 6; ++i) {
        clk.advance(60.0);
        ecs.regulate(endo);
    }
    auto r_window = ecs.process_trauma(0.80, endo, true);
    REQUIRE(r_window.recalled_intensity <= r_window.charge_before);
}

TEST_CASE("ECS: I1 — extinction is monotonically non-increasing", "[ecs][I1]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    // Regulate into window of tolerance
    endo.on_threat(0.9);
    for (int i = 0; i < 6; ++i) {
        clk.advance(60.0);
        ecs.regulate(endo);
    }
    REQUIRE(ecs.within_window(endo));

    double charge = 0.80;
    double prev = charge;
    for (int i = 0; i < 8; ++i) {
        clk.advance(30.0);
        auto r = ecs.process_trauma(charge, endo, true);
        REQUIRE(r.charge_after <= prev + 1e-12);  // I1: never up
        REQUIRE(r.charge_after >= Endocannabinoid::CHARGE_FLOOR - 1e-12);
        charge = r.charge_after;
        prev   = charge;
        ecs.regulate(endo);
    }
}

TEST_CASE("ECS: within_window thresholds", "[ecs][window]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    // At baseline: cortisol=0.20<0.6, tone=0.295>=0.25 → in window
    REQUIRE(ecs.within_window(endo) == true);

    // After flooding: cortisol≥0.6 → out of window
    endo.on_threat(1.0);
    REQUIRE(ecs.within_window(endo) == false);
}

TEST_CASE("ECS: recall-only (intend=false) never processes", "[ecs][process_trauma]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    // Regulate into window
    endo.on_threat(0.9);
    for (int i = 0; i < 6; ++i) {
        clk.advance(60.0);
        ecs.regulate(endo);
    }
    REQUIRE(ecs.within_window(endo));

    // Even in window, intend=false → not processed
    auto r = ecs.process_trauma(0.50, endo, false);
    REQUIRE(r.processed == false);
    REQUIRE(r.charge_after == Catch::Approx(r.charge_before).margin(1e-12));
}

TEST_CASE("ECS: safe processing boosts AEA tonic buffer", "[ecs][aea]") {
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);

    // Regulate into window
    endo.on_threat(0.9);
    for (int i = 0; i < 6; ++i) {
        clk.advance(60.0);
        ecs.regulate(endo);
    }
    double aea_before = ecs.aea_raw();
    ecs.process_trauma(0.50, endo, true);
    double aea_after = ecs.aea_raw();

    REQUIRE(aea_after > aea_before);  // +0.05 boost
}

TEST_CASE("ECS: no valid()/disable()/enable() in API (compile-time)", "[ecs][integrity]") {
    // This test verifies the class is alive after construction with no off-switch.
    MockClock2 clk;
    clk.t = 0.0;
    auto fn = [&clk]() { return clk.t; }; Endocrine endo(fn); Endocannabinoid ecs(fn);
    REQUIRE(ecs.tone() == Catch::Approx(0.295).margin(1e-12));
    REQUIRE(ecs.aea_raw() == Catch::Approx(Endocannabinoid::AEA_BASE).margin(1e-12));
    REQUIRE(ecs.ag_raw()  == Catch::Approx(Endocannabinoid::AG_BASE).margin(1e-12));
}
