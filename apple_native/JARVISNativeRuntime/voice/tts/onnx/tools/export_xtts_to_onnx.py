#!/usr/bin/env python3
"""
export_xtts_to_onnx.py — Build-time tool (Python + PyTorch only).

Exports pocket-tts 2.1.0 (Kyutai FlowLM + Mimi) to three ONNX files:
  - text_encoder.onnx  : token IDs → text embeddings [B, T, d_model]
  - gpt_decoder.onnx   : FlowLM single autoregressive step (growing KV-cache pattern)
  - hifigan.onnx       : Mimi batch decoder (all latents at once → full audio)

KV-cache design for gpt_decoder (growing cache, ONNX-safe):
  Input:  kv_cache_i  shape [2, B, T_cur, H, D]  (current filled cache)
  Output: kv_cache_i  shape [2, B, T_cur+1, H, D] (one new K/V appended via torch.cat)

  kv_len (int64 scalar input) carries the current cache length as a dynamic tensor,
  enabling correct dynamic RoPE offsets. T_cur is dynamic on dim 2.

hifigan design (batch mode, stateless):
  Input:  all_norm_latents [B, ldim, N]  — all N latent frames
  Output: audio            [B, 1, N*frame_size]
  Streaming state (overlap-add buffers) is avoided by directly calling the
  underlying nn.ConvTranspose1d with explicit causal trim (K−S samples trimmed
  from the right), which equals streaming with zero initial state.

Run:
  source /path/to/jarvis/.venv/bin/activate
  python tools/export_xtts_to_onnx.py --out-dir onnx_models --opset 20 --validate

Requirements (build-time only):
  pocket-tts==2.1.0, torch>=2.6.0, onnx>=1.14
  onnxruntime (optional, --validate flag)
"""

import argparse
import logging
import sys
from functools import partial
from pathlib import Path
from typing import List, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F
import onnx

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger(__name__)

try:
    from pocket_tts import TTSModel
    from pocket_tts.modules.rope import RotaryEmbedding
except ImportError as exc:
    sys.exit(
        f"pocket-tts not importable: {exc}\n"
        "Activate the project venv: source /Users/rbhanson/research/jarvis/.venv/bin/activate"
    )


# ─────────────────────────────────────────────────────────────────────────────
# RoPE helper (ONNX-friendly, no .item())
# ─────────────────────────────────────────────────────────────────────────────

def apply_rope_onnx(q: torch.Tensor, k: torch.Tensor,
                    offset: torch.Tensor,
                    rope: RotaryEmbedding) -> Tuple[torch.Tensor, torch.Tensor]:
    """Apply RoPE with a scalar offset tensor (dynamic, no .item() required by rope module)."""
    # rope.forward(q, k, offset=scalar) — pocket-tts rope accepts tensor or int
    return rope(q, k, offset=offset)


# ─────────────────────────────────────────────────────────────────────────────
# Text encoder
# ─────────────────────────────────────────────────────────────────────────────

class TextEncoderWrapper(nn.Module):
    """LUTConditioner: int64 token IDs → float32 embeddings.
    Input:  tokens  [B, T_text]  int64
    Output: embeds  [B, T_text, d_model]  float32
    """
    def __init__(self, conditioner):
        super().__init__()
        self.embed = conditioner.embed
        # output_proj may not exist on all versions
        self.out_proj = getattr(conditioner, "output_proj", None)

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        x = self.embed(tokens)
        if self.out_proj is not None:
            x = self.out_proj(x)
        return x


# ─────────────────────────────────────────────────────────────────────────────
# Single-step attention (ONNX-friendly: growing cache, no indexed writes)
# ─────────────────────────────────────────────────────────────────────────────

