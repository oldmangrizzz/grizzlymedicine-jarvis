# OPERATOR_REPORT — Phase 7 memory-extraction resistance

Operator: Robert "Grizzly" Hanson, GMRI  
Runtime: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime`

## Result

Implemented memory-extraction hardening and adversarial tests under:
`/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/memory_extraction/`

## Defensive changes

- Added `security/memory_security.h` and `security/memory_security.cpp`.
- Core-dump suppression: `setrlimit(RLIMIT_CORE, 0)` at security module startup; operator override is `JARVIS_ALLOW_CORE_DUMPS=1`.
- libsodium startup: centralized `memory_security::ensure_sodium_initialized()`; audit grep now finds only one production `sodium_init` call, in `security/memory_security.cpp`.
- Audit HMAC key: locked/no-swap via `sodium_mlock`; zeroed/unlocked during destruction.
- Convex runtime secret: locked/no-swap after load/generation; zeroed/unlocked during destruction.
- Convex derived AES/HMAC keys: zeroed after use.
- CharacterValues mock Ed25519 private key: locked/no-swap and zeroed/unlocked on destruction.

## Coverage

Secret allocation coverage: 5/8 current-or-expected sensitive classes = 62.5%.  
Current implemented key-material coverage: 5/5 = 100%.

Covered:
1. Audit HMAC key.
2. Convex runtime secret.
3. Convex AES-GCM derived key locals.
4. Convex document-HMAC derived key locals.
5. CharacterValues mock Ed25519 private key.

Open GAPs are filed in `GAPs.md` for BeliefStore/H-MEM, transcript buffers, voice anchor buffers, continuity/operator attestation key paths, cert-pin immutability, privileged live dumps, and exception-path transient plaintext.

## FileVault

Host check returned: `FileVault is On.`

Assumption: FileVault remains enabled. If FileVault is disabled, alert operator; swap and hibernation secrecy are not compliant.

## Residuals

This does not defeat PID 0/root, kernel task access, entitled debuggers, malicious hypervisors, DMA-class physical attacks, or cold-boot extraction inside the operator trust domain. Full-disk encryption and privileged-access control remain operator responsibilities.
