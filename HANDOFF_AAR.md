# JARVIS — Handoff / After-Action Report

**Date:** 2026-05-23
**Prepared for:** the next engineer picking this up cold.
**Operator:** Robert "Grizzly" Hanson, EMT-P (Ret.), Founder GMRI.

This report states what is built, what is verified, what remains open, and the exact surfaces that must not be broken. The operator's medical/accessibility constraint is real: do not hand him code-sorting tasks or vague "interpret this error" instructions. Provide mechanical steps or do the work.

---

## 1. One-line status

JARVIS is now a live owned-stack runtime with HoloGraph memory, HASP-gated computer control, a Tauri cockpit, Xcode local provider, Swift companion core, token-gated Convex realtime spine, and a hard voice invariant: **XTTS-v2 with the confirmed local JARVIS prompt WAV, or no speech**.

Provider `1234` is separate from the cockpit bridge `8787` and companion ingress `8788`. The running cockpit bridge must be restarted after code changes to load the newest Convex realtime worker and XTTS guard.

---

## 2. Non-negotiable voice invariant

The operator explicitly rejected wrong-voice fallback. Runtime speech must fail closed.

- `.env` must keep:
  - `JARVIS_TTS_BACKEND="xtts-v2"`
  - `JARVIS_TTS_MODEL="tts_models/multilingual/multi-dataset/xtts_v2"`
  - `JARVIS_TTS_LANGUAGE="en"`
  - `JARVIS_TTS_VOICE="/Users/rbhanson/research/jarvis/_local_voice/jarvis_harvard_prompt.wav"`
  - `JARVIS_TTS_VOICE_CONFIRMED="1"`
- `_baseline/tts_pocket.py` refuses live speech unless the confirmed XTTS-v2 voice path is safe.
- Legacy Chatterbox and pocket-tts constructors now raise if directly instantiated.
- `jarvis_bridge.py` preloads XTTS-v2 in the background on boot and publishes TTS status to Convex when realtime is enabled.

Validated: Python compile, bridge self-test, skill self-test, and hard-voice invariant check passed. User heard the XTTS-v2 cold/warm samples before this path was wired.

---

## 3. Runtime surfaces

### Desktop cockpit

`jarvis_app/` is a Tauri v2 desktop cockpit. The power button spawns `_baseline/jarvis_bridge.py` as a child process with `JARVIS_BRIDGE_TOKEN`; the webview calls the bridge through Rust native socket commands.

Cockpit features:
- `/state` gauges for endocrine state, ECS tone, model, field, and dream readiness.
- `/turn` text/mic interaction.
- `/skill` HASP action dispatch.
- Voice-first authorization challenge for SENSITIVE/DESTRUCTIVE skills.
- Sentry and Live hands-free listening modes.

### Xcode provider

Xcode's Locally Hosted model provider runs on port `1234`, not Ollama `11434` and not cockpit `8787`.

Command bridge in Xcode chat:
- `/skills`
- `/state`
- `/skill <name> <JSON args>`
- `/paper ...`
- `/teach skill ...`
- `/save skill ...`
- `/gtp ...`

Execution is explicit only. Sensitive/destructive skills require `auth: <private code>` on its own line.

### Companion ingress

Companion LAN ingress is token-gated separately on `8788`:
- `GET /companion/manifest` is open but redacts token file paths.
- `POST /companion/event` ingests observable iPhone/watch/CarPlay context.
- `GET /companion/status`
- `GET /companion/dream`
- `GET /companion/skills`
- `POST /companion/turn`
- `POST /companion/skill`

`/companion/skill` routes through the same `JarvisRuntime.skill` / HASP registry. It is not a control bypass.

---

## 4. Convex realtime spine

Convex deployment: `https://fleet-goose-114.convex.cloud`

Tables/functions:
- `runtimeState`
- `ambientEvents`
- `controlRequests`
- `skillCatalog`
- `onboardingEvidence`

Source:
- `convex/convex/schema.ts`
- `convex/convex/realtime.ts`
- `_baseline/convex_realtime.py`

Security:
- Every realtime function requires `JARVIS_CONVEX_REALTIME_TOKEN`.
- The token is in local `.env` and Convex env, not source.
- Private HASP authorization codes are never written to Convex.
- Queued Convex `controlRequests` are processed with `confirm=False`; SENSITIVE/DESTRUCTIVE actions complete as `authorization_required` and must be retried through the local token-gated bridge with the private code.

