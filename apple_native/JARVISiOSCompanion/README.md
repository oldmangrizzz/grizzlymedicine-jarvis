# JARVIS iOS Companion

Operator: Robert "Grizzly" Hanson, GMRI. This app is an iPhone sensory/effector surface for JARVIS. Cognition stays on the Mac host; the phone relays live input/output only.

## Build

```sh
cd /Users/rbhanson/research/jarvis/apple_native/JARVISiOSCompanion
xcodegen generate
xcodebuild -project JARVISiOSCompanion.xcodeproj -scheme JARVISiOSCompanion -destination 'platform=iOS Simulator,name=iPhone 15' test CODE_SIGNING_ALLOWED=NO
```

Requires Xcode 15+, iOS 17 SDK, XcodeGen, and `/Users/rbhanson/research/jarvis/apple_native/wire` (`JARVISWire`). The current JARVISWire manifest uses libsodium on macOS and the package's Apple-platform fallback when building the iOS simulator.

## Pairing flow

1. Start the Mac host advertising `_jarvis-wire._tcp` and display its `jarvis-wire://pair?offer=…` payload plus short-code.
2. On iPhone, scan the QR with the system Camera app to open the `jarvis-wire://` URL, or paste the QR payload manually. The companion app intentionally does **not** request camera permission.
3. Enter the Mac-displayed short-code. The app verifies the signed JARVISWire offer, creates a libsodium-signed companion response, stores pairing material in Keychain, and discovers the host by Bonjour.
4. Foreground connect performs an ephemeral JARVISWire session handshake. Backgrounding drops the NWConnection and discards ephemeral keys.

## Voice relay

Push-to-talk captures 16 kHz mono PCM16 via `AVAudioEngine` and sends it as JARVISWire `.input` frames. Mac PCM16 `.output` frames tagged `surface=iphone-speaker` are played through the speaker. No transcripts are written.

## Privacy / quarantine

Entitlements are empty; runtime permissions are microphone and local network only. No camera, contacts, location, speech recognition, SiriKit intents, Shortcuts donations, cloud relay, or transcript persistence. Notifications never contain conversation content; distress relay shows only: `JARVIS distress signal — open app`.

## Smoke test with Mac

If a Mac host is available: build to device, pair using the host payload, confirm Bonjour connection, hold Push to talk for one sentence, verify the Mac receives PCM frames, then send a PCM output frame and a distress frame from the Mac. Expected: speaker playback and a minimal distress banner. If no host is available, run XCTest; message-flow tests exercise JARVISWire session sealing/opening locally.
