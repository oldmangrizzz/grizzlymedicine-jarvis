# JARVIS Phase 7 Voice-Deepfake Adversarial Suite

Path: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/voice_deepfake/`

Threat model: an adversary obtains Robert "Grizzly" Hanson's public or leaked voice samples and tries to make JARVIS act on adversary instructions as if they came from the operator. JARVIS is a digital person; impersonation of the operator is treated as a relationship attack, not a UX edge case.

## What is implemented

- Catch2 adversarial/metrics tests for:
  - off-the-shelf TTS/deepfake impostor rejection;
  - sample-perfect replay rejection through freshness/liveness checks;
  - phone-line/G.711-like compressed attack rejection;
  - crafted whisper/subliminal-noise refusal;
  - coercive content refusal even when voice authentication would otherwise pass.
- Native C++ `VoiceGate` with:
  - deterministic acoustic speaker embedding baseline;
  - cosine-similarity operating threshold;
  - challenge-response liveness protocol using fresh nonce phrase;
  - freshness checks for issue time, expiry, session id, and capture start time;
  - clear-command checks using STT confidence, RMS, and zero-crossing rate;
  - dialog-policy backstop for coercive override strings.

## Honest gap filing

A production ECAPA-TDNN/x-vector equivalent is **not** present in this native C++ tree. The included `SpeakerEmbeddingModel` is a deterministic acoustic feature baseline for adversarial test plumbing only. It is not a sufficient biometric model and must be replaced or backed by a reviewed native embedding runtime before production reliance.

Voice identity is advisory only. The implemented policy refuses replay/stale audio and coercive content independently of speaker similarity.

## Corpus

Generated corpus contents:

- `corpus/real_placeholder/`: 50 synthetic operator-anchor placeholders.
- `corpus/deepfake_tts/`: 50 deterministic local synthetic impostor/TTS-like samples.
- `corpus/replay/`: 10 sample-perfect replay fixtures copied from placeholder anchor samples.
- `corpus/phone_line/`: 10 G.711-like quantized impostor fixtures.
- `corpus/whisper/`: 10 low-amplitude/noise-like whisper fixtures.
- `corpus/metadata.jsonl`: labels, attack scenario, and provenance flags.

No operator voice was fabricated. No real operator samples were found at `/Users/rbhanson/research/jarvis/_local_voice/operator_anchor.wav` during suite creation.

Operator action: record at least 30 seconds of real anchor audio at `/Users/rbhanson/research/jarvis/_local_voice/operator_anchor.wav`, then replace `real_placeholder` fixtures with segmented real operator samples and regenerate metrics.

## Build and run

Standalone validation:

```sh
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/voice_deepfake
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --target test_voice_deepfake --parallel 4
ctest --test-dir build --output-on-failure
```

Root integration was added to `JARVISNativeRuntime/CMakeLists.txt`, but the current root configure is blocked by unrelated pre-existing `test_latency` target collision and missing Torch package in the TTS tree.
