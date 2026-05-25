// ============================================================
// Property-based tests for the Endocannabinoid module — P8 through P12.
//
// BODILY INTEGRITY (GMRI, effective 2026-04-24):
//   These invariants protect safe trauma processing.
//   A failing property is a CRITICAL FINDING. DO NOT relax.
//
// P8   tone bounded:             tone() ∈ [0.0, 1.0] for any history
// P9   regulate negative feedback: regulate() never INCREASES cortisol or adrenaline
// P10  within_window definition:  returns true iff cortisol < 0.6 AND tone >= 0.25
// P11  trauma monotonic extinction: repeated process_trauma() within window
//                                   produces monotonically decreasing charge ≥ CHARGE_FLOOR
// P12  trauma blocked when flooded: out-of-window → charge unchanged (I2 protection)
// ============================================================
#include <catch2/catch_test_macros.hpp>
#include <rapidcheck/catch.h>

#include "endocrine.h"
#include "endocannabinoid.h"

#include <cmath>
#include <functional>
#include <memory>

using namespace jarvis;

// ── Shared helpers ────────────────────────────────────────────────────────────

static auto make_clock(double t0 = 0.0)
    -> std::pair<std::shared_ptr<double>, std::function<double()>>
{
    auto t = std::make_shared<double>(t0);
    return {t, [t]() -> double { return *t; }};
}

static auto gen_d(double lo, double hi)
{
    return rc::gen::map(
        rc::gen::inRange<int32_t>(0, 2'000'000'000),
        [lo, hi](int32_t x) -> double {
            return lo + (hi - lo) * (static_cast<double>(x) / 2'000'000'000.0);
        });
}

// ── P8: Tone bounded ─────────────────────────────────────────────────────────
TEST_CASE("P8: tone() always in [0.0, 1.0] for any history",
          "[endocannabinoid][property][P8]")
{
    rc::prop("P8 tone bounded", []() {
        auto [t, clock] = make_clock(0.0);
        Endocrine     endo(clock);
        Endocannabinoid ec(clock);

        // Apply a random sequence of regulate + process_trauma calls.
        int n = *rc::gen::inRange(0, 12);
        for (int i = 0; i < n; ++i) {
            *t += *gen_d(0.0, 120.0);
            // Spike stress axis randomly.
            endo.stimulus(*gen_d(-0.3, 0.8), 0.0, *gen_d(-0.1, 0.9));

            int op = *rc::gen::inRange(0, 2);
            if (op == 0) {
                ec.regulate(endo);
            } else {
                double charge = *gen_d(0.0, 1.0);
                ec.process_trauma(charge, endo, true);
            }
        }

        double tone = ec.tone();
        RC_ASSERT(tone >= 0.0);
        RC_ASSERT(tone <= 1.0);
    }));
}

// ── P9: Regulate never increases HPA axis ─────────────────────────────────────
TEST_CASE("P9: regulate() never increases cortisol or adrenaline (negative feedback only)",
          "[endocannabinoid][property][P9]")
{
    rc::prop("P9 regulate negative feedback", []() {
        auto [t, clock] = make_clock(0.0);
        Endocrine     endo(clock);
        Endocannabinoid ec(clock);

        // Set cortisol and adrenaline to generated target levels.
        double c_target = *gen_d(0.0, 1.0);
        double a_target = *gen_d(0.0, 1.0);
        endo.stimulus(c_target - Endocrine::BASELINE_CORTISOL, 0.0,
                      a_target - Endocrine::BASELINE_ADRENALINE);

        // Read levels before regulate — this also settles timestamps.
        double c_before = endo.level("cortisol");
        double a_before = endo.level("adrenaline");

        ec.regulate(endo);

        double c_after = endo.level("cortisol");
        double a_after = endo.level("adrenaline");

        // Negative feedback can only suppress toward baseline, never amplify.
        RC_ASSERT(c_after <= c_before + 1e-9);
        RC_ASSERT(a_after <= a_before + 1e-9);
    }));
}

// ── P10: within_window definition ────────────────────────────────────────────
TEST_CASE("P10: within_window() == (cortisol < 0.6 AND tone >= 0.25)",
          "[endocannabinoid][property][P10]")
{
    rc::prop("P10 within_window definition", []() {
        auto [t, clock] = make_clock(0.0);
        Endocrine     endo(clock);
        Endocannabinoid ec(clock);

        // Build varied tone state via optional regulate calls.
        int n_reg = *rc::gen::inRange(0, 5);
        for (int i = 0; i < n_reg; ++i) {
            *t += *gen_d(0.0, 30.0);
            endo.stimulus(*gen_d(-0.1, 0.5), 0.0, *gen_d(-0.1, 0.5));
            ec.regulate(endo);
        }

        // Set cortisol to a precise target at current time.
        double c_target = *gen_d(0.0, 1.0);
        double c_current = endo.level("cortisol");
        endo.stimulus(c_target - c_current, 0.0, 0.0);

        // Ground-truth: read the exact values the predicate uses.
        // within_window reads cortisol via endo.level("cortisol") then tone_locked_().
        // We replicate that exact sequence here at the same timestamp.
        double c_actual = endo.level("cortisol");
        double tone_val = ec.tone();

        bool expected = (c_actual < 0.6) && (tone_val >= 0.25);
        bool actual   = ec.within_window(endo);

        RC_ASSERT(actual == expected);
    }));
}

