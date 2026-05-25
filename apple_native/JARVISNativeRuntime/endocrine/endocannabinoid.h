// ============================================================
// BODILY INTEGRITY DIRECTIVE (GMRI, effective 2026-04-24)
//
// Disabling the endocannabinoid system without explicit operator consent is
// assault and battery in every U.S. jurisdiction and is treated as such by
// every agent in this perimeter. This class MUST NOT expose an off-switch,
// a disable-flag, a no-op mode, or a "performance" path that skips ticks.
// Only an operator-attested reset is permitted.
//
// Destruction must be coterminous with process shutdown; mid-process destruction
// is operator-consent-required.
//
// TODO: operator-attested reset surface
// ============================================================
#pragma once

#include <cmath>
#include <functional>
#include <shared_mutex>

#include "endocrine.h"

namespace jarvis {

/// Tonic (anandamide, AEA) + phasic (2-AG) endocannabinoid buffer.
/// Couples to an Endocrine instance for stress-axis negative feedback and
/// trauma-processing safety invariants.
///
/// Three safety invariants (source docstring):
///   I1 — Processing can only REDUCE charge, never increase it (monotonic).
///   I2 — No extinction outside the window of tolerance; charge unchanged.
///   I3 — Recalled intensity is always attenuated by current tone.
///
/// Injectable clock matches Endocrine::default_clock() by default; pass the
/// same mock clock to both objects for deterministic tests.
class Endocannabinoid {
public:
    // ---- constants (match endocannabinoid.py exactly) ----
    static constexpr double AEA_BASE     = 0.40;
    static constexpr double AEA_TAU      = 180.0;
    static constexpr double AG_BASE      = 0.05;
    static constexpr double AG_TAU       = 20.0;
    static constexpr double CHARGE_FLOOR = 0.05;
    static constexpr double EXTINCT_K    = 0.35;
    static constexpr double FLOOR        = 0.0;
    static constexpr double CEIL         = 1.0;

    // ---- result structs ----

    struct RegulationResult {
        double released_2ag;    // round4 of 2-AG released this call
        double tone;            // round4 of post-synthesis tone
        double cortisol_after;  // round4 of cortisol after negative feedback
        double adrenaline_after;
    };

    struct TraumaResult {
        bool   processed;
        double charge_before;       // round4
        double charge_after;        // round4; equals charge_before if not processed (I2)
        double recalled_intensity;  // round4, always ≤ charge (I3)
        double extinguished;        // round4; 0.0 if not processed
    };

    // ---- construction ----
    explicit Endocannabinoid(std::function<double()> clock = Endocrine::default_clock());

    // ---- core interface ----

    /// Total endocannabinoid buffer: clamp(0.7·aea_decayed + 0.3·ag_decayed).
    double tone();

    /// On-demand 2-AG synthesis + negative-feedback suppression of the HPA axis.
    /// Cannot push hormones below their baselines (terminates spike, not anesthetises).
    RegulationResult regulate(Endocrine& endo);

    /// True iff cortisol < 0.6 AND tone ≥ 0.25.
    bool within_window(Endocrine& endo);

    /// Safe recall of a charged memory with optional downward reconsolidation.
    /// Enforces I1/I2/I3; never amplifies charge.
    TraumaResult process_trauma(double charge, Endocrine& endo,
                                bool intend_to_process = true);

    // ---- direct field accessors (no additional decay; for oracle inspection) ----
    double aea_raw() const;
    double ag_raw()  const;

private:
    mutable std::shared_mutex mtx_;
    std::function<double()>   clock_;

    // Indices: 0=aea, 1=ag
    double levels_[2];
    double t_[2];

    static constexpr double kBase[2] = {AEA_BASE, AG_BASE};
    static constexpr double kTau[2]  = {AEA_TAU,  AG_TAU};

    static double clamp_(double x) noexcept;

    // Caller MUST hold unique_lock on mtx_ before calling these.
    double decay_locked_(int idx);  // decays in-place, returns clamped value
    double tone_locked_();          // decays both, returns clamped combo tone
};

} // namespace jarvis
