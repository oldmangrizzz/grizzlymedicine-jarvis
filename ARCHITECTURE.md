# JARVIS — System Architecture & Wiring Map

**Status:** living document. Maps every module to the condition it serves, the data flow,
and the test that proves it. If you're picking this up cold, read this first.

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
| 1 | Stable identity (Soul Anchor) | boot identity + `CharacterValues` + provenance class + A&Ox4 orientation (`jarvis_loop.py`, HoloGraph) | **Software: done.** Hardware-bound (silicon) identity: **NOT done** — only remaining gap. |
| 2 | Accumulated experience | HoloGraph: episodic+semantic graph, recall, continuity, Ebbinghaus decay | **Done** (separate repo, 153 tests) |
| 3 | Genuine internal state (the Pulse) | `endocrine.py` (cortisol/dopamine/adrenaline) + `endocannabinoid.py` (trauma-safe regulator) | **Done & wired into the turn** |
| 4 | Environmental/social context | `stigmergy.py` (the field) + `convex_backend.py`/`convex/` (cloud) + `swarm.py` (models as agents) | **Done, live on Convex cloud** |
| 5 | Constitutive ethics | `CharacterValues` injection + `ethics_guard.py` (output enforcement + conflict coupling) | **Done & wired** (heuristic judge; model judge pluggable) |

---

## 3. The organs (swappable parts) and their backends

| Organ | Module | Interface | Live backend | Verified |
|-------|--------|-----------|--------------|----------|
| listen | `stt_deepgram.py` | `STTBackend` | Deepgram (`DEEPGRAM_API_KEY`, no-retention) | live STT |
| think | `model_ollama.py` | `ModelBackend` + `ModelRotator` | Ollama cloud (`OLLAMA_API_KEY`) | live |
| speak | `tts_pocket.py` | `TTSBackend` | Kyutai pocket-tts (operator hardware) | structure |
| draw | `image_cloudflare.py` | `ImageBackend` | Cloudflare Workers AI (`CF_*`) | live (512KB JPEG) |
| field store | `convex_backend.py` | `StigmergyBackend` | Convex cloud `fleet-goose-114` (`CONVEX_DEPLOY_KEY`/`CONVEX_URL`) | **live on cloud** |

All keys live in `~/research/jarvis/.env` (gitignored). Nothing hardcoded.

---

## 4. Data flow of one turn (`JarvisRuntime.turn`, `jarvis_loop.py`)

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
  └─ out: reply, drift, endocrine state, ec_tone, modulation, ethics_conflict, (wav)

field (stigmergy) evaporation rate ← endo.field_volatility()   # the shared internal↔social dial
swarm deliberation: JarvisRuntime.deliberate(q, options)        # models vote via the field
```

---

## 5. Verification matrix — what proves what

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
| Endocannabinoid invariants | `endocannabinoid.py` self-test: I1 monotonic-down, I2 no-flood-processing, I3 attenuated recall |
| Stigmergy dynamics | `stigmergy.py` self-test: reinforce>fade, class decay, arousal speeds decay, quorum, 30-agent convergence + reroute |
| Swarm mechanism | `swarm.py` stub test (consensus + abstention) + live (deepseek+kimi → epinephrine) |
| Convex backend | `convex_backend.py` offline (mock) + **live on `fleet-goose-114.convex.cloud`** |

---

## 6. Cloud / external dependencies

- **Ollama cloud** — think organ + swarm agents (cloud-only; operator hardware can't host local models).
- **Deepgram** — STT, no-retention.
- **Cloudflare Workers AI** — image generation (flux-1-schnell).
- **Convex** (`fleet-goose-114`) — stigmergent field store; functions in `convex/`, deploy headless via `CONVEX_DEPLOY_KEY`.

---

## 7. What is NOT done (no blank spots hidden)

- **Hardware-bound identity (Condition 1):** identity is durable in the owned store but not yet
  cryptographically anchored to specific silicon. This is the one open condition.
- **WP-2026-03 paper is stale:** it still labels conditions 3/4/5 as partial/roadmap and says
  "three of five." As of this build, 3/4/5 are built and wired; it needs a revision pass.
- **Swarm at full roster:** mechanism proven and live with 2 cloud models; a full N-model run
  uses any subset of the current Ollama cloud roster.
- **Ethics judge:** the default judge is deterministic/heuristic; a model judge is the pluggable
  upgrade for subtle semantic violations.

---

## 8. File index (jarvis `_baseline/`)

```
listen   stt_deepgram.py
think    model_ollama.py
speak    tts_pocket.py
draw     image_cloudflare.py
state    endocrine.py  endocannabinoid.py
social   stigmergy.py  convex_backend.py  swarm.py   (+ ../convex/{schema,stigmergy}.ts)
ethics   ethics_guard.py
core     jarvis_loop.py            (JarvisRuntime: wires all organs + HoloGraph)
entry    run_jarvis.py             (mic→think→speak→draw end-to-end)
eval     jarvis_harness.py  jarvis_metrics.py  drift_stats.py  episodic_battery.py  extract_jarvis.py
tests    test_loop_integration.py (A–F)  + HoloGraph tests/ (153)
canon    REALIGNMENT_1218.md  jarvis_baseline.md  jarvis_bootup_transition.md
paper    WP-2026-03_The_JARVIS_Pilot.docx  (needs revision — see §7)
```
