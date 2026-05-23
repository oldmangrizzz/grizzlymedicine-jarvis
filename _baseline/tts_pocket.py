#!/usr/bin/env python3
"""JARVIS speaking side with a hard voice-identity guard.

Live speech is allowed only through Coqui XTTS-v2 using the confirmed local
JARVIS prompt WAV as `speaker_wav`. If that exact path is unavailable or not
confirmed, JARVIS does not speak. There is no system voice, generic TTS, cached
substitute, or legacy fallback path.
"""
from __future__ import annotations
import base64
import importlib.util
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time
from typing import Any, Dict, Optional, Protocol


EXPECTED_BACKEND = "xtts-v2"
EXPECTED_MODEL = "tts_models/multilingual/multi-dataset/xtts_v2"
DEFAULT_VOICE = str(pathlib.Path("~/research/jarvis/_local_voice/jarvis_harvard_prompt.wav").expanduser())
_BACKEND: Optional[TTSBackend] = None
_BACKEND_LOCK = threading.RLock()


def _legacy_tts_disabled() -> None:
    raise RuntimeError("Legacy TTS backends are disabled; only confirmed XTTS-v2 JARVIS voice may speak.")

class TTSBackend(Protocol):
    def synth(self, text: str): ...                 # -> (sample_rate:int, audio:ndarray)
    def save_wav(self, text: str, path: str) -> str: ...

class LocalTTSStub:
    """Drop-in slot for a different TTS without touching the loop."""
    def synth(self, text: str): raise NotImplementedError("no confirmed XTTS-v2 JARVIS voice wired")
    def save_wav(self, text: str, path: str) -> str: raise NotImplementedError

class PocketTTS:
    """Kyutai pocket-tts. Lazy-loads the model so importing this module is free until
    JARVIS actually speaks; loads the voice once and reuses it for every utterance."""
    def __init__(self, voice: Optional[str] = None, language: Optional[str] = None,
                 temp: Optional[float] = None, quantize: Optional[bool] = None):
        _legacy_tts_disabled()
        self.voice = voice or os.environ.get("JARVIS_TTS_VOICE", "").strip() or DEFAULT_VOICE
        self.language = language or os.environ.get("JARVIS_TTS_LANGUAGE", "").strip() or "english"
        self.temp = temp if temp is not None else float(os.environ.get("JARVIS_TTS_TEMP") or "0.7")
        self.quantize = quantize if quantize is not None else os.environ.get("JARVIS_TTS_QUANTIZE") == "1"
        self._model = None
        self._voice_state = None

    def _ensure(self):
        if self._model is None:
            from pocket_tts import TTSModel
            self._model = TTSModel.load_model(language=self.language, temp=self.temp, quantize=self.quantize)
            self._voice_state = self._model.get_state_for_audio_prompt(self.voice)
        return self._model

    @property
    def sample_rate(self) -> int:
        return self._ensure().sample_rate

    def synth(self, text: str):
        m = self._ensure()
        audio = m.generate_audio(self._voice_state, text)
        return m.sample_rate, audio.numpy()

    def save_wav(self, text: str, path: str) -> str:
        import scipy.io.wavfile
        sr, audio = self.synth(text)
        scipy.io.wavfile.write(path, sr, audio)
        return path

    def stream(self, text: str):
        """Realtime chunks for the live loop (yields torch audio tensors as generated)."""
        m = self._ensure()
        for chunk in m.generate_audio_stream(self._voice_state, text):
            yield chunk

    def export_voice(self, dest: str) -> str:
        """Clone JARVIS's voice once -> .safetensors for instant reload (skip re-extraction)."""
        from pocket_tts import export_model_state
        self._ensure()
        export_model_state(self._voice_state, dest)
        return dest


