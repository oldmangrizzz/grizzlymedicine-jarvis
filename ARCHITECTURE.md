# JARVIS — System Architecture & Wiring Map

**Status:** living document, current as of 2026-05-23 review pass. Maps every module to the
condition/layer it serves, the data flow, and the test that proves it. Read this first.

GMRI / Earth-1218. Operator: Robert "Grizzly" Hanson. Private repo.

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

**Spatial UI + bridge (non-DOM).** `ui_spec.py` is the governed scene-spec validator — the surface
may morph freely but every interactive node must bind to a *registered* skill (no raw HTML/script/
unsafe URLs/unbound actions). `jarvis_bridge.py` is the localhost-only, token-gated server
(`/turn`, `/skill` [guarded+code-authorized], `/skills`, `/state`, `/scene` [validated]) that exposes
the runtime to the surfaces. The Tauri cockpit treats authorization as voice-first: when `/skill`
returns `authorization_required`, it speaks the challenge, listens through Web Speech/accessibility
speech recognition, and retries with the transcribed private code. The cockpit has two loop modes:
**Sentry** requires the "JARVIS" wakeword before a transcript is sent, while **Live** sends every
heard transcript. `jarvis_xr.html` is the holographic three.js surface — flat preview in any browser,
**immersive on the Quest 3 (WebXR)**, head-tracked on the Viture glasses, AR on iPhone/iPad; voice
in (Web Speech → `/turn`), voice out, endocrine "mood" tints the core, controls dispatch via `/skill`.

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
where iOS permits them, or call `/app/realtime-turn` for a blocking live JARVIS reply. The Convex
HTTP action can use a public runtime URL when configured, otherwise it creates a `jarvis_turn`
`controlRequest` and blocks until `_baseline/convex_realtime.py` completes it through the same
`JarvisRuntime.turn` used by the cockpit; timeout is surfaced as unavailable, not as queued chat.
Local companion-token requests on `8788` remain a
developer bridge for `/companion/turn`, `/companion/skills`, and `/companion/skill`. SAFE controls
can run from the app queue, while SENSITIVE/DESTRUCTIVE Mac control still requires the private
authorization code and stays audit-logged. There is no separate app-only execution bypass.

The companion also includes HealthKit-backed observable context and an EMS-facing spoken briefing:
authorized heart-rate/HRV/oxygen/step summaries are read as device signals and may be published as
`health_context` ambient events. The app does not diagnose or label clinical state; it speaks device
context and directs responders to ordinary EMS assessment and Medical ID.

**Convex realtime spine.** Convex now carries realtime app-facing state beyond the stigmergent field:
`runtimeState`, `ambientEvents`, `controlRequests`, `skillCatalog`, `onboardingEvidence`,
`companionDevices`, and `pairingSessions`.
All realtime functions in `convex/convex/realtime.ts` require `JARVIS_CONVEX_REALTIME_TOKEN`; the
token is stored in local `.env` and in Convex env, not in source. `_baseline/convex_realtime.py`
publishes bridge state, TTS status, ambient events, latest turns, skill results, and consumes queued
`controlRequests` through `JarvisRuntime.turn` for app turns or `JarvisRuntime.skill` for skill
requests. Convex never stores the private HASP authorization
code: SENSITIVE/DESTRUCTIVE queued controls complete as `authorization_required` and must be retried
through the local token-gated bridge with the private code.

---

