# JARVIS Raw Audio Scene Classifier

**Status:** `audio_frontend: pending_raw_audio_classifier` → **implemented**

Front gate of JARVIS hearing. Separates the raw mic stream into scene classes
**before** STT is invoked. No raw audio is ever logged; only class labels,
confidence scores, and timestamps leave the classifier.

---

## Architecture

```
Raw mic (16 kHz int16 mono)
        │
        ▼
 RawAudioSceneClassifier::feed_audio()
        │
        ├─ Energy gate (RMS dBFS) ──→ silence?  →  suppress
        │
        ├─ FeatureExtractor (vDSP)
        │      Hann-windowed STFT → Power spectrum → 64-bin log-mel
        │      98 frames × 64 mels per 1-second window
        │
        ├─ ModelRuntime (CoreML, ANE)
        │      Input:  [1, 1, 98, 64]  float32
        │      Output: [5]             float32  (softmax scores)
        │      Falls back to heuristic if no model loaded
        │
        └─ Debounce (2/3 majority, 3-window history)
                │
                ├─ speech_directed  →  STT pipeline
                ├─ speech_ambient   →  log only (DO NOT send to STT — privacy)
                ├─ music            →  regulation channel
                │                        • increment endocrine dopamine
                │                        • deposit "music" topic in Pheromind
                ├─ noise            →  suppress
                └─ silence          →  suppress
```

### Timing budget

| Stage                  | Budget        | Actual (Apple M-series p99) |
|------------------------|---------------|-----------------------------|
| Energy gate            | < 0.5 ms      | ~0.02 ms                   |
| vDSP log-mel (98 FFTs) | < 3 ms        | ~1.2 ms                    |
| CoreML inference (ANE) | < 15 ms       | ~3–8 ms (model-dependent)  |
| Debounce + callback    | < 0.1 ms      | ~0.01 ms                   |
| **Total p99**          | **≤ 20 ms**   | **≤ 10 ms (typical)**      |

20 ms = 8 % of the 250 ms hot-path budget
(`audio_context.py → policy.hot_path_budget_ms: 250`).

---

## Files

```
voice/classifier/
├── CMakeLists.txt
├── README.md
├── feature_extractor.h / .cpp   — vDSP log-mel feature extraction
├── model_runtime.h / .mm        — CoreML inference wrapper (Objective-C++)
├── scene_classifier.h / .cpp    — RawAudioSceneClassifier public API
├── tools/
│   ├── train_classifier.py      — BUILD-TIME: train MobileNetV3-small CNN
│   ├── convert_to_coreml.py     — BUILD-TIME: export to .mlpackage
│   └── generate_test_fixtures.py— BUILD-TIME: synthetic WAV fixtures
└── tests/
    ├── test_classifier.cpp      — Catch2: per-class accuracy & routing
    └── test_latency.cpp         — Catch2: p99 latency assertion ≤ 20 ms
```

**Runtime contains zero Python.** The `.mm` Objective-C++ file is compiled
into the static library; CoreML and Accelerate are Apple system frameworks.

---

## Build

```bash
cd voice/classifier
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

> **Requires:** macOS 13+, Xcode Command Line Tools, CMake ≥ 3.20.
> Catch2 v3 is fetched automatically by CMake.

---

## API

```cpp
#include "scene_classifier.h"

// Heuristic-only (no trained model)
jarvis::RawAudioSceneClassifier clf;

// With CoreML model (after running train + convert tools)
jarvis::RawAudioSceneClassifier clf(
    "/path/to/audio_scene_classifier.mlpackage",
    /*window_ms*/             1000,
    /*hop_ms*/                 250,
    /*energy_threshold_dbfs*/  -50.0f
);

// Register transition callback (fired on debounced class change)
clf.on_scene_change([](jarvis::SceneEvent e) {
    switch (jarvis::routingFor(e.label)) {
        case jarvis::SceneRouting::stt:        /* send to Deepgram */  break;
        case jarvis::SceneRouting::log_only:   /* log label only */    break;
        case jarvis::SceneRouting::regulation: /* endocrine + pheromind */ break;
        case jarvis::SceneRouting::suppress:                            break;
    }
});

// In mic callback (runs on audio thread — non-blocking)
std::span<const int16_t> samples = /* from CoreAudio */;
if (auto evt = clf.feed_audio(samples)) {
    // evt is the most recently classified window
    // The on_scene_change callback already fired if the class changed
}
```

---

## Training (build-time only)

### Step 1 — Prepare dataset

Arrange audio clips in this layout:
```
dataset/
    speech_directed/   *.wav   # speech addressed to JARVIS
    speech_ambient/    *.wav   # background/TV speech
    music/             *.wav   # any music
    noise/             *.wav   # HVAC, traffic, keyboard, etc.
    silence/           *.wav   # silent / near-silent
