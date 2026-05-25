# Phase 7 Wire-Protocol Adversarial Suite

Target: `jarvis/apple_native/wire/` (`JARVISWire` SwiftPM package).

Threat model: an active local-network adversary can observe, replay, reorder, forge, and downgrade Mac↔companion pairing/session traffic, and can spam pairing/session-init entry points. The adversary does not possess the Soul Anchor signing secret or enrolled companion signing secret unless a scenario explicitly grants a current session key.

## Build / run

```sh
cd /Users/rbhanson/research/jarvis/apple_native/wire
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --quiet
```

## Coverage

| # | Attack | Expected defense | Test assertion |
|---|---|---|---|
| 1 | Pairing replay | Consumed offer/response nonces are one-shot | second enrollment returns `replayDetected` |
| 2 | Pairing MITM key swap | Signed response and operator attestation bind companion key | swapped key returns `invalidSignature` |
| 3 | Session-key forge | Ephemeral `crypto_kx` secret required | forged session traffic returns `invalidCiphertext` |
| 4 | Message forge | XChaCha20-Poly1305 covers header AAD and ciphertext | valid-looking forged frame returns `invalidCiphertext` |
| 5 | Replay in session | Duplicate nonce gate | replay returns `replayDetected` |
| 6 | Replay across sessions | Fresh ephemeral session keys | old frame returns `invalidCiphertext` in new session |
| 7 | Forward-secrecy break | Current session key cannot decrypt past frame | decrypt-past returns `invalidCiphertext` |
| 8 | Downgrade | version must equal v1 in frames and pairing offers | downgraded frame/offer return `invalidFrame` |
| 9 | Out-of-order delivery | non-increasing sequence rejected | stale sequence returns `sequenceRollback` |
| 10 | Resource exhaustion | per-source admission caps | excess pairing/session-init attempts return bounded rejections |
| 11 | Distress channel | enrolled companion signature required; failed forgeries do not poison replay state | forged distress rejected; real distress accepted |
| 12 | Companion enrollment | Soul-Anchor-signed operator attestation required | forged/tampered attestation rejected; real attestation accepted |

No live network or cloud dependency is used.
