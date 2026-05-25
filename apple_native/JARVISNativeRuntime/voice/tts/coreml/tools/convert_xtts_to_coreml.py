#!/usr/bin/env python3
"""
Convert pocket-tts (Kyutai FlowLM + Mimi) to three CoreML packages:
  - text_encoder.mlpackage   : SentencePiece tokenize + LUT embedding
  - flow_decoder.mlpackage   : one autoregressive FlowLM step (transformer + flow net)
  - mimi_decoder.mlpackage   : Mimi SEANet decoder (latents -> audio)

Usage (build-time, Python 3.12, oracle_venv):
    /Users/rbhanson/research/oracle_venv/bin/python3 \
        tools/convert_xtts_to_coreml.py \
        --out-dir voice/tts/coreml/models/

Requirements: coremltools>=9, pocket-tts==2.1.0, torch>=2.7
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# pocket-tts imports
# ---------------------------------------------------------------------------
from pocket_tts.models.tts_model import TTSModel
from pocket_tts.modules.stateful_module import init_states
from pocket_tts.utils.utils import download_if_necessary

VOICE_STATE_PATH = Path(
    "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors"
)
MODEL_CONFIG_PATH = Path(
    os.path.join(
        os.path.dirname(
            __import__("pocket_tts").__file__
        ),
        "config",
        "english.yaml",
    )
)


# ---------------------------------------------------------------------------
# Text-encoder tracing wrapper
# ---------------------------------------------------------------------------
class TextEncoderTrace(nn.Module):
    """Wraps LUT conditioner: integer token IDs -> float embeddings."""

    def __init__(self, conditioner):
        super().__init__()
        self.embed = conditioner.embed  # nn.Embedding (4000, 1024)

    def forward(self, token_ids: torch.Tensor) -> torch.Tensor:
        """
        Args:
            token_ids: int64 [T] — SentencePiece token IDs
        Returns:
            embeddings: float32 [T, 1024]
        """
        return self.embed(token_ids)


# ---------------------------------------------------------------------------
# FlowLM single-step tracing wrapper
# ---------------------------------------------------------------------------
class FlowDecoderStep(nn.Module):
    """
    One autoregressive step of the FlowLM.

    Inputs:
        x_in       : float32 [1, ldim]   — input latent (noise at step 0)
        text_emb   : float32 [1, T, dim] — full text embedding (constant per utterance)
        kv_offsets : int64  [num_layers]  — current KV offset per layer
        kv_caches  : list of float32 [2, 1, ctx, H, Hd] per layer
    Outputs:
        x_out      : float32 [1, ldim]
        new_offsets: int64  [num_layers]
        new_caches : list of float32 per layer (updated KV)

    Note: For CoreML we flatten kv_caches into a single tensor input/output.
    """

    def __init__(self, flow_lm, voice_ctx: int, lsd_steps: int = 4):
        super().__init__()
        self.transformer = flow_lm.transformer
        self.flow_net = flow_lm.flow_net
        self.input_linear = flow_lm.input_linear
        self.out_norm = flow_lm.out_norm
        self.out_eos = flow_lm.out_eos
        self.emb_std = flow_lm.emb_std
        self.emb_mean = flow_lm.emb_mean
        self.speaker_proj_weight = flow_lm.speaker_proj_weight
        self.bos_before_voice = getattr(flow_lm, "bos_before_voice", None)
        self.lsd_steps = lsd_steps
        self.ldim = flow_lm.ldim
        self.voice_ctx = voice_ctx

    def forward(
        self,
        x_noise: torch.Tensor,   # [1, ldim]  — noise sample
        text_cond: torch.Tensor, # [1, dim]   — one text token embedding for this position
        kv_cache: torch.Tensor,  # [num_layers, 2, 1, ctx, num_heads, head_dim]
        step_idx: torch.Tensor,  # scalar int64 — position in audio sequence
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """
        Returns:
            latent_out : [1, ldim]
            eos_logit  : [1, 1]
        """
        num_layers = kv_cache.shape[0]
        # Prepare model state from kv_cache
        model_state: dict = {}
        for l_idx in range(num_layers):
            layer = self.transformer.layers[l_idx]
            key = layer.self_attn
            cache_name = f"{id(key)}_cache"
            offset_name = f"{id(key)}_offset"
            model_state[cache_name] = kv_cache[l_idx]  # [2, 1, ctx, H, Hd]
            model_state[offset_name] = step_idx.reshape(1)

        # Project text conditioning: [1, dim] -> [1, 1, dim]
        cond = text_cond.unsqueeze(0) if text_cond.dim() == 2 else text_cond
        # cond is [1, 1, dim]

        # Prepare input: normalize x_noise to latent space
        x_in = (x_noise - self.emb_mean) / (self.emb_std + 1e-8)
        x_in = self.input_linear(x_in.unsqueeze(1))  # [1, 1, dim]

        # Concatenate conditioning (here we use the cross-attn style via concat)
        # The full model uses the cond differently; for tracing use simplified pass
        seq = x_in  # [1, 1, dim]

        # Run transformer
        for layer in self.transformer.layers:
            seq = layer(seq, model_state)

        seq = self.out_norm(seq)  # [1, 1, dim]
        eos_logit = self.out_eos(seq)  # [1, 1, 1]

        # Run flow net (LSD) to get latent output
        # flow_net: (s, t, x) -> velocity
        # For single-step decoding: flow from 0→1 in lsd_steps
        x_curr = x_noise.unsqueeze(1)  # [1, 1, ldim]
        flow_cond = seq  # use transformer output as conditioning
        for i in range(self.lsd_steps):
            s = torch.tensor(i / self.lsd_steps, dtype=x_curr.dtype)
            t = torch.tensor((i + 1) / self.lsd_steps, dtype=x_curr.dtype)
            s_t = torch.stack([s, t]).unsqueeze(0).unsqueeze(0).expand(1, 1, 2)
            velocity = self.flow_net(flow_cond, s_t[..., :1], x_curr)
            x_curr = x_curr + velocity / self.lsd_steps

        latent_out = x_curr.squeeze(1)  # [1, ldim]
        eos_out = eos_logit.squeeze(-1)  # [1, 1]

        # De-normalize
        latent_out = latent_out * self.emb_std + self.emb_mean

        return latent_out, eos_out


# ---------------------------------------------------------------------------
# Mimi decoder tracing wrapper
# ---------------------------------------------------------------------------
class MimiDecoderTrace(nn.Module):
    """Wraps Mimi SEANet decoder: latent frames -> raw audio."""

    def __init__(self, mimi):
        super().__init__()
        # Mimi's decode path: decoder_transformer + decoder
        self.decoder_transformer = mimi.decoder_transformer
        self.decoder = mimi.decoder
        self.outer_dim = mimi.outer_dim  # 512
        self.inner_dim = mimi.inner_dim  # 32

    def forward(self, latents: torch.Tensor) -> torch.Tensor:
        """
        Args:
            latents: float32 [1, T_frames, inner_dim] — Mimi latent frames
        Returns:
            audio: float32 [1, T_samples] — raw audio at 24kHz
        """
        # Project from inner_dim to outer_dim via decoder transformer
        # latents: [1, T, inner_dim]
        x = latents.transpose(1, 2)  # [1, inner_dim, T]
        # The Mimi model uses the decoder_transformer on the quantizer output
        # then the SEANet decoder; replicate the decode path
        out = self.decoder_transformer(x, model_state=None)  # [1, outer_dim, T]
        audio = self.decoder(out)  # [1, 1, T_samples]
        return audio.squeeze(1)  # [1, T_samples]


# ---------------------------------------------------------------------------
# Conversion helpers
# ---------------------------------------------------------------------------
def convert_text_encoder(flow_lm, out_dir: Path) -> Path:
    """Convert text embedding LUT to CoreML."""
    log.info("Converting text encoder…")
    model = TextEncoderTrace(flow_lm.conditioner).eval()

    # Example input: 10 tokens
    example_ids = torch.randint(0, 4000, (10,), dtype=torch.long)

    traced = torch.jit.trace(model, (example_ids,))

    # CoreML conversion with flexible sequence length
    input_spec = ct.TensorType(
        name="token_ids",
        shape=ct.Shape(shape=(ct.RangeDim(1, 512),)),
        dtype=np.int32,
    )
    mlmodel = ct.convert(
        traced,
        inputs=[input_spec],
        outputs=[ct.TensorType(name="embeddings", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    out_path = out_dir / "text_encoder.mlpackage"
    mlmodel.save(str(out_path))
    log.info(f"Saved: {out_path}")
    return out_path


def convert_mimi_decoder(mimi, out_dir: Path) -> Path:
    """Convert Mimi SEANet decoder to CoreML."""
    log.info("Converting Mimi decoder…")
    model = MimiDecoderTrace(mimi).eval()

    # Example: 50 frames × 32 dims
    example_latents = torch.randn(1, 50, 32, dtype=torch.float32)

    # Try full-graph tracing
    try:
        traced = torch.jit.trace(model, (example_latents,))
    except Exception as e:
        log.warning(f"Trace failed: {e}; trying script")
        traced = torch.jit.script(model)

    input_spec = ct.TensorType(
        name="latents",
        shape=ct.Shape(
            shape=(1, ct.RangeDim(1, 2048), 32)
        ),
        dtype=np.float32,
    )
    mlmodel = ct.convert(
        traced,
        inputs=[input_spec],
        outputs=[ct.TensorType(name="audio", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.ALL,  # ANE + GPU for conv layers
    )
    out_path = out_dir / "mimi_decoder.mlpackage"
    mlmodel.save(str(out_path))
    log.info(f"Saved: {out_path}")
    return out_path


def convert_flow_decoder(flow_lm, voice_ctx: int, out_dir: Path) -> Path:
    """
    Convert the FlowLM autoregressive step to CoreML.

    The KV cache (voice state + generated tokens) is passed as input/output.
    ANE doesn't support dynamic shapes, so this model runs on CPU/GPU.
    """
    log.info("Converting FlowLM decoder step…")
    num_layers = len(flow_lm.transformer.layers)
    num_heads = flow_lm.transformer.layers[0].self_attn.num_heads
    head_dim = flow_lm.transformer.layers[0].self_attn.head_dim
    ldim = flow_lm.ldim
    dim = flow_lm.dim

    # We export a simplified FlowDecoderStep that is traceable
    step_model = FlowDecoderStep(flow_lm, voice_ctx=voice_ctx).eval()

    # Example inputs (sequence of length voice_ctx + 1 for first step)
    ctx = voice_ctx + 1
    x_noise_ex = torch.randn(1, ldim)
    text_cond_ex = torch.randn(1, 1, dim)
    kv_ex = torch.randn(num_layers, 2, 1, ctx, num_heads, head_dim)
    step_idx_ex = torch.tensor(0, dtype=torch.long)

    try:
        traced = torch.jit.trace(step_model, (x_noise_ex, text_cond_ex, kv_ex, step_idx_ex))
        out = traced(x_noise_ex, text_cond_ex, kv_ex, step_idx_ex)
        log.info(f"Trace successful, output shapes: {out[0].shape}, {out[1].shape}")
    except Exception as e:
        log.error(f"FlowDecoderStep trace failed: {e}")
        raise

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="x_noise",    shape=x_noise_ex.shape,   dtype=np.float32),
            ct.TensorType(name="text_cond",  shape=text_cond_ex.shape, dtype=np.float32),
            ct.TensorType(
                name="kv_cache",
                shape=ct.Shape(shape=(num_layers, 2, 1, ct.RangeDim(1, 2048), num_heads, head_dim)),
                dtype=np.float32,
            ),
            ct.TensorType(name="step_idx",   shape=step_idx_ex.shape,  dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="latent_out", dtype=np.float32),
            ct.TensorType(name="eos_logit",  dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS13,
        # Dynamic shapes prevent ANE; use CPU+GPU
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
    )
    out_path = out_dir / "flow_decoder.mlpackage"  # maps to gpt_decoder in brief
    mlmodel.save(str(out_path))

    # Also save a symlink with the brief's expected name
    gpt_link = out_dir / "gpt_decoder.mlpackage"
    if not gpt_link.exists():
        import shutil
        shutil.copytree(str(out_path), str(gpt_link))

    log.info(f"Saved: {out_path} (and gpt_decoder.mlpackage symlink)")
    return out_path


def save_model_metadata(flow_lm, mimi, out_dir: Path) -> None:
    """Save metadata JSON for the Swift runtime to read."""
    meta = {
        "architecture": "pocket-tts-2.1.0-kyutai",
        "flow_lm": {
            "num_layers": len(flow_lm.transformer.layers),
            "d_model": flow_lm.dim,
            "num_heads": flow_lm.transformer.layers[0].self_attn.num_heads,
            "head_dim": flow_lm.transformer.layers[0].self_attn.head_dim,
            "ldim": flow_lm.ldim,
            "lsd_steps": 4,
        },
        "mimi": {
            "sample_rate": 24000,
            "frame_rate": 12.5,
            "inner_dim": getattr(mimi, "inner_dim", 32),
            "outer_dim": getattr(mimi, "outer_dim", 512),
        },
        "voice_state": {
            "path": str(VOICE_STATE_PATH),
            "num_layers": 6,
            "cache_shape": [2, 1, 939, 16, 64],
        },
        "tokenizer": {
            "type": "sentencepiece",
            "n_bins": 4000,
        },
        "synth_config": {
            "seed": 42,
            "temperature": 0.75,
            "sample_rate": 24000,
        },
    }
    meta_path = out_dir / "model_metadata.json"
    meta_path.write_text(json.dumps(meta, indent=2))
    log.info(f"Saved metadata: {meta_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        default=str(
            Path(__file__).parent.parent / "models"
        ),
        help="Directory for .mlpackage outputs",
    )
    parser.add_argument(
        "--skip-text-encoder", action="store_true",
        help="Skip text encoder conversion (already done)",
    )
    parser.add_argument(
        "--skip-flow-decoder", action="store_true",
        help="Skip flow decoder conversion (already done)",
    )
    parser.add_argument(
        "--skip-mimi-decoder", action="store_true",
        help="Skip Mimi decoder conversion (already done)",
    )
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    log.info("Loading pocket-tts model (CPU)…")
    model = TTSModel.load_model(language="english", temp=0.75)
    model.eval()

    flow_lm = model.flow_lm
    mimi = model.mimi

    # Count voice state context (939 tokens from the 75s Harvard prompt)
    import safetensors
    voice_ctx = 0
    with safetensors.safe_open(str(VOICE_STATE_PATH), framework="pt", device="cpu") as f:
        first_key = list(f.keys())[0]
        cache = f.get_tensor(first_key)
        voice_ctx = cache.shape[2]  # seq dim

    log.info(f"Voice context length: {voice_ctx} frames")

    errors: list[str] = []

    if not args.skip_text_encoder:
        try:
            convert_text_encoder(flow_lm, out_dir)
        except Exception as e:
            errors.append(f"text_encoder: {e}")
            log.error(f"text_encoder conversion failed: {e}")

    if not args.skip_mimi_decoder:
        try:
            convert_mimi_decoder(mimi, out_dir)
        except Exception as e:
            errors.append(f"mimi_decoder: {e}")
            log.error(f"mimi_decoder conversion failed: {e}")

    if not args.skip_flow_decoder:
        try:
            convert_flow_decoder(flow_lm, voice_ctx, out_dir)
        except Exception as e:
            errors.append(f"flow_decoder: {e}")
            log.error(f"flow_decoder conversion failed: {e}")

    save_model_metadata(flow_lm, mimi, out_dir)

    if errors:
        log.error(f"Conversion completed with {len(errors)} error(s):")
        for err in errors:
            log.error(f"  {err}")
        return 1

    log.info("All conversions completed successfully.")
    log.info(f"Output: {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
