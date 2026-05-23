# JARVIS — desktop control app

A small Tauri (Rust core + native webview) cockpit. One window: a power button that
brings the runtime online, and a control panel that drives it. No terminal once it's
built — that's the point.

## What the power button does

- **ON** — the Rust core mints a fresh token, spawns `jarvis_bridge.py` (which hosts the
  live runtime) as a child process with that token in its environment, waits for `/state`
  to answer, then lights the panel.
- **OFF** — kills the child cleanly. Closing the window also kills it; no orphaned runtime.

The token never leaves the machine and is never shown — the app holds it and the bridge
holds it, both on `127.0.0.1`.

## The panel

- **Internal state** — live cortisol / dopamine / adrenaline, endocannabinoid tone, and
  field-signal count, polled from `/state` every 2s.
- **Speak to JARVIS** — type or mic (on-device Web Speech); posts `/turn`, shows the reply,
  speaks replies aloud when **Voice** is on, and can run a hands-free **Loop**:
  listen → reply → listen again. **Sentry** mode requires the "JARVIS" wakeword;
  **Live** mode sends every heard transcript.
- **Actions** — Deliberate, Recall origin, Sense field (the SAFE skills), and Open XR surface
  (launches `jarvis_xr.html` for Quest 3 / Viture / Apple AR).
- **Activity** — a rolling log of everything the cockpit did.

Voice output is hard-gated by the backend: live speech is **XTTS-v2 with the
confirmed local JARVIS prompt WAV, or no speech**. There is no system voice,
generic TTS, Chatterbox, or pocket-tts fallback path.

## First run (one-time, requires the Rust toolchain)

```bash
# 1. install Rust + the Tauri CLI (once)
curl https://sh.rustup.rs -sSf | sh
cargo install tauri-cli --version "^2"

# 2. from the app folder
cd ~/research/jarvis/jarvis_app/src-tauri
cargo tauri dev      # runs it live
```

To produce a double-clickable `JARVIS.app` you launch from Finder forever after:

```bash
cargo tauri icon ~/path/to/a/1024x1024.png   # once, generates app icons
cargo tauri build                            # outputs target/release/bundle/macos/JARVIS.app
```

## Assumptions / knobs

- Expects the runtime at `~/research/jarvis/_baseline/`. Override with the `JARVIS_BASELINE`
  env var if it moves.
- Calls `~/research/jarvis/.venv/bin/python` by default so GUI launches do not fall back
  to Apple's Python 3.9. Override with `JARVIS_PYTHON` if needed. That interpreter needs
  the runtime's deps and the repo `.env` (Ollama-cloud / Deepgram / Cloudflare / Convex
  keys) already in place.
- Bridge port is `8787`.
- Convex is the realtime spine when `CONVEX_URL` and `JARVIS_CONVEX_REALTIME_TOKEN`
  are configured. The bridge publishes runtime, TTS, ambient, turn, and skill-result
  state to Convex and consumes queued `controlRequests` through HASP. Private
  authorization codes are never stored in Convex.
- Voice input/output uses macOS's selected microphone and output device. In clamshell mode, pair the
  hearing aids with the Mac and select them under macOS Sound/Input; the cockpit will use that device
  until iOS/watchOS clients exist.
- Verbal comms controls: "Jarvis live mode", "sentry mode", "stop listening", "voice off",
  and "voice on".
- Xcode's Locally Hosted model provider should use port `1234`, description `jarvis`.
  That is a separate JARVIS provider port, not Ollama's `11434` and not the cockpit bridge's `8787`.
- From Xcode chat, execution is explicit only: `/skills`, `/state`, `/skill <name> {"arg":"value"}`,
  `/paper ...`, `/teach skill ...`, `/save skill ...`, or `/gtp ...`. Sensitive/destructive
  skills require `auth: <private code>` on its own line.
- In the cockpit, sensitive/destructive `/skill` refusals trigger spoken authorization: JARVIS speaks
  the challenge, listens through Web Speech/accessibility speech recognition, then retries with the
  transcribed private code. The raw code is not logged.
- New recipe skills can be taught without Python edits:
  `/teach skill <name>` drafts and validates; `/save skill <name>` plus `auth: <private code>`
  persists it under `_baseline/skills.d/` and live-loads it.
- Skill gates can evolve without Python edits: `skill_gate_status`, `skill_gate_set`, and
  `skill_gate_clear` persist overrides in `_baseline/skill_gates.json`; changing gates requires auth.
- Apple capability skills are registered for Calendar, Reminders, Notes, Shortcuts/HomeKit, and
  CloudKit. First live use may trigger macOS privacy prompts for the corresponding apps/services.
- Email skills are registered for Mail.app, generic IMAP/SMTP, and Gmail REST. Reads/searches are
  ordinary skills; drafts are WRITE; send/move/Gmail mutation require auth; delete/trash is
  destructive-gated. Gmail login uses browser OAuth: say "Jarvis connect Gmail", authorize the
  `gmail_oauth_connect` skill, then use Google's login page with Apple Passwords/passkey/autofill.
  JARVIS stores OAuth tokens in macOS Keychain and never receives the Google password. Env-token
  deployments can still use `JARVIS_GMAIL_ACCESS_TOKEN` / `JARVIS_GMAIL_REFRESH_TOKEN`.
- YouTube and YouTube Music skills are registered for status, search/open, and browser now-playing
  context. Search/open requires auth because it moves the browser/audio environment.
- People introductions are built in: say "Jarvis introduce yourself to my wife <name>",
  "Jarvis this is my daughter <name>", or "Jarvis meet <name>". JARVIS stores the profile in
  `_baseline/people.json`; voice recognition remains pending until raw-audio enrollment exists.
- The reusable iOS/watchOS companion package lives in `~/research/jarvis/apple_companion`.
  It provides onboarding, Keychain token storage, companion event DTOs, app turn/skill
  control DTOs, per-person memory scopes, evidence records, and the ARKit-native spatial
  surface scaffold so iOS holographic/spatial interaction does not depend on a DOM/WebView
  model.
- The generated Xcode project lives in `~/research/jarvis/apple_native/JARVISCompanionApps.xcodeproj`.
  It contains `JARVISCompanionApp` (iOS) and `JARVISWatchApp` (watchOS) targets with setup,
  people onboarding, real microphone sample capture for voice registration, native ARKit
  spatial status, watch quick check-ins, and app-to-Mac control. App Store Connect build
  `1.0 (6)` is signed, uploaded, marked valid, includes the embedded watchOS app, and is
  assigned to the Internal Testers TestFlight group.
- Paper-reading mode is available from Xcode chat: `/paper load <path>`, `/paper aloud 12`,
  `hold up`, `/paper discuss <question>`, `/paper mark <note>`, and `/paper summary`.
- GTP-SDK drafting is available from Xcode chat as an explicit operator-voice translation layer,
  not JARVIS's ambient voice: `/gtp status`, `/gtp draft`, `/gtp review <draft>`, or a clear
  trigger like "write this in my voice".
