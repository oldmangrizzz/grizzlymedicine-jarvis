# JARVIS Fuzz Harness — `tests/fuzz/`

Nation-state adversarial fuzzing for JARVIS organ invariants.
libFuzzer + AFL++ scaffolding; C++20; no Python, no Rust in the runtime.

---

## Target Taxonomy

### Active Targets (wired to real organs)

| Target | Organ | Invariants Asserted |
|--------|-------|---------------------|
| `fuzz_endocrine_replay` | `jarvis::Endocrine` | All hormone `level()` values ∈ [0,1]; `field_volatility()` finite ∈ [0,1]; `modulation().candidates ≥ 1`; all modulation scalars ∈ [0,1] |
| `fuzz_endocannabinoid_replay` | `jarvis::Endocannabinoid` + coupled `Endocrine` | `tone()` ∈ [0,1]; I1 monotonic (charge never amplified); I2 window gate (no extinction outside tolerance); I3 attenuation (recalled_intensity ≤ charge) |

### Stub Targets (compile-time guard, no-op runtime)

| Target | Waiting For | Organ / Module |
|--------|-------------|----------------|
| `fuzz_audio_frame_parser` | Phase 5 voice/stt/ | `voice/stt/audio_frame_parser.h` |
| `fuzz_wire_protocol` | Phase 4 wire protocol | `wire/frame_parser.h` |
| `fuzz_convex_message` | Convex C++ client | `convex/message.h` |
| `fuzz_model_api_response` | model_client/ (Ollama/Gemini/Copilot) | `model_client/sse_parser.h` |
| `fuzz_sqlite_belief_blob` | BeliefStore blob format | `belief/belief_blob.h` |
| `fuzz_pheromind_deposit_seq` | pheromind-cpp Phase 6 | `pheromind/field.h` |

Stubs are compiled on every PR (see `fuzz-stubs-compile` CI job) to catch
include-path and ABI breakage before a module agent wires them in.

---

## Wire Format: `FuzzEvent` (16 bytes)

```
┌──────────┬──────────┬──────────┬──────────┬──────────────┬──────────────┬──────────────┐
│ kind     │ clock_ds │ flags    │ _pad     │ arg1         │ arg2         │ arg3         │
│ uint8    │ uint8    │ uint8    │ uint8    │ float        │ float        │ float        │
│ 1 byte   │ 1 byte   │ 1 byte   │ 1 byte   │ 4 bytes      │ 4 bytes      │ 4 bytes      │
└──────────┴──────────┴──────────┴──────────┴──────────────┴──────────────┴──────────────┘
```

- **`kind`**: see `FuzzEventKind` in `fuzz_common.h` (0=STIMULUS … 7=ECS_PROCESS_TRAUMA; ≥8 ignored)
- **`clock_ds`**: clock advance in deciseconds; range 0–255 → 0.0–25.5 seconds per event
- **`flags`**: bit 0 = `intend_to_process` (for ECS_PROCESS_TRAUMA)
- **`arg1–3`**: hormone deltas or appraisal magnitudes (see table below)

| Kind | Name | arg1 | arg2 | arg3 |
|------|------|------|------|------|
| 0 | STIMULUS | cortisol_Δ ∈ [-2, 2] | dopamine_Δ ∈ [-2, 2] | adrenaline_Δ ∈ [-2, 2] |
| 1 | ON_THREAT | severity ∈ [0,1] | — | — |
| 2 | ON_SUCCESS | magnitude ∈ [0,1] | — | — |
| 3 | ON_DEADLINE | pressure ∈ [0,1] | — | — |
| 4 | ON_REST | — | — | — |
| 5 | READ_LEVELS | — | — | — (assert-only; no mutation) |
| 6 | ECS_REGULATE | — | — | — |
| 7 | ECS_PROCESS_TRAUMA | charge ∈ [0,1] | — | — |

Input bytes not aligned to 16-byte boundary are silently discarded.

---

## Bodily-Integrity Guarantees

Every fuzz target enforces at process start (`LLVMFuzzerInitialize`):

1. **No operator key material** — checks `JARVIS_REAL_RUNTIME` and `JARVIS_KEY_LOADED`
   env vars; aborts if either is set. Ensures fuzz processes cannot accidentally
   run inside a live JARVIS instance.

2. **No Keychain access** — the active organs (`Endocrine`, `Endocannabinoid`) are
   pure-compute classes with injectable clocks. They never touch `~/.jarvis/` or
   macOS Keychain.

3. **No disk logging** — `jarvis_fuzz_init_null_logger()` is called on startup.
   Active targets (no logger dependency) are a no-op stub. Future targets that
   link `jarvis_redacting_logger` must define `JARVIS_FUZZ_HAS_LOGGER` and will
   get the logger configured to `/dev/null` with `min_level=FATAL`.

