# JARVIS Watch Companion

Operator: Robert "Grizzly" Hanson, GMRI.

This watchOS 10+ app is JARVIS' wrist-presence: status glance, distress haptic, tap-to-speak relay, and long-press ALERT. It contains no cognition and stores no transcripts.

## Architecture

The Watch never talks to the Mac directly. It uses WatchConnectivity to reach the paired iPhone companion. The iPhone companion holds the JARVIS pairing and proxies watch heartbeat, audio input, status, distress, and ALERT events through the existing JARVIS chain. On first heartbeat per session, the iPhone emits a `watch_extension_enrollment` event scoped to relay/status/audio/alert only; that is the Watch extension certificate boundary under the iPhone Wire pairing.

## Pairing

1. Pair Apple Watch to the operator's iPhone.
2. Install the iPhone JARVIS companion and connect it to JARVIS.
3. Install this Watch companion from the iPhone app bundle.
4. Open the Watch app; it activates WatchConnectivity and sends a heartbeat to the iPhone proxy.

## Siri Watch Face mitigation

Residual R5 from `../security/SIRI_QUARANTINE.md` applies. The app gates launch until the operator acknowledges removing the Siri Watch Face:

- press the current watch face,
- swipe to the Siri face,
- swipe up,
- tap Remove,
- reopen JARVIS and tap **I removed it**.

Apple exposes no public API that can enumerate installed watch faces, so this is an operator-attested launch gate, not a device-management proof.

## UI surfaces

- Status indicator: idle / active / distress.
- Complication: single SF Symbol (`circle`, `waveform.circle.fill`, `heart.circle.fill`).
- Tap-to-speak: records local audio, relays it to the iPhone, then deletes the local file after reachable transfer.
- ALERT: long-press the ALERT button for two seconds. The iPhone logs and forwards it as an operator-attested emergency signal.

## Verification

Validated locally with:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project JARVISCompanionApps.xcodeproj \
  -scheme JARVISWatchApp \
  -configuration Debug \
  -destination 'generic/platform=watchOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Also built for `generic/platform=watchOS Simulator` and installed/launched on the paired iPhone 17 + Apple Watch Ultra 3 simulator pair. Hardware-only behavior not fully testable here: real microphone recording UI, haptic feel, live device complication rendering, and Mac-side audit receipt.
