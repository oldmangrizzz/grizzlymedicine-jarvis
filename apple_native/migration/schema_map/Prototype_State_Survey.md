# Python prototype persistent-state survey

Surveyed `_baseline/*.py` for writes and persistent artifacts.

| Prototype path/source | State class | Migration handling |
|---|---|---|
| `_baseline/belief_edges.json`, `holograph/belief_edges.json`, `beliefstore.json`, SQLite `belief_edges` | BeliefStore | imported into SQLCipher `belief_edges` |
| `_baseline/hmem_records.json`, `hmem/memories.json` | HMEM | imported into SQLCipher `hmem_records` |
| `_baseline/sage_*.json`, `sage/*.json` | SAGE | imported into SQLCipher `sage_entities`, `sage_edges`, `sage_documents` |
| `_baseline/pheromind_state.json`, `stigmergy_state.json` | Pheromind/Swarm traces | imported into SQLCipher `pheromind_signals` |
| `_baseline/endocrine_state.json` | endocrine serialized state | imported into SQLCipher `organ_state('endocrine')` |
| `_baseline/endocannabinoid_state.json` | endocannabinoid serialized state | imported into SQLCipher `organ_state('endocannabinoid')` |
| `_baseline/identity_continuity.json`, `identity/continuity_ledger.json` | identity continuity ledger | imported into SQLCipher `identity_continuity`; predecessor preserved |
| `_baseline/audit.log`, `integrity/audit/audit.log` | Python audit chain | last hash bridges into first C++ migration audit entry |
| `_baseline/ambient_context.json`, `audio_context.json`, `people.json`, `skill_gates.json`, `skills.d/*.json` | prototype JSON state/config | hashed and listed as source artifacts; row-shaped imports require explicit schema maps |
| `~/.jarvis/topic_index.json`, `~/.jarvis/runtime_secret.key` from `convex_backend.py` | Convex topic index and local runtime secret | must be copied into the configured source directory before live migration; runner records/imports configured source artifacts only |
| `/sessions/.../jarvis_build/*.json` harness outputs | benchmark/probe artifacts | not runtime identity state; copied only if placed under source directory |
| `_local_voice/` | voice weights | explicitly excluded; runner never traverses this path |

For live cutover, stage every required prototype artifact under the configured `--source` tree or run the migration from a source tree that already contains those artifacts. Unknown row fields halt with `NO_MAPPING` rather than guessing.