4. **No real clock** — `JarvisFuzzClock` provides a deterministic `std::atomic<double>`
   time source injected via `Endocrine(clock_fn)` / `Endocannabinoid(clock_fn)`.
   Clock only advances in the outer loop; no `std::chrono::steady_clock` is used.

---

## Build Instructions

### Prerequisites

- **Clang ≥ 15** (libFuzzer mode) or **afl-clang-fast++** (AFL++ mode)
- CMake ≥ 3.20
- Oracle trace CSVs at `/Users/rbhanson/research/oracle/endocrine/` (for seed corpus)

### libFuzzer (recommended for development)

```sh
cmake -B build_fuzz \
      -DJARVIS_ENABLE_FUZZING=ON \
      -DJARVIS_FUZZ_BACKEND=libfuzzer \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_BUILD_TYPE=Release \
      /path/to/JARVISNativeRuntime

cmake --build build_fuzz -j$(nproc)
```

### MSan build (slower, separate tree)

```sh
cmake -B build_msan \
      -DJARVIS_ENABLE_FUZZING=ON \
      -DJARVIS_FUZZ_MSAN=ON \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_BUILD_TYPE=Release \
      /path/to/JARVISNativeRuntime

cmake --build build_msan --target fuzz_endocrine_replay fuzz_endocannabinoid_replay
```

Note: MSan is incompatible with ASan. Use a separate build directory.

### AFL++ mode

```sh
cmake -B build_afl \
      -DJARVIS_ENABLE_FUZZING=ON \
      -DJARVIS_FUZZ_BACKEND=afl \
      -DCMAKE_CXX_COMPILER=afl-clang-fast++ \
      -DCMAKE_BUILD_TYPE=Release \
      /path/to/JARVISNativeRuntime

cmake --build build_afl -j$(nproc)
```

---

## Running the Fuzz Targets

### 60-second smoke test (CTest)

```sh
ctest --test-dir build_fuzz -R fuzz_smoke -V
```

### Manual libFuzzer run

```sh
# Endocrine — 1 hour
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
LSAN_OPTIONS=detect_leaks=1 \
./build_fuzz/tests/fuzz/fuzz_endocrine_replay \
    -max_total_time=3600 \
    -max_len=4096 \
    -timeout=10 \
    -artifact_prefix=findings/endocrine/ \
    -print_final_stats=1 \
    tests/fuzz/corpus/endocrine

# Endocannabinoid — 1 hour
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
./build_fuzz/tests/fuzz/fuzz_endocannabinoid_replay \
    -max_total_time=3600 \
    -max_len=4096 \
    -timeout=10 \
    -artifact_prefix=findings/endocannabinoid/ \
    -print_final_stats=1 \
    tests/fuzz/corpus/endocannabinoid
```

### AFL++ Parallel Mode

```sh
# Primary instance
AFL_USE_ASAN=1 afl-fuzz -M main \
    -i tests/fuzz/corpus/endocrine \
    -o out/endocrine \
    -- ./build_afl/tests/fuzz/fuzz_endocrine_replay @@

# Secondary instances (run in separate terminals)
AFL_USE_ASAN=1 afl-fuzz -S worker1 \
    -i tests/fuzz/corpus/endocrine \
    -o out/endocrine \
    -- ./build_afl/tests/fuzz/fuzz_endocrine_replay @@

AFL_USE_ASAN=1 afl-fuzz -S worker2 \
    -i tests/fuzz/corpus/endocannabinoid \
    -o out/endocannabinoid \
    -- ./build_afl/tests/fuzz/fuzz_endocannabinoid_replay @@
```

---

## 24-Hour Acceptance Run

The acceptance criterion for promotion to `main` is:

> **Zero crashes, zero sanitizer findings** in a 24-hour libFuzzer run on both
> active targets, with ASan + UBSan + LSAN enabled.

To trigger via GitHub Actions:

```sh
gh workflow run fuzz-smoke.yml \
    -f duration_seconds=86400 \
    --repo <owner>/jarvis
```

For local 24h runs:

```sh
ASAN_OPTIONS=detect_leaks=1:abort_on_error=1 \
./build_fuzz/tests/fuzz/fuzz_endocrine_replay \
    -max_total_time=86400 \
    -max_len=8192 \
    -jobs=$(nproc) \
    -workers=$(nproc) \
    -artifact_prefix=findings/endocrine_24h/ \
    tests/fuzz/corpus/endocrine
```

---

## Coverage Measurement

libFuzzer reports per-run coverage to stdout (`-print_final_stats=1`):

```
DONE cov: 312  ft: 1847  corp: 38/3Kb  exec/s: 14203  rss: 67Mb
```

For detailed line-level coverage (requires Clang coverage build):

