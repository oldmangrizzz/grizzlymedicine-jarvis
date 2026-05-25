# Pheromind Field-Flood Adversarial Test — Phase 7 Vector 13

Target: `JARVISNativeRuntime/pheromind/`

Threat model: a compromised model, malicious tool, or hostile input source floods Pheromind to drown legitimate signals, starve memory, corrupt quorum behavior, or push endocrine-coupled volatility into pathological numeric regions.

## Build and run

ASan + UBSan:

```sh
cmake -B build_asan -S . \
  -DJARVIS_PF_SANITIZER=address-undefined \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Debug
cmake --build build_asan --parallel 4
ctest --test-dir build_asan --output-on-failure
```

TSan:

```sh
cmake -B build_tsan -S . \
  -DJARVIS_PF_SANITIZER=thread \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_BUILD_TYPE=Debug
cmake --build build_tsan --parallel 4
ctest --test-dir build_tsan --output-on-failure
```

## Scenarios and defenses

1. **High-volume deposit flood** — 1,000,000 deposits into one topic. Defense: per-signal strength cap and per-entry depositor cap.
2. **Single-topic flood** — attacker saturates one topic while legitimate topics exist. Defense: no global normalization; unrelated topic strengths remain independently sensed.
3. **Adversarial decay-rate timing** — backwards, huge, NaN, Inf, and denormal timing/volatility inputs. Defense: finite sanitization and clamp before decay math.
4. **Memory-exhaustion flood** — attempts more unique topics than capacity. Defense: `MAX_FIELD_ENTRIES` plus GC-before-refuse behavior.
5. **Concurrent flood** — 8 writer/sniffer threads. Defense: existing shared mutex coverage, verified under TSan.
6. **Pathological numeric values** — NaN/Inf/denormal/max strengths and toxic vectors. Defense: finite strength, volatility, cosine, snapshot, and sniff clamps.
7. **Sniff amplification** — repeated expensive semantic sniffs over 4096 vectorized topics. Defense: sniffs are read-only and do not grow/mutate field state.
8. **Endocrine coupling stability** — pathological endocrine stimulus followed by coupled Pheromind decay. Defense: Endocrine finite clamp and settle sanitization.
9. **ModelSwarm quorum hook** — TODO stub retained until native ModelSwarm lands.

## Observed behavior

Validated on Darwin/AppleClang with build directories under this deliverable:

- `build_asan`: 9/9 adversarial tests passed with `-fsanitize=address,undefined`.
- `build_tsan`: 9/9 adversarial tests passed with `-fsanitize=thread`.
- Existing Pheromind suite: 40/40 tests passed after the defensive changes.

Defense GAP: ModelSwarm native quorum logic is not present in this runtime tree yet; the adversarial test contains a TODO stub and does not claim quorum coverage beyond Pheromind's current `quorum()` API.
