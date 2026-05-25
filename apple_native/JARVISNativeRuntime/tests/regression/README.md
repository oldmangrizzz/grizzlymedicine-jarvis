# JARVIS Oracle Regression Harness

Phase 7 gate: every native C++ organ port must remain equivalent to its Python oracle.

## Run

```bash
cmake -B build -S /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/regression
cmake --build build --target jarvis_oracle_regression
ctest --test-dir build -L regression --output-on-failure
```

## Outputs

The regression test writes both CI-readable and human-readable reports:

- `build/tests/regression/reports/regression_results.json`
- `build/tests/regression/reports/regression_report.txt`

CTest fails if any active organ exceeds its configured threshold.

## Active oracle replays

- `endocrine` → `/Users/rbhanson/research/oracle/endocrine/endocrine_trace.csv`, default absolute threshold `1e-9`.
- `endocannabinoid` → `/Users/rbhanson/research/oracle/endocrine/endocannabinoid_trace.csv` unless `/Users/rbhanson/research/oracle/endocannabinoid/` exists, default absolute threshold `1e-9`; raw AEA/2-AG fields use `1e-6` because the oracle stores those fields at 6 decimal places.

## Stubbed organ gates

Stub entries are emitted for HoloGraph/HDC, Pheromind, Swarm, Voice, Loop, Drift, HMEM, SAGE, and CharacterValues. They appear in JSON with `status: "stub"` and do not fail CI until their C++ replay adapter is implemented.

HoloGraph/HDC is reserved for the Python baseline 153-test suite, 384 API traces, 140 HV blobs, and 50k corpus recall oracle. When the HDC adapter lands, replace the stub with an active replay and keep the `regression` CTest label.

## Configurable thresholds

CMake cache variables:

- `JARVIS_REGRESSION_ENDOCRINE_ABS_TOL` default `1e-9`
- `JARVIS_REGRESSION_ECS_ABS_TOL` default `1e-9`
- `JARVIS_REGRESSION_ECS_RAW_ABS_TOL` default `1e-6`
- `JARVIS_REGRESSION_HDC_ABS_TOL` default `0` for future exact-byte/default HDC comparison
- `JARVIS_ORACLE_ROOT` default `/Users/rbhanson/research/oracle`
- `JARVIS_REGRESSION_OUTPUT_DIR` default `${CMAKE_CURRENT_BINARY_DIR}/reports`
