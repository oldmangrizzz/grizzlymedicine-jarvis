# JARVIS Native TTS — LibTorch Branch

Deliverable path: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_libtorch/`.

## Status

**Hard gate: FAIL.** The C++ library builds, but all synthesis/equivalence tests fail before inference because `models/hifigan.pt` is absent. The TorchScript exporter produced `text_encoder.pt` and `gpt_decoder.pt`, then failed while exporting the Mimi vocoder/decoder.

Root cause from the export run:

```text
Scripting hifigan (Mimi decoder step) …
beartype.roar.BeartypeCallHintParamViolation:
Method pocket_tts.modules.conv.StreamingConvTranspose1d.forward() parameter mimi_state="None" violates type hint <class 'dict'>
```

No synthesized PCM was produced. Mel-L2 by oracle prompt:

| Prompt | mel-L2 dB | Result |
|---:|---:|---|
| 00 | NaN | FAIL |
| 01 | NaN | FAIL |
| 02 | NaN | FAIL |
| 03 | NaN | FAIL |
| 04 | NaN | FAIL |
| 05 | NaN | FAIL |
| 06 | NaN | FAIL |
| 07 | NaN | FAIL |
| 08 | NaN | FAIL |
| 09 | NaN | FAIL |
| 10 | NaN | FAIL |
| 11 | NaN | FAIL |
| 12 | NaN | FAIL |
| 13 | NaN | FAIL |
| 14 | NaN | FAIL |
| 15 | NaN | FAIL |
| 16 | NaN | FAIL |
| 17 | NaN | FAIL |
| 18 | NaN | FAIL |
| 19 | NaN | FAIL |
| 20 | NaN | FAIL |
| 21 | NaN | FAIL |
| 22 | NaN | FAIL |
| 23 | NaN | FAIL |
| 24 | NaN | FAIL |
| 25 | NaN | FAIL |
| 26 | NaN | FAIL |
| 27 | NaN | FAIL |
| 28 | NaN | FAIL |
| 29 | NaN | FAIL |
| 30 | NaN | FAIL |
| 31 | NaN | FAIL |
| 32 | NaN | FAIL |
| 33 | NaN | FAIL |
| 34 | NaN | FAIL |
| 35 | NaN | FAIL |
| 36 | NaN | FAIL |
| 37 | NaN | FAIL |
| 38 | NaN | FAIL |
| 39 | NaN | FAIL |
| 40 | NaN | FAIL |
| 41 | NaN | FAIL |
| 42 | NaN | FAIL |
| 43 | NaN | FAIL |
| 44 | NaN | FAIL |
| 45 | NaN | FAIL |
| 46 | NaN | FAIL |
| 47 | NaN | FAIL |
| 48 | NaN | FAIL |
| 49 | NaN | FAIL |

## Architecture finding

The oracle manifest identifies the reference engine as **pocket-tts 2.1.0 (Kyutai FlowLM + Mimi)**, not vanilla Coqui XTTS-v2. This branch therefore targets the oracle architecture with LibTorch/TorchScript:

| Artifact | Role |
|---|---|
| `text_encoder.pt` | SentencePiece token embedding / text conditioning |
| `gpt_decoder.pt` | FlowLM autoregressive latent step |
| `hifigan.pt` | Required Mimi vocoder/decoder step; export currently failed |
| `jarvis_voice_state.safetensors` | Canonical voice KV-cache, read-only |

## Build used

```bash
brew install sentencepiece
cd /Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/audio/tts_libtorch
cmake -S . -B build \
  -DCMAKE_PREFIX_PATH="$(/Users/rbhanson/research/jarvis/.venv/bin/python3 -c 'import torch; print(torch.utils.cmake_prefix_path)')" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

Verified build: succeeds with PyTorch/LibTorch `2.6.0`, AppleClang, macOS arm64. CMake links `libtorch`, `sentencepiece`, `nlohmann_json`, and Accelerate.framework.

## Tests run

```bash
ctest --test-dir build --output-on-failure
```

Result: `40% tests passed, 6 tests failed out of 10`; all tokenizer tests pass, including 50/50 byte-equivalence; equivalence, latency, and determinism fail because the TorchScript vocoder artifact is missing.

## MPS status

`PipelineConfig::device = "mps"` is implemented and falls back to CPU if MPS is unavailable. MPS acceleration is **not validated** because the pipeline cannot load without `hifigan.pt`.

## Stop condition report

All 50 prompts fail the hard gate at pre-inference load. Per-prompt mel-L2 table is emitted by `tests/test_equivalence.cpp`; every row is `NaN` because no PCM exists to compare against oracle mel spectrograms.
