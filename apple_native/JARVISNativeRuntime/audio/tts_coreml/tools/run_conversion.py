#!/usr/bin/env python3
"""
Focused CoreML conversion runner.
Converts pocket-tts components to CoreML packages.
"""
import os, sys, json, logging, torch, numpy as np
from pathlib import Path
import coremltools as ct

logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
log = logging.getLogger(__name__)

COREML_DIR = Path(__file__).parent.parent
MODELS_DIR = COREML_DIR / "models"
MODELS_DIR.mkdir(exist_ok=True)


def load_model():
    from pocket_tts import TTSModel
    log.info("Loading pocket-tts model...")
    model = TTSModel.load_model(language='english', temp=0.75)
    model.eval()
    return model


def convert_text_encoder(flow_lm):
    log.info("=== Converting text_encoder ===")
    embed = flow_lm.conditioner.embed
    vocab_size = embed.num_embeddings
    embed_dim  = embed.embedding_dim
    log.info(f"  Embedding: vocab={vocab_size}, dim={embed_dim}")

    class TextEnc(torch.nn.Module):
        def __init__(self, embed):
            super().__init__()
            self.embed = embed
        def forward(self, ids):
            return self.embed(ids)

    model = TextEnc(embed).eval()
    example = torch.randint(0, vocab_size, (8,), dtype=torch.long)
    traced = torch.jit.trace(model, (example,))
    out = traced(example)
    log.info(f"  Traced output: {out.shape}")

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="token_ids",
                              shape=ct.Shape(shape=(ct.RangeDim(1, 512),)),
                              dtype=np.int32)],
        outputs=[ct.TensorType(name="embeddings", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    out_path = MODELS_DIR / "text_encoder.mlpackage"
    mlmodel.save(str(out_path))
    log.info(f"  Saved: {out_path}")
    return True


def _patch_convtr_stateless(mimi):
    """
    StreamingConvTranspose1d.forward() has a beartype-enforced `mimi_state: dict`
    parameter that rejects None.  For offline batch inference the streaming state
    starts at zeros and we want a single-shot decode, so we monkey-patch each
    StreamingConvTranspose1d with a stateless equivalent that builds its own
    zero-initialised state internally.  Mathematically equivalent to:
      y = convtr(x); PT = K - S; y = y[..., :-PT] if PT else y
    """
    from pocket_tts.modules.conv import StreamingConvTranspose1d

    def _stateless_forward(self, x, mimi_state=None):
        y = self.convtr(x)
        PT = self._kernel_size - self._stride      # same as layer_state.shape[-1]
        if PT > 0:
            # partial starts at 0, so only the trim matters
            y = y[..., :-PT]
        return y

    for name, mod in mimi.named_modules():
        if isinstance(mod, StreamingConvTranspose1d):
            import types
            mod.forward = types.MethodType(_stateless_forward, mod)
            log.info(f"  Patched {name} (StreamingConvTranspose1d → stateless)")


def convert_mimi_decoder(mimi):
    log.info("=== Converting mimi_decoder ===")
    _patch_convtr_stateless(mimi)

    class MimiDecoderBatch(torch.nn.Module):
        def __init__(self, mimi):
            super().__init__()
            self.quantizer_proj = mimi.quantizer.output_proj
            self.upsample = mimi.upsample
            self.decoder_transformer = mimi.decoder_transformer
            self.decoder = mimi.decoder

        def forward(self, latents: torch.Tensor) -> torch.Tensor:
            x = self.quantizer_proj(latents)
            # upsample.convtr is now patched; ConvTrUpsample1d.forward just calls self.convtr(x, ...)
            # We call the patched convtr directly via the upsample module's own forward
            x = self.upsample.convtr(x)   # patched → stateless
            PT = self.upsample.convtr._kernel_size - self.upsample.convtr._stride
            if PT > 0:
                x = x[..., :-PT]
            # decoder_transformer: StreamingMultiheadAttention supports model_state=None
            (x,) = self.decoder_transformer(x, model_state=None)
            # decoder: StreamingConv1d supports model_state=None;
            #           StreamingConvTranspose1d is patched to stateless
            x = self.decoder(x, model_state=None)
            return x

    model = MimiDecoderBatch(mimi).eval()
    N = 50
    ex_latents = torch.randn(1, 32, N)
    with torch.no_grad():
        out = model(ex_latents)
    log.info(f"  Forward test: {ex_latents.shape} -> {out.shape}")

    traced = torch.jit.trace(model, (ex_latents,))
    traced_out = traced(ex_latents)
    log.info(f"  Trace OK: {traced_out.shape}")

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="latents",
                              shape=ct.Shape(shape=(1, 32, ct.RangeDim(1, 2048))),
                              dtype=np.float32)],
        outputs=[ct.TensorType(name="audio", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.ALL,
    )
    out_path = MODELS_DIR / "mimi_decoder.mlpackage"
    mlmodel.save(str(out_path))
    log.info(f"  Saved: {out_path}")
    return True


def convert_flow_decoder(flow_lm, voice_ctx: int):
    log.info("=== Converting flow_decoder (batch mode) ===")
    from functools import partial

    num_layers = len(flow_lm.transformer.layers)
    first_attn = flow_lm.transformer.layers[0].self_attn
    num_heads = int(first_attn.num_heads)
    head_dim  = int(getattr(first_attn, "head_dim", getattr(first_attn, "dim_per_head")))
    ldim = flow_lm.ldim
    dim  = flow_lm.dim
    log.info(f"  FlowLM: {num_layers}L, d={dim}, h={num_heads}, hd={head_dim}, ldim={ldim}")

    N_STEPS_TRACE = 30

    class FlowDecoderBatch(torch.nn.Module):
        def __init__(self, flow_lm, n_steps: int):
            super().__init__()
            self.flow_net      = flow_lm.flow_net
            self.input_linear  = flow_lm.input_linear
            self.transformer   = flow_lm.transformer
            self.out_norm      = flow_lm.out_norm
            self.out_eos       = flow_lm.out_eos
            self.emb_std       = flow_lm.emb_std
            self.emb_mean      = flow_lm.emb_mean
            self.bos_emb       = flow_lm.bos_emb
            self.ldim          = flow_lm.ldim
            self.n_steps       = n_steps

        def _lsd_step(self, cond: torch.Tensor, noise: torch.Tensor) -> torch.Tensor:
            curr = noise
            for i in range(4):
                s = i / 4.0
                t = (i + 1) / 4.0
                s_t = torch.tensor([[s, t]], dtype=cond.dtype, device=cond.device)
                vel = self.flow_net(cond, s_t[:, :1], curr)
                curr = curr + vel / 4.0
            return curr

        def forward(self, text_emb_prefix: torch.Tensor,
                    noise_seq: torch.Tensor) -> tuple:
            n_steps = self.n_steps
            ldim = self.ldim
            prev = self.bos_emb.unsqueeze(0).unsqueeze(0).expand(1, 1, ldim)
            latents = []
            eos_out = []
            for step in range(n_steps):
                x = self.input_linear(prev)
                seq = torch.cat([text_emb_prefix, x], dim=1)
                t_out = self.transformer(seq, model_state=None)
                if self.out_norm is not None:
                    t_out = self.out_norm(t_out)
                last = t_out[:, -1]
                eos  = self.out_eos(last)
                noise_i = noise_seq[step].unsqueeze(0)
                new_lat = self._lsd_step(last, noise_i)
                new_lat = new_lat * self.emb_std + self.emb_mean
                latents.append(new_lat)
                eos_out.append(eos)
                prev = torch.cat([prev, new_lat.unsqueeze(1)], dim=1)
            out_latents = torch.cat(latents, dim=0)
            out_eos     = torch.cat(eos_out, dim=0)
            return out_latents, out_eos

    model = FlowDecoderBatch(flow_lm, n_steps=N_STEPS_TRACE).eval()
    T_total = voice_ctx + 5
    ex_text  = torch.randn(1, T_total, dim)
    ex_noise = torch.randn(N_STEPS_TRACE, ldim)
    with torch.no_grad():
        out_lats, out_eos = model(ex_text, ex_noise)
    log.info(f"  Forward test: latents={out_lats.shape}, eos={out_eos.shape}")

    traced = torch.jit.trace(model, (ex_text, ex_noise))
    tr_lats, tr_eos = traced(ex_text, ex_noise)
    diff = (tr_lats - out_lats).abs().max().item()
    log.info(f"  Trace OK: max_diff={diff:.2e}")

    T_min = voice_ctx + 1
    T_max = voice_ctx + 512
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="text_emb_prefix",
                          shape=ct.Shape(shape=(1, ct.RangeDim(T_min, T_max), dim)),
                          dtype=np.float32),
            ct.TensorType(name="noise_seq",
                          shape=(N_STEPS_TRACE, ldim),
                          dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="latents", dtype=np.float32),
            ct.TensorType(name="eos",     dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
    )
    out_path = MODELS_DIR / "flow_decoder.mlpackage"
    mlmodel.save(str(out_path))
    import shutil
    gpt_path = MODELS_DIR / "gpt_decoder.mlpackage"
    if not gpt_path.exists():
        shutil.copytree(str(out_path), str(gpt_path))
    log.info(f"  Saved: {out_path}")
    return True


