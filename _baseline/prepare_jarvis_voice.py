#!/usr/bin/env python3
"""Prepare the local JARVIS TTS voice from the Harvard-sentence dataset."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
from typing import Any, Dict, List, Tuple


REPO_ID = "derekurban2001/jarvis-voice-samples"
PARQUET_PATH = "data/train-00000-of-00001.parquet"
DEFAULT_OUT = pathlib.Path("~/research/jarvis/_local_voice").expanduser()


def _audio_array(value: Any) -> Tuple[int, Any]:
    if isinstance(value, dict):
        rate = int(value.get("sampling_rate") or value.get("sample_rate") or 0)
        array = value.get("array")
        if array is not None and rate:
            return rate, array
        raw = value.get("bytes")
        if raw:
            import io
            import soundfile as sf
            data, sr = sf.read(io.BytesIO(raw), dtype="float32")
            return int(sr), data
        path = value.get("path")
        if path:
            import soundfile as sf
            data, sr = sf.read(path, dtype="float32")
            return int(sr), data
    raise ValueError(f"unsupported audio payload shape: {type(value).__name__}")


def download_dataset(out_dir: pathlib.Path) -> pathlib.Path:
    from huggingface_hub import hf_hub_download
    out_dir.mkdir(parents=True, exist_ok=True)
    return pathlib.Path(hf_hub_download(repo_id=REPO_ID, filename=PARQUET_PATH, repo_type="dataset",
                                        local_dir=out_dir / "hf_cache"))


def build_prompt_wav(parquet_path: pathlib.Path, out_path: pathlib.Path,
                     max_seconds: float = 75.0, gap_seconds: float = 0.18) -> Dict:
    import numpy as np
    import pandas as pd
    import scipy.signal
    import soundfile as sf

    df = pd.read_parquet(parquet_path)
    if "audio" not in df or "text" not in df:
        raise ValueError("dataset must contain text and audio columns")

    target_sr = 24000
    gap = np.zeros(int(target_sr * gap_seconds), dtype=np.float32)
    chunks: List[np.ndarray] = []
    transcript: List[str] = []
    total = 0
    limit = int(target_sr * max_seconds)

    for _, row in df.iterrows():
        sr, audio = _audio_array(row["audio"])
        arr = np.asarray(audio, dtype=np.float32)
        if arr.ndim > 1:
            arr = arr.mean(axis=1)
        if sr != target_sr:
            new_len = max(1, int(len(arr) * target_sr / sr))
            arr = scipy.signal.resample(arr, new_len).astype(np.float32)
        peak = float(np.max(np.abs(arr))) if len(arr) else 0.0
        if peak > 0:
            arr = (arr / peak * 0.88).astype(np.float32)
        if total + len(arr) > limit:
            remaining = limit - total
            if remaining > target_sr:
                chunks.append(arr[:remaining])
                transcript.append(str(row["text"]))
            break
        chunks.append(arr)
        chunks.append(gap)
        transcript.append(str(row["text"]))
        total += len(arr) + len(gap)
        if total >= limit:
            break

    if not chunks:
        raise ValueError("no audio rows extracted")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    combined = np.concatenate(chunks)
    sf.write(out_path, combined, target_sr, subtype="PCM_16")
    return {"wav": str(out_path), "sample_rate": target_sr, "seconds": round(len(combined) / target_sr, 2),
            "sentences": len(transcript), "transcript": transcript}


def export_voice_state(wav_path: pathlib.Path, out_path: pathlib.Path) -> Dict:
    from pocket_tts import TTSModel, export_model_state
    model = TTSModel.load_model(language="english")
    state = model.get_state_for_audio_prompt(wav_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    export_model_state(state, out_path)
    return {"voice_state": str(out_path), "exists": out_path.exists(), "bytes": out_path.stat().st_size}


def write_env_lines(env_path: pathlib.Path, voice_path: pathlib.Path) -> Dict:
    keys = {
        "JARVIS_TTS_BACKEND": "pocket-tts",
        "JARVIS_TTS_VOICE": str(voice_path),
        "JARVIS_TTS_VOICE_CONFIRMED": "1",
        "JARVIS_TTS_LANGUAGE": "english",
    }
    env_path.parent.mkdir(parents=True, exist_ok=True)
    lines = env_path.read_text().splitlines() if env_path.exists() else []
    kept = [line for line in lines if not any(line.startswith(key + "=") for key in keys)]
    kept.extend(f'{key}="{value}"' for key, value in keys.items())
    env_path.write_text("\n".join(kept).rstrip() + "\n")
    return {"env": str(env_path), "set": sorted(keys)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=str(DEFAULT_OUT))
    parser.add_argument("--env", default=str(pathlib.Path("~/research/jarvis/.env").expanduser()))
    parser.add_argument("--max-seconds", type=float, default=75.0)
    parser.add_argument("--no-export", action="store_true", help="Only build the prompt WAV; do not load pocket-tts.")
    args = parser.parse_args()

    out_dir = pathlib.Path(args.out_dir).expanduser()
    parquet_path = download_dataset(out_dir)
    wav_path = out_dir / "jarvis_harvard_prompt.wav"
    state_path = out_dir / "jarvis_voice_state.safetensors"
    result: Dict[str, Any] = {"dataset": REPO_ID, "parquet": str(parquet_path)}
    result["prompt"] = build_prompt_wav(parquet_path, wav_path, args.max_seconds)
    if args.no_export:
        result["env"] = write_env_lines(pathlib.Path(args.env).expanduser(), wav_path)
    else:
        result["voice_state"] = export_voice_state(wav_path, state_path)
        result["env"] = write_env_lines(pathlib.Path(args.env).expanduser(), state_path)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
