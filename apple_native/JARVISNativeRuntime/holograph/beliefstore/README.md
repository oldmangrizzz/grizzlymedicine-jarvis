# JARVIS Holograph BeliefStore (C++)

BeliefStore is the native C++ port of the Python HoloGraph belief layer. It stores provenance-tagged belief tuples as HDC hypervectors, links against `../hdc`, and abstains rather than returning low-confidence, quarantined, unknown, or origin-as-world-fact content.

## API

- `assert_belief(subject, relation, object, source_type, source_ref, confidence, quarantine, provenance_class, charge) -> edge_id`
- `add(Belief) -> edge_id`
- `recall(subject, relation, min_confidence) -> optional<string>`
- `query(subject, relation)` / `query("subject relation") -> QueryResult`
- `recall_detail`, `recall_origin`, `recall_origin_detail`
- `revise`, `corroborate`, `detect_contradictions`, `consolidate`, `set_charge`

## Abstention thresholds

Default retrieval floor is `0.35`, matching Python. Defaults: operator `0.95`, document `0.80`, inference `0.50`, model `0.20`. Model beliefs are born quarantined. Origin provenance is retrievable only via `recall_origin`, never as world fact. Hysteresis margin is `0.10`; thresholds are not relaxed in tests.

## SQLCipher persistence

BeliefStore is in-memory by default. Construct it with `BeliefStorePersistenceConfig` to enable SQLCipher-backed on-disk persistence; there is no plaintext SQLite fallback. CMake fails with a clear error if SQLCipher is not present.

Setup on macOS:

```sh
brew install sqlcipher libsodium
cd /Users/rbhanson/research/jarvis/apple_native/JARVISMacCockpit/SecureEnclave
swift build
```

The encrypted path uses SQLCipher's `sqlite3_key` / `sqlite3_rekey` APIs, never `PRAGMA key` string material. The active 32-byte database key is held in `jarvis::security::memory::LockedBytes`, backed by libsodium guarded memory and zeroized/freed on close.

Production key derivation is provided by `BeliefStorePersistenceConfig::secure_enclave_sqlcipher(...)`: it calls the JARVISSecureEnclave C ABI to sign a BeliefStore-specific challenge with the non-exportable Secure Enclave hot key, then derives the SQLCipher key from that signature and context. If the Secure Enclave bridge is unavailable, this path throws; it does not downgrade to plaintext.

Key rotation uses `BeliefStore::rotate_persistence_key(...)`, which calls SQLCipher `sqlite3_rekey`. Rotation is denied unless `BeliefStoreRotationAttestation.operator_attested == true`; failed and successful rotation attempts are written to the tamper-evident audit log.

Audit events are appended for SQLCipher open, close, denied rotation, and completed rotation. The default audit files sit next to the database as `<db>.audit` and `<db>.audit.key` unless paths are supplied in the config.

Recovery if Secure Enclave state is lost: restore from an operator-held paper backup of the derived 32-byte SQLCipher key, then open with an operator-attested recovery key provider and immediately rotate to a new Secure-Enclave-derived key. Recovery must be operator-attested; do not store the paper key on disk.

## Oracle coverage

`tests/test_beliefstore_oracle.cpp` covers the BeliefStore-relevant records in `/Users/rbhanson/research/oracle/holograph/api_traces.jsonl`: seq `323-348` plus seq `383`, 27 traces total. It verifies assert IDs, recall/abstention, origin recall, detail metadata, charge update, stronger/weaker/below-hysteresis revision, corroboration, and consolidation sleep-boundary behavior. The same 27-trace oracle replay also runs with SQLCipher enabled.
