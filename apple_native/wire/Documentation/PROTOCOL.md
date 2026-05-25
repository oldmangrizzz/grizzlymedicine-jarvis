# JARVIS Host/Companion Wire Protocol v1

## Roles

- **HOST:** `JARVISMacCockpit` on Mac. Holds cognition organs and the Soul Anchor signing authority.
- **COMPANION:** iOS/watchOS surfaces. They provide sensors/effectors and never run cognition organs.
- **Operator:** Robert "Grizzly" Hanson, GMRI.

Default transport is local network: Bonjour discovery plus `NWConnection` or MultipeerConnectivity. Cloud relay is out of scope by default; any future relay must carry the same encrypted frames and must not receive plaintext or keys.

## Cryptography

All cryptography is libsodium:

- Long-term identity and ceremony signatures: Ed25519 (`crypto_sign_detached`, `crypto_sign_verify_detached`).
- Forward secrecy: per-session ephemeral keypairs (`crypto_kx_keypair`) and role-specific session keys (`crypto_kx_server_session_keys` on Mac, `crypto_kx_client_session_keys` on companions).
- Message confidentiality/integrity: XChaCha20-Poly1305 IETF AEAD with the `crypto_kx` transmit/receive keys.
- Nonces: 24 random bytes per encrypted frame.

No custom crypto, no unauthenticated cognition traffic.

## Pairing ceremony

1. Mac creates a `PairingOffer` containing host ID, operator ID, Soul Anchor public key, nonce, expiry, and endpoint hints.
2. Mac signs the canonical unsigned offer with the Soul Anchor signing key.
3. Mac encodes the offer as `jarvis-wire://pair?offer=<base64url-json>` for QR display.
4. Companion scans the QR, verifies the Soul Anchor signature, and displays/verifies the short code derived from `(anchorPublicKey || offerNonce || hostID)`.
5. Companion creates an Ed25519 device signing key and returns a signed `PairingResponse` binding companion ID/kind/key to the offer nonce and short code.
6. Operator attestation is recorded as a Soul-Anchor-signed `OperatorAttestation` binding operator ID, offer nonce, companion signing key, short code, and approval timestamp.
7. Mac verifies the response and operator attestation, consumes the offer/response nonces once through admission control, and signs a `PairingRecord`, binding the companion signing key to JARVIS's Soul Anchor.

The pairing record is the companion's authorization credential for future sessions and degraded distress fallback. Enrollment without valid operator attestation is rejected.

## Session handshake

Each connection uses fresh ephemeral `crypto_kx` keys.

`SessionHello` fields:

- `role`: `host` or `companion`
- `deviceID`
- `sessionID`
- `anchorPublicKey`
- `ephemeralPublicKey`
- `nonce`
- `createdAtUnixMs`
- `signature`

The signature covers all fields except `signature`. Peers reject wrong roles, stale timestamps, invalid signatures, or anchors that do not match the trusted pairing/Soul Anchor public key. Host derives server session keys; companions derive client session keys. Reconnecting rotates keys.

## Framing

Every encrypted frame is length-prefixed big-endian binary:

```text
uint32 frameLength
uint8  version = 1
uint8  messageType
uint8  flags
uint64 sequence
int64  timestampUnixMs
bytes24 nonce
uint32 ciphertextLength
bytes  ciphertext
```

AEAD associated data is exactly:

```text
version || messageType || flags || sequence || timestampUnixMs || nonce
```

Ciphertext is canonical JSON `WirePayload` encrypted with the sender's transmit key. Receiver decrypts with its receive key.

## Replay protection

Receivers maintain a `ReplayProtector` per session/channel:

- reject duplicate nonces;
- reject timestamps outside the configured skew window (default 300 seconds);
- reject non-increasing sequence numbers.

Pairing admission additionally consumes offer/response nonces once and bounds per-source pairing/session-init floods. Distress fallback uses the same nonce/timestamp replay gate, with timestamp-derived ordering when an encrypted sequence is unavailable.

## Message types

| Type | Value | Direction | Purpose |
|---|---:|---|---|
| `input` | 1 | companion → host | Voice/text/touch/sensor input for Mac cognition. |
| `output` | 2 | host → companion | Text/audio/haptic/display directives. |
| `status` | 3 | both | Battery, network, readiness, surface state. |
| `distress` | 4 | companion → host | Urgent degraded-condition signal. |
| `pairing` | 5 | both | Pairing/enrollment events after transport is up. |
| `heartbeat` | 6 | both | Liveness and monotonic counters. |

## Distress channel

Normal distress is an encrypted `distress` frame. If the encrypted session is degraded, a companion may send `SignedDistressSignal`: companion ID, timestamp, nonce, distress body, companion signing public key, and Ed25519 signature. Host accepts it only if the companion key matches a Soul-Anchor-signed `PairingRecord` and replay checks pass. This preserves authentication when transport state is degraded; privacy is restored by the encrypted channel when available.

## Transport notes

Bonjour service type: `_jarvis-wire._tcp`. Multipeer service type should use the same semantic name shortened to Apple's limit, e.g. `jarvis-wire`. The transport carries opaque length-prefixed frames from this spec. Transport reconnects must perform a new session handshake and key derivation.
