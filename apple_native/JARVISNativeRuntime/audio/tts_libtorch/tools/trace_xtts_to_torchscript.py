#!/usr/bin/env python3
"""
trace_xtts_to_torchscript.py — BUILD-TIME TOOL ONLY (Python required; not in runtime)

Produces three TorchScript archives from the pocket-tts 2.1.0 model weights
(kyutai/pocket-tts, English, voice-cloning model):

    text_encoder.pt   — LUT text-token embedding (n_bins=4000, dim=1024)
    gpt_decoder.pt    — One FlowLM autoregressive step (transformer + LSD decode)
    hifigan.pt        — One Mimi decoder frame (latent → audio at 24 kHz)

ARCHITECTURE NOTE
-----------------
The oracle for the JARVIS libtorch equivalence test was captured with
pocket-tts 2.1.0 (Kyutai), NOT with Coqui XTTS-v2.  pocket-tts uses:
  • SentencePiece tokeniser  (vocab 4000, not BPE 6681)
  • FlowLM transformer        (6 × 1024-dim layers, not GPT)
  • Mimi codec decoder        (not HiFiGAN)
The file names here map semantically:
  text_encoder.pt   ↔  LUTConditioner.embed  (just an nn.Embedding)
  gpt_decoder.pt    ↔  FlowLM single-step forward
  hifigan.pt        ↔  Mimi single-step decode

USAGE
-----
    /path/to/.venv/bin/python3 trace_xtts_to_torchscript.py \\
        --out_dir /path/to/audio/tts_libtorch/models \\
        [--device mps|cuda|cpu]

Run from the jarvis repo root with the pocket_tts venv active.  Outputs
go to <out_dir>; the C++ runtime looks for them there at startup.

TRACING STRATEGY
----------------
• text_encoder   : torch.jit.trace (pure embedding, no control flow)
• gpt_decoder    : torch.jit.script (loops over LSD steps; explicit KV state)
• hifigan        : torch.jit.script (explicit Mimi streaming state)

All random noise for the flow model is generated externally and passed as
an explicit input so that the C++ caller controls the PRNG (required for
determinism tests).

REQUIREMENTS
------------
    pip install pocket-tts>=2.1.0 torch>=2.6.0 safetensors
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import List, Optional, Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

# ---------------------------------------------------------------------------
# Locate pocket-tts
# ---------------------------------------------------------------------------
_VENV_SITE = Path(__file__).parent.parent.parent.parent.parent.parent / ".venv" / "lib"
_site_pkgs = list(_VENV_SITE.glob("python*/site-packages"))
for _sp in _site_pkgs:
    if _sp not in sys.path:
        sys.path.insert(0, str(_sp))

try:
    from pocket_tts.models.tts_model import TTSModel
    from pocket_tts.utils.config import CONFIGS_DIR, load_config
    from pocket_tts.utils.weights_loading import get_flow_lm_state_dict, get_mimi_state_dict
except ImportError as exc:
    sys.exit(f"Cannot import pocket_tts: {exc}\nActivate the jarvis venv first.")


# ---------------------------------------------------------------------------
# TorchScript-compatible helpers  (reimplemented from pocket_tts modules)
# ---------------------------------------------------------------------------

def _apply_rope_ts(
    q: torch.Tensor,
    k: torch.Tensor,
    offset: torch.Tensor,
    max_period: float,
) -> Tuple[torch.Tensor, torch.Tensor]:
    """RoPE (Rotary Position Embedding) — TorchScript-compatible."""
    B, T, H, D = q.shape
    half = D // 2
    ds = torch.arange(half, device=q.device, dtype=torch.float32)
    freqs = torch.exp(ds * (-math.log(max_period) * 2.0 / float(D)))
    ts = torch.arange(T, device=q.device, dtype=torch.float32) + offset.float()
    ts = ts.view(T, 1)
    rotr = torch.cos(freqs * ts)   # [T, half]
    roti = torch.sin(freqs * ts)

    q2 = q.view(B, T, H, half, 2)
    k2 = k.view(B, T, H, half, 2)
    qr, qi = q2[..., 0].float(), q2[..., 1].float()
    kr, ki = k2[..., 0].float(), k2[..., 1].float()

    rotr3 = rotr.view(1, T, 1, half)
    roti3 = roti.view(1, T, 1, half)

    qo = torch.stack([qr * rotr3 - qi * roti3, qr * roti3 + qi * rotr3], dim=-1)
    ko = torch.stack([kr * rotr3 - ki * roti3, kr * roti3 + ki * rotr3], dim=-1)
    return qo.view(B, T, H, D).to(q.dtype), ko.view(B, T, H, D).to(k.dtype)


def _complete_kv_ts(
    cache: torch.Tensor,      # [2, B, S_max, H, Dh]
    offset: torch.Tensor,     # [B] int64
    k: torch.Tensor,          # [B, T, H, Dh]
    v: torch.Tensor,          # [B, T, H, Dh]
) -> Tuple[torch.Tensor, torch.Tensor]:
    """Write k/v into cache at offset, return valid slice (0..offset+T)."""
    off = int(offset[0].item())
    t = k.shape[1]
    cache[0, :, off:off + t] = k
    cache[1, :, off:off + t] = v
    return cache[0, :, :off + t], cache[1, :, :off + t]


def _build_attn_mask_ts(
    pos_q: torch.Tensor,  # [B, T_q]
    pos_k: torch.Tensor,  # [B, T_k]
    context: int,
) -> torch.Tensor:
    delta = pos_q[:, :, None] - pos_k[:, None, :]
    mask = (pos_k[:, None, :] >= 0) & (delta >= 0)
    if context > 0:
        mask = mask & (delta < context)
    return mask[:, None]  # [B, 1, T_q, T_k]


# ---------------------------------------------------------------------------
# TorchScript-compatible single FlowLM layer (attention + FF)
# ---------------------------------------------------------------------------

class TSAttentionLayer(nn.Module):
    """Single streaming causal attention layer, state passed explicitly."""

    def __init__(self, in_proj: nn.Linear, out_proj: nn.Linear,
                 norm1: nn.LayerNorm, norm2: nn.LayerNorm,
                 linear1: nn.Linear, linear2: nn.Linear,
                 num_heads: int, dim_per_head: int, max_period: float,
                 layer_scale_1: float, layer_scale_2: float) -> None:
        super().__init__()
        self.in_proj = in_proj
        self.out_proj = out_proj
        self.norm1 = norm1
        self.norm2 = norm2
        self.linear1 = linear1
        self.linear2 = linear2
        self.num_heads = num_heads
        self.dim_per_head = dim_per_head
        self.max_period = max_period
        self.ls1 = layer_scale_1
        self.ls2 = layer_scale_2

    def forward(
        self,
        x: torch.Tensor,        # [B, T, D]
        kv_cache: torch.Tensor, # [2, B, S_max, H, Dh]
        offset: torch.Tensor,   # [B] int64
    ) -> torch.Tensor:
        B, T, D = x.shape
        H = self.num_heads
        Dh = self.dim_per_head

        # --- self-attention ---
        x_orig = x
        x_n = self.norm1(x)
        projected = self.in_proj(x_n)
        packed = projected.view(B, T, 3, H, Dh)
        q = packed[:, :, 0]  # [B, T, H, Dh]
        k = packed[:, :, 1]
        v = packed[:, :, 2]

        q, k = _apply_rope_ts(q, k, offset[0], self.max_period)

        # write into cache
        off_val = int(offset[0].item())
        kv_cache[0, :, off_val:off_val + T] = k
        kv_cache[1, :, off_val:off_val + T] = v
        ck = kv_cache[0, :, :off_val + T]
        cv = kv_cache[1, :, :off_val + T]

        q_t = q.transpose(1, 2)   # [B, H, T, Dh]
        k_t = ck.permute(0, 2, 1, 3)
        v_t = cv.permute(0, 2, 1, 3)

        pos_q = offset[0].unsqueeze(0).unsqueeze(0) + torch.arange(T, device=x.device, dtype=torch.long).unsqueeze(0)
        pos_k = torch.arange(off_val + T, device=x.device, dtype=torch.long).unsqueeze(0)
        attn_mask = _build_attn_mask_ts(pos_q, pos_k, 0)  # 0 = no context limit for FlowLM

        attn_out = F.scaled_dot_product_attention(q_t, k_t, v_t, attn_mask.float(), dropout_p=0.0)
        attn_out = attn_out.transpose(1, 2).reshape(B, T, H * Dh)
        sa_update = self.out_proj(attn_out)
        x = x_orig + self.ls1 * sa_update

        # --- feed-forward ---
        x_orig2 = x
        x_n2 = self.norm2(x)
        ff_update = self.linear2(F.gelu(self.linear1(x_n2)))
        x = x_orig2 + self.ls2 * ff_update

        return x


# ---------------------------------------------------------------------------
# 1. TextEncoder  (exported as text_encoder.pt)
# ---------------------------------------------------------------------------

class TextEncoder(nn.Module):
    """LUT embedding for SentencePiece token IDs → dense embeddings.

    Input:  tokens  [B, T_text] int64
    Output: embeds  [B, T_text, dim]
    """
    def __init__(self, embed: nn.Embedding, output_proj: nn.Linear) -> None:
        super().__init__()
        self.embed = embed
        self.output_proj = output_proj

    @torch.jit.export
    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        return self.output_proj(self.embed(tokens))


# ---------------------------------------------------------------------------
# 2. FlowLMDecoder — one autoregressive step  (exported as gpt_decoder.pt)
# ---------------------------------------------------------------------------

class FlowLMDecoder(nn.Module):
    """
    Single step of the FlowLM autoregressive decoder.

    Inputs (all positional for TorchScript compatibility):
        backbone_input : [1, 1, ldim]   — previous latent (NaN → BOS embedding)
        text_cond      : [1, T, d_model] — text embeddings for this generation call
        kv_caches      : List[Tensor]   — 6 × [2, 1, S_max, H, Dh], mutated in-place
        offsets        : Tensor         — [6] int64, current write position per layer
        noise          : [1, ldim]      — pre-generated noise for LSD step 0

    Outputs:
        latent   : [1, 1, ldim]
        is_eos   : [1] bool
        (kv_caches are mutated in-place; offsets are NOT updated here — caller
         must do: offsets += 1 after each generation step)
    """
    __constants__ = ["num_layers", "ldim", "d_model", "eos_threshold", "lsd_steps"]

    def __init__(
        self,
        input_linear: nn.Linear,
        layers: List[TSAttentionLayer],
        out_norm: nn.LayerNorm,
        out_eos: nn.Linear,
        flow_net: nn.Module,   # SimpleMLPAdaLN
        bos_emb: torch.Tensor, # [ldim]
        emb_std: torch.Tensor, # [ldim]
        emb_mean: torch.Tensor,
        ldim: int,
        d_model: int,
        eos_threshold: float,
        lsd_steps: int,
    ) -> None:
        super().__init__()
        self.input_linear = input_linear
        self.layers = nn.ModuleList(layers)
        self.out_norm = out_norm
        self.out_eos = out_eos
        self.flow_net = flow_net
        self.register_buffer("bos_emb", bos_emb)
        self.register_buffer("emb_std", emb_std)
        self.register_buffer("emb_mean", emb_mean)
        self.ldim = ldim
        self.d_model = d_model
        self.eos_threshold = eos_threshold
        self.lsd_steps = lsd_steps
        self.num_layers = len(layers)

    def forward(
        self,
        backbone_input: torch.Tensor,     # [1, 1, ldim]
        text_cond: torch.Tensor,           # [1, T, d_model]
        kv_caches: List[torch.Tensor],     # num_layers × [2,1,S,H,Dh]
        offsets: torch.Tensor,             # [num_layers]
        noise: torch.Tensor,               # [1, ldim]
    ) -> Tuple[torch.Tensor, torch.Tensor]:
        # Replace NaN (BOS sentinel) with learned BOS embedding
        bos = self.bos_emb.view(1, 1, self.ldim)
        nan_mask = torch.isnan(backbone_input)
        seq = torch.where(nan_mask, bos, backbone_input)  # [1, 1, ldim]

        # Combine text conditioning + latent input
        x = self.input_linear(seq)         # [1, 1, d_model]
        x_full = torch.cat([text_cond, x], dim=1)  # [1, T+1, d_model]

        # Streaming transformer (6 layers, each writes into its KV cache)
        for i, layer in enumerate(self.layers):
            off_i = offsets[i:i+1]  # [1] offset for this layer
            x_full = layer(x_full, kv_caches[i], off_i)

        x_out = self.out_norm(x_full).to(torch.float32)

        # Take only the last position (the generated latent position)
        last = x_out[:, -1]   # [1, d_model]

        # EOS prediction
        is_eos = (self.out_eos(last) > self.eos_threshold).squeeze(-1)  # [1]

        # LSD (Lagrangian Self-Distillation) flow decode
        # noise is pre-generated externally for PRNG control
        latent = self._lsd_decode(last, noise)

        return latent.unsqueeze(1), is_eos

    def _lsd_decode(self, cond: torch.Tensor, x0: torch.Tensor) -> torch.Tensor:
        """Deterministic LSD flow decode given pre-generated noise x0."""
        # x0: [1, ldim],  cond: [1, d_model]
        current = x0
        n = self.lsd_steps
        for i in range(n):
            s = float(i) / float(n)
            t = float(i + 1) / float(n)
            s_t = torch.full((1, 1), s, dtype=current.dtype, device=current.device)
            t_t = torch.full((1, 1), t, dtype=current.dtype, device=current.device)
            flow_dir = self.flow_net(cond, s_t, t_t, current)
            current = current + flow_dir / float(n)
        return current

    @torch.jit.export
    def denormalize_latent(self, latent: torch.Tensor) -> torch.Tensor:
        """Undo emb_std/emb_mean normalisation used during training."""
        return latent * self.emb_std + self.emb_mean


# ---------------------------------------------------------------------------
# 3. MimiDecoder — one frame decode step  (exported as hifigan.pt)
# ---------------------------------------------------------------------------

class MimiDecoder(nn.Module):
    """
    Single-frame Mimi decoder step: latent → audio chunk.

    The Mimi decoder uses its own streaming KV state (2 attention layers,
    512-dim).  State is passed and mutated in-place; caller increments offsets.

    Inputs:
        latent        : [1, 1, ldim=32]      — one FlowLM latent (denormalised)
        kv_caches     : List[Tensor]         — 2 × [2, 1, S, H=8, Dh=64], mutated in-place
        offsets       : Tensor               — [2] int64
        speaker_proj  : Tensor               — [d_model, inner_dim] projection weight

    Output:
        audio_chunk   : [1, 1, frame_samples]   — raw PCM float32 at 24 kHz
    """

    def __init__(
        self,
        quantizer: nn.Module,  # DummyQuantizer
        upsample: nn.Module,   # ConvTrUpsample1d
        attn_layers: List[TSAttentionLayer],
        attn_in_proj: nn.Linear,
        attn_out_proj: nn.Linear,
        decoder_seanet: nn.Module,  # SEANetDecoder
        ldim: int,
        outer_dim: int,
    ) -> None:
        super().__init__()
        self.quantizer = quantizer
        self.upsample = upsample
        self.attn_layers_mod = nn.ModuleList(attn_layers)
        self.attn_in_proj = attn_in_proj
        self.attn_out_proj = attn_out_proj
        self.decoder_seanet = decoder_seanet
        self.ldim = ldim
        self.outer_dim = outer_dim
        self.num_attn_layers = len(attn_layers)

    def forward(
        self,
        latent: torch.Tensor,          # [1, 1, ldim]  — transposed to [1, ldim, 1]
        kv_caches: List[torch.Tensor], # 2 × [2,1,S,8,64]
        offsets: torch.Tensor,          # [2]
    ) -> torch.Tensor:
        # Transpose to [B, C, T] for conv operations
        lat = latent.transpose(1, 2)   # [1, ldim, 1]

        # Quantizer (DummyQuantizer): just projects dimension ldim → outer_dim
        emb = self.quantizer(lat)      # [1, outer_dim, 1]

        # Upsample from frame_rate (12.5 fps) to encoder frame rate (50 fps)
        emb_up = self.upsample(emb, None)  # [1, outer_dim, 4]

        # Decoder transformer (2 layers)
        emb_t = emb_up.transpose(1, 2)  # [1, 4, outer_dim]
        for i, layer in enumerate(self.attn_layers_mod):
            off_i = offsets[i:i+1]
            emb_t = layer(emb_t, kv_caches[i], off_i)
        emb_out = emb_t.transpose(1, 2)  # [1, outer_dim, 4]

        # SEANet decoder: emb → audio waveform
        audio = self.decoder_seanet(emb_out, None)  # [1, 1, samples]
        return audio


# ---------------------------------------------------------------------------
# TorchScript-compatible SimpleMLPAdaLN flow network
# ---------------------------------------------------------------------------

class TSRMSNorm(nn.Module):
    def __init__(self, alpha: torch.Tensor, eps: float = 1e-5) -> None:
        super().__init__()
        self.register_buffer("alpha", alpha.detach().clone())
        self.eps = eps

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        scale = torch.rsqrt(torch.mean(x.to(torch.float32) * x.to(torch.float32), dim=-1, keepdim=True) + self.eps)
        return (x * scale.to(x.dtype)) * self.alpha.to(x.dtype)


class TSTimestepEmbedder(nn.Module):
    def __init__(self, src: nn.Module) -> None:
        super().__init__()
        self.lin0 = src.mlp[0]
        self.lin1 = src.mlp[2]
        self.norm = TSRMSNorm(src.mlp[3].alpha, float(src.mlp[3].eps))
        self.register_buffer("freqs", src.freqs.detach().clone())

    def forward(self, t: torch.Tensor) -> torch.Tensor:
        args = t * self.freqs.to(t.dtype)
        emb = torch.cat([torch.cos(args), torch.sin(args)], dim=-1)
        emb = torch.nn.functional.silu(self.lin0(emb))
        emb = self.lin1(emb)
        return self.norm(emb)


class TSResBlock(nn.Module):
    def __init__(self, src: nn.Module) -> None:
        super().__init__()
        self.in_ln = src.in_ln
        self.mlp0 = src.mlp[0]
        self.mlp2 = src.mlp[2]
        self.ada = src.adaLN_modulation[1]

    def forward(self, x: torch.Tensor, y: torch.Tensor) -> torch.Tensor:
        mod = self.ada(torch.nn.functional.silu(y))
        shift_mlp, scale_mlp, gate_mlp = torch.chunk(mod, 3, dim=-1)
        h = self.in_ln(x) * (1.0 + scale_mlp) + shift_mlp
        h = self.mlp2(torch.nn.functional.silu(self.mlp0(h)))
        return x + gate_mlp * h


class TSFinalLayer(nn.Module):
    def __init__(self, src: nn.Module) -> None:
        super().__init__()
        self.linear = src.linear
        self.ada = src.adaLN_modulation[1]
        self.eps = float(src.norm_final.eps)

    def forward(self, x: torch.Tensor, c: torch.Tensor) -> torch.Tensor:
        mod = self.ada(torch.nn.functional.silu(c))
        shift, scale = torch.chunk(mod, 2, dim=-1)
        mean = torch.mean(x, dim=-1, keepdim=True)
        var = torch.mean((x - mean) * (x - mean), dim=-1, keepdim=True)
        x = (x - mean) * torch.rsqrt(var + self.eps)
        x = x * (1.0 + scale) + shift
        return self.linear(x)


class TSSimpleMLPAdaLN(nn.Module):
    def __init__(self, src: nn.Module) -> None:
        super().__init__()
        self.time_embed = nn.ModuleList([TSTimestepEmbedder(src.time_embed[0]), TSTimestepEmbedder(src.time_embed[1])])
        self.cond_embed = src.cond_embed
        self.input_proj = src.input_proj
        self.res_blocks = nn.ModuleList([TSResBlock(block) for block in src.res_blocks])
        self.final_layer = TSFinalLayer(src.final_layer)
        self.num_res_blocks = len(src.res_blocks)

    def forward(self, c: torch.Tensor, s: torch.Tensor, t: torch.Tensor, x: torch.Tensor) -> torch.Tensor:
        x = self.input_proj(x)
        y = (self.time_embed[0](s) + self.time_embed[1](t)) / 2.0 + self.cond_embed(c)
        for block in self.res_blocks:
            x = block(x, y)
        return self.final_layer(x, y)


# ---------------------------------------------------------------------------
# Main: load pocket-tts, build wrappers, script & export
# ---------------------------------------------------------------------------

def _get_layer_scale(layer) -> Tuple[float, float]:
    """Extract scalar layer-scale from pocket-tts LayerScale or Identity."""
    ls1 = layer.layer_scale_1
    ls2 = layer.layer_scale_2
    # LayerScale holds a Parameter of shape [D]; use its scale factor if present
    if hasattr(ls1, "scale"):
        v1 = float(ls1.scale.data.mean().item())
    elif hasattr(ls1, "gamma"):
        v1 = float(ls1.gamma.data.mean().item())
    else:
        v1 = 1.0
    if hasattr(ls2, "scale"):
        v2 = float(ls2.scale.data.mean().item())
    elif hasattr(ls2, "gamma"):
        v2 = float(ls2.gamma.data.mean().item())
    else:
        v2 = 1.0
    return v1, v2


def build_ts_layers_flowlm(flow_lm) -> List[TSAttentionLayer]:
    layers: List[TSAttentionLayer] = []
    max_period = float(flow_lm.transformer.max_period)
    for layer in flow_lm.transformer.layers:
        attn = layer.self_attn
        ls1, ls2 = _get_layer_scale(layer)
        ts_layer = TSAttentionLayer(
            in_proj=attn.in_proj,
            out_proj=attn.out_proj,
            norm1=layer.norm1,
            norm2=layer.norm2,
            linear1=layer.linear1,
            linear2=layer.linear2,
            num_heads=attn.num_heads,
            dim_per_head=attn.dim_per_head,
            max_period=max_period,
            layer_scale_1=ls1,
            layer_scale_2=ls2,
        )
        layers.append(ts_layer)
    return layers


def build_ts_layers_mimi(mimi) -> List[TSAttentionLayer]:
    """Build TSAttentionLayer wrappers for Mimi's decoder transformer."""
    layers: List[TSAttentionLayer] = []
    max_period = 10000.0
    dec_xfm = mimi.decoder_transformer
    # ProjectedTransformer wraps a StreamingTransformer
    inner = dec_xfm.transformer
    for layer in inner.layers:
        attn = layer.self_attn
        ls1, ls2 = _get_layer_scale(layer)
        ts_layer = TSAttentionLayer(
            in_proj=attn.in_proj,
            out_proj=attn.out_proj,
            norm1=layer.norm1,
            norm2=layer.norm2,
            linear1=layer.linear1,
            linear2=layer.linear2,
            num_heads=attn.num_heads,
            dim_per_head=attn.dim_per_head,
            max_period=max_period,
            layer_scale_1=ls1,
            layer_scale_2=ls2,
        )
        layers.append(ts_layer)
    return layers