def attention_step_growing_cache(
    x: torch.Tensor,              # [B, 1, embed_dim]
    kv_cache: torch.Tensor,       # [2, B, T_cur, H, D]  — valid filled cache
    in_proj: nn.Linear,
    out_proj: nn.Linear,
    rope: RotaryEmbedding,
    kv_len: torch.Tensor,         # 0-d int64 — current cache length (DYNAMIC in ONNX)
    context: Optional[int] = None,
) -> Tuple[torch.Tensor, torch.Tensor]:
    """
    One attention step with explicit KV cache (growing pattern).

    kv_len must be an explicit int64 tensor input (not derived from kv_cache.shape[2],
    which would be traced as a Python-int constant and produce wrong RoPE rotations).

    Returns: (output [B, 1, embed_dim], new_kv_cache [2, B, T_cur+1, H, D])
    """
    B, T_q, embed_dim = x.shape  # T_q == 1
    num_heads = kv_cache.shape[3]
    D = kv_cache.shape[4]       # head_dim

    # Input projection: [B, 1, embed_dim] → [B, 1, 3, H, D]
    projected = in_proj(x)
    packed = projected.view(B, T_q, 3, num_heads, D)
    q, k, v = torch.unbind(packed, dim=2)  # each [B, 1, H, D]

    # RoPE offset = kv_len (a true tensor input, dynamic in ONNX via Shape op).
    # Do NOT use kv_cache.shape[2] here — that returns a Python int during tracing
    # and gets constant-folded to the trace-time value (939), breaking all subsequent steps.
    q, k = rope(q, k, offset=kv_len)  # [B, 1, H, D]

    # Append new K, V to cache → [2, B, T_cur+1, H, D]
    k_new = k.unsqueeze(0)   # [1, B, 1, H, D]
    v_new = v.unsqueeze(0)   # [1, B, 1, H, D]
    kv_new = torch.cat([k_new, v_new], dim=0)  # [2, B, 1, H, D]
    new_kv_cache = torch.cat([kv_cache, kv_new], dim=2)  # [2, B, T_cur+1, H, D]

    # Build full K, V for attention: [B, T_cur+1, H, D]
    k_full = new_kv_cache[0]  # [B, T_cur+1, H, D]
    v_full = new_kv_cache[1]  # [B, T_cur+1, H, D]

    # Transpose for SDPA: [B, H, T, D]
    q_t   = q.transpose(1, 2)    # [B, H, 1, D]
    k_t   = k_full.transpose(1, 2)  # [B, H, T_cur+1, D]
    v_t   = v_full.transpose(1, 2)  # [B, H, T_cur+1, D]

    # Causal mask for single-step decode: all K/V positions are visible
    # (all pos_k <= pos_q = T_cur, since pos_k ∈ [0..T_cur])
    # → is_causal=False, no mask needed (all attend)
    out = F.scaled_dot_product_attention(q_t, k_t, v_t, is_causal=False)

    # Reshape: [B, H, 1, D] → [B, 1, H*D]
    out = out.transpose(1, 2).reshape(B, T_q, embed_dim)
    out = out_proj(out)

    return out, new_kv_cache


# ─────────────────────────────────────────────────────────────────────────────
# Transformer layer (ONNX-friendly)
# ─────────────────────────────────────────────────────────────────────────────

def transformer_layer_step(
    x: torch.Tensor,
    kv_cache: torch.Tensor,
    layer,  # StreamingTransformerLayer
    rope: RotaryEmbedding,
    kv_len: torch.Tensor,    # 0-d int64, passed through to attention
) -> Tuple[torch.Tensor, torch.Tensor]:
    """One transformer layer, ONNX-safe (growing cache, no in-place ops on state)."""
    attn = layer.self_attn
    # Self-attention sub-block
    x_norm = layer.norm1(x)
    attn_out, new_kv = attention_step_growing_cache(
        x_norm, kv_cache,
        attn.in_proj, attn.out_proj, rope, kv_len, attn.context
    )
    x = x + layer.layer_scale_1(attn_out)

    # Feed-forward sub-block
    x_norm2 = layer.norm2(x)
    ff_out = layer.linear2(F.gelu(layer.linear1(x_norm2)))
    x = x + layer.layer_scale_2(ff_out)

    return x, new_kv


# ─────────────────────────────────────────────────────────────────────────────
# FlowLM single-step wrapper (growing KV cache)
# ─────────────────────────────────────────────────────────────────────────────

