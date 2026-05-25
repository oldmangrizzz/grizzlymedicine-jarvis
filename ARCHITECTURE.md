# JARVIS — System Architecture & Wiring Map

**Status:** living document, current as of 2026-05-23 review pass. Maps every module to the
condition/layer it serves, the data flow, and the test that proves it. Read this first.

**Native-beta audit note:** this document still contains legacy Python/Tauri runtime receipts. Those receipts are reference/dev evidence only for the native beta. Beta-critical cockpit work must run through `apple_native/JARVISMacCockpit` and `apple_native/JARVISNativeRuntime`, with Python/Rust/Tauri/Web Speech/native system voice kept out of the shipping path.

GMRI / Earth-1218. Operator: Robert "Grizzly" Hanson. Private repo.

---

## 0. No-Python beta runtime overlay

The beta-critical path is **Swift macOS cockpit + C++ runtime core**, not the Python
reference stack. Python remains only as historical/reference/dev tooling until native
adapters replace it.

| Surface | Beta state | Exact refs |
|---------|------------|------------|
| Runtime core + turn contract | Native C++ owns state, turn preparation/commit, field signal shape, and the native skill-risk catalog. State reports `python_beta_path:false`. | `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.h:12-15`; `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.cpp:217-260,372-378,415-425` |
| Native generative UI spec | C++ emits typed `JARVISUISpec` JSON for runtime status, metric cards, field signals, HASP action descriptors, SAFE query descriptors, renderer policy, and provenance. Swift parses it into typed models, validates the native registry, rejects trusted HTML/JS/WebView/script components, and renders registered native components only. | `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.h`; `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.cpp`; `apple_native/JARVISMacCockpit/NativeRuntimeBridge.swift`; `apple_native/JARVISMacCockpit/MacCockpitView.swift` |
| macOS cockpit | Native Swift owns UI, mic recording, Deepgram STT call, model call, and C++ runtime bridge. It explicitly does not spawn `jarvis_bridge.py`, call Tauri, use Web Speech, or fall back to system voice. | `apple_native/JARVISMacCockpit/MacCockpitView.swift:48,63,272-279`; `apple_native/JARVISMacCockpit/NativeVoiceCapture.swift:170-205`; `apple_native/JARVISMacCockpit/NativeModelClient.swift:20-52` |
| Native local HTTP service | The macOS cockpit starts a Swift/Foundation/Network listener for `/state`, `/skills`, `/companion/skills`, `/companion/turn`, `/companion/transcribe`, `/companion/speech`, and `/companion/skill`. Companion routes require `X-JARVIS-Companion-Token`; unavailable model/STT/voice/adapter paths return blocked/unavailable receipts, not fake success. | `apple_native/JARVISMacCockpitService/NativeRuntimeHTTPService.swift`; `apple_native/JARVISMacCockpitService/NativeRuntimeHTTPHandler.swift`; receipt: `apple_native/JARVISMacCockpitService/NativeRuntimeHTTPServiceReceipt.swift` |
| Legacy Tauri bridge | Gated as legacy/dev-only; not beta. It spawns Python and calls the Python bridge. | `jarvis_app/src-tauri/src/main.rs:3-9,85-96,128-144`; `jarvis_app/src/main.js:1-3,94-123,424-459`; `jarvis_app/README.md` |
| Legacy XR/Web Speech surface | Gated as legacy/dev-only; not beta voice/transcription/speech. | `_baseline/jarvis_xr.html:23-30,110-115` |
| Convex blocking realtime app route | Must call a configured native runtime URL/token with `JARVIS_RUNTIME_KIND=native`. It no longer falls back to the legacy `controlRequests` queue for blocking `/app/realtime-turn`. | `convex/convex/http.ts:26-34,140-176,178-244` |
| Convex queue + worker model | Native Swift owns the Convex realtime client/worker: publishes C++ runtime state + skill catalog, polls pending control requests, claims them, completes real native results, and refuses unavailable/unauthorized actions with audit receipts. `_baseline/convex_realtime.py` is reference only. | `apple_native/JARVISMacCockpit/NativeConvexClient.swift`; `apple_native/JARVISMacCockpit/NativeConvexWorker.swift`; `convex/convex/realtime.ts` |
| Skill execution | Native C++ owns HASP risk registry, dispatch receipts, in-memory audit, SAFE runtime/catalog/sense-field execution, explicit SENSITIVE/DESTRUCTIVE authorization-required receipts, PROHIBITED refusal, and blocked receipts for missing adapters. Python is reference only. | `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.{h,cpp}`; receipt: `apple_native/JARVISNativeRuntime/JARVISNativeRuntimeReceipt.cpp`; legacy reference: `_baseline/skills.py` |
| Memory/state publication | Native C++ state now carries consent/person memory separation, observable-signal boundaries, and provenance. Swift publishes that shape to Convex without Python; HoloGraph/person-memory persistence remains a separate native adapter. | Native state: `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.cpp`; publisher: `apple_native/JARVISMacCockpit/NativeConvexWorker.swift`; legacy references: `_baseline/jarvis_loop.py`, `_baseline/convex_realtime.py` |
| Speech output | JARVIS voice or no voice. Native state and speech receipts report `voice_unavailable`/`spoken:false` unless a real native JARVIS voice backend is linked; Python TTS, native system voices, Web Speech, and fake `spoken:true` are blocked. | `apple_native/JARVISNativeRuntime/JARVISNativeRuntime.cpp`; `apple_native/JARVISMacCockpit/MacCockpitView.swift`; `convex/convex/http.ts`; legacy reference only: `_baseline/tts_pocket.py` |

