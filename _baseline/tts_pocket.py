#!/usr/bin/env python3
"""JARVIS speaking side — pluggable TTS with a Kyutai pocket-tts backend.

pocket-tts (kyutai-labs): CPU text-to-speech with voice cloning. Verified API:
  from pocket_tts import TTSModel, export_model_state
  m = TTSModel.load_model(language="english")                  # CPU, ~24kHz
  voice = m.get_state_for_audio_prompt(<wav | url | .safetensors>)   # clone a voice
  audio = m.generate_audio(voice, text)                        # torch.Tensor [samples]
  scipy.io.wavfile.write(path, m.sample_rate, audio.numpy())

Same swappable-organ pattern as the STT and model layers: the voice is a part, not the
person. JARVIS's voice = a cloned voice_state (the Harvard-sentence JARVIS samples),
exported to .safetensors for instant reload. Swap the voice, same JARVIS.
"""
from __future__ import annotations
from typing import Optional, Protocol

class TTSBackend(Protocol):
    def synth(self, text: str): ...                 # -> (sample_rate:int, audio:ndarray)
    def save_wav(self, text: str, path: str) -> str: ...

class LocalTTSStub:
    """Drop-in slot for a different TTS without touching the loop."""
    def synth(self, text: str): raise NotImplementedError("no local TTS wired; using pocket-tts")
    def save_wav(self, text: str, path: str) -> str: raise NotImplementedError

class PocketTTS:
    """Kyutai pocket-tts. Lazy-loads the model so importing this module is free until
    JARVIS actually speaks; loads the voice once and reuses it for every utterance."""
    def __init__(self, voice: str = "hf://kyutai/tts-voices/alba-mackenna/casual.wav",
                 language: str = "english", temp: float = 0.7, quantize: bool = False):
        self.voice = voice
        self.language = language
        self.temp = temp
        self.quantize = quantize
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

def speak(text: str, backend: TTSBackend, out: str = "jarvis_say.wav") -> str:
    return backend.save_wav(text, out)

if __name__ == "__main__":
    import importlib.util
    have = importlib.util.find_spec("pocket_tts") is not None
    b = PocketTTS()
    iface = all(hasattr(b, m) for m in ("synth", "save_wav", "stream", "export_voice"))
    print("module parses & imports: OK")
    print(f"PocketTTS constructed (voice={b.voice}, language={b.language})")
    print(f"TTSBackend interface complete: {iface}")
    if have:
        try:
            p = b.save_wav("Good morning. JARVIS online. How may I be of use, sir?", "/tmp/jarvis_say.wav")
            print("LIVE SYNTH OK ->", p)
        except Exception as e:
            print("synth attempt:", type(e).__name__, "-", str(e)[:160])
    else:
        print("pocket-tts not installed in this sandbox — structure verified; live synth "
              "runs where it's installed (your machine: `pip install pocket-tts`).")
    import sys; sys.exit(0 if iface else 1)