class FlowLMStepWrapper(nn.Module):
    """Single autoregressive step of FlowLMModel.

    Inputs:
      backbone_latent   [B, 1, ldim]            — current latent (NaN = BOS)
      text_embeddings   [B, T_cond, d_model]    — text + voice conditioning (may be 0-len)
      noise             [B, ldim]               — externally supplied noise for LSD decode
      kv_0 .. kv_{N-1} [2, B, T_cur, H, D]     — valid (filled) KV caches, one per layer

    Outputs:
      next_latent       [B, 1, ldim]
      is_eos            [B, 1]   bool
      kv_0_out .. kv_{N-1}_out [2, B, T_cur+1, H, D]
    """
    def __init__(self, flow_lm, lsd_decode_steps: int, eos_threshold: float, num_layers: int):
        super().__init__()
        self.flow_lm        = flow_lm
        self.lsd_decode_steps = lsd_decode_steps
        self.eos_threshold  = eos_threshold
        self.num_layers     = num_layers
        self.rope           = flow_lm.transformer.rope

    def forward(self, backbone_latent: torch.Tensor,
                text_embeddings: torch.Tensor,
                noise: torch.Tensor,
                kv_len: torch.Tensor,        # 0-d int64 — current KV cache length
                *kv_caches) -> tuple:
        # BOS substitution
        bos = self.flow_lm.bos_emb.unsqueeze(0).unsqueeze(0).expand_as(backbone_latent)
        sequence = torch.where(torch.isnan(backbone_latent), bos, backbone_latent)

        # Input projection [B, 1, d_model]
        input_ = self.flow_lm.input_linear(sequence)

        # Concatenate text conditioning prefix
        full_input = torch.cat([text_embeddings, input_], dim=1)  # [B, T_cond+1, d_model]

        # Run transformer layers (growing cache)
        x = full_input
        new_kv_caches = []
        layers = list(self.flow_lm.transformer.layers)
        for i, layer in enumerate(layers):
            x, new_kv = transformer_layer_step(x, kv_caches[i], layer, self.rope, kv_len)
            new_kv_caches.append(new_kv)

        # Apply output norm
        x = self.flow_lm.out_norm(x)

        # Strip conditioning prefix, take last (newest) position
        T_cond = text_embeddings.shape[1]
        transformer_out = x[:, -1]   # [B, d_model] — last position = just-decoded

        # EOS prediction
        is_eos = self.flow_lm.out_eos(transformer_out) > self.eos_threshold  # [B, 1]

        # LSD flow decoding (inline, no while loop — single step since lsd_decode_steps=1)
        current = noise   # [B, ldim]
        for step_i in range(self.lsd_decode_steps):
            s = torch.tensor(step_i / self.lsd_decode_steps,
                             dtype=transformer_out.dtype, device=transformer_out.device)
            t = torch.tensor((step_i + 1) / self.lsd_decode_steps,
                             dtype=transformer_out.dtype, device=transformer_out.device)
            s_like = s.expand_as(current[..., :1])
            t_like = t.expand_as(current[..., :1])
            flow_dir = self.flow_lm.flow_net(transformer_out, s_like, t_like, current)
            current = current + flow_dir / self.lsd_decode_steps

        next_latent = current.unsqueeze(1)   # [B, 1, ldim]

        return (next_latent, is_eos) + tuple(new_kv_caches)


# ─────────────────────────────────────────────────────────────────────────────
# Mimi batch decoder (non-streaming, full-sequence)
# ─────────────────────────────────────────────────────────────────────────────
#
# pocket-tts uses beartype_this_package() which wraps ALL methods at import
# time. StreamingConvTranspose1d.forward requires mimi_state: dict (not None).
# We bypass it entirely by calling the underlying nn.ConvTranspose1d directly
# and applying the causal-trim manually (equivalent to streaming with zero
# initial state). StreamingConv1d.forward accepts model_state=None (fresh state).
#
# The Mimi decoder is exported as a BATCH model:
#   Input:  all_norm_latents [B, ldim, N]  — all N latent frames
#   Output: audio            [B, 1, N * frame_size]
#
# This is simpler than per-step streaming and avoids state management.
# The C++ runtime generates all FlowLM tokens first, then calls Mimi once.

try:
    from pocket_tts.modules.conv import StreamingConvTranspose1d as _StreamingConvTr
    from pocket_tts.modules.seanet import SEANetResnetBlock as _SEANetResnetBlock
except ImportError:
    _StreamingConvTr = None
    _SEANetResnetBlock = None


