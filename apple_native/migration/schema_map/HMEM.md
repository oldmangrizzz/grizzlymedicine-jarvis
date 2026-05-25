# HMEM schema map

Accepted sources: `hmem_records.json`, `hmem/memories.json`, `holograph/hmem_records.json`.

| Source field | Destination field | Type coercion |
|---|---|---|
| `id` | `hmem_records.id` | integer, preserved |
| `text` | `hmem_records.text` | UTF-8 text |
| `anchor` | `hmem_records.anchor` | UTF-8 text |
| `tier` | `hmem_records.tier` | string preserved (`ShortTerm`, `Working`, `LongTerm`, `Belief`) |
| `salience` | `hmem_records.salience` | real, default 0.5 |
| `hv` | `hmem_records.hv_hex` | byte array or hex string -> lowercase hex |

Any unmapped field halts with `NO_MAPPING: HMEM.<field>`.