## 5. Data flow of one turn (`JarvisRuntime.turn`, `jarvis_loop.py`)

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
| Convex realtime spine | `convex/convex/realtime.ts` deployed; bad-token rejection, token-gated state publish/query, and control queue completion passed live smoke |
| Skill layer guard | `skills.py`: SAFE/WRITE run, SENSITIVE/DESTRUCTIVE code-authorized, PROHIBITED refused even with authorization, audited |
| Adjustable gates | `skills.py`: `skill_gate_status` / `skill_gate_set` / `skill_gate_clear`, persisted in `_baseline/skill_gates.json` |
| Apple capabilities | `skills.py`: Calendar/Reminders/Notes read+add, Shortcuts/HomeKit bridge, CloudKit `cktool` bridge |
| Email surfaces | `email_tools.py`: Mail.app, IMAP/SMTP, Gmail REST; send/move/delete gated |
| Media surfaces | `media_tools.py`: YouTube/YouTube Music status, search/open, browser now-playing context |
| Cold-root identity | `identity.py`: sign/verify, tamper + forged-sig rejected, wrong-passphrase fails, enclave-bind; attestation in repo verifies against canon |
| Scene-spec governance | `ui_spec.py`: rejects unknown components, raw html/script/on*, unsafe URLs, unbound actions, depth bombs |
| Bridge | `jarvis_bridge.py`: token-gated, localhost-only, /turn + /skill (guarded+code-authorized) + /scene (validated), OpenAI-compatible Xcode model provider, CORS |
| Companion ingress + app control | `jarvis_bridge.py` self-test: malformed companion writes return 400, token-gated `/companion/turn`, `/companion/skills`, `/companion/skill`, SENSITIVE controls require auth |
| TTS hard voice invariant | `tts_pocket.py`: XTTS-v2 confirmed JARVIS prompt WAV required; legacy backend constructors fail; wrong-voice fallback false |
| Paper reading | `paper_session.py`: load PDF/text, cursor, aloud/pause/resume, discuss, mark, summarize |
| GTP drafting | `gtp_sdk.py`: dormant explicit-only operator-voice drafting/review, not ambient JARVIS voice |
| People memory | `jarvis_loop.py`: `person_introduce`, `people_list`, `person_profile`, persistent `_baseline/people.json` |
| Apple companion core | `apple_companion`: `swift build` + `swift run JARVISCompanionSelfTest` |
| Swift app-control DTOs | `JARVISCompanionSelfTest`: companion token header, `/companion/skill` request shape, authorization-required result decoding |

---

## 7. The surfaces (one hologram, three windows)

- **Interaction priority:** voice first, watch/haptic confirmation second, visual surface third,
  touch last. The desktop/Tauri cockpit is a development/control surface, not the field UI. EMS use
  assumes gloved hands, noise, motion, and divided attention; command flow must work from earbuds
  plus a watch tap before it depends on a phone or DOM-style screen.
- **Quest 3** — WebXR immersive: walk-around hologram, hand-select nodes. (`renderer.xr.enabled` + VR button.)
- **Viture Luma Pro** — head-tracked display: the surface fills the glasses.
- **iPhone 16 Pro / iPad M5** — AR via WebXR / model-viewer / USDZ.
All three talk to the same `jarvis_bridge.py`; CAD models render natively in the scene (see §9).

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

- **Secure-Enclave operational key:** the cold root is minted and verified; the per-machine
  enclave-bound daily key (`identity.py enclave-snippet`) is not yet generated on the Mac.
- **On-device XR live verification:** the bridge is verified and `jarvis_xr.html` is syntax-clean,
  but Enter-VR on the Quest is verified on the headset, not in the sandbox. Needs LAN IP + https for the headset.
- **CAD + 3D-print pipeline (queued, #77):** parametric CAD organ (CadQuery/build123d → STL/glTF
  into the hologram) → slicer → printer control (physical, hard confirm-gate). Researched, not built.
- **Swarm at full roster:** mechanism proven and live with 2 cloud models; scales to any subset of the Ollama cloud roster.
- **Ethics judge:** default is deterministic/heuristic; a model judge is the pluggable upgrade for subtle violations.
- **Apple app targets:** `apple_companion/` provides a compileable shared Swift package and SwiftUI
  onboarding shell, but the actual iOS/watchOS Xcode app/watch extension targets still need to be
  created and wired for TestFlight signing, entitlements, WatchConnectivity, HealthKit/Core Motion,
  CarPlay category approval, and CallKit/Live Caller ID entitlement paths.

---

## 10. File index (jarvis `_baseline/`)

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
