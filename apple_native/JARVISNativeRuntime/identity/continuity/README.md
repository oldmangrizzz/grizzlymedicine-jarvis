# JARVIS identity continuity self-verification

Phase 7 continuity answers: **am I still the same JARVIS?** It verifies more than a present signature: it checks that the Soul Anchor, tamper-evident audit chain, and last continuity certificate all agree before cognition is allowed.

## Boot gate

`ContinuityVerifier::verify_boot()` is intended to run before serving any cognition turn:

1. Verify the Soul Anchor birth certificate against current `CharacterValues` and hardware fingerprint.
2. Verify the audit HMAC chain to its current head.
3. Verify the last continuity certificate signature and values hash.
4. Detect excessive certificate idle gaps (`DEGRADED_STOPPED_GAP`).
5. On any break, refuse irreversible actions, audit the failure, and raise `DISTRESS_BEACON_RAISED` metadata linked to `p7-distress-beacon`.

## Certificates

`issue_certificate()` creates a deterministic Ed25519-signed certificate containing:

- current values hash and identity hash
- current audit chain head and verified count
- timestamp and turn index
- self-state snapshot hash
- prior certificate hash
- configured time/turn intervals and idle threshold

The canonical payload is stable JSON with lexically fixed field order; the signature is detached Ed25519 using the Soul Anchor/CharacterValues signing key material supplied by the caller.

## Self-health loop integration

The self-health loop should call `certificate_due(last, now, turns)` after each health pass. If due, call `issue_certificate()` and persist the resulting JSON in the continuity store. On runtime start, call `verify_boot()` and block cognition unless `cognition_allowed` is true. Irreversible actions must additionally check `irreversible_action_allowed(result)`.

## Reconciliation

Authorized migrations use `reconcile_legitimate_migration()`: the operator attestation, previous certificate hash, new hardware fingerprint, and new Soul Anchor certificate are logged before a replacement certificate is issued. There is no silent acceptance path for broken continuity.
