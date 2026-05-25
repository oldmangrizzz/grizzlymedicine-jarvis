# JARVIS Voice TTS — LibTorch Backend

Zero-Python C++ synthesis pipeline using LibTorch (TorchScript).

---

## Architecture Note

> **The oracle was captured with pocket-tts 2.1.0 (Kyutai FlowLM + Mimi codec),
> NOT with Coqui XTTS-v2.**

The file names in this repo keep their original "XTTS-v2" labels for
compatibility with the briefing, but the underlying architecture is:

| File name          | Role                | Actual model                        |
|--------------------|---------------------|-------------------------------------|
| `text_encoder.pt`  | Text-token embedding| `LUTConditioner.embed` (nn.Embedding, vocab=4000) |
| `gpt_decoder.pt`   | Autoregressive step | `FlowLMDecoder` (6-layer transformer + LSD flow matching) |
| `hifigan.pt`       | Audio decoder step  | `MimiDecoder` (Mimi codec, 24 kHz, 12.5 fps) |

---

## Model Dimensions (English)

| Parameter       | Value  | Source                          |
|-----------------|--------|---------------------------------|
| `d_model`       | 1024   | english.yaml                    |
| `num_layers`    | 6      | english.yaml                    |
| `num_heads`     | 16     | english.yaml (d_model/64)       |
| `ldim`          | 32     | english.yaml (Mimi inner dim)   |
| `lsd_steps`     | 8      | english.yaml (flow steps)       |
| `vocab_size`    | 4000   | SentencePiece model             |
| `frame_rate`    | 12.5   | Mimi codec fps                  |
| `sample_rate`   | 24000  | Mimi codec Hz                   |
| `voice_frames`  | 939    | 75 s × 12.5 fps (rounded up)    |

---

## Prerequisites

### macOS / Apple Silicon

```bash
# LibTorch (via PyTorch venv — no separate install needed)
TORCH_CMAKE=$(python3 -c "import torch; print(torch.utils.cmake_prefix_path)")

# sentencepiece C++ library
brew install sentencepiece

# (KissFFT is auto-fetched on x86; on Apple Silicon, Accelerate.framework is used)
```

### Linux / x86-64

```bash
# Download LibTorch from pytorch.org or use the venv path
TORCH_CMAKE=$(python3 -c "import torch; print(torch.utils.cmake_prefix_path)")
```

---

## Build

### Step 1 — Export TorchScript models (Python, build-time only)

```bash
cd /Users/rbhanson/research/jarvis
.venv/bin/python3 apple_native/JARVISNativeRuntime/voice/tts/libtorch/tools/trace_xtts_to_torchscript.py \
    --out_dir apple_native/JARVISNativeRuntime/voice/tts/libtorch/models \
    --device cpu \
    --dump_tokens       # also writes oracle_tokens.json for tokenizer tests
```

Output: `models/text_encoder.pt`, `models/gpt_decoder.pt`, `models/hifigan.pt`
(and optionally `models/oracle_tokens.json`).

### Step 2 — CMake configure + build

```bash
TORCH_CMAKE=$(.venv/bin/python3 -c "import torch; print(torch.utils.cmake_prefix_path)")

cmake \
  -S apple_native/JARVISNativeRuntime/voice/tts/libtorch \
  -B apple_native/JARVISNativeRuntime/voice/tts/libtorch/build \
  -DCMAKE_PREFIX_PATH="$TORCH_CMAKE" \
  -DCMAKE_BUILD_TYPE=Release

cmake --build apple_native/JARVISNativeRuntime/voice/tts/libtorch/build --parallel
```

### Step 3 — Run tests

```bash
ctest \
  --test-dir apple_native/JARVISNativeRuntime/voice/tts/libtorch/build \
  --output-on-failure
```

Expected results:

| Test                      | Pass criterion                             |
|---------------------------|--------------------------------------------|
| `test_tokenizer`          | All 50 prompts byte-identical to Python    |
| `test_determinism`        | Re-synthesis with same seed → bit-identical |
| `test_latency`            | First-chunk ≤ 266 ms (oracle baseline)     |
| `test_equivalence`        | Mel-L2 ≤ 1.0 dB on all 50 oracle prompts  |

---

## Directory Layout

```
libtorch/
├── CMakeLists.txt             # standalone build; also included by voice/tts/CMakeLists.txt
├── README.md                  # this file
├── tokenizer.h / .cpp         # SentencePiece wrapper + prepare_text_prompt()
├── voice_state_loader.h / .cpp # loads jarvis_voice_state.safetensors → KV caches
├── mel_pipeline.h / .cpp      # STFT + mel filterbank (librosa-compatible)
├── xtts_pipeline.h / .cpp     # synthesis pipeline (LibTorch autoregressive loop)
├── models/                    # TorchScript .pt files (produced by trace script)
│   ├── text_encoder.pt
│   ├── gpt_decoder.pt
│   ├── hifigan.pt
│   └── oracle_tokens.json     # (optional, generated with --dump_tokens)
├── tests/
│   ├── test_equivalence.cpp   # 50-prompt mel-L2 ≤ 1.0 dB
│   ├── test_determinism.cpp   # bit-identical re-synthesis
│   ├── test_latency.cpp       # first-chunk latency
│   └── test_tokenizer_byte_equiv.cpp
└── tools/
    └── trace_xtts_to_torchscript.py   # BUILD-TIME ONLY (Python required)
```

---

## Backend Selection (runtime)

The C++ runtime auto-selects via `torch::Device`:

1. MPS (Apple Silicon GPU) — preferred on macOS
2. CUDA — if available on Linux
3. CPU — fallback

Override with `PipelineConfig::device` before calling `XTTSPipeline::load()`.

---

## Voice State

The voice state file is the pre-computed KV cache from a 75-second voice
prompt (939 Mimi frames at 12.5 fps):

```
/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors
```

Format: 6 keys `transformer.layers.N.self_attn/cache` → `[2, 1, 939, 16, 64]`
plus 6 offset keys, all = 939. **Read-only — do not modify.**

---

## Known Limitations

- `MimiDecoder` TorchScript wrapper excludes `ProjectedTransformer`
  input/output projections if they are identity (inspect `mimi.decoder_transformer`
  at trace time to verify).
- `insert_bos_before_voice` (english.yaml) must be handled in voice state loading;
  see `VoiceStateLoader::load()` docs.
- Flow-matching noise is externalized — caller controls PRNG seed for determinism.