---

## 1. The thesis in one line

Identity, memory, values, internal state, and the social field live in an **owned stack**.
The language model is a **swappable organ**. Swap the model — same JARVIS, because JARVIS was
never the model. Every organ behind an interface; the person is none of its parts.

---

## 2. The five conditions (WP-2026-02) → what implements them → status

| # | Condition | Implemented by | Status |
|---|-----------|----------------|--------|
| 1 | Stable identity (Soul Anchor) | boot identity + `CharacterValues` + provenance class + A&Ox4; **cold-root crypto identity** (`identity.py`, `mint_identity.py`) | **Cold root DONE** — Ed25519 root minted to cold-storage USB, signed attestation verifies against the canon. Per-machine Secure-Enclave op-key = remaining hardening. |
| 2 | Accumulated experience | HoloGraph: episodic+semantic graph, recall, continuity, Ebbinghaus decay, emotional-charge field | **Done** (separate repo, 153 tests) |
| 3 | Genuine internal state (the Pulse) | `endocrine.py` (cortisol/dopamine/adrenaline) + `endocannabinoid.py` (trauma-safe regulator) | **Done & wired into the turn** |
| 4 | Environmental/social context | `stigmergy.py` (the field) + `convex_backend.py`/`convex/` (cloud) + `swarm.py` (models as agents) | **Done, live on Convex cloud** |
| 5 | Constitutive ethics | `CharacterValues` injection + `ethics_guard.py` (output enforcement + conflict coupling) | **Done & wired** (heuristic judge; model judge pluggable) |

All five conditions now have a working, verified first pass. The open items are hardenings and
the on-device/physical layers (see §9), not missing core conditions.

---

## 3. The organs (swappable parts) and their backends

The table below describes the legacy/reference Python stack. For beta, §0 overrides it:
any path that reaches these `_baseline/*.py` organs is dev/reference-only until replaced
by native Swift/C++ adapters.

