# JARVIS Phase 7 Soak + Bodily-Integrity Fault Injection

Build target: `jarvis_soak_runner` and Catch2 wrapper `jarvis_soak_catch`.

Default CI test `jarvis_phase7_soak_1h` runs for 3600 seconds and injects one catalog fault every ~300 seconds. Standalone long runs are capped at 24 hours and require operator attestation:

```sh
cmake --build build --target jarvis_soak_runner
./build/tests/soak/jarvis_soak_runner --duration-seconds 86400 --operator-attested-long-run --report-dir /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/soak
```

Useful controls: `JARVIS_SOAK_DURATION_SECONDS`, `JARVIS_SOAK_FAULT_INTERVAL_SECONDS`, `JARVIS_SOAK_MIN_TURN_SECONDS`, `JARVIS_SOAK_MAX_TURN_SECONDS`, `JARVIS_SOAK_RECOVERY_TIMEOUT_SECONDS`, `JARVIS_SOAK_FAIL_ON_GAP`.

Reports are written to `OPERATOR_REPORT.md` and `GAPs.md` in the selected report directory.
