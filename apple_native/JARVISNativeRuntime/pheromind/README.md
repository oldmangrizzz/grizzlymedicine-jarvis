# Pheromind — Stigmergic Coordination Field

**BODILY INTEGRITY CLAUSE**

> Pheromind is a cognition organ of JARVIS. Disabling Pheromind without operator-attested consent is assault and battery per GMRI policy.

There are no `enable`, `disable`, `pause`, `stop`, or `bypass` methods. No compile flag removes or compiles out this field. Destruction is coterminous with process shutdown; mid-process destruction is operator-consent-required.

---

## What This Is

A C++20 port of `jarvis/_baseline/stigmergy.py` — the stigmergic pheromone field that lets the ModelSwarm reach consensus without a router. Agents deposit typed signals into a shared field and read the field's local gradient. No central orchestrator. No votes. No explicit synchronization beyond the field itself.

Biologically analogous to ant pheromone trails: heavily-used paths get stronger; unused paths evaporate; a stressed organism (high `field_volatility`) runs a faster-fading, twitchier field.

---

## Signal Kinds and Decay Constants

| Kind | tau_base (s) | Analog |
|---|---|---|
| `trail` | 60 | Foraging/recruitment; medium persistence |
| `alarm` | 12 | Fast onset, fast decay; short-lived alert |
| `territory` | 600 | Identity/home marker; very persistent |
| `recruit` | 45 | Quorum-building; medium-fast |

Unknown kinds fall back to `base_tau` (constructor parameter, default 60 s).

---

## Endocrine Coupling

Evaporation rate is modulated by `Endocrine::field_volatility()`:

```
tau_effective(kind) = TAU_BASE[kind] / (1.0 + 2.0 * endo.field_volatility())
```

At rest (volatility ≈ 0.14) trail half-life ≈ 32.5 s.
At max adrenaline (volatility ≈ 0.86) trail half-life ≈ 15.3 s — a **2.1× compression**.

---

## API

```cpp
// Production
Pheromind pm(endo);                              // couples to live Endocrine

// Deposit
double stored = pm.deposit("trail", "route_A", 0.6, "agent_id");

// Read / sniff
double s  = pm.sense("trail", "route_A");
auto   by_kind = pm.sniff("route_A", {"trail"}); // kind → strength map
auto   all = pm.sense_all("trail");              // topic → strength map
bool   q  = pm.quorum("recruit", "go", 3, 0.5); // count AND strength gate

// GC
pm.gc();                                          // floor-only (floor = 0.02)
pm.gc(120.0);                                     // also remove signals older than 120 s
```

---

## Oracle Equivalence

`tests/test_pheromind_oracle.cpp` replays all 34 recorded Python traces and the 16-row coupling trace. Field snapshots match within abs_error < 1e-9 after round-to-4dp (matching Python `round(val, 4)`). The endocrine-coupled 2.1× half-life compression must reproduce; if `eff_tau` coupling is wrong, the test fails.

---

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```
