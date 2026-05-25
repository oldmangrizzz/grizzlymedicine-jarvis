#!/usr/bin/env python3
"""
Embed the JARVIS voice state safetensors as a precomputed KV-cache bundle.

Reads:
    /Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors

Writes (in --out-dir):
    voice_state.bin      — flat float32 binary (all KV caches, layer-major order)
    voice_state.json     — shape/metadata for the Swift loader
    voice_state_check.npy — first-layer cache as numpy (for verification)

This is a build-time tool only. The Swift runtime loads voice_state.bin
directly with the layout described in voice_state.json.

Usage:
    /Users/rbhanson/research/oracle_venv/bin/python3 \
        tools/embed_voice_state.py \
        --out-dir voice/tts/coreml/models/
"""
from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from pathlib import Path

import numpy as np
import torch
from safetensors import safe_open

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger(__name__)

VOICE_STATE_PATH = Path(
    "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors"
)


def load_voice_state(path: Path) -> dict[str, torch.Tensor]:
    tensors: dict[str, torch.Tensor] = {}
    with safe_open(str(path), framework="pt", device="cpu") as f:
        for key in f.keys():
            tensors[key] = f.get_tensor(key)
    return tensors


def embed_voice_state(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    tensors = load_voice_state(VOICE_STATE_PATH)

    # Determine num_layers from keys
    import re
    layer_nums = sorted(
        {int(m.group(1)) for k in tensors if (m := re.search(r"layers\.(\d+)", k))}
    )
    num_layers = len(layer_nums)
    log.info(f"Voice state: {num_layers} layers, keys={list(tensors.keys())[:4]}…")

    # Build ordered list: layer 0 cache, layer 0 offset, layer 1 cache, ...
    cache_tensors = []
    offsets = []
    layer_meta = []

    for l_idx in layer_nums:
        cache_key = f"transformer.layers.{l_idx}.self_attn/cache"
        offset_key = f"transformer.layers.{l_idx}.self_attn/offset"

        cache = tensors[cache_key]  # [2, 1, seq, heads, head_dim]
        offset = tensors[offset_key]  # [1]

        cache_arr = cache.to(torch.float32).numpy()
        offset_val = int(offset.item())

        cache_tensors.append(cache_arr)
        offsets.append(offset_val)
        layer_meta.append(
            {
                "layer": l_idx,
                "cache_shape": list(cache_arr.shape),
                "offset": offset_val,
            }
        )
        log.info(f"  Layer {l_idx}: cache shape {cache_arr.shape}, offset {offset_val}")

    # Write binary: concatenate all cache tensors in layer-major order
    bin_path = out_dir / "voice_state.bin"
    with open(bin_path, "wb") as f:
        for arr in cache_tensors:
            f.write(arr.astype(np.float32).tobytes())
    log.info(f"Wrote binary: {bin_path} ({bin_path.stat().st_size:,} bytes)")

    # Write metadata JSON
    meta = {
        "source": str(VOICE_STATE_PATH),
        "num_layers": int(num_layers),
        "layers": layer_meta,
        "binary_layout": "layer-major float32 little-endian",
        "total_floats": int(sum(np.prod(a.shape) for a in cache_tensors)),
        "offsets": [int(o) for o in offsets],
    }
    json_path = out_dir / "voice_state.json"
    json_path.write_text(json.dumps(meta, indent=2))
    log.info(f"Wrote metadata: {json_path}")

    # Write verification numpy for first layer
    check_path = out_dir / "voice_state_check.npy"
    np.save(str(check_path), cache_tensors[0])
    log.info(f"Wrote verification: {check_path}")

    # Sanity check: reload and verify
    total_floats = meta["total_floats"]
    reloaded = np.frombuffer(bin_path.read_bytes(), dtype=np.float32)
    assert len(reloaded) == total_floats, (
        f"Binary size mismatch: got {len(reloaded)}, expected {total_floats}"
    )
    log.info(f"Verification OK: {total_floats:,} floats round-tripped correctly")

    # Cross-check first layer
    first_layer_size = int(np.prod(layer_meta[0]["cache_shape"]))
    np.testing.assert_allclose(
        reloaded[:first_layer_size].reshape(layer_meta[0]["cache_shape"]),
        cache_tensors[0],
        rtol=0,
        atol=0,
        err_msg="First layer cache did not round-trip bit-exactly",
    )
    log.info("First-layer bit-exact check: PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out-dir",
        default=str(Path(__file__).parent.parent / "models"),
        help="Output directory for embedded voice state files",
    )
    args = parser.parse_args()
    embed_voice_state(Path(args.out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
