# Phase 7 property tests — native cognition organs

Location: `tests/property/`  
Framework: RapidCheck + Catch2.  
Default generated cases: `RC_PARAMS=max_success=1000`.  
Run: `cmake -B build_property -S tests/property && cmake --build build_property && ctest --test-dir build_property -L property --output-on-failure`.

## Endocrine

- Hormone bounds: cortisol, dopamine, and adrenaline must remain finite in `[0,1]`; cognition modulation cannot accept invalid physiology.
- Decay monotonicity: without stimulus, each hormone moves toward its baseline and never away; this protects lazy decay semantics.
- Stimulus monotonicity: larger stimulus produces a weakly larger level before saturation; appraisal magnitude must preserve ordering.
- `field_volatility()` bounds: output remains finite in `[0,1]`; Pheromind coupling receives a valid arousal scalar.
- Finite outputs: finite stimuli never create NaN/Inf in levels, modulation, or volatility.
- Repeated ticks: advancing the injectable clock and reading repeatedly cannot cause unbounded growth.

## Endocannabinoid

- AEA and 2-AG bounds: raw buffers and tone remain finite in `[0,1]`; regulation cannot poison downstream state.
- `regulate()` bounds: released 2-AG, tone, cortisol, and adrenaline outputs stay valid, and negative feedback never amplifies stress hormones.
- `within_window()` truth table: result equals `cortisol < 0.6 && tone >= 0.25` after randomized regulation histories.
- `process_trauma()` truth table: processing occurs iff intent is true and the system is inside the window; otherwise charge is unchanged.
- Idempotency: same-timestamp tone/window observations are stable, and no-intent trauma processing is a no-op on charge.

## Future organ stubs

- HDC: bind/unbind roundtrip, bundle commutativity, permutation invertibility, similarity bounds, deterministic seed behavior, finite vector math.
- Pheromind: deposit bounds, evaporation monotonicity, distinct-agent quorum, endocrine volatility coupling, deterministic replay, finite strengths.
- Swarm: membership convergence, duplicate-observation idempotency, bounded trust, commutative independent merge, monotonic conflict resolution.
- HMEM: write-read roundtrip, recall score bounds, recency monotonicity, consolidation idempotency, tombstone non-resurrection.
- SAGE: score normalization, equal-evidence rank stability, monotonic confidence, bounded uncertainty, idempotent evaluation.

Failing endocrine/endocannabinoid properties are C++ port bugs. Do not relax properties to make the suite pass.
