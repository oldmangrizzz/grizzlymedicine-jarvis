#!/usr/bin/env python3
"""Native CoreML conversion attempt for JARVIS pocket-tts/XTTS-v2-clone.

Produces CoreML mlpackages under ../models. This script deliberately fails non-zero
if any required component cannot be converted; runtime tests must not silently use a
partial model.
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Tuple

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

from pocket_tts import TTSModel
from pocket_tts.modules.rope import RotaryEmbedding

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("jarvis_coreml_convert")

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MODELS_DIR = ROOT / "models"
VOICE_STATE = Path("/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors")


class TextEncoderWrapper(nn.Module):
    def __init__(self, conditioner):
        super().__init__()
        self.embed = conditioner.embed
        self.out_proj = getattr(conditioner, "output_proj", None)

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        x = self.embed(tokens)
        if self.out_proj is not None:
            x = self.out_proj(x)
        return x


def attention_step_growing_cache(x: torch.Tensor, kv_cache: torch.Tensor,
                                 in_proj: nn.Linear, out_proj: nn.Linear,
                                 rope: RotaryEmbedding, kv_len: torch.Tensor,
                                 context=None) -> Tuple[torch.Tensor, torch.Tensor]:
    B, T_q, embed_dim = x.shape
    num_heads = kv_cache.shape[3]
    D = kv_cache.shape[4]
    projected = in_proj(x)
    packed = projected.view(B, T_q, 3, num_heads, D)
    q, k, v = torch.unbind(packed, dim=2)
    q, k = rope(q, k, offset=kv_len)
    kv_new = torch.cat([k.unsqueeze(0), v.unsqueeze(0)], dim=0)
    new_kv_cache = torch.cat([kv_cache, kv_new], dim=2)
    k_full = new_kv_cache[0]
    v_full = new_kv_cache[1]
    out = F.scaled_dot_product_attention(
        q.transpose(1, 2), k_full.transpose(1, 2), v_full.transpose(1, 2), is_causal=False)
    out = out.transpose(1, 2).reshape(B, T_q, embed_dim)
    return out_proj(out), new_kv_cache


def transformer_layer_step(x: torch.Tensor, kv_cache: torch.Tensor, layer,
                           rope: RotaryEmbedding, kv_len: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
    attn = layer.self_attn
    attn_out, new_kv = attention_step_growing_cache(
        layer.norm1(x), kv_cache, attn.in_proj, attn.out_proj, rope, kv_len, attn.context)
    x = x + layer.layer_scale_1(attn_out)
    x_norm2 = layer.norm2(x)
    ff_out = layer.linear2(F.gelu(layer.linear1(x_norm2)))
    x = x + layer.layer_scale_2(ff_out)
    return x, new_kv


class FlowLMStepWrapper(nn.Module):
    def __init__(self, flow_lm, lsd_decode_steps: int, eos_threshold: float, num_layers: int):
        super().__init__()
        self.flow_lm = flow_lm
        self.lsd_decode_steps = int(lsd_decode_steps)
        self.eos_threshold = float(eos_threshold)
        self.num_layers = int(num_layers)
        self.rope = flow_lm.transformer.rope

    def forward(self, backbone_latent: torch.Tensor, text_embeddings: torch.Tensor,
                noise: torch.Tensor, kv_len: torch.Tensor, *kv_caches) -> tuple:
        bos = self.flow_lm.bos_emb.unsqueeze(0).unsqueeze(0).expand_as(backbone_latent)
        sequence = torch.where(torch.isnan(backbone_latent), bos, backbone_latent)
        input_ = self.flow_lm.input_linear(sequence)
        x = torch.cat([text_embeddings, input_], dim=1)
        new_kv = []
        for i, layer in enumerate(self.flow_lm.transformer.layers):
            x, cache_out = transformer_layer_step(x, kv_caches[i], layer, self.rope, kv_len)
            new_kv.append(cache_out)
        x = self.flow_lm.out_norm(x)
        transformer_out = x[:, -1]
        is_eos = self.flow_lm.out_eos(transformer_out) > self.eos_threshold
        current = noise
        for step_i in range(self.lsd_decode_steps):
            s = torch.tensor(step_i / self.lsd_decode_steps, dtype=transformer_out.dtype, device=transformer_out.device)
            t = torch.tensor((step_i + 1) / self.lsd_decode_steps, dtype=transformer_out.dtype, device=transformer_out.device)
            s_like = s.expand_as(current[..., :1])
            t_like = t.expand_as(current[..., :1])
            flow_dir = self.flow_lm.flow_net(transformer_out, s_like, t_like, current)
            current = current + flow_dir / self.lsd_decode_steps
        return (current.unsqueeze(1), is_eos) + tuple(new_kv)


try:
    from pocket_tts.modules.conv import StreamingConv1d as _StreamingConv
    from pocket_tts.modules.conv import StreamingConvTranspose1d as _StreamingConvTr
    from pocket_tts.modules.seanet import SEANetResnetBlock as _SEANetResnetBlock
except ImportError:  # pragma: no cover
    _StreamingConv = None
    _StreamingConvTr = None
    _SEANetResnetBlock = None


def _non_streaming_conv(layer, x: torch.Tensor) -> torch.Tensor:
    tp = layer._effective_kernel_size - layer._stride
    if tp > 0:
        if layer.pad_mode == "replicate":
            previous = x[..., :1].expand(x.shape[0], x.shape[1], tp)
        else:
            previous = torch.zeros(x.shape[0], x.shape[1], tp, dtype=x.dtype, device=x.device)
        x = torch.cat([previous, x], dim=-1)
    return layer.conv(x)


def _non_streaming_convtr(layer, x: torch.Tensor) -> torch.Tensor:
    pt = layer._kernel_size - layer._stride
    y = layer.convtr(x)
    if pt > 0:
        y = y[..., :-pt]
    return y


def _non_streaming_seanet_block(layer, x: torch.Tensor) -> torch.Tensor:
    v = x
    for sublayer in layer.block:
        if _StreamingConv is not None and isinstance(sublayer, _StreamingConv):
            v = _non_streaming_conv(sublayer, v)
        else:
            v = sublayer(v)
    return x + v


def _seanet_decode_nonstreaming(decoder, emb_out: torch.Tensor) -> torch.Tensor:
    x = emb_out
    for layer in decoder.model:
        if _StreamingConvTr is not None and isinstance(layer, _StreamingConvTr):
            x = _non_streaming_convtr(layer, x)
        elif _StreamingConv is not None and isinstance(layer, _StreamingConv):
            x = _non_streaming_conv(layer, x)
        elif _SEANetResnetBlock is not None and isinstance(layer, _SEANetResnetBlock):
            x = _non_streaming_seanet_block(layer, x)
        else:
            x = layer(x)
    return x


def _mimi_transformer_full_seq(layer, rope: RotaryEmbedding, x: torch.Tensor) -> torch.Tensor:
    attn = layer.self_attn
    H = int(attn.num_heads)
    D = int(attn.embed_dim)
    Hd = D // H
    x_norm = layer.norm1(x)
    packed = attn.in_proj(x_norm).reshape(1, -1, 3, H, Hd)
    q, k, v = torch.unbind(packed, dim=2)
    q, k = rope(q, k, offset=0)
    out = F.scaled_dot_product_attention(q.transpose(1, 2), k.transpose(1, 2), v.transpose(1, 2), is_causal=True)
    out = out.transpose(1, 2).reshape(1, -1, D)
    x = x + layer.layer_scale_1(attn.out_proj(out))
    x_norm2 = layer.norm2(x)
    ff = layer.linear2(F.gelu(layer.linear1(x_norm2)))
    return x + layer.layer_scale_2(ff)


class MimiNonStreamingDecoder(nn.Module):
    def __init__(self, mimi, flow_lm_emb_std: torch.Tensor, flow_lm_emb_mean: torch.Tensor):
        super().__init__()
        self.mimi = mimi
        self.register_buffer("emb_std", flow_lm_emb_std.clone())
        self.register_buffer("emb_mean", flow_lm_emb_mean.clone())
        self.rope = mimi.decoder_transformer.transformer.rope

    def forward(self, all_norm_latents: torch.Tensor) -> torch.Tensor:
        mimi = self.mimi
        denorm = all_norm_latents * self.emb_std.unsqueeze(-1) + self.emb_mean.unsqueeze(-1)
        quantized = mimi.quantizer(denorm)
        upsampled = _non_streaming_convtr(mimi.upsample.convtr, quantized)
        dt = mimi.decoder_transformer
        x = upsampled.transpose(1, 2)
        if dt.input_proj is not None:
            x = dt.input_proj(x)
        for layer in dt.transformer.layers:
            x = _mimi_transformer_full_seq(layer, self.rope, x)
        emb_out = dt.output_projs[0](x).transpose(1, 2)
        return _seanet_decode_nonstreaming(mimi.decoder, emb_out)


def convert_text(model: TTSModel) -> None:
    log.info("Converting text_encoder.mlpackage")
    flow = model.flow_lm.cpu().eval()
    wrapper = TextEncoderWrapper(flow.conditioner).eval()
    tokens = torch.randint(0, 4000, (1, 8), dtype=torch.long)
    traced = torch.jit.trace(wrapper, (tokens,))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=ct.Shape(shape=(1, ct.RangeDim(1, 512))), dtype=np.int32)],
        outputs=[ct.TensorType(name="text_embeddings", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    mlmodel.save(str(MODELS_DIR / "text_encoder.mlpackage"))


def convert_flow(model: TTSModel) -> None:
    log.info("Converting flow_decoder.mlpackage")
    flow = model.flow_lm.cpu().eval()
    L = len(flow.transformer.layers)
    ldim = int(flow.ldim)
    d_model = int(flow.dim)
    attn0 = flow.transformer.layers[0].self_attn
    H = int(attn0.num_heads)
    Hd = int(attn0.embed_dim // H)
    wrapper = FlowLMStepWrapper(flow, model.lsd_decode_steps, model.eos_threshold, L).eval()
    B, T_cond, T_cur = 1, 8, 939
    backbone = torch.full((B, 1, ldim), float("nan"))
    text = torch.randn(B, T_cond, d_model)
    noise = torch.randn(B, ldim)
    kv_len = torch.tensor([T_cur], dtype=torch.long)
    kv = [torch.zeros(2, B, T_cur, H, Hd) for _ in range(L)]
    traced = torch.jit.trace(wrapper, (backbone, text, noise, kv_len, *kv), strict=False)
    inputs = [
        ct.TensorType(name="backbone_latent", shape=(1, 1, ldim), dtype=np.float32),
        ct.TensorType(name="text_embeddings", shape=ct.Shape(shape=(1, ct.RangeDim(1, 512), d_model)), dtype=np.float32),
        ct.TensorType(name="noise", shape=(1, ldim), dtype=np.float32),
        ct.TensorType(name="kv_len", shape=(1,), dtype=np.int32),
    ]
    for i in range(L):
        inputs.append(ct.TensorType(name=f"kv_{i}", shape=ct.Shape(shape=(2, 1, ct.RangeDim(1, 6000), H, Hd)), dtype=np.float32))
    outputs = [ct.TensorType(name="next_latent", dtype=np.float32), ct.TensorType(name="is_eos", dtype=np.float32)]
    for i in range(L):
        outputs.append(ct.TensorType(name=f"kv_{i}_out", dtype=np.float32))
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        outputs=outputs,
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
    )
    mlmodel.save(str(MODELS_DIR / "flow_decoder.mlpackage"))


def convert_mimi(model: TTSModel) -> None:
    log.info("Converting mimi_decoder.mlpackage")
    flow = model.flow_lm.cpu().eval()
    mimi = model.mimi.cpu().eval()
    wrapper = MimiNonStreamingDecoder(mimi, flow.emb_std, flow.emb_mean).eval()
    dummy = torch.randn(1, int(flow.ldim), 4)
    with torch.no_grad():
        out = wrapper(dummy)
        log.info("Mimi forward OK: %s -> %s", tuple(dummy.shape), tuple(out.shape))
    traced = torch.jit.trace(wrapper, (dummy,), strict=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="all_norm_latents", shape=ct.Shape(shape=(1, int(flow.ldim), ct.RangeDim(1, 2048))), dtype=np.float32)],
        outputs=[ct.TensorType(name="audio", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.save(str(MODELS_DIR / "mimi_decoder.mlpackage"))


def write_metadata(model: TTSModel) -> None:
    flow = model.flow_lm
    attn0 = flow.transformer.layers[0].self_attn
    meta = {
        "architecture": "pocket-tts-2.1.0-kyutai",
        "required_packages": ["text_encoder.mlpackage", "flow_decoder.mlpackage", "mimi_decoder.mlpackage"],
        "flow_lm": {
            "num_layers": len(flow.transformer.layers),
            "d_model": int(flow.dim),
            "num_heads": int(attn0.num_heads),
            "head_dim": int(attn0.embed_dim // attn0.num_heads),
            "ldim": int(flow.ldim),
            "lsd_steps": int(model.lsd_decode_steps),
            "eos_threshold": float(model.eos_threshold),
            "vocab_size": int(flow.conditioner.embed.num_embeddings),
        },
        "mimi": {"sample_rate": 24000, "frame_rate": 12.5, "inner_dim": int(flow.ldim)},
        "voice_state": {"path": str(VOICE_STATE), "sha256_expected": "18c530633ea17c85b1b3dbf6c949579a08b1744ee391487b619c642bf35c1560"},
        "conversion": {"tool": str(Path(__file__).resolve()), "coremltools": ct.__version__, "torch": torch.__version__},
    }
    (MODELS_DIR / "model_metadata.json").write_text(json.dumps(meta, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", choices=["text", "flow", "mimi", "all"], default="all")
    args = parser.parse_args()
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    model = TTSModel.load_model(language="english", temp=0.75).cpu().eval()
    errors: list[str] = []
    steps = [args.only] if args.only != "all" else ["text", "flow", "mimi"]
    for step in steps:
        try:
            {"text": convert_text, "flow": convert_flow, "mimi": convert_mimi}[step](model)
        except Exception as exc:  # noqa: BLE001
            log.exception("%s conversion failed", step)
            errors.append(f"{step}: {type(exc).__name__}: {exc}")
    write_metadata(model)
    status = {"ok": not errors, "errors": errors}
    (ROOT / "conversion_logs" / "conversion_status.json").write_text(json.dumps(status, indent=2) + "\n")
    if errors:
        log.error("Conversion incomplete: %s", errors)
        return 1
    log.info("CoreML conversion complete: %s", MODELS_DIR)
    return 0


if __name__ == "__main__":
    sys.exit(main())