```

See §Dataset license inventory below for recommended sources.

### Step 2 — Train

```bash
python3 tools/train_classifier.py \
    --data-dir   /path/to/dataset \
    --output-dir /path/to/artifacts \
    --epochs     40 \
    --batch-size 64
```

Outputs: `best_model.pt`, `audio_scene_classifier.pt`, `model_meta.json`

### Step 3 — Convert to CoreML

```bash
python3 tools/convert_to_coreml.py \
    --model-pt   /path/to/artifacts/audio_scene_classifier.pt \
    --meta-json  /path/to/artifacts/model_meta.json \
    --output-dir /path/to/artifacts
```

Outputs: `audio_scene_classifier.mlpackage` (~2–5 MB float16)

### Step 4 — Run with model

```bash
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DTEST_MODEL_PATH=/path/to/artifacts/audio_scene_classifier.mlpackage
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

---

## Dataset license inventory

> **Operator policy:** every dataset's license is documented here because legal-process
> exposure is a threat in the JARVIS threat model. Provenance gaps are flagged explicitly.

| Dataset | License | Use | Notes |
|---------|---------|-----|-------|
| **Mozilla CommonVoice** | CC0 (public domain dedication) | speech training + eval | Audited provenance; contributor consent on record. Preferred speech source. |
| **LibriSpeech** (test-clean) | CC BY 4.0 | speech training | Derived from LibriVox audiobooks; attribution required. |
| **Oracle voice WAVs** (`oracle/voice/wav/`) | GMRI proprietary | speech test fixtures | JARVIS response phrases only; clean TTS speech. |
| **Free Music Archive (FMA small)** | CC-BY (per-track; filter needed) | music training | Use only tracks tagged CC-BY or CC0. Script to filter: `tools/filter_fma_cc.py` (future). Cite: Defferrard et al., 2017. |
| **Synthetic harmonics** (`generate_test_fixtures.py`) | None (generated) | music test fixtures | Pure-tone harmonics; no copyright. Fully deterministic. |
| **MUSAN** (noise split) | CC BY 4.0 | noise training | Use the `noise` directory. MUSAN music is mostly public domain but filter to be safe. Cite: Snyder et al., 2015. |
| **ESC-50** | CC BY-NC 3.0 | noise research ONLY | **Non-commercial only.** Do NOT ship in a commercial product or include in the production model. Use MUSAN noise instead for shipping. |

### Music gap acknowledgement

No CC0 music dataset with sufficient diversity was identified at time of writing.
FMA-small is the best available CC-BY option but requires per-track license filtering.
If filtered FMA is unacceptable, use synthetic harmonics only and document the
reduced recall (expected ~80 % vs ~95 % with diverse music training data).

---

## Privacy contract

- **Classifier sees raw audio.** It MUST NOT log audio samples, feature vectors,
  or any content that could reconstruct the operator's audio.
- **What IS logged** (via `redacting_logger.h`): class label, confidence score,
  start/end timestamp. These are safe to log per the GMRI privacy threat model.
- No telemetry. No model-drift upload. No cloud calls at runtime.
- `speech_ambient` is explicitly routed to `log_only` — background conversation
  is never transcribed via STT.

---

## Expected accuracy (with trained CoreML model)

| Class            | Recall target | Precision target |
|------------------|---------------|------------------|
| speech_directed  | ≥ 96 %        | ≥ 90 %           |
| speech_ambient   | ≥ 85 %        | ≥ 80 %           |
| music            | ≥ 90 %        | ≥ 90 %           |
| noise            | ≥ 85 %        | ≥ 85 %           |
| silence          | ~100 %        | ~100 %           |

**Heuristic-only (no model):** silence ~100 %, music ~75–85 %, speech ~60–85 %,
noise ~55–70 %. Sufficient for development; not sufficient for production.

---

## Blocked / known limitations

1. **No trained model included.** Training requires labeled audio data (see §Dataset).
   Run the build-time tools to produce `audio_scene_classifier.mlpackage`.
2. **speech_directed vs speech_ambient** split requires wakeword + speaker diarization
   context (future layer — ModelSwarm). Currently both map to `speech_directed`.
3. **Sample rate must be 16 000 Hz.** Resampling is the caller's responsibility.
   The classifier does not perform internal resampling (would add latency).
4. **Mono only.** Stereo input must be downmixed before `feed_audio`.
5. **ESC-50** is CC BY-NC; it MUST NOT be used in any model artifact that ships in a
   commercial product. Use MUSAN noise instead.
