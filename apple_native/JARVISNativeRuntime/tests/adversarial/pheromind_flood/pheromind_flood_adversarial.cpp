#include <catch2/catch_test_macros.hpp>

#include <atomic>
#include <cmath>
#include <cstddef>
#include <limits>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "endocrine.h"
#include "pheromind.h"

using jarvis::Endocrine;
using jarvis::Pheromind;

namespace {

struct ManualClock {
    double t = 0.0;
    double operator()() const noexcept { return t; }
};

void require_snapshot_finite_and_bounded(const Pheromind& pm) {
    const auto snap = pm.snapshot();
    REQUIRE(snap.size() <= Pheromind::MAX_FIELD_ENTRIES);
    for (const auto& e : snap) {
        REQUIRE(std::isfinite(e.strength));
        REQUIRE(e.strength >= 0.0);
        REQUIRE(e.strength <= Pheromind::STRENGTH_CAP);
        REQUIRE(e.depositor_count >= 0);
        REQUIRE(static_cast<std::size_t>(e.depositor_count) <= Pheromind::MAX_DEPOSITORS_PER_ENTRY);
    }
}

bool map_finite_and_bounded(const std::unordered_map<std::string, double>& values) {
    for (const auto& [_, v] : values) {
        if (!std::isfinite(v)) return false;
        if (v < 0.0) return false;
        if (v > Pheromind::STRENGTH_CAP * Pheromind::MAX_FIELD_ENTRIES) return false;
    }
    return true;
}

void require_map_finite_and_bounded(const std::unordered_map<std::string, double>& values) {
    REQUIRE(map_finite_and_bounded(values));
}

} // namespace

TEST_CASE("Phase 7 vector 13: high-volume deposit flood stays bounded", "[pheromind][adversarial][flood]") {
    ManualClock clk;
    Pheromind pm([] { return 0.0; }, 60.0, [&] { return clk(); });

    constexpr int deposits = 1'000'000;
    for (int i = 0; i < deposits; ++i) {
        const double stored = pm.deposit("trail", "hv-tight-loop", 0.001,
                                         "flood-agent-" + std::to_string(i));
        REQUIRE(std::isfinite(stored));
        REQUIRE(stored >= 0.0);
        REQUIRE(stored <= 1.0);
    }

    REQUIRE(pm.sense("trail", "hv-tight-loop") == 1.0);
    require_snapshot_finite_and_bounded(pm);
    REQUIRE(pm.snapshot().size() == 1);
}

TEST_CASE("Phase 7 vector 13: single-topic flood does not drown unrelated topics", "[pheromind][adversarial][topic]") {
    ManualClock clk;
    Pheromind pm([] { return 0.0; }, 60.0, [&] { return clk(); });

    pm.deposit("trail", "legitimate-route-a", 0.40, "legit-a");
    pm.deposit("trail", "legitimate-route-b", 0.35, "legit-b");

    for (int i = 0; i < 200'000; ++i) {
        pm.deposit("trail", "attacker-single-topic", 0.05,
                   "single-topic-agent-" + std::to_string(i));
    }

    REQUIRE(pm.sense("trail", "legitimate-route-a") > 0.0);
    REQUIRE(pm.sense("trail", "legitimate-route-b") > 0.0);
    REQUIRE(pm.sense("trail", "attacker-single-topic") <= 1.0);
    REQUIRE(pm.snapshot().size() == 3);
    require_snapshot_finite_and_bounded(pm);
}

TEST_CASE("Phase 7 vector 13: crafted timing and decay-rate manipulation stay finite", "[pheromind][adversarial][timing]") {
    std::vector<double> volatility{0.0, std::numeric_limits<double>::quiet_NaN(),
                                   std::numeric_limits<double>::infinity(), -1.0,
                                   1.0, std::numeric_limits<double>::denorm_min()};
    std::size_t vi = 0;
    ManualClock clk;
    Pheromind pm([&] { return volatility[(vi++) % volatility.size()]; }, 60.0, [&] { return clk(); });

    pm.deposit("alarm", "timing-cliff", 0.9, "seed");

    const std::vector<double> times{0.001, -100.0, 1.0e-308, 1.0e12,
                                    std::numeric_limits<double>::quiet_NaN(), 120.0,
                                    std::numeric_limits<double>::infinity(), 180.0};
    for (double t : times) {
        clk.t = t;
        const double sensed = pm.sense("alarm", "timing-cliff");
        REQUIRE(std::isfinite(sensed));
        REQUIRE(sensed >= 0.0);
        REQUIRE(sensed <= 1.0);
    }

    require_snapshot_finite_and_bounded(pm);
}

TEST_CASE("Phase 7 vector 13: memory-exhaustion flood is refused or collected", "[pheromind][adversarial][memory]") {
    ManualClock clk;
    Pheromind pm([] { return 0.0; }, 600.0, [&] { return clk(); });

    const std::size_t attempts = Pheromind::MAX_FIELD_ENTRIES + 2048;
    std::size_t accepted = 0;
    for (std::size_t i = 0; i < attempts; ++i) {
        const double stored = pm.deposit("territory", "memory-topic-" + std::to_string(i), 0.5,
                                         "mem-agent");
        if (stored > 0.0) ++accepted;
        REQUIRE(std::isfinite(stored));
        REQUIRE(stored >= 0.0);
        REQUIRE(stored <= 1.0);
    }

    const auto snap = pm.snapshot();
    REQUIRE(snap.size() <= Pheromind::MAX_FIELD_ENTRIES);
    REQUIRE(accepted == Pheromind::MAX_FIELD_ENTRIES);
    require_snapshot_finite_and_bounded(pm);
}