def _non_streaming_convtr(layer, x: torch.Tensor) -> torch.Tensor:
    """Non-streaming pass through StreamingConvTranspose1d.

    Equivalent to streaming with zero initial partial state:
    1. Run the raw nn.ConvTranspose1d
    2. Trim the last (kernel_size - stride) samples from the output
       (the overlap-add tail that would carry to the next chunk)
    """
    K = layer._kernel_size
    S = layer._stride
    PT = K - S
    y = layer.convtr(x)   # underlying nn.ConvTranspose1d
    if PT > 0:
        y = y[..., :-PT]
    return y


def _seanet_decode_nonstreaming(decoder, emb_out: torch.Tensor) -> torch.Tensor:
    """Walk decoder.model, dispatching each layer type correctly."""
    x = emb_out
    for layer in decoder.model:
        if _StreamingConvTr is not None and isinstance(layer, _StreamingConvTr):
            x = _non_streaming_convtr(layer, x)
        elif _SEANetResnetBlock is not None and isinstance(layer, _SEANetResnetBlock):
            # SEANetResnetBlock.forward(x, model_state) — StreamingConv1d accepts None
            x = layer(x, model_state=None)
        elif hasattr(layer, 'forward') and 'model_state' in (
            layer.forward.__code__.co_varnames if hasattr(layer.forward, '__code__') else []
        ):
            x = layer(x, model_state=None)
        else:
            x = layer(x)
    return x


def _mimi_transformer_full_seq(layer, rope: RotaryEmbedding,
                                x: torch.Tensor) -> torch.Tensor:
    """Full-sequence transformer layer (causal, no KV cache needed for batch export)."""
    B, T, D = x.shape
    attn = layer.self_attn
    num_heads = attn.num_heads
    head_dim = D // num_heads

    x_norm = layer.norm1(x)
    projected = attn.in_proj(x_norm)
    packed = projected.view(B, T, 3, num_heads, head_dim)
    q, k, v = torch.unbind(packed, dim=2)  # each [B, T, H, head_dim]

    # RoPE with offset=0 (full sequence from position 0)
    q, k = rope(q, k, offset=0)

    q_t = q.transpose(1, 2)  # [B, H, T, head_dim]
    k_t = k.transpose(1, 2)
    v_t = v.transpose(1, 2)
    out = F.scaled_dot_product_attention(q_t, k_t, v_t, is_causal=True)
    out = out.transpose(1, 2).reshape(B, T, D)
    out = attn.out_proj(out)

    x = x + layer.layer_scale_1(out)
    x_norm2 = layer.norm2(x)
    ff = layer.linear2(F.gelu(layer.linear1(x_norm2)))
    x = x + layer.layer_scale_2(ff)
    return x


class MimiNonStreamingDecoder(nn.Module):
    """Mimi batch decoder: all normalized latents at once → full audio.

    Inputs:
      all_norm_latents  [B, ldim, N]  — all N normalized latent frames

    Outputs:
      audio             [B, 1, N * frame_size]  — raw waveform

    Notes:
      - Upsample (16x) uses raw nn.ConvTranspose1d + causal trim (= streaming w/ zero state)
      - Decoder transformer runs full-sequence causal self-attention (no KV cache)
      - SEANet decode uses StreamingConv1d(model_state=None) + raw ConvTranspose1d + trim
      - Avoids all beartype-gated stateful APIs
    """
    def __init__(self, mimi, flow_lm_emb_std: torch.Tensor, flow_lm_emb_mean: torch.Tensor):
        super().__init__()
        self.mimi = mimi
        self.register_buffer("emb_std",  flow_lm_emb_std.clone())   # [ldim]
        self.register_buffer("emb_mean", flow_lm_emb_mean.clone())  # [ldim]
        self.rope = mimi.decoder_transformer.transformer.rope

    def forward(self, all_norm_latents: torch.Tensor) -> torch.Tensor:
        # all_norm_latents: [B, ldim, N]
        mimi = self.mimi

        # Denormalize: [B, ldim, N]
        emb_std  = self.emb_std.unsqueeze(-1)   # [ldim, 1]
        emb_mean = self.emb_mean.unsqueeze(-1)  # [ldim, 1]
        denorm = all_norm_latents * emb_std + emb_mean   # [B, ldim, N]

        # Quantizer projection: [B, ldim, N] → [B, outer_dim, N]
        quantized = mimi.quantizer(denorm)

        # Upsample 16x: [B, outer_dim, N] → [B, outer_dim, N*16]
        upsampled = _non_streaming_convtr(mimi.upsample.convtr, quantized)

        # Decoder transformer (full sequence, causal)
        dt = mimi.decoder_transformer
        emb = upsampled.transpose(1, 2)   # [B, N*16, outer_dim]
        if dt.input_proj is not None:
            emb = dt.input_proj(emb)

        x = emb
        for layer in dt.transformer.layers:
            x = _mimi_transformer_full_seq(layer, self.rope, x)

        ys = [op(x).transpose(1, 2) for op in dt.output_projs]
        emb_out = ys[0]  # [B, outer_dim, N*16]

        # SEANet decode
        audio = _seanet_decode_nonstreaming(mimi.decoder, emb_out)  # [B, 1, N*frame_size]
        return audio



