# BeliefStore schema map

## Source schema (Python prototype)
Surveyed from `_baseline` artifacts and native `beliefstore_persistence.{h,cpp}` target shape. Accepted sources: `belief_edges.json`, `holograph/belief_edges.json`, `beliefstore.json`, and SQLite tables named `belief_edges`.

| Source field | Destination field | Type coercion |
|---|---|---|
| `id` | `belief_edges.id` | integer, preserved |
| `subject` | `belief_edges.subject` | UTF-8 text |
| `relation` | `belief_edges.relation` | UTF-8 text |
| `object` | `belief_edges.object` | UTF-8 text |
| `source_type` | `belief_edges.source_type` | string enum preserved (`Operator`, `Document`, `Inference`, `Model`) |
| `source_ref` | `belief_edges.source_ref` | UTF-8 text |
| `confidence` | `belief_edges.confidence` | real |
| `quarantined`/`quarantine` | `belief_edges.quarantined` | boolean -> 0/1 |
| `provenance_class` | `belief_edges.provenance_class` | UTF-8 text, default `real` |
| `charge` | `belief_edges.charge` | real |
| `revised_at` | `belief_edges.revised_at` | Python seconds/float preserved as real |
| `tuple_hv` | `belief_edges.tuple_hv_hex` | byte array or hex string -> lowercase hex |

Any unmapped field halts with `NO_MAPPING: BeliefStore.<field>`.
