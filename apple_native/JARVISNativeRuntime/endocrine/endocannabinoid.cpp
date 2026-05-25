#include "endocannabinoid.h"

#include <cmath>

namespace jarvis {

// ---- static helpers ----

static double ecs_round4(double x) {
    return std::round(x * 10000.0) / 10000.0;
}

double Endocannabinoid::clamp_(double x) noexcept {
    return x < FLOOR ? FLOOR : (x > CEIL ? CEIL : x);
}

// ---- construction ----

Endocannabinoid::Endocannabinoid(std::function<double()> clock)
    : clock_(std::move(clock))
{
    double now = clock_();
    levels_[0] = AEA_BASE;
    levels_[1] = AG_BASE;
    t_[0] = t_[1] = now;
}

// ---- locked internals (caller holds unique_lock) ----

double Endocannabinoid::decay_locked_(int idx) {
    // Matches Python _decay: store unclamped decayed value, update timestamp,
    // return clamped.
    double dt  = std::max(0.0, clock_() - t_[idx]);
    double b   = kBase[idx];
    double val = b + (levels_[idx] - b) * std::exp(-dt / kTau[idx]);
    levels_[idx] = val;
    t_[idx]      = clock_();
    return clamp_(val);
}

double Endocannabinoid::tone_locked_() {
    double a = decay_locked_(0);  // aea
    double g = decay_locked_(1);  // ag
    return clamp_(0.7 * a + 0.3 * g);
}

// ---- public interface ----

double Endocannabinoid::tone() {
    std::unique_lock lock(mtx_);
    return tone_locked_();
}

double Endocannabinoid::aea_raw() const {
    std::shared_lock lock(mtx_);
    return levels_[0];
}

double Endocannabinoid::ag_raw() const {
    std::shared_lock lock(mtx_);
    return levels_[1];
}

Endocannabinoid::RegulationResult Endocannabinoid::regulate(Endocrine& endo) {
    // Step 1: read endocrine state — no ECS lock held to avoid lock-ordering deadlock.
    double c = endo.level("cortisol");
    double a = endo.level("adrenaline");
    double stress = std::max(c, a);

    // Steps 2–5: ECS state update under ECS lock.
    double release, ret_tone;
    {
        std::unique_lock lock(mtx_);

        // step 2: initial tone (decays aea and ag, updates timestamps)
        double t0 = tone_locked_();
        release = std::max(0.0, stress - t0);

        // step 3: _decay ag (dt=0 since tone_locked_ just set t_[1]; no-op in value)
        decay_locked_(1);

        // step 4: synthesise 2-AG
        levels_[1] = clamp_(levels_[1] + 0.8 * release);

        // step 5: tone with updated ag
        ret_tone = tone_locked_();   // used for damp AND return value
    }

    // Step 6: apply negative feedback — no ECS lock (calls into Endocrine).
    double damp = 0.6 * ret_tone;
    double c_delta = (c > 0.20) ? -damp * (c - 0.20) : 0.0;
    double a_delta = (a > 0.10) ? -damp * (a - 0.10) : 0.0;
    endo.stimulus(c_delta, 0.0, a_delta);

    // Step 7: final endocrine reads for return dict (matches Python's return stmt).
    double c_after = endo.level("cortisol");
    double a_after = endo.level("adrenaline");

    return {
        ecs_round4(release),
        ecs_round4(ret_tone),
        ecs_round4(c_after),
        ecs_round4(a_after)
    };
}

bool Endocannabinoid::within_window(Endocrine& endo) {
    // Matches Python: cortisol check first, then tone.
    // Read cortisol without ECS lock, then acquire ECS lock for tone.
    double c = endo.level("cortisol");
    std::unique_lock lock(mtx_);
    double t = tone_locked_();
    return c < 0.6 && t >= 0.25;
}

Endocannabinoid::TraumaResult Endocannabinoid::process_trauma(double charge, Endocrine& endo,
                                              bool intend_to_process) {
    charge = clamp_(charge);

    // Get tone (decays aea/ag to 'now'), used for recalled_intensity and extinction.
    double t;
    {
        std::unique_lock lock(mtx_);
        t = tone_locked_();
    }

    double recalled = ecs_round4(clamp_(charge * (1.0 - 0.7 * t)));

    // Check window — also calls endo.level("cortisol") which updates its timestamp.
    bool in_window = within_window(endo);

    if (!intend_to_process || !in_window) {
        // I2: charge returned unchanged, never amplified.
        return {false, ecs_round4(charge), ecs_round4(charge), recalled, 0.0};
    }

    // Extinction step (I1).
    double removable   = EXTINCT_K * t * std::max(0.0, charge - CHARGE_FLOOR);
    double new_charge  = std::max(CHARGE_FLOOR, charge - removable);
    new_charge         = std::min(new_charge, charge);  // I1 hard guard

    // Safe exposure mildly boosts tonic buffer (matches Python).
    {
        std::unique_lock lock(mtx_);
        decay_locked_(0);  // aea: dt≈0 (tone_locked_ just ran), effectively no-op
        levels_[0] = clamp_(levels_[0] + 0.05);
    }

    return {
        true,
        ecs_round4(charge),
        ecs_round4(new_charge),
        recalled,
        ecs_round4(charge - new_charge)
    };
}

} // namespace jarvis
