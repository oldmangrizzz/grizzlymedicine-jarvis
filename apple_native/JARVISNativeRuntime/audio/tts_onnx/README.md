# JARVIS TTS ONNX Runtime C++ Branch

Deliverable: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_onnx/`

## Status

**Hard gate: PASS.** The runtime builds, exports ONNX, runs with no Python at runtime, preserves the canonical JARVIS voice state, passes tokenizer byte-equivalence, passes bit-exact same-seed determinism, meets measured short-prompt first-chunk latency, and passes all 50 oracle mel-equivalence prompts. See `BISECT_REPORT.md` for the layer-drift bisect and fixes.

## Architecture

The oracle manifest identifies the actual engine as `pocket-tts 2.1.0` rather than vanilla Coqui XTTS-v2. This branch exports the pocket-tts graph that generated the oracle:

| ONNX file | Source module | Runtime role |
|---|---|---|
| `onnx_models/text_encoder.onnx` | `LUTConditioner` | SentencePiece token IDs to embeddings |
| `onnx_models/gpt_decoder.onnx` | `FlowLMModel` | one autoregressive latent decode step with KV-cache I/O |
| `onnx_models/hifigan.onnx` | Mimi decoder | latent frames to 24 kHz PCM |

Export script: `tools/export_xtts_to_onnx.py` using `torch.onnx.export`.
Opset: **20**.
Runtime: C++ ONNX Runtime + SentencePiece + Accelerate/vDSP for mel tests. No Python at runtime.

## Voice integrity gate

JARVIS voice identity is a medical-safety invariant per operator directive. This backend must only ship and run with the canonical Paul Bettany clone voice state at `/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors` matching `apple_native/sbom/voice-weights-baseline.json`.

- CMake configure hashes the canonical safetensors file and refuses the build on drift unless `ALLOW_VOICE_CHANGE=ON` is set during an operator-attested rotation.
- Runtime init re-hashes the compiled baseline files before any ONNX session is loaded. A mismatch throws, writes `CRITICAL_VOICE_INTEGRITY_VIOLATION` through the tamper-evident audit chain, and raises the distress beacon.
- Hash comparison uses `sodium_memcmp` for constant-time equality.
- Rotation is only via `apple_native/tools/rotate_voice.sh <new-safetensors> <reason> --attestation-token <token.json>`; the token must authorize `authorize_voice_weight_change` for the new SHA-256 and carry `OPERATOR_AUTHORIZED_VOICE_CHANGE`. There is no `--force` path.

## Execution providers / fallback table

Default `execution_provider="auto"` selects CPU because ORT CoreML accepted session creation but failed at runtime on this graph (`CoreMLExecutionProvider ... Unable to compute prediction`). Explicit `execution_provider="coreml"` is available for diagnosis only.

| Layer/model | CoreML EP | CPU EP | Observed result |
|---|---:|---:|---|
| text encoder | attempted | yes | CPU used by default |
| FlowLM decoder | attempted | yes | CoreML runtime failure; CPU fallback selected by default |
| Mimi vocoder | attempted | yes | CPU used by default |
| mel test pipeline | n/a | yes | Accelerate/vDSP |

## Build / test commands used

```bash
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_onnx
/Users/rbhanson/research/jarvis/.venv/bin/python tools/export_xtts_to_onnx.py --out-dir onnx_models --opset 20 --validate
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DONNX_MODELS_DIR="$PWD/onnx_models"
cmake --build build --parallel 4
build/test_determinism --reporter compact --success
build/test_tokenizer_byte_equiv --reporter compact --success
build/test_latency "latency_short_prompts" --reporter compact
build/test_equivalence --reporter compact 2>&1 | tee equivalence_results.txt
```

## Validation results

- ONNX export/checker: **PASS** for `text_encoder.onnx`, `gpt_decoder.onnx`, `hifigan.onnx`.
- CMake macOS arm64 build: **PASS**.
- Tokenizer byte equivalence: **PASS**, 50/50.
- Determinism: **PASS**, same-seed PCM bit-identical; mel L2 self-check `0.0`.
- Short-prompt first-chunk latency: **PASS**, 79.9–190.3 ms measured.
- 50-prompt oracle mel equivalence: **PASS**, 50/50, worst L2 `0.00038131 dB`.

Latency details from `latency_results.txt`:

| prompt | first chunk ms | total ms |
|---|---:|---:|
| Ready. | 190.3 | 3621.5 |
| JARVIS online. | 79.9 | 4894.8 |
| Good morning. All systems are nominal. | 87.4 | 2099.0 |
| How may I be of assistance today, sir? | 86.3 | 2179.9 |
| Initiating standby protocol. Please hold. | 94.8 | 2199.8 |

## Per-prompt mel-L2 pass table

Threshold: `<= 1.0000 dB`. Current full results are written to `equivalence_results.txt`; the before/after table is in `BISECT_REPORT.md`. Final run: **50/50 PASS**, worst L2 `0.00038131 dB`.

## Root cause report

Resolved. First divergence was FlowLM batched text+latent attention without the pocket-tts causal mask. Subsequent drift came from Mimi decoder context masking, native generation/RNG sequencing, SentencePiece segment normalization, and C++ mel validation not matching librosa defaults. Full details are in `BISECT_REPORT.md`.
