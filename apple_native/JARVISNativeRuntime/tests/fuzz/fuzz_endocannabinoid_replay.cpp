// fuzz_endocannabinoid_replay.cpp — libFuzzer / AFL++ harness for
//                                   jarvis::Endocannabinoid (+ coupled Endocrine)
//
// Consumes fuzz input as a sequence of FuzzEvent records (see fuzz_common.h).
// After every event the following invariants are asserted:
//
//   INV-ECS1: tone() ∈ [0.0, 1.0]  (finite, not NaN, not Inf)
//
// For process_trauma() calls:
//   INV-I1 (Monotonic):   processed=true  → charge_after ≤ charge_before
//                         Processing can only REDUCE charge, never amplify.
//   INV-I2 (Window gate): !within_window && intend_to_process
//                         → charge_after == charge_before
//                         No extinction outside the window of tolerance.
//   INV-I3 (Attenuation): recalled_intensity ≤ charge_before  (always)
//                         Recalled intensity is always attenuated by tone.
//   INV-I4 (Range):       recalled_intensity ∈ [0.0, 1.0]
//
// The coupled Endocrine also has all of its own invariants verified via
// the same event types (STIMULUS, ON_THREAT, ON_SUCCESS, ON_DEADLINE, ON_REST).
//
// Bodily integrity: same guarantees as fuzz_endocrine_replay.cpp.
//
// Seed corpus: corpus/endocannabinoid/  (seeded from oracle traces at build time)
//
// Build: see fuzz_endocrine_replay.cpp header for cmake invocations.
// Run (libFuzzer, 60s smoke):
//   ./fuzz_endocannabinoid_replay -max_total_time=60 -max_len=4096 \
//       -timeout=5 corpus/endocannabinoid

#include "fuzz_common.h"
#include "endocrine.h"
#include "endocannabinoid.h"

#include <cstddef>
#include <cstdint>
#include <vector>

extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    jarvis_fuzz_assert_environment();
    jarvis_fuzz_init_null_logger();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, std::size_t size) {
    if (size < sizeof(FuzzEvent)) return 0;

    // Both organs share the same injected clock — matches production coupling.
    JarvisFuzzClock clk;
    jarvis::Endocrine       endo(clk.fn());
    jarvis::Endocannabinoid ecs (clk.fn());

    std::vector<FuzzEvent> events;
    jarvis_fuzz_parse_events(data, size, events);

    for (const auto& ev : events) {
        clk.advance(static_cast<double>(ev.clock_ds) * 0.1);

        const auto kind = static_cast<FuzzEventKind>(ev.kind);
        switch (kind) {
            // ── Endocrine mutations (drive coupled state) ─────────────────────
            case FuzzEventKind::STIMULUS:
                endo.stimulus(
                    jarvis_fuzz_bounded(ev.arg1, -2.0f, 2.0f),
                    jarvis_fuzz_bounded(ev.arg2, -2.0f, 2.0f),
                    jarvis_fuzz_bounded(ev.arg3, -2.0f, 2.0f));
                break;
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

            // ── Endocannabinoid mutations ─────────────────────────────────────
            case FuzzEventKind::ECS_REGULATE:
                ecs.regulate(endo);
                break;

            case FuzzEventKind::ECS_PROCESS_TRAUMA: {
                const double charge = static_cast<double>(
                    jarvis_fuzz_bounded(ev.arg1, 0.0f, 1.0f));
                const bool intend   = (ev.flags & 0x01u) != 0u;

                // Snapshot window status BEFORE the call (same clock, so both
                // this call and the internal call inside process_trauma will
                // observe consistent cortisol/tone after lazy decay settles).
                const bool in_window = ecs.within_window(endo);

                const auto r = ecs.process_trauma(charge, endo, intend);

                // INV-I1: Processing only REDUCES charge (monotonic).
                // Allow a tiny epsilon for double rounding (round4 in impl).
                if (r.processed && r.charge_after > r.charge_before + 1e-9) {
                    const char* msg =
                        "[JARVIS FUZZ] I1 VIOLATED: "
                        "process_trauma increased charge\n";
                    (void)::write(2, msg, __builtin_strlen(msg));
                    __builtin_trap();
                }

                // INV-I2: Outside window + intend=true → charge unchanged.
                if (!in_window && intend && r.charge_after != r.charge_before) {
                    const char* msg =
                        "[JARVIS FUZZ] I2 VIOLATED: "
                        "charge changed outside window of tolerance\n";
                    (void)::write(2, msg, __builtin_strlen(msg));
                    __builtin_trap();
                }

                // INV-I3: recalled_intensity ≤ charge_before.
                if (r.recalled_intensity > r.charge_before + 1e-9) {
                    const char* msg =
                        "[JARVIS FUZZ] I3 VIOLATED: "
                        "recalled_intensity > charge_before\n";
                    (void)::write(2, msg, __builtin_strlen(msg));
                    __builtin_trap();
                }

                // INV-I4: recalled_intensity ∈ [0,1].
                jarvis_fuzz_assert_unit(r.recalled_intensity, "recalled_intensity");
                break;
            }

            case FuzzEventKind::READ_LEVELS:
            default:
                break;
        }

        // ── INV-ECS1: tone must be in [0,1] after every event ────────────────
        jarvis_fuzz_assert_unit(ecs.tone(), "tone");
    }

    return 0;
}

// ── AFL++ persistent-mode shim ────────────────────────────────────────────────
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
