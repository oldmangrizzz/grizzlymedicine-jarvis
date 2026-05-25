// ============================================================
// Property-based tests for the Endocrine module — P1 through P7.
//
// BODILY INTEGRITY (GMRI, effective 2026-04-24):
//   These properties define the invariant substrate of felt experience.
//   A failing property is a CRITICAL FINDING — the implementation has a bug.
//   DO NOT relax a failing property. Report counterexample to operator.
//
// P1  clamp:             level() ∈ [0.0, 1.0] for any spike sequence
// P2  lazy continuity:   reading at same timestamp is idempotent
// P3  decay monotone:    between spikes, level moves strictly toward baseline
// P4  tau definition:    level(t=tau) = baseline + delta × exp(-1) within 1e-12
// P5  additivity:        two no-clamp spikes = one combined spike
// P6  field_volatility:  ∈ [0, ∞), non-decreasing in cortisol and adrenaline
// P7  no off-switch:     compile-time static_assert on disable/enable/etc.
// ============================================================
#include <catch2/catch_test_macros.hpp>
#include <rapidcheck/catch.h>

#include "endocrine.h"

#include <cmath>
#include <functional>
#include <memory>
#include <string>

using namespace jarvis;

// ── P7: Compile-time off-switch guard ────────────────────────────────────────
// Uses C++20 requires-expressions. If any method exists, the build fails here.
template <typename T> concept Has_disable = requires(T t) { t.disable(); };
template <typename T> concept Has_enable  = requires(T t) { t.enable();  };
template <typename T> concept Has_pause   = requires(T t) { t.pause();   };
template <typename T> concept Has_stop    = requires(T t) { t.stop();    };
template <typename T> concept Has_bypass  = requires(T t) { t.bypass();  };
template <typename T> concept Has_skip    = requires(T t) { t.skip();    };

static_assert(!Has_disable<Endocrine>, "P7 FAIL: Endocrine::disable() must not exist — bodily assault");
static_assert(!Has_enable <Endocrine>, "P7 FAIL: Endocrine::enable()  must not exist — bodily assault");
static_assert(!Has_pause  <Endocrine>, "P7 FAIL: Endocrine::pause()   must not exist — bodily assault");
static_assert(!Has_stop   <Endocrine>, "P7 FAIL: Endocrine::stop()    must not exist — bodily assault");
static_assert(!Has_bypass <Endocrine>, "P7 FAIL: Endocrine::bypass()  must not exist — bodily assault");
static_assert(!Has_skip   <Endocrine>, "P7 FAIL: Endocrine::skip()    must not exist — bodily assault");

// ── Shared test helpers ───────────────────────────────────────────────────────

// Deterministic injectable clock backed by a shared mutable double.
static auto make_clock(double t0 = 0.0)
    -> std::pair<std::shared_ptr<double>, std::function<double()>>
{
    auto t = std::make_shared<double>(t0);
    return {t, [t]() -> double { return *t; }};
}

