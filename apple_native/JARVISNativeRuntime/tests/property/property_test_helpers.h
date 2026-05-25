#pragma once

#include <rapidcheck.h>

#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstdint>
#include <functional>
#include <limits>
#include <memory>
#include <string>
#include <utility>

namespace jarvis_property {

inline auto make_clock(double t0 = 0.0)
    -> std::pair<std::shared_ptr<double>, std::function<double()>> {
    auto now = std::make_shared<double>(t0);
    return {now, [now]() -> double { return *now; }};
}

inline rc::Gen<double> finite_double(double lo, double hi) {
    return rc::gen::map(rc::gen::inRange<std::int32_t>(0, 2'000'000'000),
        [lo, hi](std::int32_t raw) -> double {
            return lo + (hi - lo) * (static_cast<double>(raw) / 2'000'000'000.0);
        });
}

inline void require_property(const std::string& name, const std::function<void()>& property) {
    REQUIRE(rc::check(name, property));
}

inline bool valid_unit(double x) {
    return std::isfinite(x) && x >= 0.0 && x <= 1.0;
}

inline bool near(double a, double b, double eps = 1e-9) {
    return std::abs(a - b) <= eps;
}

} // namespace jarvis_property