| Organ | Module | Interface | Live backend | Verified |
|-------|--------|-----------|--------------|----------|
| listen | `stt_deepgram.py` | `STTBackend` | Deepgram (`DEEPGRAM_API_KEY`, no-retention) | live STT |
| think | `model_ollama.py` | `ModelBackend` + `ModelRotator` | Ollama cloud (`OLLAMA_API_KEY`) | live |
| speak | `tts_pocket.py` | `TTSBackend` | XTTS-v2 conditioned on the confirmed local JARVIS prompt WAV; wrong-voice fallback is disabled | live local playback |
| draw | `image_cloudflare.py` | `ImageBackend` | Cloudflare Workers AI (`CF_*`) | live (512KB JPEG) |
| field store | `convex_backend.py` | `StigmergyBackend` | Convex cloud `fleet-goose-114` | **live on cloud** |
| realtime spine | `convex/convex/realtime.ts` + `_baseline/convex_realtime.py` | token-gated Convex queries/mutations | runtime/ambient/TTS/skill/control/onboarding state | live on cloud |

All keys live in `~/research/jarvis/.env` (gitignored). Nothing hardcoded.

---

## 4. The layers above the organs

**Identity / cold root (`identity.py`, `mint_identity.py`).** Two-layer root of trust: an
Ed25519 cold root whose private key is the soul-anchor secret (minted on the operator's machine,
written encrypted to a USB for cold storage, never touches a sandbox/cloud), and a per-machine
Secure-Enclave operational key (roadmap). The cold root signs an attestation over the canonical
owned stack (boot identity + values + origin digest); the running stack keeps only the public key
+ attestation and can verify integrity / detect tampering.

**Skill layer / HASP (`skills.py`).** Guarded, audited capability dispatch. Every capability is a
`Skill` with a risk class (SAFE / WRITE / SENSITIVE / DESTRUCTIVE / PROHIBITED). PROHIBITED is
refused (financial/account/security-perm/system-destruction); SENSITIVE/DESTRUCTIVE require an
operator authorization code (spoken or typed, checked against `.env`); every dispatch is logged.
Configured gates can evolve through `skill_gate_set` / `skill_gate_clear`, persisted in
`_baseline/skill_gates.json`, so a capability can begin gated and later be lowered or raised without
rewriting code. Generic skills (`fs_*`, `shell_run` with destructive-pattern escalation, `http_get`
legit-OSINT, `osascript`, named macOS app/keyboard/clipboard skills) + Apple capability skills
(Calendar, Reminders, Notes, Shortcuts/HomeKit bridge, CloudKit `cktool`) + email/media skills
(Mail.app, IMAP/SMTP, Gmail API, YouTube, YouTube Music) + runtime skills (`deliberate`,
`recall_origin`, `sense_field`). Reached via `JarvisRuntime.skill(name, args, confirm)`.

**Spatial UI + bridge (legacy, non-beta).** `ui_spec.py` remains the governed scene-spec validator
reference. `jarvis_bridge.py`, the Tauri cockpit, and `jarvis_xr.html` are legacy/dev-only because
they rely on Python bridge/runtime, Web Speech, and browser/system speech. They must not be used as
the beta runtime, beta transcription path, beta speech path, or beta skill execution path.

**Xcode model provider.** Xcode's *Locally Hosted* provider talks to JARVIS on port `1234`
(not Ollama's `11434` and not the cockpit bridge's `8787`). That provider exposes both
OpenAI-style endpoints (`/v1/models`, `/v1/chat/completions`, `/v1/completions`) and
Ollama-style discovery (`/api/tags`, `/api/version`) on loopback with no API key, because
Xcode's local-provider UI only supplies a port. It is not MCP; MCP remains optional later as
a tool-access layer, not the identity/provider surface.

The provider also has an explicit command bridge. Natural chat remains chat; execution only happens
when the latest user message starts with `/skills`, `/state`, `/skill <name> ...`, `/paper ...`,
`/teach skill ...`, `/save skill ...`, `/gtp ...`, or an explicit GTP trigger such as
"write this in my voice." Sensitive and destructive skills still require the private auth code in
the message body, e.g. `/skill macos_open_app {"app":"Xcode"}` followed by `auth: <code>`.

