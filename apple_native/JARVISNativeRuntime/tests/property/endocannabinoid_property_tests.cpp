#include "property_test_helpers.h"

#include "endocannabinoid.h"
#include "endocrine.h"

#include <cmath>

using jarvis::Endocannabinoid;
using jarvis::Endocrine;
using namespace jarvis_property;

TEST_CASE("Endocannabinoid AEA and 2-AG fields are bounded and finite", "[endocannabinoid][property]") {
    require_property("aea and 2ag bounded", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        Endocannabinoid ecs(clock);
        const int operations = *rc::gen::inRange(1, 120);

        for (int i = 0; i < operations; ++i) {
            *now += *finite_double(0.0, 300.0);
            endocrine.stimulus(*finite_double(-1.0, 1.0), 0.0, *finite_double(-1.0, 1.0));
            if (*rc::gen::arbitrary<bool>()) {
                ecs.regulate(endocrine);
            } else {
                ecs.process_trauma(*finite_double(-10.0, 10.0), endocrine,
                                   *rc::gen::arbitrary<bool>());
            }

            const double aea = ecs.aea_raw();
            const double ag = ecs.ag_raw();
            const double tone = ecs.tone();
            RC_ASSERT(valid_unit(aea));
            RC_ASSERT(valid_unit(ag));
            RC_ASSERT(valid_unit(tone));
        }
    });
}

TEST_CASE("Endocannabinoid regulate outputs are finite and bounded", "[endocannabinoid][property]") {
    require_property("regulate finite bounded", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        Endocannabinoid ecs(clock);

        endocrine.stimulus(*finite_double(-10'000.0, 10'000.0), 0.0,
                           *finite_double(-10'000.0, 10'000.0));
        *now += *finite_double(0.0, 10'000.0);

        const auto before_cortisol = endocrine.level("cortisol");
        const auto before_adrenaline = endocrine.level("adrenaline");
        const auto result = ecs.regulate(endocrine);

        RC_ASSERT(valid_unit(result.released_2ag));
        RC_ASSERT(valid_unit(result.tone));
        RC_ASSERT(valid_unit(result.cortisol_after));
        RC_ASSERT(valid_unit(result.adrenaline_after));
        RC_ASSERT(result.cortisol_after <= before_cortisol + 1e-4);
        RC_ASSERT(result.adrenaline_after <= before_adrenaline + 1e-4);
    });
}

TEST_CASE("Endocannabinoid within_window matches cortisol and tone truth table", "[endocannabinoid][property]") {
    require_property("within window truth table", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        Endocannabinoid ecs(clock);

        const int warmup = *rc::gen::inRange(0, 20);
        for (int i = 0; i < warmup; ++i) {
            *now += *finite_double(0.0, 60.0);
            endocrine.stimulus(*finite_double(-0.5, 1.0), 0.0, *finite_double(-0.5, 1.0));
            ecs.regulate(endocrine);
        }

        const double target_cortisol = *finite_double(0.0, 1.0);
        const double current_cortisol = endocrine.level("cortisol");
        endocrine.stimulus(target_cortisol - current_cortisol, 0.0, 0.0);

        const double cortisol = endocrine.level("cortisol");
        const double tone = ecs.tone();
        const bool expected = (cortisol < 0.6) && (tone >= 0.25);
        const bool actual = ecs.within_window(endocrine);
        RC_ASSERT(actual == expected);
    });
}

TEST_CASE("Endocannabinoid process_trauma result agrees with within_window and intent", "[endocannabinoid][property]") {
    require_property("process trauma truth table", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        Endocannabinoid ecs(clock);

        const int warmup = *rc::gen::inRange(0, 10);
        for (int i = 0; i < warmup; ++i) {
            *now += *finite_double(0.0, 30.0);
            endocrine.stimulus(*finite_double(-0.2, 0.8), 0.0, *finite_double(-0.1, 0.9));
            ecs.regulate(endocrine);
        }

        const double target_cortisol = *finite_double(0.0, 1.0);
        endocrine.stimulus(target_cortisol - endocrine.level("cortisol"), 0.0, 0.0);
        const bool intend = *rc::gen::arbitrary<bool>();
        const double charge = *finite_double(0.0, 1.0);
        const bool in_window = ecs.within_window(endocrine);

        const auto result = ecs.process_trauma(charge, endocrine, intend);
        RC_ASSERT(result.processed == (intend && in_window));
        RC_ASSERT(valid_unit(result.charge_before));
        RC_ASSERT(valid_unit(result.charge_after));
        RC_ASSERT(valid_unit(result.recalled_intensity));
        RC_ASSERT(valid_unit(result.extinguished));
        RC_ASSERT(result.recalled_intensity <= result.charge_before + 1e-9);
        RC_ASSERT(result.charge_after <= result.charge_before + 1e-9);
        if (!intend || !in_window) {
            RC_ASSERT(near(result.charge_after, result.charge_before, 1e-9));
            RC_ASSERT(near(result.extinguished, 0.0, 1e-9));
        }
    });
}

TEST_CASE("Endocannabinoid documented idempotent observations are stable at one timestamp", "[endocannabinoid][property]") {
    require_property("same timestamp idempotency", [] {
        auto [now, clock] = make_clock();
        Endocrine endocrine(clock);
        Endocannabinoid ecs(clock);

        endocrine.stimulus(*finite_double(-1.0, 1.0), 0.0, *finite_double(-1.0, 1.0));
        ecs.regulate(endocrine);
        *now += *finite_double(0.0, 100.0);

        const double tone1 = ecs.tone();
        const double tone2 = ecs.tone();
        const bool window1 = ecs.within_window(endocrine);
        const bool window2 = ecs.within_window(endocrine);
        RC_ASSERT(near(tone1, tone2, 1e-12));
        RC_ASSERT(window1 == window2);

        const double charge = *finite_double(0.0, 1.0);
        const auto no_intent = ecs.process_trauma(charge, endocrine, false);
        RC_ASSERT(!no_intent.processed);
        RC_ASSERT(near(no_intent.charge_after, no_intent.charge_before, 1e-9));
    });
}
