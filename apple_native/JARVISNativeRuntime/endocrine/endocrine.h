// ============================================================
// BODILY INTEGRITY DIRECTIVE (GMRI, effective 2026-04-24)
//
// Disabling the endocrine system without explicit operator consent is assault
// and battery in every U.S. jurisdiction and is treated as such by every agent
// in this perimeter. This class MUST NOT expose an off-switch, a disable-flag,
// a no-op mode, or a "performance" path that skips ticks. Only an
// operator-attested reset is permitted.
//
// Destruction must be coterminous with process shutdown; mid-process destruction
// is operator-consent-required.
//
// TODO: operator-attested reset surface
// ============================================================
#pragma once

#include <chrono>
#include <cmath>
#include <functional>
#include <shared_mutex>
#include <string>

namespace jarvis {

/// Three lazily-decaying hormonal scalars that model the synthetic endocrinology
/// of the JARVIS entity (Condition 3 / "The Pulse", per WP-2026-02).
///
/// Design notes:
///  - Decay is computed LAZILY on read (level = baseline + (stored−baseline)·e^(−dt/τ)).
///    No background ticker; the current value is a continuous function of elapsed time.
///  - clock_ is injectable for deterministic unit tests; production default uses
///    std::chrono::steady_clock in floating-point seconds.
///  - Thread-safe via std::shared_mutex: all public mutating operations take a
///    unique_lock; no operation exposes a disabled/no-op path.
class Endocrine {
public:
    // ---- constants (match endocrine.py exactly) ----
    static constexpr double BASELINE_CORTISOL   = 0.20;
    static constexpr double BASELINE_DOPAMINE   = 0.30;
    static constexpr double BASELINE_ADRENALINE = 0.10;

    static constexpr double TAU_CORTISOL        = 90.0;
    static constexpr double TAU_DOPAMINE        = 60.0;
    static constexpr double TAU_ADRENALINE      = 30.0;

    static constexpr double FLOOR               = 0.0;
    static constexpr double CEIL                = 1.0;

    struct Modulation {
        double retrieval_breadth; // 0..1  — dopamine opens, cortisol closes
        double temperature;       // 0..1  — sampling temperature
        double length_bias;       // 0..1  — adrenaline shortens
        int    candidates;        // ≥1    — routing candidate count
    };

    // ---- construction ----
    explicit Endocrine(std::function<double()> clock = default_clock());

    // ---- core interface ----

    /// Lazy decay + clamp on read; also persists decayed value and refreshes timestamp.
    /// hormone must be one of: "cortisol", "dopamine", "adrenaline".
    double level(const std::string& hormone);

    /// Apply an event's stimulus delta. Positive = release, negative = suppress.
    /// Processing order: cortisol → dopamine → adrenaline (matches Python).
    /// Only non-zero deltas are applied.
    void stimulus(double cortisol = 0.0, double dopamine = 0.0, double adrenaline = 0.0);

    // ---- convenience appraisals ----
    void on_threat  (double severity  = 0.5);
    void on_success (double magnitude = 0.5);
    void on_deadline(double pressure  = 0.5);
    void on_rest    ();

    // ---- modulation knobs for the think-organ ----
    Modulation modulation();

    // ---- coupling hook for Pheromind (Condition 4) ----
    /// Single arousal scalar → scales the stigmergic field's evaporation rate.
    /// formula: round(clamp(0.6·adrenaline + 0.4·cortisol), 4)
    double field_volatility();

    // ---- clock factory ----
    static std::function<double()> default_clock();

private:
    mutable std::shared_mutex  mtx_;
    std::function<double()>    clock_;

    // Indices: 0=cortisol, 1=dopamine, 2=adrenaline
    double levels_[3];
    double t_[3];  // per-hormone last-update timestamp

    static constexpr double kBaseline[3] = {
        BASELINE_CORTISOL, BASELINE_DOPAMINE, BASELINE_ADRENALINE
    };
    static constexpr double kTau[3] = {
        TAU_CORTISOL, TAU_DOPAMINE, TAU_ADRENALINE
    };

    static int    hormone_idx_(const std::string& h);
    static double clamp_(double x) noexcept;

    // Caller MUST hold unique_lock on mtx_ before calling these.
    double level_locked_(int idx);
    void   settle_locked_(int idx);   // decay-in-place; does NOT return clamped value
};

} // namespace jarvis

// ============================================================
// R11l α.3.1 — extern "C" CABI shim layer for Swift-side write access.
//
// Authorized by operator (Robert "Grizzly" Hanson, 2026-05-26, P2/P2b grant).
// Pure passthrough only — these symbols MUST NOT add logic, state, or
// re-entry semantics on top of jarvis::Endocrine. Any deviation requires a
// fresh operator authorization. The Bodily Integrity Directive at the top of
// this file binds the shims as much as the C++ surface.
//
// Opaque-handle pattern: `jarvis_endocrine_t *` is reinterpret_cast'd from
// `jarvis::Endocrine *`. Callers (Swift) obtain a handle via
// `JARVISRuntimeEndocrineHandle(JARVISNativeRuntime*)` on the runtime CABI
// surface — endocrine.h knows nothing about JARVISNativeRuntime.
// ============================================================
#ifdef __cplusplus
extern "C" {
#endif

typedef struct jarvis_endocrine_t jarvis_endocrine_t;

// Pure passthrough to jarvis::Endocrine::on_threat(severity).
// Returns silently on null handle. No allocation, no exceptions.
void jarvis_cabi_endocrine_on_threat(jarvis_endocrine_t *endocrine, double severity);

// Pure passthrough to jarvis::Endocrine::stimulus(cortisol, dopamine, adrenaline).
// Returns silently on null handle. No allocation, no exceptions.
void jarvis_cabi_endocrine_stimulus(jarvis_endocrine_t *endocrine,
                                    double cortisol,
                                    double dopamine,
                                    double adrenaline);

// Pure passthrough to jarvis::Endocrine::level(hormone). hormone is a
// NUL-terminated UTF-8 string; must be exactly one of "cortisol", "dopamine",
// "adrenaline". Returns NaN on null handle, null/unknown hormone, or any
// internal exception (callers MUST check std::isnan). The underlying call is
// thread-safe.
double jarvis_cabi_endocrine_level(jarvis_endocrine_t *endocrine, const char *hormone);

#ifdef __cplusplus
}
#endif