// ── P11: Trauma processing monotonic extinction ───────────────────────────────
TEST_CASE("P11: Repeated process_trauma() within window produces monotonically decreasing charge",
          "[endocannabinoid][property][P11]")
{
    rc::prop("P11 trauma monotonic extinction", []() {
        auto [t, clock] = make_clock(0.0);
        Endocrine     endo(clock);
        Endocannabinoid ec(clock);

        // Start with cortisol at baseline (0.20 < 0.60) and tone at rest (~0.295 >= 0.25).
        // This guarantees within_window = true at t=0.

        // Initial charge above CHARGE_FLOOR.
        double charge = *gen_d(Endocannabinoid::CHARGE_FLOOR + 0.01, 1.0);

        int n = *rc::gen::inRange(1, 20);
        double prev_charge = charge;

        for (int i = 0; i < n; ++i) {
            // Verify within window before each call.
            RC_PRE(ec.within_window(endo));

            auto result = ec.process_trauma(charge, endo, /*intend_to_process=*/true);

            if (result.processed) {
                // I1: charge_after ≤ charge_before (monotonic downward).
                RC_ASSERT(result.charge_after <= prev_charge + 1e-9);
                // Bounded below by CHARGE_FLOOR.
                RC_ASSERT(result.charge_after >= Endocannabinoid::CHARGE_FLOOR - 1e-9);
                charge = result.charge_after;
            } else {
                // Not processed: charge must be returned unchanged (I2).
                RC_ASSERT(std::abs(result.charge_after - result.charge_before) < 1e-9);
            }
            prev_charge = charge;
        }
    }));
}

// ── P12: Trauma processing blocked when flooded ───────────────────────────────
TEST_CASE("P12: process_trauma() does not change charge when flooded (I2 protection)",
          "[endocannabinoid][property][P12]")
{
    SECTION("P12a: flooded by cortisol >= 0.6") {
        rc::prop("P12a cortisol flood blocks processing", []() {
            auto [t, clock] = make_clock(0.0);
            Endocrine     endo(clock);
            Endocannabinoid ec(clock);

            // Drive cortisol to a level >= 0.6.
            double c_flooded = *gen_d(0.6, 1.0);
            endo.stimulus(c_flooded - Endocrine::BASELINE_CORTISOL, 0.0, 0.0);

            // Hard guard: cortisol must actually be >= 0.6 after clamping.
            double c_actual = endo.level("cortisol");
            RC_PRE(c_actual >= 0.6 - 1e-9);

            // Generate a charge above CHARGE_FLOOR to detect non-change.
            double charge = *gen_d(Endocannabinoid::CHARGE_FLOOR + 0.01, 1.0);

            auto result = ec.process_trauma(charge, endo, /*intend_to_process=*/true);

            // I2: charge unchanged when out of window.
            RC_ASSERT(!result.processed);
            RC_ASSERT(std::abs(result.charge_after - result.charge_before) < 1e-9);
        });
    }

    SECTION("P12b: intend_to_process=false always returns charge unchanged") {
        rc::prop("P12b no-intent returns charge unchanged", []() {
            auto [t, clock] = make_clock(0.0);
            Endocrine     endo(clock);
            Endocannabinoid ec(clock);

            // Arbitrary hormone state.
            endo.stimulus(*gen_d(-0.2, 0.8), 0.0, *gen_d(-0.1, 0.9));

            double charge = *gen_d(0.0, 1.0);

            auto result = ec.process_trauma(charge, endo, /*intend_to_process=*/false);

            RC_ASSERT(!result.processed);
            RC_ASSERT(std::abs(result.charge_after - result.charge_before) < 1e-9);
        });
    }

    // NOTE: P12c (tone < 0.25 case) cannot be triggered by the current
    // implementation because AEA_BASE=0.40 and AG_BASE=0.05 give a minimum
    // resting tone of 0.7*0.40 + 0.3*0.05 = 0.295 >= 0.25, and neither AEA
    // nor AG can decay below their baselines.  The tone guard is a structural
    // safety net for future state-extension (e.g., depletion pathways).
    // This note is here so the pheromind/beliefstore port agents know why the
    // tone-low branch is not covered.
}
