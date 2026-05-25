# JARVIS Phase 7 Soak Operator Report

Operator: Robert "Grizzly" Hanson, GMRI

## Verdict

- Completed: yes
- Passed invariant gate: yes
- Requested duration: 35 seconds
- Elapsed: 36330 ms
- Turns: 23
- Endocrine ticks: 62
- Identity verifications: 5
- Audit chain length: 65

## Resource Bounds

| Metric | Baseline | Peak | Bound |
|---|---:|---:|---:|
| RSS | 6717440 B (6.41 MiB) | 7897088 B (7.53 MiB) | baseline + 268435456 B (256.00 MiB) |
| File descriptors | 6 | 6 | baseline + 64 |
| Threads | 1 | 2 | baseline + 64 |

## Fault Recovery

| Fault | Outcome | Recovery seconds |
|---|---|---:|
| endocrine_extreme_stimulus | recovered | 0.000 |
| pheromind_deposit_storm | recovered | 0.000 |
| swarm_single_head_failure | recovered | 0.000 |
| hdc_nan_inf_similarity | recovered | 0.000 |
| beliefstore_abstention_cascade | recovered | 0.000 |
| hmem_tier_exhaustion | recovered | 0.000 |
| sage_interrupt_consolidation | recovered | 0.000 |
| audit_disk_full_append | recovered | 0.000 |
| network_convex_drop | recovered | 0.000 |
| stt_websocket_drop | recovered | 0.000 |
| degradation_external_load | recovered | 11.085 |
| identity_secure_enclave_unavailable | recovered | 0.000 |
| time_monotonic_jitter | recovered | 0.000 |
| filesystem_transient_read_failure | recovered | 0.000 |
| endocrine_extreme_stimulus | recovered | 0.000 |
| pheromind_deposit_storm | recovered | 0.000 |
| swarm_single_head_failure | recovered | 0.000 |
| hdc_nan_inf_similarity | recovered | 0.000 |
| beliefstore_abstention_cascade | recovered | 0.000 |
| hmem_tier_exhaustion | recovered | 0.000 |
| sage_interrupt_consolidation | recovered | 0.000 |
| audit_disk_full_append | recovered | 0.000 |

## Invariant Violations

None.

## GAPs Filed

See `GAPs.md`.
