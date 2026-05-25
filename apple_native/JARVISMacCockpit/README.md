# JARVISMacCockpit

macOS 14+ SwiftUI shell for the GMRI JARVIS native runtime. The cockpit mounts `JARVISNativeRuntime` through C ABI bindings and exposes operator-facing instruments: endocrine state, Pheromind volatility, swarm activity, CUSUM drift, identity continuity, redacted transcript, and native audit receipts.

## Build

```sh
cd apple_native/JARVISMacCockpit
swift build
JARVIS_COCKPIT_SMOKE=1 swift run JARVISMacCockpit
JARVIS_COCKPIT_SPEAKER_SMOKE=1 swift run JARVISMacCockpit
```

## Environment file resolution

Runtime environment resolution order is:

1. Existing process environment values win.
2. If `JARVIS_ENV_FILE` is set, missing values are loaded from that file.
3. Otherwise, missing values are loaded from `~/.jarvis/config/env` when present.

`JARVISMacCockpit.xcodeproj` and `Config/JARVISMacCockpit.xcconfig` are included for Xcode. This machine only has Command Line Tools, so `xcodebuild` and XCTest execution require full Xcode.

## Hardened Runtime and entitlements

`JARVISMacCockpit.entitlements` is least-privilege for distribution:

- Hardened Runtime allows no JIT, no unsigned executable memory, no DYLD environment variables, and no library-validation bypass.
- Network client is enabled for STT/Convex.
- Audio input is enabled for microphone STT.
- User-selected read/write files are enabled for operator-chosen audit exports.
- Network server, camera, contacts, calendar, and unrelated entitlements are absent.

`Config/JARVISMacCockpit.xcconfig` sets manual Developer ID signing, `CODE_SIGN_ENTITLEMENTS`, `ENABLE_HARDENED_RUNTIME = YES`, and runtime/timestamp signing flags. Operator action: provide `APPLE_TEAM_ID` and a Developer ID Application identity at archive/signing time.

## Developer ID certificate setup

1. Enroll the GMRI Apple Developer account in the Apple Developer Program.
2. In Xcode: **Settings > Accounts > Manage Certificates > + > Developer ID Application**.
3. Or in Apple Developer Certificates: create a **Developer ID Application** certificate, generate/upload a CSR from Keychain Access, download the certificate, and install it in the login keychain.
4. Confirm the exact identity string:

```sh
security find-identity -v -p codesigning | grep 'Developer ID Application'
```

Use that full common name as `APPLE_DEVELOPER_ID`, for example `Developer ID Application: Robert Hanson (TEAMID)`.

## notarytool setup

Preferred local profile:

```sh
xcrun notarytool store-credentials jarvis-notary \
  --apple-id "operator@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Create the app-specific password at <https://appleid.apple.com/> under **Sign-In and Security > App-Specific Passwords**. Store only the generated app-specific password, not the primary Apple ID password.

## Sign and notarize

Dry-run without Apple credentials:

```sh
bash ../tools/sign_and_notarize.sh \
  --dry-run \
  --app /path/to/JARVISMacCockpit.app
```

Real signing/notarization after building the Release `.app`:

```sh
export APPLE_TEAM_ID="TEAMID"
export APPLE_DEVELOPER_ID="Developer ID Application: Robert Hanson (TEAMID)"
export APPLE_API_KEY="jarvis-notary"

bash ../tools/sign_and_notarize.sh \
  --app /path/to/JARVISMacCockpit.app
```

The script signs with `--options runtime --timestamp`, verifies with:

```sh
codesign --verify --deep --strict --verbose=4 /path/to/JARVISMacCockpit.app
spctl --assess --verbose --type execute /path/to/JARVISMacCockpit.app
```

and submits with `xcrun notarytool submit --wait`, staples, validates the staple, and re-runs Gatekeeper assessment. Actual signing/notarization is operator-action because it requires Apple credentials and the installed Developer ID private key.

## Policy

No UI affordance disables, pauses, or kills cognition organs. Siri quarantine runs before runtime mount; blocking Siri authorization refuses launch and presents remediation.

Voice input is wired as capture/transcription plumbing. Native JARVIS voice remains silent unless the phase-2 voice backend confirms a correct voice receipt; no system voice fallback is allowed.

The **People JARVIS recognizes** panel adds and removes family voice anchors with Touch ID, plain-English prompts, playback, retry paths, audit entries, and voice-baseline hash updates.
