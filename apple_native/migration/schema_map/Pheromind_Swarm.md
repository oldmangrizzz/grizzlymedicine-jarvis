# Pheromind / Swarm schema map

Accepted sources: `pheromind_state.json`, `stigmergy_state.json`, `swarm/pheromind_state.json`, and `swarm_state.json`.

| Source field | Destination field | Type coercion |
|---|---|---|
| `kind` | `pheromind_signals.kind` | UTF-8 text |
| `topic` | `pheromind_signals.topic` | UTF-8 text |
| `strength` | `pheromind_signals.strength` | real |
| `last_t` | `pheromind_signals.last_t` | Python monotonic/seconds as real |
| `depositors` | `pheromind_signals.depositors_json` | JSON preserved exactly |
| `vec` | `pheromind_signals.vec_hex` | bytes/hex/JSON digest -> hex |
| complete `swarm_state.json` | `organ_state('swarm')` | canonical JSON string |

Any unmapped signal field halts with `NO_MAPPING: Pheromind.<field>`.