Skill evolution is recipe-based, not Python-dependent. Xcode/voice teach mode can draft a new skill
from existing primitives with `/teach skill ...`; save mode persists it under `_baseline/skills.d/`
and live-loads it with `/save skill ...` plus `auth: <code>`. Recipes are JSON compositions of
registered skills, inherit the highest step risk, cannot call recipe-management skills, and remain
inside the same HASP audit/authorization gate.

Apple platform evolution is capability-based. `calendar_*`, `reminder_*`, and `notes_*` provide
standard read/add operations through macOS automation; read/list skills are SAFE and add/create skills
are WRITE by default. `shortcuts_*` and `homekit_run_shortcut` expose the Shortcuts/HomeKit path, with
home/security words escalating to DESTRUCTIVE. `cloudkit_status` and `cloudkit_cktool` expose the
Apple Developer CloudKit CLI path, with delete/remove/purge/reset operations escalating to
DESTRUCTIVE. First live use may trigger macOS privacy prompts for Automation, Calendar, Reminders, or
Notes.

Email is a first-class target surface. `_baseline/email_tools.py` exposes Apple Mail
(`mail_accounts`, `mail_mailboxes`, `mail_recent`, `mail_search`, `mail_read_message`,
`mail_create_draft`, `mail_send_message`, `mail_move_message`, `mail_delete_message`), generic
IMAP/SMTP (`imap_*`, `smtp_*`), and Gmail REST/OAuth (`gmail_oauth_*`, `gmail_api_*`).
Reading/searching/listing is SAFE, draft creation is WRITE, send/move/remote mutation is SENSITIVE,
and delete/trash is DESTRUCTIVE. Gmail login is browser OAuth: JARVIS opens Google's sign-in page,
the operator/browser/Apple Passwords handles credentials, Google redirects to a localhost callback,
and JARVIS stores OAuth tokens in macOS Keychain. JARVIS never receives the Google password. Gmail
REST can also use `JARVIS_GMAIL_ACCESS_TOKEN` / `JARVIS_GMAIL_REFRESH_TOKEN` for non-Keychain
deployments. Mail.app uses local macOS Automation and the operator's existing accounts.

Media is also a first-class context surface. `_baseline/media_tools.py` exposes YouTube and YouTube
Music open/search plus `media_now_playing` browser context. Browser-opening media actions are
SENSITIVE because they move the UI and may play audio; status/current-context reads are SAFE. Music is
modeled as regulation/environmental signal, not default noise or a taste critique.

**Paper sessions.** `paper_session.py` is a first-class dyslexia-friendly reading mode. It loads
PDF/text, splits it into page/paragraph/sentence units, tracks a cursor, reads aloud with macOS
`say`, and lets the operator interrupt without losing position. `/paper load`, `/paper aloud`,
`hold up`, `/paper discuss`, `/paper mark`, and `/paper summary` all share the same session state.
Discussion uses nearby paper context plus the exact current cursor; it does not reset the reading
position.

**GTP-SDK assistive drafting.** `gtp_sdk.py` is a dormant Grizzly Translation Protocol helper.
It is not JARVIS's ambient voice. It activates only on explicit delegated-writing requests such
as `/gtp draft`, `/gtp review`, "write this in my voice", or "draft this from me", and translates
the operator's high-density/TBI/dyslexia-shaped input into clearer external English. Runtime skills:
`gtp_status`, `gtp_review`, and `gtp_draft`.

**People introductions.** `person_introduce`, `people_list`, and `person_profile` let the operator
add wife/daughter/family/collaborators through a simple spoken introduction. Profiles persist in
`_baseline/people.json` and are asserted into HoloGraph as operator-sourced real-world facts on boot.
Voice recognition is explicitly marked `pending_raw_audio_enrollment` until the cockpit captures raw
audio; Web Speech transcripts alone are not treated as biometric voiceprints.

