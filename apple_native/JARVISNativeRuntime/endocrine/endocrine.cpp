#include "endocrine.h"

#include <cmath>
#include <mutex>
#include <stdexcept>

namespace jarvis {

// ---- static helpers ----

static double round4(double x) {
    return std::round(x * 10000.0) / 10000.0;
}

double Endocrine::clamp_(double x) noexcept {
    if (std::isnan(x)) return FLOOR;
    if (x <= FLOOR) return FLOOR;
    if (x >= CEIL) return CEIL;
    return x;
}

int Endocrine::hormone_idx_(const std::string& h) {
    if (h == "cortisol")   return 0;
    if (h == "dopamine")   return 1;
    if (h == "adrenaline") return 2;
    throw std::invalid_argument("Endocrine: unknown hormone '" + h + "'");
}

/*static*/ std::function<double()> Endocrine::default_clock() {
    return []() -> double {
        using namespace std::chrono;
        return duration<double>(steady_clock::now().time_since_epoch()).count();
    };
}

// ---- construction ----

Endocrine::Endocrine(std::function<double()> clock)
    : clock_(std::move(clock))
{
    double now = clock_();
    for (int i = 0; i < 3; ++i) {
        levels_[i] = kBaseline[i];
        t_[i]      = now;
    }
}

// ---- locked internals (caller holds unique_lock) ----

void Endocrine::settle_locked_(int idx) {
    // Decay stored level to 'now' and persist (unclamped value stored, matching Python).
    double dt  = std::max(0.0, clock_() - t_[idx]);
    double b   = kBaseline[idx];
    double val = b + (levels_[idx] - b) * std::exp(-dt / kTau[idx]);
    if (!std::isfinite(val)) val = b;
    levels_[idx] = val;
    t_[idx]      = clock_();
}

double Endocrine::level_locked_(int idx) {
    settle_locked_(idx);
    return clamp_(levels_[idx]);
}

// ---- public interface ----

double Endocrine::level(const std::string& hormone) {
    int idx = hormone_idx_(hormone);
    std::unique_lock lock(mtx_);
    return level_locked_(idx);
}

void Endocrine::stimulus(double cortisol, double dopamine, double adrenaline) {
    // Process in fixed order (cortisol, dopamine, adrenaline) matching Python.
    double deltas[3] = {cortisol, dopamine, adrenaline};
    std::unique_lock lock(mtx_);
    for (int i = 0; i < 3; ++i) {
        if (deltas[i] != 0.0 && std::isfinite(deltas[i])) {
            level_locked_(i);  // settle decay to now first (matches Python)
            levels_[i] = clamp_(levels_[i] + deltas[i]);
            // timestamp was set by level_locked_; NOT reset again here (matches Python)
        }
    }
}

void Endocrine::on_threat(double severity) {
    stimulus(severity, 0.0, 0.6 * severity);
}

void Endocrine::on_success(double magnitude) {
    stimulus(-0.3 * magnitude, magnitude, 0.0);
}

void Endocrine::on_deadline(double pressure) {
    stimulus(0.3 * pressure, 0.0, pressure);
}

void Endocrine::on_rest() {
    stimulus(-0.2, 0.0, -0.2);
}

Endocrine::Modulation Endocrine::modulation() {
    std::unique_lock lock(mtx_);
    double c = level_locked_(0);
    double d = level_locked_(1);
    double a = level_locked_(2);
    return {
        clamp_(0.5 + 0.5 * d - 0.4 * c),
        round4(clamp_(0.4 + 0.6 * d - 0.4 * c)),
        round4(clamp_(1.0 - 0.7 * a)),
        std::max(1, static_cast<int>(std::round(4.0 * (1.0 - 0.6 * a))))
    };
}

double Endocrine::field_volatility() {
    std::unique_lock lock(mtx_);
    double a = level_locked_(2);  // adrenaline
    double c = level_locked_(0);  // cortisol
    return round4(clamp_(0.6 * a + 0.4 * c));
}

} // namespace jarvis
