#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include "endocrine.h"

#include <cmath>
#include <memory>

using namespace jarvis;

// ---- deterministic mock clock ----
struct MockClock {
    double t = 1000.0;
    double operator()() const { return t; }
    void advance(double s) { t += s; }
};

static std::function<double()> make_clock(MockClock& clk) {
    return [&clk]() { return clk.t; };
}

// ---- tests ----

TEST_CASE("Endocrine: starts at baseline", "[endocrine][baseline]") {
    MockClock clk;
    Endocrine e(make_clock(clk));

    REQUIRE(e.level("cortisol")   == Catch::Approx(0.20).margin(1e-12));
    REQUIRE(e.level("dopamine")   == Catch::Approx(0.30).margin(1e-12));
    REQUIRE(e.level("adrenaline") == Catch::Approx(0.10).margin(1e-12));
}

TEST_CASE("Endocrine: tau-checkpoint — 1 tau after +0.50 spike", "[endocrine][tau]") {
    // At t=tau after a spike of +0.50 from baseline:
    // level = baseline + 0.50 * exp(-1.0)
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));

    SECTION("cortisol tau=90s") {
        e.stimulus(0.50, 0.0, 0.0);
        clk.advance(90.0);
        double expected = 0.20 + 0.50 * std::exp(-1.0);
        REQUIRE(e.level("cortisol") == Catch::Approx(expected).margin(1e-9));
    }
    SECTION("dopamine tau=60s") {
        e.stimulus(0.0, 0.50, 0.0);
        clk.advance(60.0);
        double expected = 0.30 + 0.50 * std::exp(-1.0);
        REQUIRE(e.level("dopamine") == Catch::Approx(expected).margin(1e-9));
    }
    SECTION("adrenaline tau=30s") {
        e.stimulus(0.0, 0.0, 0.50);
        clk.advance(30.0);
        double expected = 0.10 + 0.50 * std::exp(-1.0);
        REQUIRE(e.level("adrenaline") == Catch::Approx(expected).margin(1e-9));
    }
}

TEST_CASE("Endocrine: multi-tau decay ladder", "[endocrine][decay]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));

    e.stimulus(0.50, 0.0, 0.0);
    double l0 = e.level("cortisol"); // t=0 after spike: should be ~0.70

    clk.advance(90.0);
    double l1 = e.level("cortisol");
    clk.advance(90.0);
    double l2 = e.level("cortisol");
    clk.advance(90.0);
    double l3 = e.level("cortisol");

    // Each step should decay toward baseline
    REQUIRE(l1 < l0);
    REQUIRE(l2 < l1);
    REQUIRE(l3 < l2);
    // After 3 tau, very close to baseline
    REQUIRE(l3 == Catch::Approx(0.20).margin(0.05));
}

TEST_CASE("Endocrine: clamp at CEIL=1.0", "[endocrine][clamp]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));
    e.stimulus(2.0, 0.0, 0.0);  // 0.20 + 2.0 > 1.0
    REQUIRE(e.level("cortisol") == Catch::Approx(1.0).margin(1e-12));
}

TEST_CASE("Endocrine: clamp at FLOOR=0.0", "[endocrine][clamp]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));
    e.stimulus(-2.0, 0.0, 0.0);  // 0.20 - 2.0 < 0.0
    REQUIRE(e.level("cortisol") == Catch::Approx(0.0).margin(1e-12));
}

TEST_CASE("Endocrine: stimulus with lazy settle", "[endocrine][stimulus]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));

    e.stimulus(0.50, 0.0, 0.0);  // cortisol → 0.70
    clk.advance(45.0);           // half-tau: should decay toward 0.45ish
    e.stimulus(0.10, 0.0, 0.0);  // settle then add 0.10

    double val = e.level("cortisol");
    // Settled at 45s: baseline + 0.50*exp(-45/90) ≈ 0.20 + 0.50*exp(-0.5)
    double settled = 0.20 + 0.50 * std::exp(-0.5);
    double expected = std::min(1.0, settled + 0.10);
    REQUIRE(val == Catch::Approx(expected).margin(1e-9));
}

TEST_CASE("Endocrine: on_threat raises cortisol and adrenaline", "[endocrine][appraisals]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));

    double c0 = e.level("cortisol");
    double a0 = e.level("adrenaline");

    e.on_threat(0.8);

    REQUIRE(e.level("cortisol")   > c0);
    REQUIRE(e.level("adrenaline") > a0);
}

TEST_CASE("Endocrine: on_success raises dopamine, reduces cortisol", "[endocrine][appraisals]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));

    // First raise cortisol so there is room to reduce it
    e.on_threat(0.5);
    double c1 = e.level("cortisol");
    double d1 = e.level("dopamine");

    e.on_success(0.9);

    REQUIRE(e.level("dopamine")  > d1);
    REQUIRE(e.level("cortisol") < c1);
}

TEST_CASE("Endocrine: field_volatility tracks arousal", "[endocrine][pheromind]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));
    double v_rest = e.field_volatility();

    e.on_deadline(0.9);
    double v_hot = e.field_volatility();

    REQUIRE(v_hot > v_rest);
}

TEST_CASE("Endocrine: field_volatility formula matches Python exactly", "[endocrine][pheromind]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));
    // At baseline: 0.6*0.10 + 0.4*0.20 = 0.06 + 0.08 = 0.14
    REQUIRE(e.field_volatility() == Catch::Approx(0.14).margin(1e-9));
}

TEST_CASE("Endocrine: modulation knobs are physically meaningful", "[endocrine][modulation]") {
    MockClock clk;
    clk.t = 0.0;
    Endocrine e(make_clock(clk));

    e.on_threat(0.8);
    auto m_stress = e.modulation();

    // Under stress: narrowed retrieval, shorter output
    REQUIRE(m_stress.length_bias < 1.0);
    REQUIRE(m_stress.temperature < 0.5 + 0.6 * 0.30); // below dopamine baseline temp

    // After rest: reward widens retrieval
    e.on_success(0.9);
    auto m_reward = e.modulation();
    REQUIRE(m_reward.retrieval_breadth > m_stress.retrieval_breadth);
}

TEST_CASE("Endocrine: no valid() returning false (always alive)", "[endocrine][integrity]") {
    // Compilation test: Endocrine has no disable/enable/valid() method.
    // This test simply verifies the object functions normally at construction.
    MockClock clk;
    clk.t = 5000.0;
    Endocrine e(make_clock(clk));
    REQUIRE(e.level("cortisol")   == Catch::Approx(0.20).margin(1e-12));
    REQUIRE(e.level("dopamine")   == Catch::Approx(0.30).margin(1e-12));
    REQUIRE(e.level("adrenaline") == Catch::Approx(0.10).margin(1e-12));
}