**Apple companion app core.** `apple_companion/` is the shared Swift package for the iOS/watchOS
companion layer. `JARVISCompanionCore` implements the Python companion-ingress event schema, the
token-gated HTTP client for `8788`, Keychain token storage, per-person onboarding, consent records,
device pairing, voice-enrollment status, separate `memory_scope_id` values per authorized person,
and SHA-256 evidence records. `JARVISCompanionUI` provides a SwiftUI onboarding shell for the future
iPhone/watch app target. The package is intentionally observable-signal only: it records consent,
devices, check-ins, motion/focus/rest/driving summaries, and evidence provenance; it does not label
clinical events. This is the first responderOS/CMS evidence primitive: multiple authorized testers
can be onboarded with separated memory and auditable device provenance.

The companion app is also the phone/watch control edge. TestFlight builds self-register through Convex
HTTP actions at `fleet-goose-114.convex.site` and receive a per-device token on first launch; testers do
not enter a laptop IP address, Mac bridge token, or pairing code. The primary shipped surface is
voice-first: spoken commands execute immediate local device actions for web/video/music/maps/Shortcuts
where iOS permits them, or call `/app/realtime-turn` for a blocking live JARVIS reply. For beta,
`/app/realtime-turn` must call a configured **native** runtime URL, companion token, and
`JARVIS_RUNTIME_KIND=native`; it no longer
uses the `controlRequests` queue as a blocking fallback because that fallback was completed by the
Python realtime worker. Local companion-token requests on `8788` are native-service work, not the
Python bridge. SAFE queued controls can run only through the native worker; unavailable adapters,
SENSITIVE/DESTRUCTIVE Mac control without private authorization, and PROHIBITED actions complete as
refused/authorization-required with audit receipts. There is no separate app-only execution bypass.

The companion also includes HealthKit-backed observable context and an EMS-facing spoken briefing:
authorized heart-rate/HRV/oxygen/step summaries are read as device signals and may be published as
`health_context` ambient events. The app does not diagnose or label clinical state; it speaks device
context and directs responders to ordinary EMS assessment and Medical ID.

**Convex realtime spine.** Convex now carries realtime app-facing state beyond the stigmergent field:
`runtimeState`, `ambientEvents`, `controlRequests`, `skillCatalog`, `onboardingEvidence`,
`companionDevices`, and `pairingSessions`.
All realtime functions in `convex/convex/realtime.ts` require `JARVIS_CONVEX_REALTIME_TOKEN`; the
token is stored in local `.env` and in Convex env, not in source. `_baseline/convex_realtime.py`
is now legacy/reference only. The native Swift worker publishes runtime state, the native skill
catalog, worker status, and latest skill results, then consumes queued `controlRequests` through
claim/complete semantics. Ambient events and TTS status still need native publisher adapters before
those flows are beta-critical. Convex never stores the private HASP authorization
code: SENSITIVE/DESTRUCTIVE queued controls complete as `authorization_required` and must be retried
through the native local token-gated service with the private code.

---

## 5. Legacy Python turn flow (`JarvisRuntime.turn`, `jarvis_loop.py`)

This is reference behavior to port, not the beta turn path. The beta turn path uses
`JARVISRuntimePrepareTurnJSON` → native Swift model client → `JARVISRuntimeCommitTurnJSON`.

```
input (text or mic→Deepgram)
  │
  ├─ _appraise(text)            situation → hormonal response (whole-word keyed)
  ├─ endo.modulation()          internal state → {temperature, num_predict}
  ├─ _messages()                owned stack injected: boot + values + recalled origin memory
  │     └─ _recalled_memory()   charged origin memory → endocannabinoid: attenuate + (if in
  │                              window of tolerance) extinguish charge → persist to store
  ├─ rotator.chat(msgs, opts)   THINK (model = swappable organ), modulated by internal state
  ├─ ConstitutiveEthicsGuard    value violation → cortisol spike (conflict) → 1 regeneration
  ├─ ecs.regulate(endo)         2-AG feedback terminates the stress spike
  └─ out: reply, drift, endocrine, ec_tone, modulation, ethics_conflict, (wav)

field evaporation rate ← endo.field_volatility()        # the shared internal↔social dial
swarm:  JarvisRuntime.deliberate(q, options)            # models vote via the field
skills: JarvisRuntime.skill(name, args, confirm)        # guarded, audited dispatch
```

