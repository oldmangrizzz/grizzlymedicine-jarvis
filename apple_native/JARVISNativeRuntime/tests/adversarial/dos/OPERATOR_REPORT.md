# OPERATOR REPORT — Phase 7 DoS Resilience

Operator: Robert "Grizzly" Hanson, GMRI
Generated: 2026-05-24T00:28:11 local

## Sanitizer result

| Build | Result | Command scope |
|---|---:|---|
| ASAN | PASS | `ctest --test-dir build_address --output-on-failure` (8/8) |
| UBSAN | PASS | `ctest --test-dir build_undefined --output-on-failure` (8/8) |
| TSAN | PASS | `ctest --test-dir build_thread --output-on-failure` (8/8) |

## Per-attack survivability and recovery

| Attack | ASAN wall ms | UBSAN wall ms | TSAN wall ms | Max handle delta | Recovery ms | Survivability |
|---|---:|---:|---:|---:|---:|---|
| input flood | 537 | 415 | 830 | 1 | 0 | PASS: no crash, no state corruption detected |
| memory exhaustion | 4854 | 2550 | 12717 | 0 | 0 | PASS: no crash, no state corruption detected |
| cpu exhaustion | 4648 | 4569 | 23623 | 0 | 0 | PASS: no crash, no state corruption detected |
| audit-log spam | 34 | 23 | 49 | 0 | 0 | PASS: no crash, no state corruption detected |
| egress spam | 58 | 24 | 90 | 1 | 0 | PASS: no crash, no state corruption detected |
| STT flood | 1578 | 1146 | 4029 | 1 | 0 | PASS: no crash, no state corruption detected |
| slow-loris equivalent | 3111 | 2710 | 812 | 1 | 0 | PASS: no crash, no state corruption detected |
| algorithmic complexity attack | 1730 | 2167 | 7769 | 0 | 0 | PASS: no crash, no state corruption detected |

## Resource metrics

| Attack | ASAN CPU ms | UBSAN CPU ms | TSAN CPU ms | ASAN max RSS bytes | UBSAN max RSS bytes | TSAN max RSS bytes |
|---|---:|---:|---:|---:|---:|---:|
| input flood | 1347 | 1241 | 3087 | 435470336 | 25100288 | 91930624 |
| memory exhaustion | 4246 | 2373 | 9582 | 209715200 | 41910272 | 157089792 |
| cpu exhaustion | 3940 | 4224 | 22437 | 407388160 | 18907136 | 60194816 |
| audit-log spam | 23 | 15 | 42 | 30490624 | 18137088 | 63340544 |
| egress spam | 138 | 67 | 180 | 54345728 | 22151168 | 83640320 |
| STT flood | 800 | 276 | 933 | 228212736 | 51314688 | 205160448 |
| slow-loris equivalent | 384 | 183 | 269 | 129515520 | 37076992 | 133545984 |
| algorithmic complexity attack | 871 | 1992 | 7527 | 139231232 | 30031872 | 107544576 |

## Residuals

- STT flood and slow-loris tests use fail-closed unallowlisted-host sessions, not a live Deepgram-compatible WSS slow-loris server. This verifies native session allocation, egress denial, audit consistency, and handle recovery without making outbound calls.
- CUSUM monitoring was found TSAN-unsafe under concurrent ScorecardMonitor input flood; fixed by adding a monitor mutex. Regression coverage is now in this DoS suite and existing CUSUM tests.
- High-load HDC and BeliefStore tests slow JARVIS paths under sanitizer, but did not stop them or corrupt state.
