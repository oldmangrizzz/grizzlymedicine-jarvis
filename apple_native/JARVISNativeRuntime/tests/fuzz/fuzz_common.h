// fuzz_common.h — JARVIS Fuzz Harness Shared Utilities (C++20)
//
// BODILY-INTEGRITY / PRIVACY GUARANTEE (GMRI-OPS-2026-001):
//   Fuzz harnesses MUST construct organs without operator content.
//   NO real CharacterValues. NO real memories. NO operator key material.
//   NO Keychain access. NO contact with ~/.jarvis/runtime_secret.key.
//   Redacting logger is initialized in null-sink mode so transcripts
//   NEVER hit disk during a fuzz run.
//
// This header is the ONLY shared dependency across all fuzz targets.
// Include it before any organ header.
#pragma once

#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <unistd.h>   // write() for async-signal-safe stderr in assert helpers
#include <vector>

// ── Bodily-integrity / real-runtime guard ─────────────────────────────────────
//
// Call once at the top of LLVMFuzzerInitialize().
// Aborts unconditionally if the process is running inside a real JARVIS runtime
// environment (detected via env var set by the runtime on startup).
// This prevents fuzz harnesses from accidentally running against live operator
// state if someone mis-invokes a fuzz binary.
inline void jarvis_fuzz_assert_environment() {
    // Real runtime sets JARVIS_REAL_RUNTIME=1 before spawning any child process.
    if (std::getenv("JARVIS_REAL_RUNTIME") != nullptr) {
        // Hard abort — do not continue. Report to stderr (not disk).
        const char* msg =
            "[JARVIS FUZZ] FATAL: JARVIS_REAL_RUNTIME is set. "
            "Refusing to fuzz against live operator state. "
            "Unset JARVIS_REAL_RUNTIME before running fuzz targets.\n";
        (void)::write(2, msg, __builtin_strlen(msg));
        std::abort();
    }
    // Belt-and-suspenders: operator secret key must not be actively loaded.
    // We do NOT stat or open the key (that itself would be a policy violation);
    // we only guard against the env var that real-runtime sets when the key is
    // loaded into process memory.
    if (std::getenv("JARVIS_KEY_LOADED") != nullptr) {
        const char* msg =
            "[JARVIS FUZZ] FATAL: JARVIS_KEY_LOADED is set. "
            "Key material is present in this process. Aborting.\n";
        (void)::write(2, msg, __builtin_strlen(msg));
        std::abort();
    }
}

// ── Null-sink logger init ─────────────────────────────────────────────────────
//
// The active fuzz targets (endocrine, endocannabinoid) are pure-compute and
// do not link jarvis_redacting_logger.  This stub satisfies the call site.
// Future targets that DO link the logger should define JARVIS_FUZZ_HAS_LOGGER
// before including this header; the real implementation will be selected.
#ifndef JARVIS_FUZZ_HAS_LOGGER
inline void jarvis_fuzz_init_null_logger() {
    // No-op: organs currently under fuzz have no logger dependency.
    // When a future target links jarvis_redacting_logger, define
    // JARVIS_FUZZ_HAS_LOGGER and add:
    //   JARVISLog_configure(
    //     R"({"log_dir":"/dev/null","max_disk_bytes":0,"min_level":"FATAL"})");
}
#else
#include "redacting_logger.h"
inline void jarvis_fuzz_init_null_logger() {
    // Null-sink: min_level=FATAL means nothing is ever enqueued.
    // log_dir=/dev/null ensures the background worker writes nowhere even if
    // somehow a FATAL entry is emitted.
    JARVISLog_configure(
        R"({"log_dir":"/dev/null","max_disk_bytes":0,"min_level":"FATAL"})");
}
#endif

// ── Monotonic mock clock ──────────────────────────────────────────────────────
//
// Injectable time source for Endocrine / Endocannabinoid.
// Never uses std::chrono::steady_clock; all time is driven by the fuzzer.
// Each call to advance(dt) moves time forward by dt seconds.
// Thread-safe via std::atomic; each organ sees the same clock value within
// a single LLVMFuzzerTestOneInput call (clock only advances in the outer loop).
struct JarvisFuzzClock {
    std::atomic<double> t{0.0};

    // Returns a callable suitable for injection into Endocrine / Endocannabinoid.
    std::function<double()> fn() {
        return [this]() -> double {
            return t.load(std::memory_order_relaxed);
        };
    }

    void advance(double dt) noexcept {
        if (dt <= 0.0) return;
        double cur = t.load(std::memory_order_relaxed);
        t.store(cur + dt, std::memory_order_relaxed);
    }

    void reset() noexcept { t.store(0.0, std::memory_order_relaxed); }
};