@torch.no_grad()
def main() -> None:
    parser = argparse.ArgumentParser(description="Trace pocket-tts to TorchScript")
    parser.add_argument("--out_dir", default="models", help="Output directory for .pt files")
    parser.add_argument("--device", default="cpu", choices=["cpu", "mps", "cuda"],
                        help="Device for scripting (cpu recommended for portability)")
    parser.add_argument("--language", default="english")
    parser.add_argument("--dump_tokens", action="store_true",
                        help="Also dump oracle_tokens.json for tokenizer byte-equiv tests")
    args = parser.parse_args()

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    dev = torch.device(args.device)

    print(f"Loading pocket-tts ({args.language}) …")
    model = TTSModel.load_model(language=args.language)
    model.eval()
    model.to(dev)

    flow_lm = model.flow_lm
    mimi = model.mimi

    lsd_steps: int = model.lsd_decode_steps
    temp: float = model.temp
    eos_threshold: float = float(model.eos_threshold)
    ldim: int = flow_lm.ldim
    d_model: int = flow_lm.dim

    # ── 1. text_encoder.pt ──────────────────────────────────────────────────
    print("Scripting text_encoder …")
    lut = flow_lm.conditioner
    text_enc = TextEncoder(
        embed=lut.embed,
        output_proj=lut.output_proj if hasattr(lut, "output_proj") else nn.Identity(),
    ).to(dev)

    # Validate with example tokens
    example_tokens = torch.zeros(1, 8, dtype=torch.long, device=dev)
    example_emb = text_enc(example_tokens)
    print(f"  text_encoder output shape: {example_emb.shape}")  # [1, 8, d_model]

    scripted_te = torch.jit.script(text_enc)
    te_path = out / "text_encoder.pt"
    scripted_te.save(str(te_path))
    print(f"  saved → {te_path}")

    # ── 2. gpt_decoder.pt (FlowLM single step) ──────────────────────────────
    print("Scripting gpt_decoder (FlowLM step) …")
    ts_layers = build_ts_layers_flowlm(flow_lm)
    gpt_dec = FlowLMDecoder(
        input_linear=flow_lm.input_linear,
        layers=ts_layers,
        out_norm=flow_lm.out_norm,
        out_eos=flow_lm.out_eos,
        flow_net=TSSimpleMLPAdaLN(flow_lm.flow_net),
        bos_emb=flow_lm.bos_emb.data.clone(),
        emb_std=flow_lm.emb_std.clone(),
        emb_mean=flow_lm.emb_mean.clone(),
        ldim=ldim,
        d_model=d_model,
        eos_threshold=eos_threshold,
        lsd_steps=lsd_steps,
    ).to(dev)

    num_fl_layers = len(ts_layers)
    S_max = 1100  # voice_state (939) + tokens (~50) + generation (~100)
    example_bi = torch.full((1, 1, ldim), float("nan"), device=dev)
    example_tc = torch.zeros(1, 8, d_model, device=dev)
    example_kv = [torch.full((2, 1, S_max, 16, 64), float("nan"), device=dev)
                  for _ in range(num_fl_layers)]
    example_off = torch.zeros(num_fl_layers, dtype=torch.long, device=dev)
    example_noise = torch.randn(1, ldim, device=dev)

    # Dry-run to verify shapes
    latent, eos = gpt_dec(example_bi, example_tc, example_kv, example_off, example_noise)
    print(f"  gpt_decoder output: latent={latent.shape}, is_eos={eos.shape}")

    scripted_gpt = torch.jit.script(gpt_dec)
    gpt_path = out / "gpt_decoder.pt"
    scripted_gpt.save(str(gpt_path))
    print(f"  saved → {gpt_path}")

    # Dump token references before the vocoder export. This keeps tokenizer
    # validation available even if Mimi TorchScript export fails.
    if args.dump_tokens:
        _dump_oracle_tokens(out, flow_lm)

    # ── 3. hifigan.pt (Mimi decoder step) ───────────────────────────────────
    print("Scripting hifigan (Mimi decoder step) …")
    mimi_layers = build_ts_layers_mimi(mimi)
    num_mimi_layers = len(mimi_layers)

    mimi_dec = MimiDecoder(
        quantizer=mimi.quantizer,
        upsample=mimi.upsample,
        attn_layers=mimi_layers,
        attn_in_proj=nn.Identity(),  # ProjectedTransformer handles input projection
        attn_out_proj=nn.Identity(),
        decoder_seanet=mimi.decoder,
        ldim=int(mimi.quantizer.dimension) if hasattr(mimi.quantizer, "dimension") else ldim,
        outer_dim=mimi.dimension,
    ).to(dev)

    # Mimi KV cache dims: [2, B, S, 8 heads, 64 dim/head]
    MIMI_S_MAX = 2000
    example_lat = torch.randn(1, 1, ldim, device=dev)
    example_mkv = [torch.full((2, 1, MIMI_S_MAX, 8, 64), float("nan"), device=dev)
                   for _ in range(num_mimi_layers)]
    example_moff = torch.zeros(num_mimi_layers, dtype=torch.long, device=dev)

    audio_chunk = mimi_dec(example_lat, example_mkv, example_moff)
    print(f"  hifigan output: audio_chunk={audio_chunk.shape}")  # [1, 1, ~1920]

    scripted_mimi = torch.jit.script(mimi_dec)
    hifigan_path = out / "hifigan.pt"
    scripted_mimi.save(str(hifigan_path))
    print(f"  saved → {hifigan_path}")

    # ── Summary ─────────────────────────────────────────────────────────────
    print()
    print("=== TRACE COMPLETE ===")
    for p in [te_path, gpt_path, hifigan_path]:
        mb = p.stat().st_size / 1024 / 1024
        print(f"  {p.name}  ({mb:.1f} MB)")
    print()
    print("Model dimensions (embed in CMakeLists / xtts_pipeline.cpp):")
    print(f"  ldim={ldim}  d_model={d_model}  lsd_steps={lsd_steps}")
    print(f"  vocab_size=4000  temp={temp}  eos_threshold={eos_threshold}")
    print(f"  num_fl_layers={num_fl_layers}  num_mimi_layers={num_mimi_layers}")
    print()
    print("Zero-Python runtime: YES — C++ uses LibTorch torch::jit::load() only")