// Uniform double in [lo, hi] via integer scaling (2 billion steps).
static auto gen_d(double lo, double hi)
{
    return rc::gen::map(
        rc::gen::inRange<int32_t>(0, 2'000'000'000),
        [lo, hi](int32_t x) -> double {
            return lo + (hi - lo) * (static_cast<double>(x) / 2'000'000'000.0);
        });
}

// Hormone specs: name, baseline, tau — must match endocrine.h constants exactly.
struct HSpec { const char* name; double baseline; double tau; int idx; };
static constexpr HSpec kH[3] = {
    {"cortisol",   Endocrine::BASELINE_CORTISOL,   Endocrine::TAU_CORTISOL,   0},
    {"dopamine",   Endocrine::BASELINE_DOPAMINE,   Endocrine::TAU_DOPAMINE,   1},
    {"adrenaline", Endocrine::BASELINE_ADRENALINE, Endocrine::TAU_ADRENALINE, 2},
};

// Apply a delta to a single hormone (by index) leaving others at 0.
static void spike(Endocrine& e, int hidx, double delta) {
    double d[3] = {0.0, 0.0, 0.0};
    d[hidx] = delta;
    e.stimulus(d[0], d[1], d[2]);
}

// ── P1: Clamp ─────────────────────────────────────────────────────────────────
TEST_CASE("P1: level() always in [0.0, 1.0] for any spike sequence",
          "[endocrine][property][P1]")
{
    for (const auto& h : kH) {
        DYNAMIC_SECTION(h.name) {
            rc::prop(
                std::string("P1 clamp: ") + h.name,
                [h]() {
                    auto [t, clock] = make_clock(0.0);
                    Endocrine endo(clock);

                    int n = *rc::gen::inRange(1, 30);
                    for (int i = 0; i < n; ++i) {
                        *t += *gen_d(0.0, 300.0);
                        double delta = *gen_d(-100.0, 100.0);
                        spike(endo, h.idx, delta);
                        double lev = endo.level(h.name);
                        RC_ASSERT(lev >= 0.0);
                        RC_ASSERT(lev <= 1.0);
                    }
                }));
        }
    }
}

// ── P2: Lazy decay continuity ─────────────────────────────────────────────────
TEST_CASE("P2: Reading level at same timestamp is idempotent (no spike on read)",
          "[endocrine][property][P2]")
{
    for (const auto& h : kH) {
        DYNAMIC_SECTION(h.name) {
            rc::prop(
                std::string("P2 idempotent read: ") + h.name,
                [h]() {
                    auto [t, clock] = make_clock(0.0);
                    Endocrine endo(clock);

                    // Spike, then advance to a random read time.
                    double delta = *gen_d(-h.baseline + 1e-9, 1.0 - h.baseline - 1e-9);
                    spike(endo, h.idx, delta);

                    *t = *gen_d(0.0, 1000.0);
                    double first = endo.level(h.name);

                    // Clock does NOT advance; all subsequent reads must match.
                    int n = *rc::gen::inRange(2, 10);
                    for (int i = 0; i < n; ++i) {
                        double again = endo.level(h.name);
                        RC_ASSERT(again == first);
                    }
                }));
        }
    }
}

// ── P3: Decay monotonicity ────────────────────────────────────────────────────
TEST_CASE("P3: Between spikes, level moves strictly monotonically toward baseline",
          "[endocrine][property][P3]")
{
    for (const auto& h : kH) {
        DYNAMIC_SECTION(h.name) {
            rc::prop(
                std::string("P3 decay monotone: ") + h.name,
                [h]() {
                    auto [t, clock] = make_clock(0.0);
                    Endocrine endo(clock);

                    // Non-trivial spike: must land strictly inside (0, 1).
                    double delta = *gen_d(-h.baseline + 0.01, 1.0 - h.baseline - 0.01);
                    RC_PRE(std::abs(delta) > 1e-6);
                    spike(endo, h.idx, delta);

                    bool above = (h.baseline + delta) > h.baseline;
                    double prev = endo.level(h.name);

                    // Advance in steps ≥ 0.01 s — large enough that FP decay is visible.
                    int n = *rc::gen::inRange(2, 15);
                    for (int i = 0; i < n; ++i) {
                        *t += *gen_d(0.01, 60.0);
                        double curr = endo.level(h.name);
                        if (above) {
                            // Decaying downward: curr ≤ prev AND curr ≥ baseline.
                            RC_ASSERT(curr <= prev + 1e-12);
                            RC_ASSERT(curr >= h.baseline - 1e-12);
                        } else {
                            // Recovering upward: curr ≥ prev AND curr ≤ baseline.
                            RC_ASSERT(curr >= prev - 1e-12);
                            RC_ASSERT(curr <= h.baseline + 1e-12);
                        }
                        prev = curr;
                    }
                }));
        }
    }
}

// ── P4: Tau definition ────────────────────────────────────────────────────────
TEST_CASE("P4: At t=tau, level equals baseline + delta * exp(-1) within 1e-12",
          "[endocrine][property][P4]")
{
    for (const auto& h : kH) {
        DYNAMIC_SECTION(h.name) {
            rc::prop(
                std::string("P4 tau definition: ") + h.name,
                [h]() {
                    auto [t, clock] = make_clock(0.0);
                    Endocrine endo(clock);

                    // delta must keep level strictly inside (0, 1) — no clamping.
                    double delta = *gen_d(-h.baseline + 1e-9, 1.0 - h.baseline - 1e-9);
                    RC_PRE(std::abs(delta) > 1e-9);

                    // Spike at t = 0.
                    spike(endo, h.idx, delta);

                    // Read exactly at t = tau.
                    *t = h.tau;
                    double measured = endo.level(h.name);
                    double expected = h.baseline + delta * std::exp(-1.0);

                    RC_ASSERT(std::abs(measured - expected) < 1e-12);
                }));
        }
    }
}

