# JARVIS operator-attestation protocol

This module is the highest-trust gate for irreversible, high-stakes, or identity-affecting operations. Voice match is never sufficient.

## Protocol

1. JARVIS issues a challenge containing `version`, 256-bit random nonce, operation type, operation description, subject digest, operator id, enrolled-key fingerprint, issue time, and expiry time.
2. The operator signs the challenge canonical payload with the enrolled operator Ed25519 attestation key.
3. JARVIS verifies: known outstanding challenge, operation and description match, challenge is not expired, enrolled public key fingerprint matches, and Ed25519 signature verifies.
4. Every challenge, response, denial, and success is written to the tamper-evident audit log as `AUTHORITY_GATE`.
5. Challenge issuance is rate-limited. There is no bypass mode.

## Operations requiring attestation

- Re-anchor ceremony / post-birth identity change.
- Disable a defense layer, including temporarily allowing a cloud endpoint.
- Modify `CharacterValues`.
- Authorize voice-weight change / tripwire override.
- Authorize migration to new hardware.
- Authorize emergency-mode operation that bypasses standard refusal.
- Authorize irreversible external action: money, identity changes, or third-party API calls with side effects.

## Enrollment

`OperatorKeyEnrollmentCeremony::enroll_operator_public_key(...)` records the operator-bound Ed25519 public key and fingerprint. The current ceremony accepts the public key supplied by an external operator-side key holder. When `p5-soul-anchor-ceremony` lands, it must replace this stub with Secure Enclave / ceremony output and persist the enrollment record.

## Integration hooks

Use `AttestationGate` for the minimum high-stakes operations:

- `require_reanchor_confirmation`
- `require_defense_layer_disable`
- `require_character_values_modification`
- `require_voice_weight_change`
- `require_hardware_migration`
- `require_emergency_mode_bypass`
- `require_irreversible_external_action`

The operation may proceed only after `AttestationService::verify_response(...)` returns `AttestationStatus::valid` for the same operation type, description, and subject digest.

## p5 soul-anchor hook

Use `AttestationGate::require_reanchor_confirmation(...)` before any re-anchor confirmation. The re-anchor operation must proceed only after `OperationType::re_anchor_ceremony` verifies successfully.

## Build/test

```bash
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/identity/operator_attestation
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 8
ctest --test-dir build --output-on-failure
```
