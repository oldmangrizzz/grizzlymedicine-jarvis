# JARVIS Native Runtime Side-Channel Audit — Phase 7

Threat model: co-located code execution on the same Mac attempts to infer JARVIS secrets or identity material through timing, cache, or microarchitectural side channels.

## Contents

- `test_side_channel_timing.cpp` — Catch2 timing harness, 10,000 samples per input class, Welch t-test summary.
- `STATIC_AUDIT.md` — call-site and comparison audit.
- `GAPs.md` — filed gaps for found timing/input-dependent behavior.
- `OPERATOR_REPORT.md` — operator-facing summary and test results.
- `CMakeLists.txt` — standalone and top-level-integrated CMake target.

## Run

```sh
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target test_side_channel_timing -j2
ctest --test-dir build --output-on-failure
```

## Scope boundary

Apple Silicon Spectre/Meltdown-class mitigations, cache partitioning, scheduler isolation, and browser-process containment are OS/platform trust-domain controls. This suite audits JARVIS native runtime code paths and documents platform microarchitectural attacks as out-of-scope unless a JARVIS code path directly introduces secret-dependent branches or memory access.
