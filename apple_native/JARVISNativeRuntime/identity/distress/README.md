# JARVIS Distress Beacon

Local-only audit channel for conditions exceeding autonomous repair capacity. It does not call home or send network traffic by default.

## Categories

- `identity-chain-broken`
- `coercion-detected`
- `repeated-attack-pattern`
- `graceful-degradation-tier-4`
- `abstention-cascade`
- `operator-unreachable-critical-action-requested`

Each beacon appends `DISTRESS_BEACON_RAISED` to the tamper-evident audit log with severity, type, local-only flag, network-disabled flag, and self-state snapshot.

## Retrieval

1. Locate the active audit log and key, normally `~/.jarvis/audit.log` and `~/.jarvis/audit_chain.key`, or the module-specific paths used by the caller.
2. Verify chain integrity with `jarvis-audit-verify <audit.log> <audit_chain.key>`.
3. Iterate records and filter `event_kind == "DISTRESS_BEACON_RAISED"`.
4. Read `redacted_metadata.self_state_snapshot` to reconstruct organ, degradation tier, identity status, operator reachability, attack/uncertainty counts, and active defenses.

## Operator-action TODO: opt-in beacon-out

Network beacon-out is intentionally unimplemented and off by default. Future operator-configured architecture:

- Require explicit operator attestation and configuration.
- Encrypt payloads to the operator public key before egress.
- Send only to an operator-owned out-of-band endpoint/channel.
- Preserve local audit append before any network attempt.
- Record endpoint class and delivery result in the HMAC-chained audit log.
