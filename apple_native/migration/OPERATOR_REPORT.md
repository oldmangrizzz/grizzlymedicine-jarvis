# Operator report

Built under `/Users/rbhanson/research/jarvis/apple_native/migration/`:
- `jarvis-migrate` C++ SQLCipher migration runner with `--dry-run`, `--migrate`, and `--verify`.
- `jarvis-migrate-rollback` C++ rollback binary.
- Manifest generation with source hashes, row counts, schema map, audit bridge, and identity predecessor continuity.
- Operator-attestation gate; no `--force` exists.
- Voice guard that refuses `_local_voice` paths and halts on externally supplied voice-hash mismatch.
- Catch2 tests for dry-run, migration/verify, rollback, atomic failure, audit continuity, attestation, voice untouched, and per-organ round-trip.
- Prototype persistent-state survey in `schema_map/Prototype_State_Survey.md`.

Validated:
- `cmake --build ... --target test_migration jarvis-migrate jarvis-migrate-rollback` succeeded.
- `ctest --output-on-failure` passed: 8/8 tests.

Environment limits / gaps:
- Real production prototype stores outside `_baseline` were not destructively migrated; tests used synthetic state.
- Native HMEM/SAGE/endocrine persistence headers do not expose stable SQLCipher schemas yet, so those organs are stored in encrypted migration tables preserving exact values. Filed in `GAPS.md`.