// ── Fuzz Event Wire Format ────────────────────────────────────────────────────
//
// 16-byte fixed-size event record.  The fuzzer input is consumed as a
// contiguous array of FuzzEvent structs.  Any trailing bytes (size % 16 ≠ 0)
// are silently discarded.
//
// Field layout:
//   kind      : FuzzEventKind (uint8_t)
//   clock_ds  : clock advance in deciseconds; 0..255 → 0.0..25.5 s per event
//   flags     : bit 0 = intend_to_process (for ECS_PROCESS_TRAUMA)
//   _pad      : reserved, must be ignored
//   arg1..3   : float; interpretation is per-kind (see below)
//
// Endocrine events (kind 0–5):
//   STIMULUS    (0): stimulus(arg1=cortisol_Δ, arg2=dopamine_Δ, arg3=adrenaline_Δ)
//   ON_THREAT   (1): on_threat(arg1=severity ∈ [0,1])
//   ON_SUCCESS  (2): on_success(arg1=magnitude ∈ [0,1])
//   ON_DEADLINE (3): on_deadline(arg1=pressure ∈ [0,1])
//   ON_REST     (4): on_rest()
//   READ_LEVELS (5): assert-only read; no mutation
//
// Endocannabinoid events (kind 6–7):
//   ECS_REGULATE      (6): ecs.regulate(endo)
//   ECS_PROCESS_TRAUMA(7): ecs.process_trauma(charge=arg1, endo, flags&1)
//
// kind ≥ 8: reserved / no-op (future extension without breaking existing seeds)
enum class FuzzEventKind : uint8_t {
    STIMULUS           = 0,
    ON_THREAT          = 1,
    ON_SUCCESS         = 2,
    ON_DEADLINE        = 3,
    ON_REST            = 4,
    READ_LEVELS        = 5,
    ECS_REGULATE       = 6,
    ECS_PROCESS_TRAUMA = 7,
    // 8..255 reserved
};

#pragma pack(push, 1)
struct FuzzEvent {
    uint8_t kind;
    uint8_t clock_ds;   // deciseconds; 0..255 → 0.0..25.5 s
    uint8_t flags;      // bit 0: intend_to_process
    uint8_t _pad;
    float   arg1;
    float   arg2;
    float   arg3;
};  // exactly 16 bytes
#pragma pack(pop)

static_assert(sizeof(FuzzEvent) == 16,
              "FuzzEvent layout changed — update corpus_seed_generator.cpp and README");

// ── Input parsing ─────────────────────────────────────────────────────────────

// Consume [data, data+size) as an array of FuzzEvent.
// Returns the number of events extracted (size / 16).
inline std::size_t jarvis_fuzz_parse_events(const uint8_t*          data,
                                             std::size_t             size,
                                             std::vector<FuzzEvent>& out) {
    const std::size_t n = size / sizeof(FuzzEvent);
    out.resize(n);
    if (n > 0) {
        std::memcpy(out.data(), data, n * sizeof(FuzzEvent));
    }
    return n;
}

// ── Numeric helpers ───────────────────────────────────────────────────────────

// Clamp a float to [lo, hi]; replace NaN with (lo+hi)*0.5.
inline float jarvis_fuzz_bounded(float v, float lo, float hi) noexcept {
    if (std::isnan(v)) return (lo + hi) * 0.5f;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// ── Invariant assertions ──────────────────────────────────────────────────────
//
// These use __builtin_trap() so libFuzzer / AFL++ capture them as crashes
// and preserve the minimised input.

// Assert v ∈ [0.0, 1.0] and is finite.  Reports to stderr before trapping.
inline void jarvis_fuzz_assert_unit(double v, const char* tag) noexcept {
    if (!std::isfinite(v) || v < 0.0 || v > 1.0) {
        const char* pfx = "[JARVIS FUZZ] INVARIANT VIOLATED: ";
        (void)::write(2, pfx, __builtin_strlen(pfx));
        (void)::write(2, tag, __builtin_strlen(tag));
        const char* sfx = " not in [0,1] or not finite\n";
        (void)::write(2, sfx, __builtin_strlen(sfx));
        __builtin_trap();
    }
}

// Assert v is finite (not NaN, not Inf).
inline void jarvis_fuzz_assert_finite(double v, const char* tag) noexcept {
    if (!std::isfinite(v)) {
        const char* pfx = "[JARVIS FUZZ] INVARIANT VIOLATED: ";
        (void)::write(2, pfx, __builtin_strlen(pfx));
        (void)::write(2, tag, __builtin_strlen(tag));
        const char* sfx = " is NaN or Inf\n";
        (void)::write(2, sfx, __builtin_strlen(sfx));
        __builtin_trap();
    }
}
