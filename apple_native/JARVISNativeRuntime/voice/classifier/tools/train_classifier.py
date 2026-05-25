#!/usr/bin/env python3
"""train_classifier.py — Build-time training tool for the JARVIS audio scene classifier.

Trains a compact CNN (MobileNetV3-small adapted for log-mel input) on a labeled
dataset of speech / music / noise / silence audio.  Output: a TorchScript
checkpoint + class labels JSON consumed by convert_to_coreml.py.

This script runs at BUILD TIME only.  It MUST NOT be bundled with the runtime.
Runtime inference is C++ / CoreML — zero Python.

Usage:
    python3 train_classifier.py \\
        --data-dir   /path/to/dataset \\
        --output-dir /path/to/model_artifacts \\
        --epochs     30 \\
        --batch-size 64

Dataset directory layout expected:
    <data-dir>/
        speech_directed/   *.wav or *.flac — speech clips (16 kHz mono preferred)
        speech_ambient/    *.wav or *.flac
        music/             *.wav or *.flac
        noise/             *.wav or *.flac
        silence/           *.wav or *.flac   (or generate synthetically)

Recommended datasets (by license):
    speech_directed / speech_ambient:
        - Mozilla CommonVoice (CC0) — https://commonvoice.mozilla.org
        - LibriSpeech test-clean subset (CC BY 4.0) — https://www.openslr.org/12
    music:
        - Free Music Archive "Small" subset CC-BY — https://github.com/mdeff/fma
          (fma_small.zip, CC-BY licensed tracks only)
        - Synthetic harmonics from generate_test_fixtures.py (no license needed)
    noise:
        - MUSAN noise subset (CC BY 4.0) — https://www.openslr.org/17
          Use the "noise" and "music" splits (note: MUSAN music = mostly public domain)
        - ESC-50 (CC BY-NC 3.0) — suitable for research; do NOT ship in commercial product
          https://github.com/karolpiczak/ESC-50
    silence:
        Generated synthetically (zero-fill or 1-LSB dither).

See README.md §Dataset license inventory for full provenance.
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import random
import sys
import time
from typing import Optional

# ── Dependency check ──────────────────────────────────────────────────────────

def _check_deps() -> None:
    missing = []
    for pkg in ("torch", "torchvision", "torchaudio", "numpy"):
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(f"[train_classifier] Missing packages: {', '.join(missing)}")
        print("Install: pip install torch torchvision torchaudio numpy")
        sys.exit(1)

_check_deps()

import numpy as np                       # noqa: E402
import torch                             # noqa: E402
import torch.nn as nn                    # noqa: E402
import torch.optim as optim              # noqa: E402
import torchaudio                        # noqa: E402
import torchaudio.transforms as T        # noqa: E402
import torchvision.models as tvm         # noqa: E402
from torch.utils.data import Dataset, DataLoader  # noqa: E402

# ── Constants (must match feature_extractor.h defaults) ──────────────────────

SR          = 16_000
N_MELS      = 64
WINDOW_MS   = 25
HOP_MS      = 10
FFT_SIZE    = 512
FMIN        = 80.0
FMAX        = 8_000.0
WINDOW_SECS = 1.0
N_FRAMES    = int((SR * WINDOW_SECS - (WINDOW_MS * SR // 1000)) / (HOP_MS * SR // 1000)) + 1

CLASSES = [
    "speech_directed",
    "speech_ambient",
    "music",
    "noise",
    "silence",
]
N_CLASSES = len(CLASSES)

# ── Log-mel transform (matches feature_extractor.cpp parameters exactly) ─────

def make_mel_transform() -> nn.Sequential:
    window_samps = WINDOW_MS * SR // 1000  # 400
    hop_samps    = HOP_MS    * SR // 1000  # 160
    return nn.Sequential(
        T.Resample(orig_freq=SR, new_freq=SR),  # identity — placeholder for resampling
        T.MelSpectrogram(
            sample_rate   = SR,
            n_fft         = FFT_SIZE,
            win_length    = window_samps,
            hop_length    = hop_samps,
            n_mels        = N_MELS,
            f_min         = FMIN,
            f_max         = FMAX,
            power         = 2.0,
            center        = False,
        ),
        T.AmplitudeToDB(stype="power", top_db=80.0),
    )


# ── Dataset ───────────────────────────────────────────────────────────────────

class SceneDataset(Dataset):
    """Audio scene dataset.

    Loads WAV/FLAC files from <data-dir>/<class_name>/*.wav.
    Each sample is a 1-second random crop (or zero-padded if shorter).
    """

    def __init__(
        self,
        data_dir: pathlib.Path,
        transform: nn.Sequential,
        augment: bool = True,
        seed: int = 42,
    ) -> None:
        self.transform = transform
        self.augment   = augment
        self.rng       = random.Random(seed)

        self.items: list[tuple[pathlib.Path, int]] = []
        for cls_idx, cls_name in enumerate(CLASSES):
            cls_dir = data_dir / cls_name
            if not cls_dir.exists():
                print(f"[warn] Missing class directory: {cls_dir}")
                continue
            exts = {".wav", ".flac", ".mp3", ".ogg"}
            files = [p for p in cls_dir.rglob("*") if p.suffix.lower() in exts]
            print(f"  {cls_name}: {len(files)} files")
            for f in files:
                self.items.append((f, cls_idx))

        if not self.items:
            raise ValueError(f"No audio files found in {data_dir}")

        self.rng.shuffle(self.items)

    def __len__(self) -> int:
        return len(self.items)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, int]:
        path, label = self.items[idx]

        waveform, sr = torchaudio.load(str(path))
        waveform = waveform.mean(dim=0, keepdim=True)  # to mono

        # Resample to 16 kHz if needed
        if sr != SR:
            waveform = torchaudio.functional.resample(waveform, sr, SR)

        target_len = SR  # 1 second
        waveform   = _crop_or_pad(waveform, target_len, self.rng)

        # Augmentation (training only)
        if self.augment:
            waveform = _augment(waveform, self.rng)

        # Log-mel spectrogram: [1, N_MELS, N_FRAMES]
        # TODO(removal-cond: torchaudio.transforms.MelSpectrogram type stub accepts Tensor argument types matching runtime)
        logmel = self.transform(waveform)   # type: ignore[arg-type]
        return logmel, label


def _crop_or_pad(waveform: torch.Tensor, target: int,
                  rng: random.Random) -> torch.Tensor:
    n = waveform.shape[-1]
    if n > target:
        start = rng.randint(0, n - target)
        waveform = waveform[..., start: start + target]
    elif n < target:
        pad = target - n
        waveform = torch.nn.functional.pad(waveform, (0, pad))
    return waveform


def _augment(waveform: torch.Tensor, rng: random.Random) -> torch.Tensor:
    # Time-domain gain jitter ±6 dB
    gain_db = rng.uniform(-6.0, 6.0)
    waveform = waveform * (10.0 ** (gain_db / 20.0))
    # Additive Gaussian noise (very low level)
    if rng.random() < 0.3:
        noise_amp = rng.uniform(1e-4, 5e-4)
        waveform = waveform + torch.randn_like(waveform) * noise_amp
    return waveform.clamp(-1.0, 1.0)


# ── Model ────────────────────────────────────────────────────────────────────

class AudioSceneClassifier(nn.Module):
    """MobileNetV3-small adapted for 1-channel log-mel input.

    Architecture rationale:
    - MobileNetV3-small is designed for mobile/edge inference (< 5 ms on ANE)
    - We replace the first conv to accept 1-channel (grayscale) mel input
    - Global average pooling compresses variable time dimension
    - Linear head outputs N_CLASSES logits
    - Total parameters: ~1.5 M — fits comfortably in the ANE model cache

    Input:  [batch, 1, N_MELS, N_FRAMES]   (channel, freq, time)
    Output: [batch, N_CLASSES]              (logits)
    """

    def __init__(self, n_classes: int = N_CLASSES) -> None:
        super().__init__()
        self.backbone = tvm.mobilenet_v3_small(weights=None)

        # Replace first Conv2d: 3→1 channels, same kernel/stride/padding
        first_conv = self.backbone.features[0][0]
        self.backbone.features[0][0] = nn.Conv2d(
            in_channels  = 1,
            out_channels = first_conv.out_channels,
            kernel_size  = first_conv.kernel_size,
            stride       = first_conv.stride,
            padding      = first_conv.padding,
            bias         = False,
        )
        # Initialize from the original weights (average across RGB channels)
        with torch.no_grad():
            self.backbone.features[0][0].weight.copy_(
                first_conv.weight.mean(dim=1, keepdim=True)
            )

        # Replace classifier head
        in_features = self.backbone.classifier[-1].in_features
        self.backbone.classifier[-1] = nn.Linear(in_features, n_classes)

    # TODO(removal-cond: nn.Module type stub accepts narrower forward(Tensor)->Tensor override without [override] complaint)
    def forward(self, x: torch.Tensor) -> torch.Tensor:  # type: ignore[override]
        return self.backbone(x)


# ── Training ─────────────────────────────────────────────────────────────────

def train(args: argparse.Namespace) -> None:
    device = (
        "mps"  if torch.backends.mps.is_available()
        else "cuda" if torch.cuda.is_available()
        else "cpu"
    )
    print(f"[train] device={device}  epochs={args.epochs}  batch={args.batch_size}")

    out_dir = pathlib.Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    transform = make_mel_transform()

    # Split dataset 85 % train / 15 % val
    full_dataset = SceneDataset(
        pathlib.Path(args.data_dir),
        transform=transform,
        augment=True,
    )
    n_val   = max(1, int(0.15 * len(full_dataset)))
    n_train = len(full_dataset) - n_val
    train_ds, val_ds = torch.utils.data.random_split(
        full_dataset, [n_train, n_val],
        generator=torch.Generator().manual_seed(42),
    )

    train_loader = DataLoader(train_ds, batch_size=args.batch_size,
                              shuffle=True,  num_workers=4, pin_memory=True)
    val_loader   = DataLoader(val_ds,   batch_size=args.batch_size,
                              shuffle=False, num_workers=2, pin_memory=True)

    model = AudioSceneClassifier(n_classes=N_CLASSES).to(device)

    optimizer = optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs)
    criterion = nn.CrossEntropyLoss(label_smoothing=0.1)

    best_val_acc = 0.0
    best_path    = out_dir / "best_model.pt"

    for epoch in range(1, args.epochs + 1):
        # ── Train ─────────────────────────────────────────────────────────────
        model.train()
        train_loss = 0.0
        train_correct = 0
        for logmel, labels in train_loader:
            logmel  = logmel.to(device)
            labels  = labels.to(device)
            optimizer.zero_grad()
            logits  = model(logmel)
            loss    = criterion(logits, labels)
            loss.backward()
            optimizer.step()
            train_loss    += loss.item() * logmel.size(0)
            train_correct += (logits.argmax(1) == labels).sum().item()
        scheduler.step()

        # ── Validate ──────────────────────────────────────────────────────────
        model.eval()
        val_loss = 0.0
        val_correct = 0
        confusion   = [[0] * N_CLASSES for _ in range(N_CLASSES)]

        with torch.no_grad():
            for logmel, labels in val_loader:
                logmel = logmel.to(device)
                labels = labels.to(device)
                logits = model(logmel)
                val_loss    += criterion(logits, labels).item() * logmel.size(0)
                preds        = logits.argmax(1)
                val_correct += (preds == labels).sum().item()
                for t, p in zip(labels.cpu().tolist(), preds.cpu().tolist()):
                    confusion[t][p] += 1

        train_acc = train_correct / n_train
        val_acc   = val_correct   / n_val
        print(
            f"epoch {epoch:3d}/{args.epochs}"
            f"  train_acc={train_acc:.3f}"
            f"  val_acc={val_acc:.3f}"
            f"  lr={scheduler.get_last_lr()[0]:.2e}"
        )

        if val_acc > best_val_acc:
            best_val_acc = val_acc
            torch.save(model.state_dict(), best_path)
            print(f"  → saved best model (val_acc={val_acc:.3f})")

    # ── Final report ──────────────────────────────────────────────────────────
    print(f"\n[train] Best val accuracy: {best_val_acc:.4f}")

    # Load best weights and export TorchScript
    model.load_state_dict(torch.load(best_path, map_location="cpu"))
    model.eval()
    model.to("cpu")

    example_input = torch.zeros(1, 1, N_MELS, N_FRAMES)
    traced = torch.jit.trace(model, example_input)
    ts_path = out_dir / "audio_scene_classifier.pt"
    traced.save(str(ts_path))
    print(f"[train] TorchScript saved: {ts_path}")

    # Save metadata for convert_to_coreml.py
    meta = {
        "classes": CLASSES,
        "n_classes": N_CLASSES,
        "sample_rate": SR,
        "n_mels": N_MELS,
        "window_ms": WINDOW_MS,
        "hop_ms": HOP_MS,
        "fft_size": FFT_SIZE,
        "fmin": FMIN,
        "fmax": FMAX,
        "n_frames": N_FRAMES,
        "torchscript": str(ts_path),
        "best_val_accuracy": best_val_acc,
    }
    meta_path = out_dir / "model_meta.json"
    meta_path.write_text(json.dumps(meta, indent=2))
    print(f"[train] Metadata saved: {meta_path}")


# ─── CLI ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data-dir",    required=True,  help="Dataset root directory")
    parser.add_argument("--output-dir",  required=True,  help="Output directory for artifacts")
    parser.add_argument("--epochs",      type=int,   default=30)
    parser.add_argument("--batch-size",  type=int,   default=64)
    parser.add_argument("--lr",          type=float, default=1e-3)
    parser.add_argument("--seed",        type=int,   default=42)
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)
    random.seed(args.seed)

    train(args)


if __name__ == "__main__":
    main()