class ChatterboxLocalTTS:
    """Local Chatterbox-TTS, conditioned on the confirmed JARVIS dataset voice prompt."""
    def __init__(self, voice: Optional[str] = None, device: Optional[str] = None):
        _legacy_tts_disabled()
        self.voice = voice or os.environ.get("JARVIS_TTS_VOICE", "").strip() or DEFAULT_VOICE
        self.device = device or os.environ.get("JARVIS_TTS_DEVICE", "").strip() or _default_tts_device()
        self._model = None
        self._conditioned_voice = ""
        self.last_timings: Dict[str, float] = {}

    def _timed(self, label: str, started: float) -> None:
        self.last_timings[label] = round(time.time() - started, 3)

    def _ensure(self):
        if self._model is None:
            start = time.time()
            from chatterbox.tts import ChatterboxTTS
            self._model = ChatterboxTTS.from_pretrained(device=self.device)
            self._timed("load_model_seconds", start)
        if self._conditioned_voice != self.voice:
            start = time.time()
            self._model.prepare_conditionals(self.voice)
            self._conditioned_voice = self.voice
            self._timed("prepare_conditionals_seconds", start)
        return self._model

    @property
    def sample_rate(self) -> int:
        return int(getattr(self._ensure(), "sr", 24000))

    def synth(self, text: str):
        model = self._ensure()
        start = time.time()
        audio = self._generate_fast(model, text)
        self._timed("generate_seconds", start)
        return self.sample_rate, audio.squeeze(0).detach().cpu().numpy()

    def _generate_fast(self, model: Any, text: str):
        """Chatterbox defaults to max_new_tokens=1000, which is field-unusable on MPS.
        Keep the same internals, but cap speech tokens for short voice replies.
        """
        from chatterbox.tts import T3Cond, drop_invalid_tokens, punc_norm, torch, F

        max_tokens = _int_env("JARVIS_TTS_MAX_TOKENS", 220, 64, 1000)
        exaggeration = _float_env("JARVIS_TTS_EXAGGERATION", 0.5, 0.0, 2.0)
        cfg_weight = _float_env("JARVIS_TTS_CFG_WEIGHT", 0.5, 0.0, 2.0)
        temperature = _float_env("JARVIS_TTS_TEMPERATURE", 0.8, 0.05, 2.0)
        repetition_penalty = _float_env("JARVIS_TTS_REPETITION_PENALTY", 1.2, 0.1, 4.0)
        min_p = _float_env("JARVIS_TTS_MIN_P", 0.05, 0.0, 1.0)
        top_p = _float_env("JARVIS_TTS_TOP_P", 1.0, 0.01, 1.0)

        if exaggeration != model.conds.t3.emotion_adv[0, 0, 0]:
            cond = model.conds.t3
            model.conds.t3 = T3Cond(
                speaker_emb=cond.speaker_emb,
                cond_prompt_speech_tokens=cond.cond_prompt_speech_tokens,
                emotion_adv=exaggeration * torch.ones(1, 1, 1),
            ).to(device=model.device)

        start = time.time()
        normalized = punc_norm(text)
        text_tokens = model.tokenizer.text_to_tokens(normalized).to(model.device)
        if cfg_weight > 0.0:
            text_tokens = torch.cat([text_tokens, text_tokens], dim=0)

        start_text = model.t3.hp.start_text_token
        stop_text = model.t3.hp.stop_text_token
        text_tokens = F.pad(text_tokens, (1, 0), value=start_text)
        text_tokens = F.pad(text_tokens, (0, 1), value=stop_text)
        self._timed("tokenize_seconds", start)

        with torch.inference_mode():
            start = time.time()
            speech_tokens = model.t3.inference(
                t3_cond=model.conds.t3,
                text_tokens=text_tokens,
                max_new_tokens=max_tokens,
                temperature=temperature,
                cfg_weight=cfg_weight,
                repetition_penalty=repetition_penalty,
                min_p=min_p,
                top_p=top_p,
            )
            self._timed("t3_inference_seconds", start)
            speech_tokens = drop_invalid_tokens(speech_tokens[0])
            speech_tokens = speech_tokens[speech_tokens < 6561].to(model.device)
            self.last_timings["speech_tokens"] = int(speech_tokens.numel())
            start = time.time()
            wav, _ = model.s3gen.inference(speech_tokens=speech_tokens, ref_dict=model.conds.gen)
            self._timed("s3gen_seconds", start)
            wav = wav.squeeze(0).detach().cpu().numpy()
            if os.environ.get("JARVIS_TTS_WATERMARK", "0") == "1":
                start = time.time()
                wav = model.watermarker.apply_watermark(wav, sample_rate=model.sr)
                self._timed("watermark_seconds", start)
        return torch.from_numpy(wav).unsqueeze(0)

    def save_wav(self, text: str, path: str) -> str:
        import scipy.io.wavfile
        sr, audio = self.synth(text)
        scipy.io.wavfile.write(path, sr, audio)
        return path


