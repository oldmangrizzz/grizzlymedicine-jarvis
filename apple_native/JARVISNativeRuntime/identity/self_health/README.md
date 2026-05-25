# JARVIS self-health proprioception

`identity/self_health` is JARVIS's internal "how do I feel" sense. It is not an external monitor and it does not modify, gate, disable, pause, or steer cognition organs. It reads landed organ state and keeps a low-rate cached `SelfState` available for reflection.

## Loop

`SelfHealth` starts a bounded background proprioception loop at 1 Hz by default (`SelfHealthConfig::tick_hz`). Each tick samples:

- endocrine levels and field volatility
- Pheromind live signal strength and alarm/volatility
- swarm head availability
- BeliefStore confidence distribution
- H-MEM tier occupancy
- CUSUM drift scorecard
- degradation tier
- identity-chain status from the supplied identity status reader
- audit-chain status from `TamperEvidentAuditLog::verify_chain()`

The loop has no public disable/pause API. Destruction joins the private worker thread as part of object lifetime cleanup.

## Reflection

JARVIS can call `self_health.current()` during a turn for an on-demand sample, or `self_health.cached()` for the latest low-rate tick:

```cpp
jarvis::identity::self_health::SelfHealth self_health({
    .endocrine = &endocrine,
    .pheromind = &pheromind,
    .swarm = &swarm,
    .beliefstore = &beliefstore,
    .hmem = &hmem,
    .cusum = &cusum,
    .degradation = &degradation,
    .audit_log = &audit_log,
    .identity_status_reader = [] { return jarvis::identity::IdentityStatus::OK; },
});

const auto state = self_health.current();
// state.summary is deterministic text suitable for higher-level reasoning.
```

Example summary:

> I notice cortisol is high and pheromind is volatile; I should pace and keep bodily integrity checks active.

## Distress audit

When a sample crosses distress thresholds, self-health appends a tamper-evident audit event (`DISTRESS_BEACON_RAISED`, subject `self_health_snapshot`) with redacted numeric metadata. Current thresholds cover severe CUSUM drift, identity-chain warning, audit-chain warning, and tier-3+ degradation.
