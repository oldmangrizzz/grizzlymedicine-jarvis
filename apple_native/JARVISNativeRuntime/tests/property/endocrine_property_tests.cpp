#include "property_test_helpers.h"

#include "endocrine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <string>

using jarvis::Endocrine;
using namespace jarvis_property;

namespace {

struct HormoneSpec {
    const char* name;
    double baseline;
    double tau;
    int index;
};

constexpr std::array<HormoneSpec, 3> kHormones{{
    {"cortisol", Endocrine::BASELINE_CORTISOL, Endocrine::TAU_CORTISOL, 0},
    {"dopamine", Endocrine::BASELINE_DOPAMINE, Endocrine::TAU_DOPAMINE, 1},
    {"adrenaline", Endocrine::BASELINE_ADRENALINE, Endocrine::TAU_ADRENALINE, 2},
}};

void apply_delta(Endocrine& endocrine, int hormone, double delta) {
    double deltas[3] = {0.0, 0.0, 0.0};
    deltas[hormone] = delta;
    endocrine.stimulus(deltas[0], deltas[1], deltas[2]);
}

double read_level(Endocrine& endocrine, const HormoneSpec& hormone) {
    return endocrine.level(hormone.name);
}

} // namespace

TEST_CASE("Endocrine hormone levels are bounded and finite", "[endocrine][property]") {
    for (const auto hormone : kHormones) {
        DYNAMIC_SECTION(hormone.name) {
            require_property(std::string("bounded finite hormone: ") + hormone.name, [hormone] {
                auto [now, clock] = make_clock();
                Endocrine endocrine(clock);
                const int operations = *rc::gen::inRange(1, 80);

                for (int i = 0; i < operations; ++i) {
                    *now += *finite_double(0.0, 600.0);
                    apply_delta(endocrine, hormone.index, *finite_double(-10'000.0, 10'000.0));
                    RC_ASSERT(valid_unit(read_level(endocrine, hormone)));
                }
            });
        }
    }
}

TEST_CASE("Endocrine decay is monotonic without stimulus", "[endocrine][property]") {
    for (const auto hormone : kHormones) {
        DYNAMIC_SECTION(hormone.name) {
            require_property(std::string("monotonic decay: ") + hormone.name, [hormone] {
                auto [now, clock] = make_clock();
                Endocrine endocrine(clock);
                const double delta = *finite_double(-hormone.baseline + 0.001,
                                                    1.0 - hormone.baseline - 0.001);
                RC_PRE(std::abs(delta) > 1e-6);
                apply_delta(endocrine, hormone.index, delta);

                double previous = read_level(endocrine, hormone);
                const bool decays_down = previous > hormone.baseline;
                const int reads = *rc::gen::inRange(2, 40);

                for (int i = 0; i < reads; ++i) {
                    *now += *finite_double(0.001, 900.0);
                    const double current = read_level(endocrine, hormone);
                    RC_ASSERT(std::isfinite(current));
                    if (decays_down) {
                        RC_ASSERT(current <= previous + 1e-12);
                        RC_ASSERT(current >= hormone.baseline - 1e-12);
                    } else {
                        RC_ASSERT(current >= previous - 1e-12);
                        RC_ASSERT(current <= hormone.baseline + 1e-12);
                    }
                    previous = current;
                }
            });
        }
    }
}

TEST_CASE("Endocrine stimulus response is monotonic in stimulus magnitude before saturation", "[endocrine][property]") {
    for (const auto hormone : kHormones) {
        DYNAMIC_SECTION(hormone.name) {
            require_property(std::string("monotonic stimulus: ") + hormone.name, [hormone] {
                auto [now, clock] = make_clock();
                (void)now;

                const double lo = *finite_double(-hormone.baseline, 1.0 - hormone.baseline);
                const double extra = *finite_double(0.0, (1.0 - hormone.baseline) - lo);
                const double hi = lo + extra;

                Endocrine lower(clock);
                Endocrine higher(clock);
                apply_delta(lower, hormone.index, lo);
                apply_delta(higher, hormone.index, hi);

                const double lower_level = read_level(lower, hormone);
                const double higher_level = read_level(higher, hormone);
                RC_ASSERT(valid_unit(lower_level));
                RC_ASSERT(valid_unit(higher_level));
                RC_ASSERT(lower_level <= higher_level + 1e-12);
            });
        }
    }
}

TEST_CASE("Endocrine field_volatility is finite and in documented unit range", "[endocrine][property]") {
    require_property("field volatility unit range", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        endocrine.stimulus(*finite_double(-10'000.0, 10'000.0),
                           *finite_double(-10'000.0, 10'000.0),
                           *finite_double(-10'000.0, 10'000.0));
        *now += *finite_double(0.0, 10'000.0);

        const double volatility = endocrine.field_volatility();
        RC_ASSERT(valid_unit(volatility));
    });
}

TEST_CASE("Endocrine public outputs never produce NaN or infinity for finite inputs", "[endocrine][property]") {
    require_property("finite endocrine outputs", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        const int operations = *rc::gen::inRange(1, 100);

        for (int i = 0; i < operations; ++i) {
            *now += *finite_double(0.0, 1000.0);
            endocrine.stimulus(*finite_double(-1.0e12, 1.0e12),
                               *finite_double(-1.0e12, 1.0e12),
                               *finite_double(-1.0e12, 1.0e12));
            const auto modulation = endocrine.modulation();
            RC_ASSERT(std::isfinite(endocrine.level("cortisol")));
            RC_ASSERT(std::isfinite(endocrine.level("dopamine")));
            RC_ASSERT(std::isfinite(endocrine.level("adrenaline")));
            RC_ASSERT(std::isfinite(endocrine.field_volatility()));
            RC_ASSERT(std::isfinite(modulation.retrieval_breadth));
            RC_ASSERT(std::isfinite(modulation.temperature));
            RC_ASSERT(std::isfinite(modulation.length_bias));
            RC_ASSERT(modulation.candidates >= 1);
        }
    });
}

TEST_CASE("Endocrine repeated clock ticks remain stable without unbounded growth", "[endocrine][property]") {
    require_property("stable repeated ticks", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        endocrine.stimulus(*finite_double(-10'000.0, 10'000.0),
                           *finite_double(-10'000.0, 10'000.0),
                           *finite_double(-10'000.0, 10'000.0));

        const int ticks = *rc::gen::inRange(50, 500);
        for (int i = 0; i < ticks; ++i) {
            *now += *finite_double(0.0, 120.0);
            for (const auto hormone : kHormones) {
                RC_ASSERT(valid_unit(read_level(endocrine, hormone)));
            }
            RC_ASSERT(valid_unit(endocrine.field_volatility()));
        }
    });
}