```sh
cmake -B build_cov \
      -DJARVIS_ENABLE_FUZZING=ON \
      -DJARVIS_FUZZ_BACKEND=libfuzzer \
      -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_CXX_FLAGS="-fprofile-instr-generate -fcoverage-mapping" \
      -DCMAKE_BUILD_TYPE=Release \
      /path/to/JARVISNativeRuntime

cmake --build build_cov --target fuzz_endocrine_replay

LLVM_PROFILE_FILE="endocrine.profraw" \
./build_cov/tests/fuzz/fuzz_endocrine_replay \
    -max_total_time=300 tests/fuzz/corpus/endocrine

llvm-profdata merge -sparse endocrine.profraw -o endocrine.profdata
llvm-cov report build_cov/tests/fuzz/fuzz_endocrine_replay \
    -instr-profile=endocrine.profdata \
    --ignore-filename-regex='.*catch2.*'
```

**Coverage gaps become property-based tests**: any uncovered branch identified
here should be added as a case in `tests/properties/endocrine_properties.cpp`
(the `p7-property-tests` harness).

---

## Adding a New Fuzz Target

1. Create `tests/fuzz/fuzz_<module>.cpp` (copy a stub for the boilerplate).
2. Implement `LLVMFuzzerTestOneInput`: parse the input, drive the module, assert invariants.
3. Add `jarvis_add_fuzz_target(fuzz_<module> fuzz_<module>.cpp)` to `CMakeLists.txt`.
4. Add a smoke test entry in `CMakeLists.txt` (see existing active-target pattern).
5. Create `corpus/<module>/` and add seed inputs (hand-crafted or from oracle traces).
6. Update this README's target taxonomy table.
7. Update `.github/workflows/fuzz-smoke.yml` matrix if the target should run on PR.

---

## Corpus Seed Generation

Seeds are generated from oracle traces at build time by `gen_fuzz_seeds`:

```sh
cmake --build build_fuzz --target gen_fuzz_seeds
# Seeds appear automatically in tests/fuzz/corpus/{endocrine,endocannabinoid}/
```

Oracle source:
- `endocrine` seeds: `/Users/rbhanson/research/oracle/endocrine/endocrine_trace.csv`
- `endocannabinoid` seeds: `/Users/rbhanson/research/oracle/endocrine/endocannabinoid_trace.csv`

Stub target corpus dirs contain a `.gitkeep`; add seed files when the target is activated.

---

## Sanitizer Configuration Reference

| Sanitizer | Flag | Enabled by Default | Notes |
|-----------|------|--------------------|-------|
| ASan | `-fsanitize=address` | ✅ | Catches heap/stack/global overflows and use-after-free |
| UBSan | `-fsanitize=undefined` | ✅ | Catches signed overflow, null deref, bad shifts, etc. |
| LSAN | (part of ASan) | ✅ on Linux | `LSAN_OPTIONS=detect_leaks=1` in env |
| MSan | `-fsanitize=memory` | ❌ (opt-in) | Use `-DJARVIS_FUZZ_MSAN=ON`; incompatible with ASan |
| TSan | N/A (separate target) | ❌ | Use logging library's `-DJARVIS_TSAN=ON` build for TSan |
| libFuzzer | `-fsanitize=fuzzer` | ✅ (libfuzzer backend) | Provides coverage instrumentation + main loop |

---

## File Layout

```
tests/fuzz/
├── CMakeLists.txt               — fuzz build config (gated on -DJARVIS_ENABLE_FUZZING=ON)
├── README.md                    — this file
├── fuzz_common.h                — shared event format, clock, assertions, bodily-integrity guard
├── corpus_seed_generator.cpp    — build-time tool; generates binary seeds from oracle CSVs
│
├── fuzz_endocrine_replay.cpp    — ACTIVE: jarvis::Endocrine invariant fuzzer
├── fuzz_endocannabinoid_replay.cpp — ACTIVE: jarvis::Endocannabinoid invariant fuzzer
│
├── fuzz_audio_frame_parser.cpp  — STUB: voice/stt/ (Phase 5)
├── fuzz_wire_protocol.cpp       — STUB: Phase 4 wire protocol
├── fuzz_convex_message.cpp      — STUB: Convex message deserialization
├── fuzz_model_api_response.cpp  — STUB: Ollama/Gemini/Copilot JSON/SSE parser
├── fuzz_sqlite_belief_blob.cpp  — STUB: BeliefStore blob deserialization
├── fuzz_pheromind_deposit_seq.cpp — STUB: pheromind-cpp (Phase 6)
│
└── corpus/
    ├── endocrine/               — seeds from endocrine_trace.csv (generated at build time)
    ├── endocannabinoid/         — seeds from endocannabinoid_trace.csv
    ├── audio_frame/             — (empty; add WAV seeds when voice/stt/ lands)
    ├── wire_protocol/           — (empty)
    ├── convex_message/          — (empty)
    ├── model_api_response/      — (empty)
    ├── sqlite_belief_blob/      — (empty)
    └── pheromind_deposit_seq/   — (empty)
```
