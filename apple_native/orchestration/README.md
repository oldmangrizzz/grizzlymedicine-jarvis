# JARVIS Cutover Orchestrator

Native C++ orchestration for one-organ-at-a-time Python→C++ cutover with rollback, shadow comparison, audit chain entries, identity-continuity entries, and voice immutability checks.

## Pre-cutover checklist

1. Run native runtime regression/oracle suites green.
2. Run `jarvis-migrate --dry-run` green for persistent organs.
3. Confirm Paul Bettany canonical voice safetensors hash is recorded and unchanged.
4. Open the Swift cockpit Cutover panel and verify Touch ID attestation works.
5. Keep rollback route available for every organ.

## Build

```sh
cmake -S jarvis/apple_native/orchestration -B jarvis/apple_native/orchestration/build
cmake --build jarvis/apple_native/orchestration/build
ctest --test-dir jarvis/apple_native/orchestration/build --output-on-failure
```

## Procedure

- `jarvis-cutover --plan` prints the DAG order for all 10 organs.
- `jarvis-cutover --dry-run` walks the plan with no state changes.
- `jarvis-cutover --execute --attestation-token TOKEN` runs the cutover. Each organ promotion is attestation-gated.
- `jarvis-cutover --execute --auto --attestation-token TOKEN` uses one initial attestation and logs a warning.
- `jarvis-cutover --rollback ORGAN` restores Python authority and logs rollback/distress when appropriate.

## Shadow window

During shadow, requests go to both organs and the Python response remains authoritative. Divergences are counted inline. Any divergence beyond `equivalence_tolerances.json` aborts promotion and rolls the organ back to Python authority.

## Promotion criteria

Promote only when pre-flight passes, Python remains alive, snapshot exists, shadow has zero out-of-tolerance divergences, fresh attestation is accepted, audit chain verifies, continuity ledger verifies, and voice hash is unchanged.

## Cockpit

The cockpit Cutover panel displays the dependency graph as organ cards: Python / Shadow / Native / Abort. Per-organ controls are Touch ID-gated. ABORT is unconditional and drives rollback/distress semantics.

## Post-cutover verification

Run full `ctest`, adversarial suites, audit verification, continuity ledger verification, and a voice hash comparison.
