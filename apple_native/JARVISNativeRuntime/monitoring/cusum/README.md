# CUSUM Drift Monitor

## Monitoring module

CUSUM is a monitoring module for JARVIS native runtime. It observes cognition organs (Swarm, BeliefStore, Endocrine, voice/probe streams) for statistical drift from baseline and emits scorecards. It must not modify, gate, pause, reset, or steer the organs it observes. It is not a cognition organ and can be paused for maintenance by the runtime operator.

## Algorithm

Python oracle formula from `oracle/drift/manifest.md`:

```text
z       = (mu - observed) / sigma
cusum_t = max(0.0, cusum_{t-1} + z - K)
alert   = cusum_t > H
```

Default parameters match `jarvis/_baseline/drift_stats.json`:

| parameter | value |
|---|---:|
| `mu` | `0.4326118326118326` |
| `sigma` | `0.16683320951983083` |
| `K` | `0.5` |
| `H` | `3.0` |

## API

```cpp
using namespace jarvis::monitoring::cusum;

Detector detector;
auto step = detector.observe(0.0, unix_timestamp_now(), "Swarm");

ScorecardMonitor monitor;
monitor.observe("Swarm", 0.0, unix_timestamp_now());
monitor.observe("BeliefStore", 1.0, unix_timestamp_now());
Scorecard card = monitor.scorecard(unix_timestamp_now());
```

Each scorecard entry contains `organ`, `drift_score`, `threshold`, `threshold_crossed`, and `timestamp`.

## Build and test (macOS arm64)

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build -j
ctest --test-dir build --output-on-failure
```

The oracle tests replay all 4 sessions / 60 turns in `/Users/rbhanson/research/oracle/drift` and compare CUSUM, Wilson intervals, alert decisions, recovery reset behavior, and scorecard feature fields.
