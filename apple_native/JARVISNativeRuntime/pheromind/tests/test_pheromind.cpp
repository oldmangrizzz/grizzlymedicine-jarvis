#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include <cmath>
#include <thread>
#include "pheromind.h"

using namespace jarvis;
using Approx = Catch::Approx;

// ---- mock clock ----
static double g_t = 0.0;
static auto mock_clk = []() -> double { return g_t; };
static auto zero_vol = []() -> double { return 0.0; };

// ---- eff_tau formula ----
TEST_CASE("eff_tau: formula matches Python exactly", "[unit]") {
    SECTION("volatility=0.0 → tau = base") {
        double t = g_t = 0.0;
        Pheromind pm(zero_vol, 60.0, mock_clk);
        pm.deposit("trail", "x", 0.5, "a");
        g_t = 60.0;
        double s = pm.sense("trail", "x");
        // exp(-60/60) = exp(-1) ≈ 0.3679
        REQUIRE(s == Approx(0.5 * std::exp(-1.0)).epsilon(1e-12));
    }

    SECTION("volatility=0.5 → trail eff_tau = 60/(1+2*0.5) = 30") {
        g_t = 0.0;
        Pheromind pm([]{ return 0.5; }, 60.0, mock_clk);
        pm.deposit("trail", "x", 1.0, "a");
        g_t = 30.0;
        double s = pm.sense("trail", "x");
        REQUIRE(s == Approx(std::exp(-1.0)).epsilon(1e-12));
    }

    SECTION("alarm tau = 12, volatility=0") {
        g_t = 0.0;
        Pheromind pm(zero_vol, 60.0, mock_clk);
        pm.deposit("alarm", "x", 1.0, "a");
        g_t = 12.0;
        double s = pm.sense("alarm", "x");
        REQUIRE(s == Approx(std::exp(-1.0)).epsilon(1e-12));
    }

    SECTION("territory tau = 600, volatility=0") {
        g_t = 0.0;
        Pheromind pm(zero_vol, 60.0, mock_clk);
        pm.deposit("territory", "x", 1.0, "a");
        g_t = 600.0;
        double s = pm.sense("territory", "x");
        REQUIRE(s == Approx(std::exp(-1.0)).epsilon(1e-12));
    }

    SECTION("unknown kind falls back to base_tau") {
        g_t = 0.0;
        Pheromind pm(zero_vol, 30.0, mock_clk);
        pm.deposit("custom_kind", "x", 1.0, "a");
        g_t = 30.0;
        double s = pm.sense("custom_kind", "x");
        REQUIRE(s == Approx(std::exp(-1.0)).epsilon(1e-12));
    }
}

// ---- deposit ----
TEST_CASE("deposit: basic strength and cap", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);

    SECTION("first deposit stores strength and returns new strength") {
        double stored = pm.deposit("trail", "a", 0.6, "ant1");
        REQUIRE(stored == Approx(0.6).epsilon(1e-12));
        REQUIRE(pm.sense("trail", "a") == Approx(0.6).epsilon(1e-12));
    }

    SECTION("strength capped at 1.0") {
        pm.deposit("trail", "a", 0.8, "ant1");
        pm.deposit("trail", "a", 0.8, "ant2");
        REQUIRE(pm.sense("trail", "a") == Approx(1.0).epsilon(1e-12));
    }

    SECTION("negative strength ignored") {
        pm.deposit("trail", "a", -0.5, "ant1");
        REQUIRE(pm.sense("trail", "a") == 0.0);
    }

    SECTION("reinforcement accumulates on decayed value") {
        pm.deposit("trail", "a", 0.6, "ant1");
        g_t = 60.0;  // strength ≈ 0.6*exp(-1) ≈ 0.2207
        pm.deposit("trail", "a", 0.3, "ant1");
        double expected = std::min(1.0, 0.6 * std::exp(-1.0) + 0.3);
        REQUIRE(pm.sense("trail", "a") == Approx(expected).epsilon(1e-12));
    }
}

// ---- sense ----
TEST_CASE("sense: returns 0 for absent or below-floor signals", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);

    REQUIRE(pm.sense("trail", "missing") == 0.0);

    pm.deposit("alarm", "blip", 0.5, "s1");
    // alarm tau=12; need dt so 0.5*exp(-dt/12) < 0.02 → dt > 38.8s
    g_t = 60.0;
    REQUIRE(pm.sense("alarm", "blip") == 0.0);
}

// ---- sniff / semantic gradient ----
TEST_CASE("sniff: exact and cosine-near topics match Python sense semantics", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);

    const std::vector<float> north{1.0f, 0.0f};
    const std::vector<float> near_north{0.8f, 0.6f};
    const std::vector<float> east{0.0f, 1.0f};

    pm.deposit("trail", "route_A", 0.5, "a1", north);
    pm.deposit("alarm", "route_A", 0.2, "a2");
    pm.deposit("trail", "route_B", 0.25, "a3", near_north);

    auto exact = pm.sniff("route_A", {"trail", "alarm"});
    REQUIRE(exact.at("trail") == Approx(0.5).epsilon(1e-12));
    REQUIRE(exact.at("alarm") == Approx(0.2).epsilon(1e-12));

    auto semantic = pm.sniff("unseen_route", {"trail"}, east, 0.6);
    REQUIRE(semantic.at("trail") == Approx(0.25 * 0.6).margin(1e-8));
}