Validated live:
- bad-token rejection
- token-gated state publish/query
- queued control request completion through the Python worker

---

## 5. Apple companion status

`apple_companion/` is a Swift package, not yet signed app/watch targets.

Built:
- `JARVISCompanionCore`
  - companion event schema
  - dream/status DTOs
  - token-gated HTTP client
  - app turn/skill control DTOs
  - Keychain token storage
  - per-person onboarding
  - consent records
  - device pairing
  - voice-enrollment status
  - separated `memory_scope_id`
  - SHA-256 evidence ledger
- `JARVISCompanionUI`
  - SwiftUI onboarding shell
- `JARVISCompanionSelfTest`
  - executable self-test because this local Swift install lacks XCTest/Testing modules

Validated:

```bash
cd /Users/rbhanson/research/jarvis/apple_companion
swift build
swift run JARVISCompanionSelfTest
```

Next app work:
- create actual iOS app and watchOS extension targets in Xcode
- add Swift package products
- wire Keychain pairing UI to the companion token / Convex realtime token
- add WatchConnectivity
- add HealthKit/Core Motion summary collectors
- add App Intents
- add CarPlay surfaces
- later: CallKit / Live Caller ID entitlement paths

Keep event language observable-only. No clinical labels.

---

## 6. HoloGraph memory role

HoloGraph remains the owned memory substrate:
- origin vs real provenance
- confabulation-resistant belief store
- operator-owned CharacterValues
- emotional-charge axis orthogonal to truth/confidence
- cross-session continuity

Current public HoloGraph repo validation remains **153 passing tests**. JARVIS uses that substrate for identity, values, origin memory, and recall; Convex carries the live social/realtime field around it.

---

## 7. HASP skill layer

`_baseline/skills.py` is the guarded capability layer:
- `SAFE`
- `WRITE`
- `SENSITIVE`
- `DESTRUCTIVE`
- `PROHIBITED`

Capabilities include:
- filesystem read/write
- shell/AppleScript/macOS keyboard/app/clipboard
- Calendar, Reminders, Notes
- Shortcuts/HomeKit
- CloudKit `cktool`
- Mail.app, IMAP/SMTP, Gmail OAuth/API
- YouTube / YouTube Music
- paper-reading
- GTP-SDK explicit operator-voice drafting
- TTS status

SENSITIVE/DESTRUCTIVE require private authorization. PROHIBITED refuses even with authorization. Gate overrides persist in `_baseline/skill_gates.json`.

---

## 8. Validation run in this pass

Current validation performed after XTTS, companion-control, and Convex realtime wiring:

```bash
python -m py_compile _baseline/tts_pocket.py _baseline/jarvis_bridge.py _baseline/skills.py _baseline/convex_realtime.py
BRIDGE_SELFTEST=1 python _baseline/jarvis_bridge.py
python _baseline/skills.py
python _baseline/convex_realtime.py
cd convex && npx --yes --package typescript tsc --noEmit --skipLibCheck --moduleResolution Bundler --module ESNext --target ES2022 --lib ES2022,DOM convex/schema.ts convex/stigmergy.ts convex/realtime.ts
cd apple_companion && swift build --quiet && swift run --quiet JARVISCompanionSelfTest
```

Live Convex smoke also passed against `fleet-goose-114`.

---

## 9. Open items

- Restart the running cockpit bridge so the live process loads newest XTTS/realtime code.
- Build actual signed iOS/watchOS app targets around `apple_companion/`.
- Decide the final app-side realtime contract for Convex subscriptions.
- Keep Mac as a compute host, not the long-term center of gravity: app should be the voice/control edge.
- Later: optimized on-device cloned voice only if it preserves the exact approved JARVIS voice. If not exact, silence or route to the approved resident engine.

---

## 10. Safety boundaries to preserve

- No wrong voice in the operator's ears.
- No fallback system/browser voice pretending to be JARVIS.
- No Convex storage of private authorization codes.
- No app-only computer-control bypass.
- No clinical labels in companion evidence.
- No secrets committed from `.env`, `_local_voice/`, `_local_companion/`, or generated token stores.