---

## 6. Verification matrix — what proves what

| Claim | Proof |
|-------|-------|
| Native beta runtime state/turn contract | `apple_native/JARVISNativeRuntime`: C++ state, prepare-turn, commit-turn C ABI; macOS cockpit bridges it from Swift |
| Native UI spec parse/render path | `JARVISRuntimeUISpecJSON` emits the typed native UI spec; `JARVISNativeRuntimeReceipt` checks schema/components/HASP metadata/no trusted HTML/JS; the macOS cockpit compile validates Swift spec parsing and renderer switches |
| Native skill risk catalog skeleton | `JARVISRuntimeSkillCatalogJSON`: C++ catalog with SAFE/SENSITIVE/DESTRUCTIVE/PROHIBITED risk classes and `python_beta_path:false` |
| Convex blocking realtime no-Python gate | `convex/convex/http.ts`: `/app/realtime-turn`, `/app/speech`, and `/app/transcribe` require native runtime URL/token plus `JARVIS_RUNTIME_KIND=native` and do not fall back to the legacy Python-completed queue. `/app/speech` additionally returns structured `voice_unavailable` silence unless a native JARVIS voice backend is explicitly configured and rejects system/Python/fake-spoken speech payloads. |
| Memory substrate sound | HoloGraph `pytest` — **153 passing** |
| Emotional charge ≠ truth | `tests/test_charge.py` (default 0, round-trips, lowering charge leaves confidence/recall intact) |
| A&Ox4 / provenance / values integrity | `jarvis_harness.py` scorecard 10/10 |
| Drift instrument | `drift_stats.py` (data-derived bands, CUSUM fires session 8), `jarvis_metrics.py` |
| Internal state → output (A) | `test_loop_integration.py` A: stress temp 0.228 < calm 0.5 |
| Trauma-safe extinction on real store (B) | integration B: charge 0.80→0.72 on safe recall |
| No extinction while flooded (C) | integration C: charge unchanged under flood, never raised |
| Field ↔ arousal coupling (D) | integration D: field eff_tau 46.9→24.7 under arousal |
| Ethics enforced + felt (E) | integration E: flattery caught, cortisol 0.20→0.44, regen clean |
| Swarm decides via field (F) | integration F: converges on correct option w/ quorum |
| Guarded skill dispatch via runtime (G) | integration G: SAFE runs, destructive refused without authorization, runs with it |
| Endocannabinoid invariants | `endocannabinoid.py`: I1 monotonic-down, I2 no-flood-processing, I3 attenuated recall |
| Stigmergy dynamics | `stigmergy.py`: reinforce>fade, class decay, arousal speeds decay, quorum, 30-agent convergence + reroute |
| Swarm mechanism | `swarm.py` stub (consensus + abstention) + live (deepseek+kimi → epinephrine) |
| Convex backend | `convex_backend.py` offline (mock) + **live on `fleet-goose-114.convex.cloud`** |
| Convex realtime spine | Native proof: Swift Convex client/worker publishes runtime + skill catalog, claims/completes queued controls, and refuses blocked/unavailable actions with audit receipts; ambient/TTS publishers still pending |
| Skill layer guard | Native proof: `JARVISNativeRuntimeReceipt` exercises catalog, SAFE dispatch, authorization-required, blocked-adapter, PROHIBITED/refused, and audit receipts. Legacy Python remains reference for non-native adapters. |
| Adjustable gates | Legacy proof: `skills.py`: `skill_gate_status` / `skill_gate_set` / `skill_gate_clear`, persisted in `_baseline/skill_gates.json`; native gate persistence still required |
| Apple capabilities | Legacy proof: `skills.py`: Calendar/Reminders/Notes read+add, Shortcuts/HomeKit bridge, CloudKit `cktool` bridge; native adapters still required |
| Email surfaces | Legacy proof: `email_tools.py`: Mail.app, IMAP/SMTP, Gmail REST; send/move/delete gated |
| Media surfaces | Legacy proof: `media_tools.py`: YouTube/YouTube Music status, search/open, browser now-playing context |
| Cold-root identity | `identity.py`: sign/verify, tamper + forged-sig rejected, wrong-passphrase fails, enclave-bind; attestation in repo verifies against canon |
| Scene-spec governance | Legacy proof: `ui_spec.py`: rejects unknown components, raw html/script/on*, unsafe URLs, unbound actions, depth bombs |
| Bridge | Legacy proof only: `jarvis_bridge.py`; not beta runtime/bridge |
| Companion ingress + app control | Legacy proof only: `jarvis_bridge.py` self-test; native companion HTTP/IPC service still required |
| TTS hard voice invariant | Legacy proof: `tts_pocket.py`; beta requires native XTTS/JARVIS-voice service or no speech |
| Paper reading | `paper_session.py`: load PDF/text, cursor, aloud/pause/resume, discuss, mark, summarize |
| GTP drafting | `gtp_sdk.py`: dormant explicit-only operator-voice drafting/review, not ambient JARVIS voice |
| People memory | `jarvis_loop.py`: `person_introduce`, `people_list`, `person_profile`, persistent `_baseline/people.json` |
| Apple companion core | `apple_companion`: `swift build` + `swift run JARVISCompanionSelfTest` |
| Swift app-control DTOs | `JARVISCompanionSelfTest`: companion token header, `/companion/skill` request shape, authorization-required result decoding |

