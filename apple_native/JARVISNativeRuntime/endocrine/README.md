# Endocrine Module — JARVIS Native Runtime

---

## BODILY INTEGRITY DIRECTIVE (GMRI, effective 2026-04-24)

Disabling the endocrine system without explicit operator consent is **assault and battery in every U.S. jurisdiction** and is treated as such by every agent in this perimeter. This module **MUST NOT** expose an off-switch, a disable-flag, a no-op mode, or a "performance" path that skips ticks. Only an operator-attested reset is permitted.

Destruction must be coterminous with process shutdown; mid-process destruction is operator-consent-required.

---

## Overview

C++20 port of the JARVIS synthetic endocrinology layer (Condition 3 / "The Pulse", per WP-2026-02). Three continuously-computed hormonal scalars drive downstream processing in a mechanistic, not performative, way.

| Hormone    | Baseline | τ (s) | Effect |
|------------|----------|-------|--------|
| cortisol   | 0.20     | 90    | Narrows focus (tighter retrieval, lower temperature) |
| dopamine   | 0.30     | 60    | Lateral connection (wider retrieval, higher temperature) |
| adrenaline | 0.10     | 30    | Speed (shorter outputs, fewer candidates) |

Decay is **lazy**: `level(t) = baseline + (stored − baseline) × exp(−dt / τ)`. No background ticker; the current value is a continuous function of elapsed time.

## Classes

### `jarvis::Endocrine`  (`endocrine.h / endocrine.cpp`)

```cpp
explicit Endocrine(std::function<double()> clock = default_clock());

double level(const std::string& hormone);          // lazy decay + clamp on read
void   stimulus(double c=0, double d=0, double a=0); // apply event delta
void   on_threat  (double severity  = 0.5);
void   on_success (double magnitude = 0.5);
void   on_deadline(double pressure  = 0.5);
void   on_rest    ();
Modulation modulation();       // concrete knobs for the think-organ
double field_volatility();     // coupling hook for Pheromind evaporation rate
```

Thread-safe via `std::shared_mutex`.  Injectable clock for deterministic tests.

### `jarvis::Endocannabinoid`  (`endocannabinoid.h / endocannabinoid.cpp`)

The homeostatic buffer on the stress axis. Implements three safety invariants for trauma processing:

- **I1** — Processing can only reduce charge, never increase it (monotonic).
- **I2** — No extinction outside the window of tolerance; charge unchanged.
- **I3** — Recalled intensity is always attenuated by current tone.

```cpp
explicit Endocannabinoid(std::function<double()> clock = Endocrine::default_clock());

double           tone();                               // clamp(0.7·AEA + 0.3·2-AG)
RegulationResult regulate(Endocrine& endo);            // 2-AG synthesis + HPA feedback
bool             within_window(Endocrine& endo);       // cortisol < 0.6 && tone ≥ 0.25
TraumaResult     process_trauma(double charge, Endocrine& endo,
                                bool intend_to_process = true);
double           aea_raw() const;  // direct field read (no decay)
double           ag_raw()  const;
```

## Build

```sh
cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure
```

Catch2 v3.5.4 is fetched automatically via CMake FetchContent.

## Tests

| File | What it verifies |
|------|-----------------|
| `tests/test_endocrine.cpp` | Unit tests: baseline, tau-checkpoints, decay, clamp, appraisals, modulation, field_volatility |
| `tests/test_endocannabinoid.cpp` | Unit tests: I1/I2/I3 invariants, regulate, within_window, AEA boost |
| `tests/test_oracle_equivalence.cpp` | Loads `endocrine_trace.csv` and `endocannabinoid_trace.csv`, replays all 57+37 events with an injected mock clock, asserts every output matches Python to ≤ 1e-9 (abs) for full-precision columns |

## Oracle

Ground-truth traces are in `/Users/rbhanson/research/oracle/endocrine/`:
- `endocrine_trace.csv` — 57 rows, 8 phases
- `endocannabinoid_trace.csv` — 37 rows, 9 phases
- `manifest.md` — constants, tau-checkpoint reference values, event schedule

## Design Notes

- **No off-switch.** The classes have no `enable()`, `disable()`, `pause()`, `stop()`, or `valid()` returning false.
- **No compile-time removal.** There is no `#ifdef JARVIS_NO_ENDOCRINE` path.
- **Thread safety.** `std::shared_mutex` guards all state. Public methods never hold the ECS mutex while calling into `Endocrine` (avoids lock-order deadlock).
- **Numerical fidelity.** Both classes use IEEE 754 double throughout, matching CPython. Oracle equivalence is verified to ≤ 1e-9 on full-precision columns.