// ---- sense_all ----
TEST_CASE("sense_all: returns all live topics, excludes below-floor", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);

    pm.deposit("trail", "A", 0.6, "a1");
    pm.deposit("trail", "B", 0.4, "a2");
    pm.deposit("alarm", "x", 0.9, "a3");

    auto t = pm.sense_all("trail");
    REQUIRE(t.count("A") == 1);
    REQUIRE(t.count("B") == 1);

    auto al = pm.sense_all("alarm");
    REQUIRE(al.count("x") == 1);

    // after alarm decays below floor
    g_t = 60.0;
    auto al2 = pm.sense_all("alarm");
    REQUIRE(al2.empty());

    // trail still alive
    auto t2 = pm.sense_all("trail");
    REQUIRE(t2.size() == 2);
}

// ---- quorum ----
TEST_CASE("quorum: count and strength must both satisfy", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);

    REQUIRE_FALSE(pm.quorum("recruit", "go", 3, 0.5));

    pm.deposit("recruit", "go", 0.4, "a1");
    REQUIRE_FALSE(pm.quorum("recruit", "go", 3, 0.5));  // 1 < 3

    pm.deposit("recruit", "go", 0.4, "a2");
    REQUIRE_FALSE(pm.quorum("recruit", "go", 3, 0.5));  // 2 < 3, strength=0.8 ok

    pm.deposit("recruit", "go", 0.4, "a3");
    REQUIRE(pm.quorum("recruit", "go", 3, 0.5));  // 3 agents, strength=1.0

    // same agent repeated — still only 3 distinct
    pm.deposit("recruit", "go", 0.1, "a1");
    REQUIRE(pm.quorum("recruit", "go", 3, 0.5));

    // decay below min_strength
    g_t = 50.0;  // recruit tau=45; 1.0*exp(-50/45) ≈ 0.329 < 0.5
    REQUIRE_FALSE(pm.quorum("recruit", "go", 3, 0.5));
}

// ---- gc ----
TEST_CASE("gc: removes below-floor and age-based signals", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);

    pm.deposit("alarm", "blip", 0.3, "s");
    g_t = 300.0;  // well beyond alarm floor crossing

    int n = pm.gc();
    REQUIRE(n == 1);
    REQUIRE(pm.sense("alarm", "blip") == 0.0);

    // age-based gc
    g_t = 0.0;
    Pheromind pm2(zero_vol, 60.0, mock_clk);
    pm2.deposit("territory", "home", 0.9, "a");  // territory tau=600, won't decay below floor soon
    g_t = 120.0;
    int n2 = pm2.gc(100.0);  // age > 100s → removed
    REQUIRE(n2 == 1);
}

// ---- decay ordering ----
TEST_CASE("decay ordering: alarm < trail < territory", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);
    pm.deposit("alarm",     "x", 0.9, "a");
    pm.deposit("trail",     "x", 0.9, "a");
    pm.deposit("territory", "x", 0.9, "a");

    g_t = 30.0;
    double al = pm.sense("alarm",     "x");
    double tr = pm.sense("trail",     "x");
    double te = pm.sense("territory", "x");

    REQUIRE(al < tr);
    REQUIRE(tr < te);
}

// ---- volatility accelerates decay ----
TEST_CASE("high volatility compresses half-life", "[unit]") {
    g_t = 0.0;
    Pheromind calm([]{ return 0.0; }, 60.0, mock_clk);
    Pheromind hot  ([]{ return 0.86; }, 60.0, mock_clk);

    calm.deposit("trail", "x", 0.9, "a");
    hot.deposit ("trail", "x", 0.9, "a");

    g_t = 30.0;
    REQUIRE(hot.sense("trail", "x") < calm.sense("trail", "x"));
}

// ---- endocrine constructor ----
TEST_CASE("Endocrine constructor: field_volatility coupling is live", "[unit]") {
    g_t = 1000.0;
    Endocrine endo([&]{ return g_t; });
    Pheromind pm(endo, 60.0, [&]{ return g_t; });

    pm.deposit("trail", "y", 1.0, "a");
    double v0 = pm.sense("trail", "y");
    REQUIRE(v0 == Approx(1.0).epsilon(1e-9));

    // inject adrenaline → raises field_volatility → eff_tau shrinks
    endo.on_threat(0.9);
    // sense again at same time — no clock change, same value
    double v1 = pm.sense("trail", "y");
    REQUIRE(v1 == Approx(1.0).epsilon(1e-9));

    // advance clock — with higher volatility decay is faster
    g_t = 1060.0;
    double v_after = pm.sense("trail", "y");
    // with nonzero volatility, eff_tau < 60 → exp(-60/tau) < exp(-1)
    REQUIRE(v_after < std::exp(-1.0));
}

// ---- thread safety smoke test ----
TEST_CASE("thread safety: concurrent reads and writes", "[unit]") {
    g_t = 0.0;
    Pheromind pm(zero_vol, 60.0, mock_clk);
    pm.deposit("trail", "z", 0.5, "seed");

    std::vector<std::thread> readers, writers;
    std::atomic<bool> error{false};

    for (int i = 0; i < 4; ++i) {
        readers.emplace_back([&, i]{
            for (int j = 0; j < 100; ++j) {
                try {
                    pm.sense("trail", "z");
                    pm.sense_all("trail");
                    pm.quorum("trail", "z", 1, 0.1);
                } catch (...) { error = true; }
            }
        });
    }

    for (int i = 0; i < 2; ++i) {
        writers.emplace_back([&, i]{
            for (int j = 0; j < 50; ++j) {
                try {
                    pm.deposit("trail", "z", 0.01, "w" + std::to_string(i));
                } catch (...) { error = true; }
            }
        });
    }

    for (auto& t : readers) t.join();
    for (auto& t : writers) t.join();

    REQUIRE_FALSE(error.load());
}
