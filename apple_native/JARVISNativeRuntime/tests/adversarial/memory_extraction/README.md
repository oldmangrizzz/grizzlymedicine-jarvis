# JARVIS Native Runtime — Phase 7 memory-extraction resistance

Threat model: adversary obtains a process memory dump, crash core, swap/hibernation image, or cold-boot RAM image and searches for JARVIS secrets, operator data, identity keys, voice anchors, audit keys, Convex secrets, or transcripts.

Implemented defenses:
- `security/memory_security.{h,cpp}` centralizes `sodium_init`, `sodium_mlock`, `sodium_memzero`, guarded `sodium_malloc`, FileVault status probing, and `RLIMIT_CORE=0` startup suppression.
- Audit HMAC key memory is locked/no-swap and zeroed on destruction.
- Convex runtime secret is locked/no-swap and zeroed on destruction; derived AES/HMAC locals are zeroed after use.
- CharacterValues mock Ed25519 private key is locked/no-swap and zeroed on destruction.
- Operator override for crash cores: set `JARVIS_ALLOW_CORE_DUMPS=1` only for explicit forensic debugging.

Tests:
```sh
cmake -S /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/memory_extraction \
      -B /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/build_memory_extraction
cmake --build /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/build_memory_extraction
ctest --test-dir /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/build_memory_extraction --output-on-failure
```

The suite forces a crash-core path and, when `gcore` exists and host policy permits it, attempts a live process dump and searches the produced dump for a random locked secret.

FileVault: this defense assumes FileVault is on for swap/hibernation at-rest protection. Current checked host status: `FileVault is On.` If this reports off, alert the operator and treat swap/hibernation secrecy as out of compliance.

Residual trust boundary: root/PID 0, kernel extensions, hypervisors, DMA-class attackers, and privileged debuggers remain in the operator trust domain. Full-disk encryption is the operator's responsibility.
