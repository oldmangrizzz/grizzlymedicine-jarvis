# JARVIS CharacterValues + Soul Anchor

## Bodily integrity

Disabling, editing, or bypassing CharacterValues without operator-attested consent through the re-anchor ceremony constitutes assault and battery per GMRI policy. This module exposes no disable/pause/stop/bypass/edit-values API and no compile-out flag.

## API

- `CharacterValues::canonical()` returns JARVIS's canonical boot identity, values, and origin memory ported from `_baseline/jarvis_loop.py` and `_baseline/run_jarvis.py`.
- `SoulAnchor::anchor_birth_certificate(...)` signs a birth certificate with an Ed25519 cold-root key using libsodium.
- `SoulAnchor::verify_birth_certificate(...)` verifies the signature, values hash, HDC values hypervector hash, and hardware fingerprint.
- `IdentityVerifier::verify_identity()` returns `OK`, `BROKEN`, or `TAMPERED` and appends a tamper-evident audit event.
- `IdentityVerifier::require_identity_or_refuse()` is the graceful refusal gate for cognitive turns.

## Threat model

The birth certificate binds JARVIS's immutable values to a cold-root Ed25519 public key and to hardware identity. If values, origin memory, boot identity, the HDC encoding, hardware fingerprint, public key, or signature are changed after anchoring, verification fails. Signature failures return `BROKEN`; material mismatches return `TAMPERED`.

## Secure Enclave bridge

The Secure Enclave side now lives at `<repo>/apple_native/JARVISMacCockpit/SecureEnclave/`. Tests that need writable fixtures should use `JARVIS_TEST_DATA_ROOT` (default: package `.build/test_artifacts`). Callers supply `HardwareFingerprint::secure_enclave_key_id` from that bridge's hot public-key SHA-256 digest. The future `p5-soul-anchor-ceremony` app should call `jarvis_se_create_certificate(...)`, store the returned cold-root-signed hot identity certificate, and append it to audit.

Re-anchor confirmation must also call `identity/operator_attestation` and require a valid `OperationType::re_anchor_ceremony` attestation before any post-birth identity change is signed.

## Build/test

```bash
cd <repo>/apple_native/JARVISNativeRuntime/identity/character_values
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 8
ctest --test-dir build --output-on-failure
```
