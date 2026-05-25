#!/usr/bin/env python3
"""generate_test_fixtures.py — Build-time synthetic audio fixture generator.

Produces deterministic WAV files used by test_classifier.cpp.
All fixtures are purely synthetic (no copyrighted material).
Called automatically by CMakeLists.txt at configure time.

Usage:
    python3 generate_test_fixtures.py --out-dir /path/to/fixtures
"""
from __future__ import annotations

import argparse
import math
import pathlib
import struct
import wave
from typing import Sequence

SR = 16_000      # 16 kHz mono int16 — target format for the classifier


# ─── WAV writer ──────────────────────────────────────────────────────────────

def write_wav(path: pathlib.Path, samples: Sequence[int], sr: int = SR) -> None:
    """Write a list of int16 samples as a 16-bit mono WAV file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "w") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(sr)
        packed = struct.pack(f"<{len(samples)}h", *samples)
        wf.writeframes(packed)


def clamp_i16(x: float) -> int:
    return max(-32767, min(32767, int(x * 32767.0)))


# ─── Fixture generators ──────────────────────────────────────────────────────

def make_silence(n_samples: int = SR) -> list[int]:
    """Completely silent buffer (below any energy threshold)."""
    return [0] * n_samples


def make_near_silence(n_samples: int = SR) -> list[int]:
    """1-LSB dither — effectively –90 dBFS."""
    import random
    rng = random.Random(42)
    return [rng.randint(-1, 1) for _ in range(n_samples)]


def make_harmonic_music(
    n_samples: int = SR * 3,
    fundamental: float = 220.0,
    n_harmonics: int = 8,
    seed_phase: float = 0.0,
) -> list[int]:
    """Harmonic overtone series (piano-like, A3 = 220 Hz).

    Decay coefficient 0.65 per harmonic ensures energy in low-mid bands.
    Fully deterministic given the same parameters.
    """
    amps = [0.65 ** h for h in range(n_harmonics)]
    total = sum(amps)
    samples = []
    for i in range(n_samples):
        t = i / SR
        s = sum(
            a * math.sin(2.0 * math.pi * fundamental * (h + 1) * t + seed_phase)
            for h, a in enumerate(amps)
        )
        samples.append(clamp_i16(0.45 * s / total))
    return samples


def make_noise_hvac(n_samples: int = SR) -> list[int]:
    """Broadband spectrally-flat noise (HVAC / ventilation).

    Generated with a simple linear-congruential RNG for determinism.
    """
    a, c, m = 1664525, 1013904223, 2**32
    state = 0xDEADBEEF
    samples = []
    for _ in range(n_samples):
        state = (a * state + c) & (m - 1)
        val = (state >> 17) & 0x7FFF  # 15-bit
        if state & (1 << 16):
            val = -val
        samples.append(int(val * 0.35))  # scale to ~-10 dBFS
    return samples


def make_speech_sine_formants(n_samples: int = SR * 2) -> list[int]:
    """Approximate voiced speech via superimposed formant sinusoids.

    F0=120 Hz (male voice), F1=700 Hz, F2=1220 Hz, F3=2600 Hz.
    This is NOT real speech but exercises the ZCR/centroid heuristic
    for speech-like signal properties.
    """
    # (frequency, relative_amplitude)
    formants = [(120, 1.0), (700, 0.60), (1220, 0.40), (2600, 0.20)]
    total_amp = sum(a for _, a in formants)
    samples = []
    for i in range(n_samples):
        t = i / SR
        s = sum(
            a * math.sin(2.0 * math.pi * f * t)
            for f, a in formants
        )
        samples.append(clamp_i16(0.40 * s / total_amp))
    return samples


# ─── Main ─────────────────────────────────────────────────────────────────────

FIXTURES: dict[str, list[int]] = {}


def build_fixtures() -> dict[str, list[int]]:
    out: dict[str, list[int]] = {}

    # Silence
    out["silence_full.wav"]       = make_silence(SR * 3)
    out["silence_near_zero.wav"]  = make_near_silence(SR * 3)

    # Music — 10 different pitches / durations for variety
    pitches = [110.0, 165.0, 220.0, 330.0, 440.0, 550.0, 660.0, 880.0, 220.0, 330.0]
    for i, f0 in enumerate(pitches):
        out[f"music_{i:02d}.wav"] = make_harmonic_music(
            n_samples=SR * 3, fundamental=f0, seed_phase=i * 0.31
        )

    # Noise
    out["noise_hvac.wav"] = make_noise_hvac(SR * 3)

    # Synthetic speech-like signal
    out["speech_formants.wav"] = make_speech_sine_formants(SR * 3)

    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate synthetic audio test fixtures")
    parser.add_argument("--out-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    fixtures = build_fixtures()
    out_dir: pathlib.Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    for filename, samples in fixtures.items():
        p = out_dir / filename
        write_wav(p, samples)

    print(f"Generated {len(fixtures)} fixtures in {out_dir}")
    for filename in sorted(fixtures.keys()):
        p = out_dir / filename
        print(f"  {p} ({len(fixtures[filename]) // SR:.1f}s)")


if __name__ == "__main__":
    main()
