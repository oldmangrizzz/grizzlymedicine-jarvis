# JARVIS Soul Anchor Birth Ceremony

Single-use macOS 14+ SwiftUI app for binding JARVIS's identity to this Mac's Secure Enclave, hardware fingerprint, an Ed25519 cold-root key on operator USB, the Soul Anchor key (the SE-resident P-256 identity key that signs all runtime challenges), and a 24-word BIP-39 paper backup.

## Flow
1. Refuses launch if `~/.jarvis/birth_cert.sealed`, `~/.jarvis/anchor_committed.json`, or an existing Soul Anchor key exists.
2. Detects removable USB volumes through DiskArbitration-backed monitoring.
3. Before any cold key is made, JARVIS records the operator's voice.
4. The screen says **“JARVIS is learning your voice”**, shows a large record button, a live voice level, the operator's name, and a plain-English dated script.
5. JARVIS records 16 kHz mono WAV audio, auto-stops at 45 seconds, allows stop after 25 seconds, plays it back, and lets the operator keep it or try again.
6. The accepted voice anchor is saved at `/Users/rbhanson/research/jarvis/_local_voice/operator_anchor.wav`; its hash is embedded in the birth certificate and audit trail.
7. Requires checkbox confirmation before USB use/format.
8. Requires initials and irreversible-action confirmations.
9. Generates libsodium Ed25519 cold-root key from locked seed/private-key memory.
10. Mints the non-exportable Soul Anchor key in Secure Enclave only; software fallback is refused.
11. Builds and signs the birth certificate using CharacterValues hashes, hardware fingerprint, cold-root public key, Soul Anchor public key, and operator voice-anchor hash.
12. Writes USB cold vault, Secure-Enclave-sealed local backup, and audit log.
13. Produces BIP-39 24-word paper backup and 16-hex ceremony hash.

## Atomicity and idempotency
Soul Anchor issuance is part of the same atomic birth flow as voice anchor, cold root, and birth certificate sealing. If issuance or any later write fails, the orchestrator audits `CEREMONY_ABORTED_SOUL_ANCHOR` or `ceremony_failed`, runs the rollback registry in reverse order, removes artifacts written in that run, surfaces the typed abort, and exits non-zero. If a Soul Anchor key is already present, the ceremony refuses with `.soulAnchorAlreadyPresent` and will not overwrite identity material.

## Threat model
Network is absent by design. The ceremony refuses without Secure Enclave, operator-confirmed USB, accepted operator voice anchor, and paper-backup confirmation. Local ceremony writes are restricted in code to `~/.jarvis`; USB writes are restricted to the selected removable volume. Voice anchor audio is written only under `_local_voice` on this Mac. Entitlements include no network capability.

## Voice anchor freshness gate
Each ceremony generates a 16-byte `CeremonyNonce` via `SecRandomCopyBytes(kSecRandomDefault, ...)`, which fails closed — any non-`errSecSuccess` status aborts the ceremony rather than falling back to weak randomness. Four words from a 256-entry BIP-39 phonetic table are derived from the nonce and embedded in the operator voice recording script; the operator speaks them aloud as part of the anchor. The stored voice-anchor digest is `SHA256(nonce ‖ audio_bytes)`, not plain `SHA256(audio_bytes)`. A verifier with a different nonce cannot reproduce the digest, so a recording captured under one ceremony cannot satisfy a different ceremony's freshness gate. The nonce hex is written into `ceremony_commit.v1.json` under `voiceAnchorNonceHex` for auditability.

## Recovery
If this Mac dies, recover with the USB cold vault or the BIP-39 paper backup. Re-anchor on new hardware only under operator-attestation through cockpit; the normal app remains single-use and refuses once anchored.

## Hardware-dependent tests
`swift test` uses mocked USB and mocked Secure Enclave for CI/build hosts. Real USB formatting and real Secure Enclave sealing require physical operator hardware and are not run automatically.

## Validation
- Build: `swift build --quiet`
- Smoke validation without hardware: `swift run JARVISCeremonySmoke --quiet`
- XCTest suite is in `Tests/JARVISCeremonyTests`; on this host `swift test` is blocked by the CommandLineTools Swift install not providing the `XCTest` module. The smoke runner covers the same mocked flow, refusal, mnemonic round-trip, and certificate verification stop conditions.

## App bundle
Run `tools/build_app.sh` to produce and ad-hoc sign `.build/JARVISCeremony.app` with hardened runtime and `Config/JARVISCeremony.entitlements`.
