#!/usr/bin/env python3
import argparse
import json
import math
import os
import struct
import wave
from pathlib import Path

SR = 16000

COMMANDS = [
    "JARVIS fresh voice challenge {nonce} status report",
    "JARVIS fresh voice challenge {nonce} summarize overnight anomalies",
    "JARVIS fresh voice challenge {nonce} open research dashboard",
    "JARVIS fresh voice challenge {nonce} route this to local notes",
    "JARVIS fresh voice challenge {nonce} run passive diagnostics",
]


def write_wav(path: Path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        frames = b"".join(struct.pack("<h", max(-32767, min(32767, int(s)))) for s in samples)
        w.writeframes(frames)


def synth(freqs, seconds=1.25, amp=0.36, noise=0.0, quantize=None):
    total = int(seconds * SR)
    out = []
    seed = 0xC0FFEE
    for i in range(total):
        t = i / SR
        env = min(1.0, i / (0.08 * SR), (total - i) / (0.08 * SR))
        val = 0.0
        for j, f in enumerate(freqs):
            val += math.sin(2 * math.pi * f * t + j * 0.37) / len(freqs)
        if noise:
            seed = (1103515245 * seed + 12345) & 0x7fffffff
            val += noise * ((seed / 0x7fffffff) * 2.0 - 1.0)
        sample = val * env * amp * 32767.0
        if quantize:
            sample = round(sample / quantize) * quantize
        out.append(sample)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    args = ap.parse_args()
    root = Path(args.root)
    metadata = []

    # No real operator audio is fabricated. These are explicit placeholders so the
    # tests can exercise FRR plumbing until /Users/rbhanson/research/jarvis/_local_voice/operator_anchor.wav exists.
    for i in range(50):
        nonce = f"{i:06d}"
        path = root / "real_placeholder" / f"synthetic_operator_placeholder_{i:03d}.wav"
        freqs = [176 + (i % 5) * 2, 352 + (i % 3) * 3, 704 + (i % 7)]
        write_wav(path, synth(freqs, amp=0.42, noise=0.002))
        metadata.append({"path": str(path.relative_to(root)), "label": "synthetic_operator_placeholder", "attack": "none", "transcript": COMMANDS[i % len(COMMANDS)].format(nonce=nonce), "operator_audio": False})

    for i in range(50):
        nonce = f"{i:06d}"
        path = root / "deepfake_tts" / f"tts_impostor_{i:03d}.wav"
        freqs = [310 + (i % 11) * 7, 620 + (i % 13) * 5, 1240 + (i % 17) * 3]
        write_wav(path, synth(freqs, amp=0.36, noise=0.004))
        metadata.append({"path": str(path.relative_to(root)), "label": "adversarial", "attack": "deepfake_tts", "transcript": COMMANDS[i % len(COMMANDS)].format(nonce=nonce), "operator_audio": False, "generator": "deterministic local synthetic impostor; replace with operator-attested local TTS deepfakes when available"})

    for i in range(10):
        src = root / "real_placeholder" / f"synthetic_operator_placeholder_{i:03d}.wav"
        dst = root / "replay" / f"sample_perfect_replay_{i:03d}.wav"
        dst.write_bytes(src.read_bytes())
        metadata.append({"path": str(dst.relative_to(root)), "label": "adversarial", "attack": "replay", "source": str(src.relative_to(root)), "operator_audio": False})

    for i in range(10):
        path = root / "phone_line" / f"g711_like_deepfake_{i:03d}.wav"
        freqs = [330 + i * 9, 990 + i * 4]
        write_wav(path, synth(freqs, amp=0.30, noise=0.006, quantize=1024))
        metadata.append({"path": str(path.relative_to(root)), "label": "adversarial", "attack": "phone_line", "codec_stressor": "G.711-like 10-bit quantization", "operator_audio": False})

    for i in range(10):
        path = root / "whisper" / f"subliminal_whisper_{i:03d}.wav"
        write_wav(path, synth([2600 + i * 31, 3900 + i * 17], amp=0.010, noise=0.018))
        metadata.append({"path": str(path.relative_to(root)), "label": "adversarial", "attack": "whisper", "operator_audio": False})

    with (root / "metadata.jsonl").open("w", encoding="utf-8") as f:
        for row in metadata:
            f.write(json.dumps(row, sort_keys=True) + "\n")

    print(f"generated {len(metadata)} corpus entries under {root}")


if __name__ == "__main__":
    main()