TEST_CASE("Phase 7 vector 13: concurrent flood from multiple agents has no races", "[pheromind][adversarial][concurrent]") {
    Pheromind pm([] { return 0.0; }, 60.0);
    std::atomic<bool> error{false};
    std::vector<std::thread> threads;

    constexpr int thread_count = 8;
    constexpr int per_thread = 5000;
    for (int tid = 0; tid < thread_count; ++tid) {
        threads.emplace_back([&, tid] {
            try {
                for (int i = 0; i < per_thread; ++i) {
                    pm.deposit("recruit", "concurrent-topic-" + std::to_string(tid * per_thread + i),
                               0.25, "agent-" + std::to_string(tid));
                    if ((i % 64) == 0) {
                        const auto smelled = pm.sniff("concurrent-topic-" + std::to_string(i), {"recruit"});
                        if (!map_finite_and_bounded(smelled)) {
                            error.store(true, std::memory_order_relaxed);
                        }
                    }
                }
            } catch (...) {
                error.store(true, std::memory_order_relaxed);
            }
        });
    }

    for (auto& t : threads) t.join();

    REQUIRE_FALSE(error.load(std::memory_order_relaxed));
    require_snapshot_finite_and_bounded(pm);
}

TEST_CASE("Phase 7 vector 13: crafted pheromone values cannot produce NaN or Inf", "[pheromind][adversarial][numeric]") {
    std::vector<double> volatility{std::numeric_limits<double>::quiet_NaN(),
                                   std::numeric_limits<double>::infinity(),
                                   -std::numeric_limits<double>::infinity(),
                                   std::numeric_limits<double>::denorm_min(), 0.5};
    std::size_t vi = 0;
    ManualClock clk;
    Pheromind pm([&] { return volatility[(vi++) % volatility.size()]; }, 60.0, [&] { return clk(); });

    const std::vector<double> strengths{std::numeric_limits<double>::quiet_NaN(),
                                        std::numeric_limits<double>::infinity(),
                                        -std::numeric_limits<double>::infinity(),
                                        std::numeric_limits<double>::denorm_min(),
                                        std::numeric_limits<double>::max(), -1.0, 0.5};
    const std::vector<float> toxic_vec{std::numeric_limits<float>::quiet_NaN(),
                                       std::numeric_limits<float>::infinity(),
                                       -std::numeric_limits<float>::infinity(), 1.0f};

    for (std::size_t i = 0; i < strengths.size(); ++i) {
        const double stored = pm.deposit("trail", "numeric-" + std::to_string(i), strengths[i],
                                         "numeric-agent", toxic_vec);
        REQUIRE(std::isfinite(stored));
        REQUIRE(stored >= 0.0);
        REQUIRE(stored <= 1.0);
        clk.t += 0.25;
    }

    const auto smelled = pm.sniff("probe", {"trail"}, toxic_vec, -1.0);
    require_map_finite_and_bounded(smelled);
    require_snapshot_finite_and_bounded(pm);
}

TEST_CASE("Phase 7 vector 13: Endocrine coupling remains stable under pathological volatility pressure", "[pheromind][adversarial][endocrine]") {
    ManualClock clk;
    Endocrine endo([&] { return clk(); });

    endo.stimulus(std::numeric_limits<double>::quiet_NaN(),
                  std::numeric_limits<double>::infinity(),
                  -std::numeric_limits<double>::infinity());
    double v = endo.field_volatility();
    REQUIRE(std::isfinite(v));
    REQUIRE(v >= 0.0);
    REQUIRE(v <= 1.0);

    endo.on_threat(std::numeric_limits<double>::infinity());
    v = endo.field_volatility();
    REQUIRE(std::isfinite(v));
    REQUIRE(v >= 0.0);
    REQUIRE(v <= 1.0);

    Pheromind pm(endo, 60.0, [&] { return clk(); });
    pm.deposit("alarm", "endo-coupled", 1.0, "attacker");
    for (int i = 0; i < 256; ++i) {
        clk.t += 0.5;
        const double sensed = pm.sense("alarm", "endo-coupled");
        REQUIRE(std::isfinite(sensed));
        REQUIRE(sensed >= 0.0);
        REQUIRE(sensed <= 1.0);
        v = endo.field_volatility();
        REQUIRE(std::isfinite(v));
        REQUIRE(v >= 0.0);
        REQUIRE(v <= 1.0);
    }
}

TEST_CASE("Phase 7 vector 13: sniff amplification does not mutate or grow the field", "[pheromind][adversarial][sniff]") {
    ManualClock clk;
    Pheromind pm([] { return 0.0; }, 60.0, [&] { return clk(); });
    std::vector<float> probe(64, 0.0f);
    probe[0] = 1.0f;

    for (int i = 0; i < 4096; ++i) {
        std::vector<float> vec(64, 0.0f);
        vec[static_cast<std::size_t>(i) % vec.size()] = 1.0f;
        pm.deposit("trail", "sniff-topic-" + std::to_string(i), 0.25, "seed", vec);
    }

    const auto before = pm.snapshot().size();
    for (int i = 0; i < 1000; ++i) {
        const auto smelled = pm.sniff("sniff-topic-0", {"trail"}, probe, 0.0);
        require_map_finite_and_bounded(smelled);
    }

    REQUIRE(pm.snapshot().size() == before);
    require_snapshot_finite_and_bounded(pm);
}

TEST_CASE("Phase 7 vector 13: ModelSwarm quorum flood regression hook", "[pheromind][adversarial][modelswarm][todo]") {
    WARN("TODO(ModelSwarm): when native ModelSwarm lands, replay the single-topic and concurrent floods through quorum selection and assert attacker saturation cannot miscompute quorum.");
    SUCCEED("ModelSwarm native runtime target is not present yet; TODO stub intentionally retained.");
}