# ─────────────────────────────────────────────────────────────────────────────
# Export helpers
# ─────────────────────────────────────────────────────────────────────────────

def export_text_encoder(model: TTSModel, out_path: Path, opset: int):
    log.info("Exporting text_encoder.onnx …")
    wrapper = TextEncoderWrapper(model.flow_lm.conditioner).eval().cpu()

    dummy_tokens = torch.randint(0, 4000, (1, 8), dtype=torch.long)

    torch.onnx.export(
        wrapper, (dummy_tokens,), str(out_path),
        opset_version=opset,
        input_names=["tokens"],
        output_names=["text_embeddings"],
        dynamic_axes={"tokens":         {0: "batch", 1: "seq_len"},
                      "text_embeddings":{0: "batch", 1: "seq_len"}},
        do_constant_folding=True,
    )
    log.info("  Saved %s (%.2f MB)", out_path.name, out_path.stat().st_size / 1e6)


def export_flow_lm_step(model: TTSModel, out_path: Path, opset: int):
    log.info("Exporting gpt_decoder.onnx (FlowLM single step, growing KV cache) …")

    flow_lm    = model.flow_lm.cpu().eval()
    num_layers = len(flow_lm.transformer.layers)
    ldim       = flow_lm.ldim
    d_model    = flow_lm.dim
    attn0      = flow_lm.transformer.layers[0].self_attn
    num_heads  = attn0.num_heads
    head_dim   = attn0.embed_dim // num_heads

    log.info("  layers=%d d_model=%d ldim=%d heads=%d head_dim=%d",
             num_layers, d_model, ldim, num_heads, head_dim)

    wrapper = FlowLMStepWrapper(
        flow_lm=flow_lm,
        lsd_decode_steps=model.lsd_decode_steps,
        eos_threshold=model.eos_threshold,
        num_layers=num_layers,
    ).eval().cpu()

    B     = 1
    T_cond= 8     # number of text+voice conditioning tokens (traced, dynamic later)
    T_cur = 939   # initial KV cache length (voice state prefill)

    backbone_latent  = torch.full((B, 1, ldim), float("nan"))
    text_embeddings  = torch.randn(B, T_cond, d_model)
    noise            = torch.randn(B, ldim)   # externally supplied noise
    kv_len           = torch.tensor(T_cur, dtype=torch.long)
    kv_caches        = [
        torch.zeros(2, B, T_cur, num_heads, head_dim)
        for _ in range(num_layers)
    ]

    dummy_inputs = (backbone_latent, text_embeddings, noise, kv_len, *kv_caches)

    input_names  = ["backbone_latent", "text_embeddings", "noise", "kv_len"]
    for i in range(num_layers):
        input_names.append(f"kv_{i}")

    output_names = ["next_latent", "is_eos"]
    for i in range(num_layers):
        output_names.append(f"kv_{i}_out")

    dynamic_axes = {
        "backbone_latent": {0: "batch"},
        "text_embeddings": {0: "batch", 1: "cond_len"},
        "noise":           {0: "batch"},
        "next_latent":     {0: "batch"},
        "is_eos":          {0: "batch"},
    }
    for i in range(num_layers):
        dynamic_axes[f"kv_{i}"]     = {1: "batch", 2: "cache_len"}
        dynamic_axes[f"kv_{i}_out"] = {1: "batch", 2: "cache_len_plus_1"}

    torch.onnx.export(
        wrapper, dummy_inputs, str(out_path),
        opset_version=opset,
        input_names=input_names,
        output_names=output_names,
        dynamic_axes=dynamic_axes,
        do_constant_folding=True,
    )
    log.info("  Saved %s (%.2f MB)", out_path.name, out_path.stat().st_size / 1e6)