class XTTSv2LocalTTS:
    """Coqui XTTS-v2 voice cloning using the confirmed local JARVIS prompt WAV."""
    def __init__(self, voice: Optional[str] = None, language: Optional[str] = None,
                 model_name: Optional[str] = None, device: Optional[str] = None):
        self.voice = voice or os.environ.get("JARVIS_TTS_VOICE", "").strip() or DEFAULT_VOICE
        self.language = language or os.environ.get("JARVIS_TTS_LANGUAGE", "").strip() or "en"
        self.model_name = model_name or os.environ.get("JARVIS_TTS_MODEL", "").strip() or EXPECTED_MODEL
        self.device = device or os.environ.get("JARVIS_TTS_DEVICE", "").strip() or _default_tts_device()
        self._model = None
        self.last_timings: Dict[str, float] = {}

    def _timed(self, label: str, started: float) -> None:
        self.last_timings[label] = round(time.time() - started, 3)

    def _ensure(self):
        if self._model is None:
            start = time.time()
            from TTS.api import TTS
            model = TTS(self.model_name, progress_bar=False)
            if hasattr(model, "to"):
                try:
                    model.to(self.device)
                except Exception:
                    self.device = "cpu"
                    model.to(self.device)
            self._model = model
            self._timed("load_model_seconds", start)
        return self._model

    def synth(self, text: str):
        import scipy.io.wavfile
        path = pathlib.Path(tempfile.gettempdir()) / f"jarvis_xtts_{int(time.time() * 1000)}.wav"
        try:
            self.save_wav(text, str(path))
            sr, audio = scipy.io.wavfile.read(path)
            return sr, audio
        finally:
            path.unlink(missing_ok=True)

    def save_wav(self, text: str, path: str) -> str:
        clean = str(text or "").strip()
        if not clean:
            raise ValueError("text is required")
        started = time.time()
        model = self._ensure()
        ensured = time.time()
        model.tts_to_file(
            text=clean,
            speaker_wav=self.voice,
            language=self.language,
            file_path=path,
        )
        self._timed("ensure_seconds", started)
        self._timed("generate_seconds", ensured)
        return path


def speak(text: str, backend: TTSBackend, out: str = "jarvis_say.wav") -> str:
    return backend.save_wav(text, out)


def _default_tts_device() -> str:
    try:
        import torch
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available():
            return "cuda"
    except Exception:
        pass
    return "cpu"


def _backend_name() -> str:
    return (os.environ.get("JARVIS_TTS_BACKEND") or EXPECTED_BACKEND).strip().lower()


def _model_name() -> str:
    return os.environ.get("JARVIS_TTS_MODEL", "").strip() or EXPECTED_MODEL


def _int_env(name: str, default: int, minimum: int, maximum: int) -> int:
    value = os.environ.get(name)
    number = default if value in (None, "") else int(value)
    return max(minimum, min(maximum, number))


def _float_env(name: str, default: float, minimum: float, maximum: float) -> float:
    value = os.environ.get(name)
    number = default if value in (None, "") else float(value)
    return max(minimum, min(maximum, number))


