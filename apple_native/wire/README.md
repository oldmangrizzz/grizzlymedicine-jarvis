# JARVISWire

SwiftPM package for the host/companion wire protocol between `JARVISMacCockpit` and iOS/watchOS companion surfaces.

- Mac is the **host**; iPhone and Watch are **companions**.
- Companions relay input/output/status/distress only. Cognition remains on Mac.
- Pairing and session handshakes are authenticated by the Soul Anchor identity chain.
- Companion enrollment requires Soul-Anchor-signed operator attestation and one-shot pairing nonce admission.
- Session traffic uses libsodium only: Ed25519 signatures, `crypto_kx` ephemeral session keys, and XChaCha20-Poly1305 AEAD.
- Cloud relay is not part of default transport. If added later, relay bytes are already E2E ciphertext.

## Use

```swift
import JARVISWire

let hostAnchor = SodiumSoulAnchor(keyPair: anchorKeyPair)
let offer = try PairingCeremony.createOffer(
    hostID: "jarvis-mac",
    endpointHints: ["bonjour:_jarvis-wire._tcp"],
    anchor: hostAnchor
)
let qrPayload = try PairingCeremony.encodeQRCodePayload(offer)
```

For a live session, both peers call `SessionHandshake.begin(...)`, exchange signed hellos over Bonjour/NWConnection/MultipeerConnectivity, then call `finish(peerHello:expectedPeerRole:trustedAnchorPublicKey:)`. Use `WireSession.seal(_:)` and `WireSession.open(_:)` for framed encrypted messages. Use `PairingAdmissionController` at enrollment/session-init boundaries to consume pairing nonces once and bound request floods.

## Build/test

Requires libsodium. On this machine it is linked from Homebrew at `/opt/homebrew/opt/libsodium`.

```bash
cd /Users/rbhanson/research/jarvis/apple_native/wire
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --quiet
```

## Files

- `Documentation/PROTOCOL.md` — wire protocol specification.
- `Sources/JARVISWire/` — Swift implementation.
- `Tests/JARVISWireTests/` — XCTest coverage for pairing, message flow, replay rejection, signature forgery rejection, key rotation, and distress fallback.
- `Tests/AdversarialTests/` — Phase 7 adversarial wire-protocol attack suite, README, OPERATOR_REPORT, and GAPs.