def save_metadata(flow_lm, mimi, voice_ctx):
    meta = {
        "architecture": "pocket-tts-2.1.0-kyutai",
        "flow_lm": {
            "num_layers": len(flow_lm.transformer.layers),
            "d_model": int(flow_lm.dim),
            "num_heads": int(flow_lm.transformer.layers[0].self_attn.embed_dim //
                            flow_lm.transformer.layers[0].self_attn.num_heads),
            "head_dim": int(flow_lm.dim // flow_lm.transformer.layers[0].self_attn.num_heads),
            "ldim": int(flow_lm.ldim),
            "lsd_steps": 4,
            "vocab_size": int(flow_lm.conditioner.embed.num_embeddings),
        },
        "mimi": {
            "sample_rate": 24000,
            "frame_rate": 12.5,
            "inner_dim": 32,
            "outer_dim": 512,
            "upsample_stride": 16,
        },
        "voice_state": {
            "path": "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors",
            "num_layers": 6,
            "seq_len": int(voice_ctx),
        },
        "tokenizer": {
            "type": "sentencepiece",
            "path": str(Path("~/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots/d29db7978e464fb90cb3359ee0c69a273b9142cc/languages/english/tokenizer.model").expanduser()),
            "n_bins": 4000,
        },
        "synth_config": {"seed": 42, "temperature": 0.75, "sample_rate": 24000},
    }
    path = MODELS_DIR / "model_metadata.json"
    path.write_text(json.dumps(meta, indent=2))
    log.info(f"Saved metadata: {path}")


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--only", choices=["text", "mimi", "flow", "all"], default="all")
    args = p.parse_args()

    model = load_model()
    flow_lm = model.flow_lm
    mimi = model.mimi
    voice_ctx = 939

    errors = []
    if args.only in ("text", "all"):
        try:
            convert_text_encoder(flow_lm)
        except Exception as e:
            errors.append(f"text_encoder: {e}")
            log.error(f"text_encoder FAILED: {e}", exc_info=True)

    if args.only in ("mimi", "all"):
        try:
            convert_mimi_decoder(mimi)
        except Exception as e:
            errors.append(f"mimi_decoder: {e}")
            log.error(f"mimi_decoder FAILED: {e}", exc_info=True)

    if args.only in ("flow", "all"):
        try:
            convert_flow_decoder(flow_lm, voice_ctx)
        except Exception as e:
            errors.append(f"flow_decoder: {e}")
            log.error(f"flow_decoder FAILED: {e}", exc_info=True)

    save_metadata(flow_lm, mimi, voice_ctx)

    if errors:
        log.error(f"Errors ({len(errors)}): {errors}")
        sys.exit(1)
    log.info("All conversions complete!")