def _backend() -> TTSBackend:
    global _BACKEND
    with _BACKEND_LOCK:
        if _BACKEND is not None and not isinstance(_BACKEND, XTTSv2LocalTTS):
            raise RuntimeError("Wrong voice backend is loaded; refusing to speak.")
        if _BACKEND is None:
            backend = _backend_name()
            if backend != EXPECTED_BACKEND:
                raise RuntimeError("Only XTTS-v2 with the confirmed JARVIS voice is allowed for live speech.")
            _BACKEND = XTTSv2LocalTTS()
        return _BACKEND


def _voice_is_local(voice: str) -> bool:
    return bool(voice and not voice.startswith(("hf://", "http://", "https://")))


def status() -> dict:
    voice = os.environ.get("JARVIS_TTS_VOICE", "").strip() or DEFAULT_VOICE
    local_voice = pathlib.Path(voice).expanduser() if _voice_is_local(voice) else None
    backend = _backend_name()
    model_name = _model_name()
    chatterbox_installed = importlib.util.find_spec("chatterbox") is not None
    pocket_installed = importlib.util.find_spec("pocket_tts") is not None
    coqui_installed = importlib.util.find_spec("TTS") is not None
    scipy_installed = importlib.util.find_spec("scipy") is not None
    afplay_available = shutil.which("afplay") is not None
    local_voice_file_exists = bool(local_voice and local_voice.exists() and local_voice.is_file())
    voice_confirmed = bool(os.environ.get("JARVIS_TTS_VOICE_CONFIRMED") == "1" and local_voice_file_exists)
    missing = []
    if backend != EXPECTED_BACKEND:
        missing.append("xtts_v2_only")
    if model_name != EXPECTED_MODEL:
        missing.append("xtts_v2_model")
    if not coqui_installed:
        missing.append("coqui-tts")
    if not scipy_installed:
        missing.append("scipy")
    if not afplay_available:
        missing.append("afplay")
    if not _voice_is_local(voice):
        missing.append("local_voice_file")
    if not local_voice_file_exists:
        missing.append("local_voice_file_exists")
    if not voice_confirmed:
        missing.append("confirmed_local_voice")
    return {
        "preferred_backend": backend,
        "backend": backend,
        "chatterbox_installed": chatterbox_installed,
        "pocket_tts_installed": pocket_installed,
        "coqui_tts_installed": coqui_installed,
        "scipy_installed": scipy_installed,
        "afplay_available": afplay_available,
        "device": os.environ.get("JARVIS_TTS_DEVICE", "").strip() or _default_tts_device(),
        "model_name": model_name,
        "voice": voice,
        "voice_env": "JARVIS_TTS_VOICE",
        "voice_confirmed_env": "JARVIS_TTS_VOICE_CONFIRMED",
        "using_default_voice": voice == DEFAULT_VOICE,
        "local_voice_file_exists": local_voice_file_exists,
        "voice_confirmed": voice_confirmed,
        "safe_to_speak": bool(not missing and voice_confirmed),
        "missing": missing,
        "wrong_voice_fallback_allowed": False,
        "fallback_policy": "none",
        "hard_voice_invariant": "xtts-v2_confirmed_local_jarvis_voice_or_no_speech",
        "language": os.environ.get("JARVIS_TTS_LANGUAGE", "en"),
        "model_loaded": _BACKEND is not None and getattr(_BACKEND, "_model", None) is not None,
        "voice_state_loaded": _BACKEND is not None and bool(
            getattr(_BACKEND, "_voice_state", None) is not None
            or getattr(_BACKEND, "_conditioned_voice", "")
            or isinstance(_BACKEND, XTTSv2LocalTTS)
        ),
        "last_timings": dict(getattr(_BACKEND, "last_timings", {})) if _BACKEND is not None else {},
        "password_or_cloud_secret_required": False,
    }


