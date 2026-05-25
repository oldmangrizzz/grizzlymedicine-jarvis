#!/usr/bin/env python3
"""convert_to_coreml.py — Convert a trained TorchScript model to CoreML .mlpackage.

Run AFTER train_classifier.py has produced audio_scene_classifier.pt.
Output: audio_scene_classifier.mlpackage — load this in model_runtime.mm.

Usage:
    python3 convert_to_coreml.py \\
        --model-pt    /path/to/artifacts/audio_scene_classifier.pt \\
        --meta-json   /path/to/artifacts/model_meta.json \\
        --output-dir  /path/to/artifacts

Requirements:
    pip install coremltools torch

Compute units:
    MLComputeUnitsAll — allows the converter to target ANE.
    For ≤ 20 ms inference on Apple Silicon, the model must be:
      - Float16 precision (--half flag)
      - Small enough to reside in ANE cache

Notes on the CoreML interface expected by model_runtime.mm:
    Input  feature name: "logmel"   shape: (1, 1, n_frames, n_mels)  dtype: float32
    Output feature name: "scores"   shape: (1, n_classes)            dtype: float32
    The output is raw logits; model_runtime.mm reads them directly.
    Apply softmax in the classifier layer of the PyTorch model before tracing
    if you want probabilities — OR apply it in model_runtime.mm after inference.
    Current model_runtime.mm reads raw values and picks argmax; the training
    script uses CrossEntropyLoss (logits), so no final softmax is baked in.
    This is intentional: CoreML's softmax op is fast on ANE.

To add a softmax to the CoreML model:
    Use ct.PassPipeline.DEFAULT with a softmax node added via ct.optimize.coreml,
    or simply add nn.Softmax(dim=1) as the last layer before tracing.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys


def _check_deps() -> None:
    missing = []
    for pkg in ("torch", "coremltools"):
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"[convert] Missing packages: {', '.join(missing)}")
        print("Install: pip install torch coremltools")
        sys.exit(1)


_check_deps()

import torch                # noqa: E402
import coremltools as ct    # noqa: E402


def convert(args: argparse.Namespace) -> None:
    meta_path = pathlib.Path(args.meta_json)
    pt_path   = pathlib.Path(args.model_pt)
    out_dir   = pathlib.Path(args.output_dir)

    if not pt_path.exists():
        print(f"[convert] TorchScript file not found: {pt_path}")
        sys.exit(1)
    if not meta_path.exists():
        print(f"[convert] Metadata file not found: {meta_path}")
        sys.exit(1)

    meta = json.loads(meta_path.read_text())
    n_frames = meta["n_frames"]
    n_mels   = meta["n_mels"]
    classes  = meta["classes"]

    print(f"[convert] Loading TorchScript: {pt_path}")
    model = torch.jit.load(str(pt_path), map_location="cpu")
    model.eval()

    # Example input must match the shape expected by model_runtime.mm:
    # [batch=1, channel=1, n_frames, n_mels]
    example_input = torch.zeros(1, 1, n_frames, n_mels, dtype=torch.float32)

    print(f"[convert] Tracing with input shape {list(example_input.shape)}")

    # CoreML conversion
    mlmodel = ct.convert(
        model,
        inputs=[ct.TensorType(
            name  = "logmel",
            shape = ct.Shape(shape=(1, 1, n_frames, n_mels)),
            dtype = ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32,
        )],
        outputs=[ct.TensorType(
            name  = "scores",
            dtype = ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32,
        )],
        compute_precision=(
            ct.precision.FLOAT16 if args.half else ct.precision.FLOAT32
        ),
        compute_units=ct.ComputeUnit.ALL,   # target ANE
        convert_to="mlprogram",             # .mlpackage (newer format, ANE-optimized)
        minimum_deployment_target=ct.target.macOS13,
    )

    # Attach metadata
    mlmodel.short_description = "JARVIS Raw Audio Scene Classifier"
    mlmodel.author            = "GMRI / Robert Hanson"
    mlmodel.license           = "Proprietary"
    mlmodel.version           = "1.0"

    # Class labels for debugging (not used by model_runtime.mm at runtime)
    mlmodel.user_defined_metadata["classes"]         = ",".join(classes)
    mlmodel.user_defined_metadata["sample_rate"]     = str(meta["sample_rate"])
    mlmodel.user_defined_metadata["n_mels"]          = str(n_mels)
    mlmodel.user_defined_metadata["n_frames"]        = str(n_frames)
    mlmodel.user_defined_metadata["best_val_acc"]    = str(meta.get("best_val_accuracy", "unknown"))

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "audio_scene_classifier.mlpackage"
    mlmodel.save(str(out_path))

    size_mb = sum(f.stat().st_size for f in out_path.rglob("*") if f.is_file()) / (1024 * 1024)
    print(f"[convert] Saved: {out_path}")
    print(f"[convert] Model size: {size_mb:.2f} MB")
    print(f"[convert] Classes: {classes}")
    print(f"[convert] Precision: {'float16' if args.half else 'float32'}")
    print(f"[convert] Compute units: ALL (ANE + GPU + CPU)")
    print()
    print("Next step:")
    print(f"  RawAudioSceneClassifier clf(\"{out_path}\");")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--model-pt",   required=True)
    parser.add_argument("--meta-json",  required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--half", action="store_true", default=True,
                        help="Convert to float16 for ANE (default: on)")
    parser.add_argument("--no-half", dest="half", action="store_false")
    args = parser.parse_args()
    convert(args)


if __name__ == "__main__":
    main()