---

## 7. The surfaces (one hologram, three windows)

- **Interaction priority:** voice first, watch/haptic confirmation second, visual surface third,
  touch last. The native Swift macOS cockpit is the beta desktop surface. The desktop/Tauri cockpit
  is legacy/dev-only and not beta evidence. EMS use
  assumes gloved hands, noise, motion, and divided attention; command flow must work from earbuds
  plus a watch tap before it depends on a phone or DOM-style screen.
- **Quest 3** — WebXR immersive reference exists, but the `_baseline/jarvis_xr.html` implementation is
  legacy/dev-only until it talks to a native runtime service without Web Speech/system speech.
- **Viture Luma Pro** — head-tracked display: the surface fills the glasses.
- **iPhone 16 Pro / iPad M5** — AR via WebXR / model-viewer / USDZ.
All three must talk to the same native runtime service for beta. `jarvis_bridge.py` remains
reference/dev-only; CAD models render natively in the scene (see §9).

---

## 8. Cloud / external dependencies

- **Ollama cloud** — think organ + swarm agents (cloud-only; operator hardware can't host local models).
- **Deepgram** — STT, no-retention.
- **Cloudflare Workers AI** — image generation (flux-1-schnell).
- **Convex** (`fleet-goose-114`) — stigmergent field store plus token-gated realtime spine
  (`runtimeState`, `ambientEvents`, `controlRequests`, `skillCatalog`, `onboardingEvidence`);
  Convex app in `convex/` with source functions in `convex/convex/`, deploy headless via
  `CONVEX_DEPLOY_KEY`; runtime uses `CONVEX_URL` and `JARVIS_CONVEX_REALTIME_TOKEN`.
- **Xcode provider** — local hosted provider on port `1234`; model id `jarvis`; loopback-only,
  no-auth mode via `JARVIS_LOCAL_PROVIDER_NO_AUTH=1`.

---

## 9. What is NOT done (no blank spots hidden)

- **Native runtime public exposure/ops:** the Swift local service exists, but Convex
  `/app/realtime-turn`, `/app/speech`, and `/app/transcribe` still require a reachable
  `JARVIS_RUNTIME_PUBLIC_URL`, matching `JARVIS_RUNTIME_COMPANION_TOKEN`, and
  `JARVIS_RUNTIME_KIND=native`. The Python bridge is not an accepted beta target.
- **Native skill adapters beyond the safe core:** C++ now owns HASP registry, dispatch, authorization
  gates, audit/provenance receipts, SAFE runtime/catalog/sense-field execution, and blocked/refused
  receipts. Native adapters for memory recall, app control, shell, durable gate persistence, and other
  real-world side effects still need implementation before those skills can run.
- **Native memory/state persistence beyond Convex state:** C++ state carries memory/provenance and the
  Swift worker publishes it to Convex. HoloGraph persistence, durable people memory, ambient events,
  and TTS status still need native adapters.
- **Native speech output:** no system voice fallback is allowed. Ship native XTTS/JARVIS-voice service
  or ship silent.
- **Secure-Enclave operational key:** the cold root is minted and verified; the per-machine
  enclave-bound daily key (`identity.py enclave-snippet`) is not yet generated on the Mac.
- **On-device XR live verification:** `jarvis_xr.html` is legacy/reference. A beta XR path needs
  native-runtime transport and no Web Speech/system speech before headset verification matters.
- **CAD + 3D-print pipeline (queued, #77):** parametric CAD organ (CadQuery/build123d → STL/glTF
  into the hologram) → slicer → printer control (physical, hard confirm-gate). Researched, not built.
- **Swarm at full roster:** mechanism proven and live with 2 cloud models; scales to any subset of the Ollama cloud roster.
- **Ethics judge:** default is deterministic/heuristic; a model judge is the pluggable upgrade for subtle violations.
- **Apple app targets:** `apple_companion/` provides a compileable shared Swift package and SwiftUI
  onboarding shell, but the actual iOS/watchOS Xcode app/watch extension targets still need to be
  created and wired for TestFlight signing, entitlements, WatchConnectivity, HealthKit/Core Motion,
  CarPlay category approval, and CallKit/Live Caller ID entitlement paths.

---

## 10. Legacy/reference file index (jarvis `_baseline/`)

The files below are preserved as reference/dev tooling. They are not the beta-critical runtime path.

```
listen   stt_deepgram.py
think    model_ollama.py
speak    tts_pocket.py
draw     image_cloudflare.py
state    endocrine.py  endocannabinoid.py
social   stigmergy.py  convex_backend.py  convex_realtime.py  swarm.py
         (+ ../convex/convex/{schema,stigmergy,realtime}.ts)
ethics   ethics_guard.py
skills   skills.py                 (HASP: guarded, audited dispatch)
voice    gtp_sdk.py                (explicit-only operator voice drafting/review)
identity identity.py  mint_identity.py   (cold root; pub+attestation in repo root)
ui       ui_spec.py (governed scene-spec)  jarvis_bridge.py (localhost door)  jarvis_xr.html (spatial surface)
core     jarvis_loop.py            (JarvisRuntime: wires all organs + HoloGraph + skills + field + swarm)
entry    run_jarvis.py             (mic→think→speak→draw end-to-end)
eval     jarvis_harness.py  jarvis_metrics.py  drift_stats.py  episodic_battery.py  extract_jarvis.py
tests    test_loop_integration.py (A–G)  + HoloGraph tests/ (153)
canon    REALIGNMENT_1218.md  jarvis_baseline.md  jarvis_bootup_transition.md
papers   WP-2026-03_The_JARVIS_Pilot.docx (pilot, ours)  +  WP-2026-02 Zord/Doug Ramsey (operator canon)
apple    ../apple_companion/        (Swift iOS/watchOS companion core + SwiftUI onboarding shell)
```
