# Operator-facing report: Phase 7 Wire-Protocol adversarial suite

| Attack | Result | Notes |
|---|---:|---|
| Pairing replay | Rejected | `PairingAdmissionController` consumes offer and response nonces once. |
| Pairing MITM | Rejected | Companion key substitution breaks signed response / operator attestation binding. |
| Session-key forge | Rejected | Random attacker `crypto_kx` keys cannot produce receiver-valid AEAD traffic. |
| Message forge | Rejected | Valid-looking sequence/nonce/timestamp fails XChaCha20-Poly1305 authentication. |
| Replay in session | Rejected | Duplicate nonce is rejected. |
| Replay across sessions | Rejected | Fresh session keys prevent decrypting old frames in a new session. |
| Forward-secrecy break | Rejected | Compromised current receive key cannot decrypt past session frame. |
| Downgrade | Rejected | Frame and pairing-offer versions must match protocol v1. |
| Out-of-order delivery | Rejected | Stale sequence returns `sequenceRollback`. |
| Resource exhaustion | Bounded | Per-source pairing/session-init caps reject excess attempts without crash. |
| Distress channel | Preserved | Forged distress is rejected; legitimate enrolled-companion distress remains accepted. |
| Companion enrollment | Rejected without attestation | Enrollment now requires Soul-Anchor-signed operator attestation. |

Overall: the suite covers all requested Phase 7 attacks with deterministic local XCTest cases and a concrete `MockWireAdversary` implementation.
