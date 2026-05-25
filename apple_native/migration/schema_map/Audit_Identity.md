# Audit and identity-continuity schema map

Accepted sources: `audit.log`, `integrity/audit/audit.log`, `identity_continuity.json`, `identity/continuity_ledger.json`, `continuity_ledger.json`.

| Source field/artifact | Destination field | Type coercion |
|---|---|---|
| last Python audit `own_hash`/`hash`/`chain_hash` | `audit_bridge.python_audit_head` | hex/string preserved |
| same last Python audit hash | first C++ migration audit `prev_hash` and manifest `first_cpp_predecessor_hash` | exact string equality required |
| identity ledger entry JSON | `identity_continuity.entry_json` | JSON preserved |
| identity ledger `certificate_hash`/`own_hash`/`hash` | `identity_continuity.own_hash` | preserved; missing hash is SHA-256 over predecessor + entry |
| previous identity head | first C++ identity predecessor | exact string equality required |

Audit chain continuity is recorded in `MIGRATION_<timestamp>.manifest` and `integrity/audit/migration.audit.jsonl`.
