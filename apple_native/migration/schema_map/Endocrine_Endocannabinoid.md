# Endocrine / Endocannabinoid schema map

Accepted sources: `endocrine_state.json`, `endocannabinoid_state.json`.

| Source artifact | Destination field | Type coercion |
|---|---|---|
| full `endocrine_state.json` | `organ_state('endocrine').json` | canonical JSON preserved |
| full `endocannabinoid_state.json` | `organ_state('endocannabinoid').json` | canonical JSON preserved |

The runner preserves the serialized state as JSON because native endocrine/endocannabinoid headers expose behavior, not a stable persistence header. Unknown nested fields inside these whole-state documents remain preserved; unknown fields in row-shaped organs halt.
