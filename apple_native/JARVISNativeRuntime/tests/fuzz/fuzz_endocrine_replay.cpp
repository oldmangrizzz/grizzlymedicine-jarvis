// fuzz_endocrine_replay.cpp — libFuzzer / AFL++ harness for jarvis::Endocrine
//
// Consumes fuzz input as a sequence of FuzzEvent records (see fuzz_common.h).
// After every event the following invariants are asserted:
//
//   INV-E1: level("cortisol")   ∈ [0.0, 1.0]  (finite, not NaN, not Inf)
//   INV-E2: level("dopamine")   ∈ [0.0, 1.0]
//   INV-E3: level("adrenaline") ∈ [0.0, 1.0]
//   INV-E4: field_volatility()  is finite and ∈ [0.0, 1.0]
//   INV-E5: modulation().candidates ≥ 1
//   INV-E6: modulation().retrieval_breadth, temperature, length_bias ∈ [0.0, 1.0]
//
// Bodily integrity:
//   - Endocrine is constructed with an injected deterministic clock.
//     NO real std::chrono::steady_clock, NO operator content.
//   - Logger is null-sink (organs have no logger dependency; see fuzz_common.h).
//   - Process aborts if JARVIS_REAL_RUNTIME or JARVIS_KEY_LOADED env vars
//     are detected (real-runtime guard in jarvis_fuzz_assert_environment).
//
// Seed corpus: corpus/endocrine/  (seeded from oracle/endocrine/endocrine_trace.csv
//              via gen_fuzz_seeds at build time)
//
// Build (libFuzzer):
//   cmake -DJARVIS_ENABLE_FUZZING=ON -DJARVIS_FUZZ_BACKEND=libfuzzer \
//         -DCMAKE_CXX_COMPILER=clang++ ...
//   cmake --build . --target fuzz_endocrine_replay
//
// Build (AFL++):
//   cmake -DJARVIS_ENABLE_FUZZING=ON -DJARVIS_FUZZ_BACKEND=afl \
//         -DCMAKE_CXX_COMPILER=afl-clang-fast++ ...
//
// Run (libFuzzer, 60s smoke):
//   ./fuzz_endocrine_replay -max_total_time=60 -max_len=4096 \
//       -timeout=5 corpus/endocrine
//
// Run (AFL++):
//   afl-fuzz -M main -i corpus/endocrine -o out/endocrine \
//       -- ./fuzz_endocrine_replay @@

#include "fuzz_common.h"
#include "endocrine.h"

#include <cstddef>
#include <cstdint>
#include <vector>

// ── Process-level init (called once per fuzz process) ────────────────────────

extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    jarvis_fuzz_assert_environment();
    jarvis_fuzz_init_null_logger();
    return 0;
}

// ── Fuzz entry point ──────────────────────────────────────────────────────────

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, std::size_t size) {
    // Discard inputs too small to hold a single event.
    if (size < sizeof(FuzzEvent)) return 0;

    // Fresh deterministic clock and Endocrine per run.
    // No shared state between runs — no operator content leakage.
    JarvisFuzzClock clk;
    jarvis::Endocrine endo(clk.fn());

    std::vector<FuzzEvent> events;
    jarvis_fuzz_parse_events(data, size, events);

    for (const auto& ev : events) {
        // Advance simulated time before processing each event.
        clk.advance(static_cast<double>(ev.clock_ds) * 0.1);

        const auto kind = static_cast<FuzzEventKind>(ev.kind);
        switch (kind) {
            case FuzzEventKind::STIMULUS: {
                // Clamp deltas to a range that exercises both saturation and
                // suppression without feeding extreme NaN-producing values.
                const double c = jarvis_fuzz_bounded(ev.arg1, -2.0f, 2.0f);
                const double d = jarvis_fuzz_bounded(ev.arg2, -2.0f, 2.0f);
                const double a = jarvis_fuzz_bounded(ev.arg3, -2.0f, 2.0f);
                endo.stimulus(c, d, a);
                break;
            }
            case FuzzEventKind::ON_THREAT:
                endo.on_threat(jarvis_fuzz_bounded(ev.arg1, 0.0f, 1.0f));
                break;
            case FuzzEventKind::ON_SUCCESS:
                endo.on_success(jarvis_fuzz_bounded(ev.arg1, 0.0f, 1.0f));
                break;
            case FuzzEventKind::ON_DEADLINE:
                endo.on_deadline(jarvis_fuzz_bounded(ev.arg1, 0.0f, 1.0f));
                break;
            case FuzzEventKind::ON_REST:
                endo.on_rest();
                break;
            case FuzzEventKind::READ_LEVELS:
            default:
                // Assert-only event; falls through to invariant checks below.
                break;
        }

        // ── Invariant checks after every event ───────────────────────────────

        // INV-E1..3: all hormone levels must be in [0,1].
        jarvis_fuzz_assert_unit(endo.level("cortisol"),   "cortisol");
        jarvis_fuzz_assert_unit(endo.level("dopamine"),   "dopamine");
        jarvis_fuzz_assert_unit(endo.level("adrenaline"), "adrenaline");

        // INV-E4: field_volatility = round4(clamp(0.6·adrenaline + 0.4·cortisol))
        //         must be finite and in [0,1].
        jarvis_fuzz_assert_unit(endo.field_volatility(), "field_volatility");

        // INV-E5..6: modulation must be self-consistent.
        const auto mod = endo.modulation();
        if (mod.candidates < 1) {
            const char* msg =
                "[JARVIS FUZZ] INVARIANT VIOLATED: "
                "modulation().candidates < 1\n";
            (void)::write(2, msg, __builtin_strlen(msg));
            __builtin_trap();
        }
        jarvis_fuzz_assert_unit(mod.retrieval_breadth, "retrieval_breadth");
        jarvis_fuzz_assert_unit(mod.temperature,       "temperature");
        jarvis_fuzz_assert_unit(mod.length_bias,       "length_bias");
    }

    return 0;
}

// ── AFL++ persistent-mode shim ────────────────────────────────────────────────
// Activated when JARVIS_FUZZ_AFL is defined (set by CMake when backend=afl).
// Provides main() that drives LLVMFuzzerTestOneInput via __AFL_LOOP.
#ifdef JARVIS_FUZZ_AFL
__AFL_FUZZ_INIT();

int main() {
#ifdef __AFL_HAVE_MANUAL_CONTROL
    __AFL_INIT();
#endif
    unsigned char* buf = __AFL_FUZZ_TESTCASE_BUF;
    while (__AFL_LOOP(100000)) {
        int len = __AFL_FUZZ_TESTCASE_LEN;
        if (len > 0) {
            LLVMFuzzerTestOneInput(buf, static_cast<std::size_t>(len));
        }
    }
    return 0;
}
#endif  // JARVIS_FUZZ_AFL
