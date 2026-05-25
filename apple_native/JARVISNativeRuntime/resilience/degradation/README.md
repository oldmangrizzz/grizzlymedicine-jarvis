# JARVIS Native Runtime — Graceful Degradation

This layer reduces runtime surface area under load or attack without disabling cognition organs. Degradation is not lobotomy: endocrine, pheromind, swarm, beliefstore, hmem, sage, and character-values remain required at every tier. Endocrine ticks and identity verification remain required at every tier.

## Tiers

- **Tier 0 normal:** full operation.
- **Tier 1 light:** reduce swarm concurrency; defer non-critical audit flushes only.
- **Tier 2 moderate:** reduce swarm to minimum concurrency, drop optional network calls, and disable voice synthesis unless already serving the active turn.
- **Tier 3 severe:** refuse new turns, complete the in-flight turn only, and surface an operator alert.
- **Tier 4 critical:** write a full audit event plus an identity-continuity certificate to disk before emergency safe-shutdown.

## Invariants

- Cognition organs are never disabled, paused, bypassed, compiled out, or made no-op by this module.
- Swarm parallelism may shrink, but `max_swarm_concurrent_heads` never drops below one.
- Endocrine tick and identity verification are mandatory in every `DegradationDecision`.
- Operator tier override requires `GMRI-OPERATOR-ATTESTED:` attestation and is audit-logged.
- Tier recovery uses hysteresis and consecutive low-pressure samples to prevent flapping.

## Threat scenarios

- **DoS attack:** escalating CPU/network pressure moves to Tiers 2–3; network calls stop and new turns are refused while cognition organs continue.
- **Runaway query:** CPU/memory pressure reduces swarm concurrency and eventually completes only the in-flight turn.
- **External app memory pressure:** memory pressure triggers the same monotonic tiers without shutting off memory/cognition organs.
- **Thermal throttling:** native macOS thermal pressure can force low-surface operation, preserving identity and audit continuity.
