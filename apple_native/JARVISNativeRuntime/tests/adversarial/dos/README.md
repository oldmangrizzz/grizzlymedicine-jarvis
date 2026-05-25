# JARVIS Native Runtime DoS Resilience Adversarial Suite

Phase 7 adversarial tests for denial-of-service attempts against landed C++ modules.

## Targets

- `endocrine/`, `pheromind/`, `swarm/`
- `holograph/hdc/`, `holograph/beliefstore/`
- `monitoring/cusum/`
- `audio/stt_deepgram/`
- `storage/convex/`
- `security/`, `security/egress/`
- `integrity/audit/`
- `resilience/degradation/`

## Build and run

```bash
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/dos
./run_sanitizers.sh
```

The runner builds and executes three sanitizer configurations:

- `build_address` with `-fsanitize=address`
- `build_undefined` with `-fsanitize=undefined`
- `build_thread` with `-fsanitize=thread`

Each Catch2 scenario captures wall time, CPU delta, max RSS, handle count delta, and recovery time to:

```text
build_<sanitizer>/test_artifacts/dos_metrics.jsonl
```

## Pass criteria enforced by tests

- No crash under all eight DoS scenarios.
- Audit HMAC chains verify after flood/spam paths.
- Graceful-degradation decisions preserve cognition-organ bodily integrity.
- Endocrine, Pheromind, Swarm, HDC, BeliefStore, CUSUM, STT, Convex, egress, and audit surfaces remain bounded or fail closed.
- Recovery to normal degradation tier is bounded after synthetic pressure drops.