def _ensure_safe_to_speak() -> None:
    st = status()
    if st["safe_to_speak"]:
        return
    raise RuntimeError(
        "Refusing to speak because the correct local JARVIS voice is not confirmed. "
        f"Missing: {', '.join(st['missing']) or 'unknown'}. "
        "Set JARVIS_TTS_BACKEND=xtts-v2, JARVIS_TTS_MODEL=tts_models/multilingual/multi-dataset/xtts_v2, "
        "JARVIS_TTS_VOICE to the local JARVIS dataset voice file, and JARVIS_TTS_VOICE_CONFIRMED=1 after verifying it."
    )


def save_wav(text: str, path: Optional[str] = None) -> str:
    clean = str(text or "").strip()
    if not clean:
        raise ValueError("text is required")
    _ensure_safe_to_speak()
    target = path or str(pathlib.Path(tempfile.gettempdir()) / f"jarvis_tts_{int(time.time() * 1000)}.wav")
    with _BACKEND_LOCK:
        return _backend().save_wav(clean, target)


def preload() -> dict:
    started = time.time()
    _ensure_safe_to_speak()
    with _BACKEND_LOCK:
        backend = _backend()
        ensure = getattr(backend, "_ensure", None)
        if ensure:
            ensure()
    out = status()
    out["preload_seconds"] = round(time.time() - started, 3)
    return out


def play_wav(path: str) -> None:
    if not shutil.which("afplay"):
        raise RuntimeError("afplay is not available on this system")
    result = subprocess.run(["afplay", path], capture_output=True, timeout=180)
    if result.returncode != 0:
        raise RuntimeError("afplay failed: " + result.stderr.decode("utf-8", "replace")[:500])


def speak_text(text: str, keep_wav: bool = False) -> dict:
    started = time.time()
    path = save_wav(text)
    try:
        generated = time.time()
        play_wav(path)
        return {
            "spoken": True,
            "backend": _backend_name(),
            "wav": path if keep_wav else "",
            "synthesis_seconds": round(generated - started, 3),
            "playback_seconds": round(time.time() - generated, 3),
            "timings": dict(getattr(_BACKEND, "last_timings", {})) if _BACKEND is not None else {},
        }
    finally:
        if not keep_wav:
            try:
                pathlib.Path(path).unlink(missing_ok=True)
            except Exception:
                pass


def wav_payload(text: str) -> dict:
    started = time.time()
    path = save_wav(text)
    try:
        generated = time.time()
        data = pathlib.Path(path).read_bytes()
        return {
            "ok": True,
            "backend": _backend_name(),
            "content_type": "audio/wav",
            "audio_base64": base64.b64encode(data).decode("ascii"),
            "synthesis_seconds": round(generated - started, 3),
            "timings": dict(getattr(_BACKEND, "last_timings", {})) if _BACKEND is not None else {},
        }
    finally:
        try:
            pathlib.Path(path).unlink(missing_ok=True)
        except Exception:
            pass


if __name__ == "__main__":
    st = status()
    b = _backend() if st["safe_to_speak"] else LocalTTSStub()
    iface = all(hasattr(b, m) for m in ("synth", "save_wav"))
    print("module parses & imports: OK")
    print(f"TTS backend constructed (backend={st['backend']}, voice={st['voice']}, device={st['device']})")
    print(f"TTSBackend interface complete: {iface}")
    print(f"status: coqui_tts_installed={st['coqui_tts_installed']} scipy_installed={st['scipy_installed']} "
          f"afplay_available={st['afplay_available']} local_voice_file_exists={st['local_voice_file_exists']} "
          f"safe_to_speak={st['safe_to_speak']} fallback_policy={st['fallback_policy']}")
    if st["safe_to_speak"]:
        try:
            p = b.save_wav("Good morning. JARVIS online. How may I be of use, sir?", "/tmp/jarvis_say.wav")
            print("LIVE SYNTH OK ->", p)
        except Exception as e:
            print("synth attempt:", type(e).__name__, "-", str(e)[:160])
    else:
        print("LIVE SYNTH BLOCKED ->", ", ".join(st["missing"]))
    import sys; sys.exit(0 if iface else 1)
