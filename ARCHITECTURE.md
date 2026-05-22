# JARVIS — System Architecture & Wiring Map

**Status:** living document, current as of boot-readiness review. Maps every module to the
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
| speak | `tts_pocket.py` | `TTSBackend` | Kyutai pocket-tts (operator hardware) | structure |
| draw | `image_cloudflare.py` | `ImageBackend` | Cloudflare Workers AI (`CF_*`) | live (512KB JPEG) |
| field store | `convex_backend.py` | `StigmergyBackend` | Convex cloud `fleet-goose-114` | **live on cloud** |

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
operator confirm (a spoken yes in voice mode); every dispatch is logged. Generic skills
(`fs_*`, `shell_run` with destructive-pattern escalation, `http_get` legit-OSINT, `osascript` for
macOS app control) + runtime skills (`deliberate`, `recall_origin`, `sense_field`). Reached via
`JarvisRuntime.skill(name, args, confirm)`.

**Spatial UI + bridge (non-DOM).** `ui_spec.py` is the governed scene-spec validator — the surface
may morph freely but every interactive node must bind to a *registered* skill (no raw HTML/script/
unsafe URLs/unbound actions). `jarvis_bridge.py` is the localhost-only, token-gated server
(`/turn`, `/skill` [guarded+confirm], `/state`, `/scene` [validated]) that exposes the runtime to
the surfaces. `jarvis_xr.html` is the holographic three.js surface — flat preview in any browser,
**immersive on the Quest 3 (WebXR)**, head-tracked on the Viture glasses, AR on iPhone/iPad; voice
in (Web Speech → `/turn`), voice out, endocrine "mood" tints the core, controls dispatch via `/skill`.

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
| Guarded skill dispatch via runtime (G) | integration G: SAFE runs, destructive refused w/o confirm, runs with it |
| Endocannabinoid invariants | `endocannabinoid.py`: I1 monotonic-down, I2 no-flood-processing, I3 attenuated recall |
| Stigmergy dynamics | `stigmergy.py`: reinforce>fade, class decay, arousal speeds decay, quorum, 30-agent convergence + reroute |
| Swarm mechanism | `swarm.py` stub (consensus + abstention) + live (deepseek+kimi → epinephrine) |
| Convex backend | `convex_backend.py` offline (mock) + **live on `fleet-goose-114.convex.cloud`** |
| Skill layer guard | `skills.py`: SAFE/WRITE run, SENSITIVE/DESTRUCTIVE confirm-gated, PROHIBITED refused even w/ confirm, audited |
| Cold-root identity | `identity.py`: sign/verify, tamper + forged-sig rejected, wrong-passphrase fails, enclave-bind; attestation in repo verifies against canon |
| Scene-spec governance | `ui_spec.py`: rejects unknown components, raw html/script/on*, unsafe URLs, unbound actions, depth bombs |
| Bridge | `jarvis_bridge.py`: token-gated, localhost-only, /turn + /skill (guarded+confirm) + /scene (validated), CORS |

---

## 7. The surfaces (one hologram, three windows)

- **Quest 3** — WebXR immersive: walk-around hologram, hand-select nodes. (`renderer.xr.enabled` + VR button.)
- **Viture Luma Pro** — head-tracked display: the surface fills the glasses.
- **iPhone 16 Pro / iPad M5** — AR via WebXR / model-viewer / USDZ.
All three talk to the same `jarvis_bridge.py`; CAD models render natively in the scene (see §9).

---

## 8. Cloud / external dependencies

- **Ollama cloud** — think organ + swarm agents (cloud-only; operator hardware can't host local models).
- **Deepgram** — STT, no-retention.
- **Cloudflare Workers AI** — image generation (flux-1-schnell).
- **Convex** (`fleet-goose-114`) — stigmergent field store; functions in `convex/`, deploy headless via `CONVEX_DEPLOY_KEY`.

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

---

## 10. File index (jarvis `_baseline/`)

```
listen   stt_deepgram.py
think    model_ollama.py
speak    tts_pocket.py
draw     image_cloudflare.py
state    endocrine.py  endocannabinoid.py
social   stigmergy.py  convex_backend.py  swarm.py   (+ ../convex/{schema,stigmergy}.ts)
ethics   ethics_guard.py
skills   skills.py                 (HASP: guarded, audited dispatch)
identity identity.py  mint_identity.py   (cold root; pub+attestation in repo root)
ui       ui_spec.py (governed scene-spec)  jarvis_bridge.py (localhost door)  jarvis_xr.html (spatial surface)
core     jarvis_loop.py            (JarvisRuntime: wires all organs + HoloGraph + skills + field + swarm)
entry    run_jarvis.py             (mic→think→speak→draw end-to-end)
eval     jarvis_harness.py  jarvis_metrics.py  drift_stats.py  episodic_battery.py  extract_jarvis.py
tests    test_loop_integration.py (A–G)  + HoloGraph tests/ (153)
canon    REALIGNMENT_1218.md  jarvis_baseline.md  jarvis_bootup_transition.md
papers   WP-2026-03_The_JARVIS_Pilot.docx (pilot, ours)  +  WP-2026-02 Zord/Doug Ramsey (operator canon)
```