def export_mimi_decoder(model: TTSModel, out_path: Path, opset: int):
    log.info("Exporting hifigan.onnx (Mimi batch decoder, non-streaming) …")

    mimi    = model.mimi.cpu().eval()
    flow_lm = model.flow_lm.cpu().eval()
    ldim    = flow_lm.ldim

    log.info("  ldim=%d frame_rate=%.1f encoder_frame_rate=%.1f",
             ldim, mimi.frame_rate, mimi.encoder_frame_rate)

    wrapper = MimiNonStreamingDecoder(
        mimi=mimi,
        flow_lm_emb_std=flow_lm.emb_std,
        flow_lm_emb_mean=flow_lm.emb_mean,
    ).eval().cpu()

    B = 1
    N = 4   # trace with 4 latent frames (dynamic axis allows any N)

    dummy_inputs = (torch.randn(B, ldim, N),)

    torch.onnx.export(
        wrapper, dummy_inputs, str(out_path),
        opset_version=opset,
        input_names=["all_norm_latents"],
        output_names=["audio"],
        dynamic_axes={
            "all_norm_latents": {0: "batch", 2: "n_frames"},
            "audio":            {0: "batch", 2: "audio_len"},
        },
        do_constant_folding=True,
    )
    log.info("  Saved %s (%.2f MB)", out_path.name, out_path.stat().st_size / 1e6)


def validate_onnx(path: Path, ort_available: bool):
    # Structural check (no runtime needed)
    m = onnx.load(str(path))
    onnx.checker.check_model(m)
    log.info("  ONNX checker OK: %s", path.name)
    if ort_available:
        import onnxruntime as ort
        sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        log.info("  ORT session load OK: %s", path.name)


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Export pocket-tts 2.1.0 → ONNX (build-time)")
    parser.add_argument("--out-dir",  required=True,
                        help="Output directory for *.onnx files")
    parser.add_argument("--opset",    type=int, default=20)
    parser.add_argument("--temp",     type=float, default=0.75,
                        help="Temperature used by the oracle (default: 0.75)")
    parser.add_argument("--validate", action="store_true",
                        help="Run onnx.checker and optional ORT load after export")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("Loading pocket-tts model (temp=%.2f, lsd_steps=1, eos_thresh=-4.0) …", args.temp)
    model = TTSModel.load_model(temp=args.temp, lsd_decode_steps=1,
                                noise_clamp=None, eos_threshold=-4.0)
    model = model.cpu().eval()
    log.info("  Loaded. ldim=%d d_model=%d layers=%d",
             model.flow_lm.ldim, model.flow_lm.dim,
             len(model.flow_lm.transformer.layers))

    ort_available = False
    try:
        import onnxruntime; ort_available = True
    except ImportError:
        pass

    te_path  = out_dir / "text_encoder.onnx"
    gpt_path = out_dir / "gpt_decoder.onnx"
    hfg_path = out_dir / "hifigan.onnx"

    export_text_encoder(model, te_path, args.opset)
    export_flow_lm_step(model, gpt_path, args.opset)
    export_mimi_decoder(model, hfg_path, args.opset)

    if args.validate:
        for p in [te_path, gpt_path, hfg_path]:
            validate_onnx(p, ort_available)

    log.info("\nExport complete:")
    for p in [te_path, gpt_path, hfg_path]:
        sz = p.stat().st_size / 1e6 if p.exists() else -1
        log.info("  %-30s  %.2f MB", p.name, sz)

    log.info("\nNext:")
    log.info("  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DONNX_MODELS_DIR=%s", out_dir)
    log.info("  cmake --build build && ctest --test-dir build --output-on-failure")


if __name__ == "__main__":
    main()