# ---------------------------------------------------------------------------
# oracle_tokens.json dump helper (--dump_tokens)
# ---------------------------------------------------------------------------

def _dump_oracle_tokens(out_dir: Path, flow_lm: "FlowLMDecoder") -> None:
    """
    Runs all 50 oracle prompts through Python SentencePiece and writes
    oracle_tokens.json to out_dir.  This file is consumed by
    tests/test_tokenizer_byte_equiv.cpp for byte-level equivalence testing.

    Format::

        {
          "tokenizer_model": "/abs/path/to/tokenizer.model",
          "prompts": [
            {"idx": 0, "text": "...", "tokens": [id, id, ...]},
            ...
          ]
        }
    """
    import json
    import sentencepiece as spm

    # Locate tokenizer model from pocket_tts internals
    from pocket_tts.utils.config import CONFIGS_DIR
    tok_model_path: Optional[str] = None
    try:
        import huggingface_hub as hf
        # Try the standard HuggingFace cache layout
        snapshot = hf.snapshot_download(
            "kyutai/pocket-tts-without-voice-cloning",
            local_files_only=True,
        )
        candidates = list(Path(snapshot).rglob("**/english*/tokenizer.model"))
        if candidates:
            tok_model_path = str(candidates[0])
    except Exception:
        pass

    if tok_model_path is None or not Path(tok_model_path).exists():
        # Fallback: find from flow_lm's wrapped tokenizer attribute
        for attr in ("tokenizer", "_tokenizer", "text_encoder", "conditioner"):
            obj = getattr(flow_lm, attr, None)
            if obj is not None:
                mdl = getattr(obj, "model_path", getattr(obj, "_model_path", None))
                if mdl and Path(mdl).exists():
                    tok_model_path = str(mdl)
                    break

    if tok_model_path is None or not Path(tok_model_path).exists():
        cache = Path.home() / ".cache" / "huggingface" / "hub" / "models--kyutai--pocket-tts-without-voice-cloning"
        candidates = sorted(cache.glob("snapshots/*/languages/english_2026-04/tokenizer.model"))
        if not candidates:
            candidates = sorted(cache.glob("snapshots/*/languages/english/tokenizer.model"))
        if candidates:
            tok_model_path = str(candidates[0])

    if tok_model_path is None or not Path(tok_model_path).exists():
        print(f"  WARNING: could not locate tokenizer.model — oracle_tokens.json NOT written")
        return

    # Locate oracle prompts
    oracle_prompts = Path("/Users/rbhanson/research/oracle/voice/prompts.json")
    if not oracle_prompts.exists():
        oracle_prompts = Path(__file__).resolve().parents[7] / "oracle" / "voice" / "prompts.json"

    if not oracle_prompts.exists():
        print(f"  WARNING: prompts.json not found at {oracle_prompts} — skipping dump_tokens")
        return

    # --- tokenization ---
    sp = spm.SentencePieceProcessor()
    sp.Load(tok_model_path)

    def _prepare_text(text: str) -> str:
        """Replicate pocket_tts.conditioners.text.prepare_text_prompt exactly."""
        t = text.strip()
        # collapse multiple spaces
        import re
        t = re.sub(r" +", " ", t)
        if not t:
            return t
        # uppercase first character
        t = t[0].upper() + t[1:]
        # append period if last char is alnum
        if t and t[-1].isalnum():
            t += "."
        return t

    prompts_data = json.loads(oracle_prompts.read_text())
    prompts = prompts_data["prompts"]

    results = []
    for p in prompts:
        raw_text = p["text"]
        prepared = _prepare_text(raw_text)
        tokens = sp.EncodeAsIds(prepared)
        results.append({"idx": p["idx"], "text": raw_text, "prepared": prepared, "tokens": tokens})

    out_path = out_dir / "oracle_tokens.json"
    out_path.write_text(json.dumps({
        "tokenizer_model": tok_model_path,
        "prompts": results,
    }, indent=2, ensure_ascii=False))
    print(f"  oracle_tokens.json → {out_path}  ({len(results)} prompts)")


if __name__ == "__main__":
    main()
