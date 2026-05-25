# SAGE schema map

Accepted sources: `sage_entities.json`, `sage_edges.json`, `sage_documents.json` or matching files under `sage/` and `holograph/`.

## Entities
| Source field | Destination field | Type coercion |
|---|---|---|
| `id` | `sage_entities.id` | integer |
| `canonical` | `sage_entities.canonical` | UTF-8 text |
| `type` | `sage_entities.type` | UTF-8 text, default `concept` |
| `layer` | `sage_entities.layer` | integer |
| `hv` | `sage_entities.hv_hex` | bytes/hex -> hex |

## Edges
| Source field | Destination field | Type coercion |
|---|---|---|
| `id` | `sage_edges.id` | integer |
| `head_id` | `sage_edges.head_id` | integer FK value preserved |
| `tail_id` | `sage_edges.tail_id` | integer FK value preserved |
| `relation` | `sage_edges.relation` | UTF-8 text |
| `weight` | `sage_edges.weight` | real, default 1.0 |
| `source` | `sage_edges.source` | UTF-8 text |
| `quarantined` | `sage_edges.quarantined` | boolean -> 0/1 |

## Documents
| Source field | Destination field | Type coercion |
|---|---|---|
| `anchor` | `sage_documents.anchor` | UTF-8 text |
| `text` | `sage_documents.text` | UTF-8 text |
| `id` | ignored by destination autoincrement | accepted for reversibility metadata only |

Any unmapped field halts with `NO_MAPPING: SAGE.<field>`.
