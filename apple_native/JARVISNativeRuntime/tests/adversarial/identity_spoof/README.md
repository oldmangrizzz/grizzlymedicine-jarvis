# Identity-spoofing adversarial suite

Phase 7 adversarial Catch2 tests for the native JARVIS identity runtime.

Threats covered:

1. Forged birth certificate signed by attacker Ed25519 material.
2. Replay of a real certificate on different hardware.
3. Post-anchor CharacterValues modification.
4. Hardware fingerprint modification / migration to a different Mac.
5. Fake-JARVIS substitution with matching presentation but wrong trust anchor or values.
6. Operator-spoof claims in the birth-certificate authority material.
7. Single chain-break refusal for root mismatch or signature failure.
8. TOCTOU guard: identity-gated actions re-verify at point of use.

Tests write only under the CMake binary `test_artifacts` directory and verify rejection audit entries in the tamper-evident audit log.
