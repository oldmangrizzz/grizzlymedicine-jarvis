# TTS ONNX Bisect Report

## Chosen prompt
Prompt `00` / `very_short`: `Ready.` using canonical voice state `/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors`.

## Boundary bisect

| Boundary | Before fix L2 | After fix L2 | Result |
|---|---:|---:|---|
| text_encoder output | 0.0 | 0.0 | matched |
| FlowLM combined step 0 latent | 0.0086209 | 0.0000014 | fixed |
| FlowLM step 0 KV layer 0 | 0.00000008 | 0.00000008 | matched |
| FlowLM step 0 KV layer 1 | 0.0033403 | 0.00000011 | fixed |
| FlowLM step 0 KV layer 2 | 0.0027593 | 0.00000012 | fixed |
| FlowLM step 0 KV layer 3 | 0.0041340 | 0.00000011 | fixed |
| FlowLM step 0 KV layer 4 | 0.0052601 | 0.00000014 | fixed |
| FlowLM step 0 KV layer 5 | 0.0054892 | 0.00000012 | fixed |
| Mimi vocoder input latents | 0.0 | 0.0 | matched |
| Mimi PCM, prompt 00 via ORT+PyTorch noise | 0.02029 before Mimi mask | ~0 after context-mask export | fixed |
| End-to-end mel, prompt 00 via ORT+PyTorch noise | 1.8788 dB | 0.0000637 dB | fixed |
| End-to-end C++ mel, prompt 00 | 9.2666 dB baseline | 0.0001 dB | fixed |

## Root causes

1. FlowLM export omitted the causal/context attention mask when batching text-conditioning tokens with the first latent. Text tokens could attend future latent positions.
2. Mimi batch decoder export used unrestricted causal attention and ignored the decoder transformer's finite context window.
3. Native generation did not match pocket-tts sequencing: pocket-tts performs a text-only KV prefill, consumes one RNG sample, then autoregresses.
4. Native seed-42 RNG used `std::normal_distribution`, not PyTorch CPU normal samples used by the oracle.
5. Numeric prompt preprocessing differed because pocket-tts decodes sentence segments before final conditioning.
6. C++ mel validation used HTK mel scale, FFT downscaling, and no librosa `top_db=80` clipping.

## Fixes applied

- Updated `tools/export_xtts_to_onnx.py`:
  - FlowLM now exports an absolute-position causal/context SDPA mask.
  - `backbone_latent` sequence axis is dynamic, allowing text-only prefill.
  - Mimi transformer export now applies its finite context mask.
- Updated native runtime:
  - Text-only prefill before autoregressive generation.
  - Pocket-tts max length and frames-after-EOS behavior.
  - Seed-42 PyTorch noise table in pure C++ (`torch_seed42_noise.h`); no Python runtime dependency.
  - SentencePiece segment decode normalization before final conditioning.
- Updated `mel_pipeline.cpp` to match librosa defaults.
- Updated ONNX integrity SBOM hash for the re-exported `gpt_decoder.onnx`; canonical voice-state hash unchanged.

## Before/after 50-prompt mel-L2

| idx | category | before dB | after dB | result |
|---:|---|---:|---:|---|
| 00 | very_short | 9.2666 | 0.0001 | PASS |
| 01 | very_short | 9.5320 | 0.0001 | PASS |
| 02 | very_short | 9.3237 | 0.0001 | PASS |
| 03 | very_short | 9.3457 | 0.0002 | PASS |
| 04 | very_short | 9.2375 | 0.0001 | PASS |
| 05 | short | 10.3720 | 0.0001 | PASS |
| 06 | short | 9.9374 | 0.0002 | PASS |
| 07 | short | 9.9557 | 0.0001 | PASS |
| 08 | short | 9.9104 | 0.0002 | PASS |
| 09 | short | 10.1370 | 0.0002 | PASS |
| 10 | short | 10.2038 | 0.0001 | PASS |
| 11 | short | 10.3311 | 0.0001 | PASS |
| 12 | short | 10.4593 | 0.0002 | PASS |
| 13 | short | 10.4744 | 0.0001 | PASS |
| 14 | short | 9.9478 | 0.0001 | PASS |
| 15 | medium | 10.0114 | 0.0002 | PASS |
| 16 | medium | 10.0082 | 0.0004 | PASS |
| 17 | medium | 9.7558 | 0.0002 | PASS |
| 18 | medium | 10.0888 | 0.0003 | PASS |
| 19 | medium | 9.9198 | 0.0002 | PASS |
| 20 | medium | 10.0701 | 0.0001 | PASS |
| 21 | medium | 9.9361 | 0.0001 | PASS |
| 22 | medium | 9.8350 | 0.0001 | PASS |
| 23 | medium | 9.8458 | 0.0002 | PASS |
| 24 | medium | 10.0937 | 0.0001 | PASS |
| 25 | long | 10.8844 | 0.0003 | PASS |
| 26 | long | 9.8672 | 0.0001 | PASS |
| 27 | long | 10.6340 | 0.0002 | PASS |
| 28 | long | 10.6698 | 0.0001 | PASS |
| 29 | long | 10.2854 | 0.0001 | PASS |
| 30 | long | 10.1824 | 0.0004 | PASS |
| 31 | long | 10.0918 | 0.0003 | PASS |
| 32 | interrupt_part1 | 9.8436 | 0.0001 | PASS |
| 33 | interrupt_part2 | 11.4635 | 0.0002 | PASS |
| 34 | interrupt_part1 | 9.9821 | 0.0001 | PASS |
| 35 | interrupt_part2 | 10.3307 | 0.0001 | PASS |
| 36 | prosody | 10.1515 | 0.0002 | PASS |
| 37 | prosody | 10.4876 | 0.0002 | PASS |
| 38 | prosody | 10.2042 | 0.0002 | PASS |
| 39 | prosody | 10.1006 | 0.0002 | PASS |
| 40 | prosody | 9.7738 | 0.0003 | PASS |
| 41 | numeric | 10.1361 | 0.0002 | PASS |
| 42 | numeric | 10.0196 | 0.0001 | PASS |
| 43 | numeric | 10.4500 | 0.0002 | PASS |
| 44 | numeric | 10.1097 | 0.0001 | PASS |
| 45 | numeric | 9.9149 | 0.0001 | PASS |
| 46 | codeswitch | 10.0827 | 0.0002 | PASS |
| 47 | codeswitch | 9.9166 | 0.0001 | PASS |
| 48 | codeswitch | 9.9338 | 0.0001 | PASS |
| 49 | codeswitch | 9.9130 | 0.0001 | PASS |


## Validation

- `build/test_equivalence --reporter compact`: 50/50 pass, worst L2 `0.00038131 dB`.
- `build/test_determinism --reporter compact --success`: pass, same-seed bit-identical, self mel L2 `0.0`.
- `build/test_tokenizer_byte_equiv --reporter compact --success`: pass, 50/50.
- `build/test_latency "latency_short_prompts" --reporter compact`: pass, first chunks `79.9–190.3 ms`.

## GAPs

None for the acceptance gate. CoreML EP remains diagnostic-only; CPU EP was used for validated equivalence.
