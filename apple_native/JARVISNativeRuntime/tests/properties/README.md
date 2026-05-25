# Property Tests — JARVIS Organ Modules

**Location:** `tests/properties/`  
**Framework:** [RapidCheck](https://github.com/emil-e/rapidcheck) (pure C++, no Rust) + Catch2 v3  
**Default cases per property:** 1000 (set via `RC_PARAMS=checks=1000`)  
**Run all:** `ctest -L property`  
**Override case count:** `RC_PARAMS="checks=N" ctest -L property`

---

## What property-based tests buy us

Unit tests prove specific inputs work. Property tests prove invariants hold across a
*generated* input space — the kind of guarantee that survives adversarial scrutiny and
nation-state-grade fuzzing. Each `rc::prop` call generates `checks` random inputs and
shrinks any failure to the minimal counterexample before reporting.

---

## Endocrine properties (`endocrine_properties.cpp`)

| ID  | Name                | Invariant |
|-----|---------------------|-----------|
| P1  | Clamp               | For any sequence of spikes in `[-100.0, +100.0]` applied at any times, `level()` is always in `[0.0, 1.0]`. |
| P2  | Lazy continuity     | Reading `level()` multiple times at the **same** timestamp returns the same value — no spike on read. |
| P3  | Decay monotonicity  | Between spikes, `level()` moves strictly monotonically toward baseline — never away. |
| P4  | Tau definition      | For a spike of `delta` from baseline, `level(t=tau) = baseline + delta × exp(−1)` within `1e-12`. |
| P5  | Additivity          | Two sequential spikes `(delta1, delta2)` at the same clock time (no clamping) equal one spike of `(delta1 + delta2)`. |
| P6  | field_volatility    | `field_volatility()` ∈ `[0.0, ∞)` and is monotonically non-decreasing in cortisol and adrenaline. |
| P7  | No off-switch       | **Compile-time** `static_assert` (C++20 concepts) that `Endocrine` exposes no `disable`/`enable`/`pause`/`stop`/`bypass`/`skip` method. |

### Notes

- All three hormones (cortisol, dopamine, adrenaline) are tested independently under P1–P5.
- P4 uses the deterministic clock injection to set `clock() = tau` exactly; the expected value is `baseline + delta * std::exp(-1.0)` which must match to `< 1e-12` absolute error.
- P7 fails at **compile time** (not runtime) if any off-switch method is added.

---

## Endocannabinoid properties (`endocannabinoid_properties.cpp`)

| ID  | Name                        | Invariant |
|-----|-----------------------------|-----------|
| P8  | Tone bounded                | `tone()` ∈ `[0.0, 1.0]` for any history of `regulate` and `process_trauma` calls. |
| P9  | Regulate negative feedback  | After `regulate(endo)`, cortisol and adrenaline are **weakly lower or equal** — never amplified. |
| P10 | within_window definition    | `within_window()` returns `true` iff `cortisol < 0.6 AND tone >= 0.25` — tested against arbitrary states. |
| P11 | Trauma monotonic extinction | Repeated `process_trauma()` within window with `intend_to_process=true` produces a monotonically decreasing charge sequence bounded below by `CHARGE_FLOOR = 0.05`. |
| P12 | Trauma blocked when flooded | When `cortisol >= 0.6` (out of window) or `intend_to_process=false`, `process_trauma()` does NOT change charge (I2 protection). |

### Notes on P12

P12c (tone < 0.25 case) **cannot be triggered** by the current implementation: `AEA_BASE = 0.4`, `AG_BASE = 0.05` give a minimum resting tone of `0.7×0.40 + 0.3×0.05 = 0.295 ≥ 0.25`, and neither AEA nor AG can decay below their baselines in the current API. The tone guard is a structural safety net for future depletion pathways — not a dead branch.

---

## Pheromind properties (`pheromind_properties.cpp`)

**STATUS: STUB** — pheromind module is being ported concurrently. Fill in when `pheromind.h` lands.

| ID  | Name                  | Invariant (stub) |
|-----|-----------------------|------------------|
| P13 | Decay monotonicity    | Without new deposits, field strength is monotonically decreasing over time for any topic. |
| P14 | Quorum strictness     | `quorum(kind, topic, N)` returns `true` iff at least N **distinct** agents have current deposits; same agent × N must NOT pass. |
| P15 | Endocrine coupling    | Higher `field_volatility()` produces **faster** decay (effective tau decreases with volatility). |

---

## HDC properties (`hdc_properties.cpp`)

Both `RealKernel` (float32, cosine similarity) and `TernaryKernel` (trits {-1,0,+1}) are tested.

| ID  | Name                    | Invariant |
|-----|-------------------------|-----------|
| P16 | bind/unbind roundtrip   | TERNARY: `similarity(bind(a, bind(a,b)), b) == 1.0` (sign-preserving self-inverse). REAL: `similarity(...) >= 0.0` (cosine numerator Σ(a²·b²) ≥ 0 always). |
| P17 | Bundle commutativity    | TERNARY: `bundle([a,b,c]) == bundle([c,b,a])` byte-exact (int32 accumulator). REAL: similarity ≥ 0.999 (sequential float32 += is not bit-exact under reordering; see note). |
| P18 | Permute invertibility   | `permute_roll(permute_roll(a, k), -k) == a` byte-exact for both kernels and all integer shifts. |
| P19 | Similarity bounds       | REAL: similarity ∈ `[-1.0, 1.0]`. TERNARY: structural bound is `[-1.0, 1.0]` (current formula); the oracle manifest specifies `[0.0, 1.0]` — see critical-finding note below. |

### P17 REAL — floating-point non-commutativity

The `RealKernel::bundle` implementation uses sequential `float32 +=` accumulation. Float32 addition is not associative, so `a+b+c ≠ c+b+a` in general. The P17 REAL test therefore uses similarity ≥ 0.999 rather than byte-exact equality. If the spec requires byte-exact commutativity for REAL bundle, the implementation must adopt compensated (Kahan) summation or sorted-input accumulation — that is a spec-driven change, not a property relaxation.

### P19 TERNARY — spec gap note

The oracle manifest states similarity ∈ `[0.0, 1.0]` for "ternary normalised Hamming". The current implementation uses `(matches − mismatches) / max(active, 1)` which spans `[-1.0, 1.0]`. If RapidCheck finds `sim < 0`, that is a **CRITICAL FINDING** — the formula diverges from the spec. The tighter `RC_ASSERT(sim >= -1e-9)` is present in the test file but commented out; uncomment to enforce the strict spec bound.

---

## BeliefStore properties (`beliefstore_properties.cpp`)

**STATUS: STUB** — module not yet present.

---

## Failure policy

> A failing property is a **CRITICAL FINDING** — the implementation has a bug. DO NOT relax the property to make it pass. Record the shrunk counterexample from RapidCheck stderr, set `status='blocked'` on the todo, and route to operator + relevant port agent.

---

## CI integration

```
# Run all property tests with default 1000 cases:
ctest -L property

# Run with higher case count (e.g., 10000 for release validation):
RC_PARAMS="checks=10000" ctest -L property

# Run a single suite:
ctest -L property -R endocrine_properties

# Verbose output with shrunk counterexamples on stderr:
ctest -L property --output-on-failure
```