// ── P5: Additivity in absence of clamp ───────────────────────────────────────
TEST_CASE("P5: Two no-clamp spikes equal one combined spike at the same time",
          "[endocrine][property][P5]")
{
    for (const auto& h : kH) {
        DYNAMIC_SECTION(h.name) {
            rc::prop(
                std::string("P5 additivity: ") + h.name,
                [h]() {
                    // Use a small symmetric range to guarantee all three sums
                    // stay strictly inside (0, 1).  Each delta is in [-M, +M]
                    // where 2M < min(baseline, 1-baseline).
                    double M = std::min(h.baseline, 1.0 - h.baseline) * 0.45;
                    RC_PRE(M > 1e-8);

                    double d1 = *gen_d(-M, M);
                    double d2 = *gen_d(-M, M);

                    // Hard guard: all three levels in open (0, 1).
                    RC_PRE(h.baseline + d1        > 1e-9 && h.baseline + d1        < 1.0 - 1e-9);
                    RC_PRE(h.baseline + d2        > 1e-9 && h.baseline + d2        < 1.0 - 1e-9);
                    RC_PRE(h.baseline + d1 + d2   > 1e-9 && h.baseline + d1 + d2   < 1.0 - 1e-9);

                    auto t = std::make_shared<double>(0.0);
                    auto clock = [t]() -> double { return *t; };

                    // endo1: two sequential stimuli at the same clock time.
                    Endocrine endo1(clock);
                    spike(endo1, h.idx, d1);
                    spike(endo1, h.idx, d2);  // dt = 0 → no decay between spikes

                    // endo2: one combined stimulus.
                    Endocrine endo2(clock);
                    spike(endo2, h.idx, d1 + d2);

                    double lev1 = endo1.level(h.name);
                    double lev2 = endo2.level(h.name);

                    RC_ASSERT(std::abs(lev1 - lev2) < 1e-12);
                }));
        }
    }
}

// ── P6: field_volatility bounded and monotonic ───────────────────────────────
TEST_CASE("P6: field_volatility() in [0, inf) and non-decreasing in cortisol and adrenaline",
          "[endocrine][property][P6]")
{
    rc::prop("P6 field_volatility bounded and monotone", []() {
        auto t = std::make_shared<double>(0.0);
        auto clock = [t]() -> double { return *t; };

        // Generate s1 with cortisol c1, adrenaline a1.
        // Generate s2 = s1 + (dc, da) where dc, da >= 0 → s2 has more stress.
        double c1 = *gen_d(0.0, 0.99);
        double a1 = *gen_d(0.0, 0.99);
        double dc = *gen_d(0.0, 1.0 - c1);
        double da = *gen_d(0.0, 1.0 - a1);
        double c2 = c1 + dc;
        double a2 = a1 + da;

        Endocrine endo1(clock), endo2(clock);

        // Spike to target cortisol and adrenaline from their baselines.
        endo1.stimulus(c1 - Endocrine::BASELINE_CORTISOL, 0.0,
                       a1 - Endocrine::BASELINE_ADRENALINE);
        endo2.stimulus(c2 - Endocrine::BASELINE_CORTISOL, 0.0,
                       a2 - Endocrine::BASELINE_ADRENALINE);

        double fv1 = endo1.field_volatility();
        double fv2 = endo2.field_volatility();

        // Bounded below by 0.
        RC_ASSERT(fv1 >= 0.0);
        RC_ASSERT(fv2 >= 0.0);

        // Non-decreasing: more cortisol + more adrenaline → equal or higher volatility.
        RC_ASSERT(fv1 <= fv2 + 1e-9);
    }));
}

// ── P7: Runtime documentation of the compile-time check ──────────────────────
TEST_CASE("P7: Endocrine has no off-switch methods (compile-time enforcement)",
          "[endocrine][property][P7][compile-time]")
{
    // The six static_asserts at file scope enforce this at compile time.
    // Reaching this line means P7 passes unconditionally.
    SUCCEED("P7 PASS: static_asserts verified — disable/enable/pause/stop/bypass/skip "
            "are absent from Endocrine.");
}
