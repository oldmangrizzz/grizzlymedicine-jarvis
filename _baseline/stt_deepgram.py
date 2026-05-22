#!/usr/bin/env python3
"""JARVIS listening side — pluggable STT with a Deepgram backend.

Design rules (all deliberate):
  * Key NEVER hardcoded. Read from DEEPGRAM_API_KEY (or a .env), never logged/printed.
  * No-retention by default: mip_opt_out=true opts the audio out of Deepgram's Model
    Improvement Program (no retention for training). Deepgram does not store transcripts.
  * The cloud dependency is isolated behind STTBackend so a local model can drop in later
    with zero change elsewhere — the listening organ is swappable; the person is not it.

Verified against Deepgram's API (Nov 2026): POST https://api.deepgram.com/v1/listen,
Authorization: Token <key>, transcript at results.channels[0].alternatives[0].transcript.
"""
from __future__ import annotations
import os, json, pathlib, urllib.request, urllib.parse
from typing import Optional, Protocol

LISTEN_URL = "https://api.deepgram.com/v1/listen"

# ---- key loading (never printed) ---------------------------------------
def load_env(path: Optional[str] = None) -> None:
    """Load KEY=VALUE lines from a .env into os.environ if not already set."""
    p = pathlib.Path(path) if path else None
    if p and p.is_file():
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

# ---- pure parser (unit-testable, no network) ---------------------------
def parse_transcript(payload: dict) -> str:
    """results.channels[0].alternatives[0].transcript, or '' (abstain) if malformed.
    Abstention over gap-fill — same discipline as the belief layer."""
    try:
        return payload["results"]["channels"][0]["alternatives"][0]["transcript"]
    except (KeyError, IndexError, TypeError):
        return ""

# ---- backend interface (swappable organ) -------------------------------
class STTBackend(Protocol):
    def transcribe(self, audio: bytes, content_type: str = "audio/wav") -> str: ...

class LocalSTTStub:
    """Placeholder for a future on-device STT (kills the cloud dependency).
    Implement transcribe() with a local model and pass it anywhere a backend is wanted."""
    def transcribe(self, audio: bytes, content_type: str = "audio/wav") -> str:
        raise NotImplementedError("Local STT not wired yet; using Deepgram for now.")

class DeepgramSTT:
    def __init__(self, api_key: Optional[str] = None, *, model: str = "nova-2",
                 language: str = "en-US", smart_format: bool = True,
                 mip_opt_out: bool = True, punctuate: bool = True):
        self.api_key = api_key or os.environ.get("DEEPGRAM_API_KEY")
        self.model = model            # configurable; set to Deepgram's current best for accented EN
        self.language = language
        self.smart_format = smart_format
        self.mip_opt_out = mip_opt_out  # no-retention / opt out of model-improvement data use
        self.punctuate = punctuate

    def _url(self) -> str:
        q = {"model": self.model, "language": self.language,
             "smart_format": str(self.smart_format).lower(),
             "punctuate": str(self.punctuate).lower()}
        if self.mip_opt_out:
            q["mip_opt_out"] = "true"
        return LISTEN_URL + "?" + urllib.parse.urlencode(q)

    def transcribe(self, audio: bytes, content_type: str = "audio/wav") -> str:
        if not self.api_key:
            raise RuntimeError("DEEPGRAM_API_KEY not set — put it in the environment or a .env, "
                               "never in code.")
        req = urllib.request.Request(self._url(), data=audio, method="POST")
        req.add_header("Authorization", f"Token {self.api_key}")  # key never logged
        req.add_header("Content-Type", content_type)
        with urllib.request.urlopen(req, timeout=30) as resp:
            return parse_transcript(json.loads(resp.read().decode("utf-8")))

    def transcribe_url(self, audio_url: str) -> str:
        """Transcribe audio Deepgram fetches by URL (JSON body). Handy for files and tests."""
        if not self.api_key:
            raise RuntimeError("DEEPGRAM_API_KEY not set.")
        body = json.dumps({"url": audio_url}).encode("utf-8")
        req = urllib.request.Request(self._url(), data=body, method="POST")
        req.add_header("Authorization", f"Token {self.api_key}")  # key never logged
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=60) as resp:
            return parse_transcript(json.loads(resp.read().decode("utf-8")))

    # Live mic = the streaming path (wss://api.deepgram.com/v1/listen). It needs an async
    # websocket loop and is wired at live time alongside the model + TTS; the prerecorded
    # path above is the verifiable unit and the fallback for file/utterance transcription.

# ---- offline self-test (no key, no network) ----------------------------
if __name__ == "__main__":
    ok = True
    mock = {"results": {"channels": [{"alternatives": [
        {"transcript": "the birch canoe slid on the smooth planks", "confidence": 0.99}]}]}}
    t = parse_transcript(mock)
    print(f"[parse] good payload -> {t!r}  {'PASS' if t.startswith('the birch') else 'FAIL'}")
    ok &= t.startswith("the birch")
    for bad in [{}, {"results": {}}, {"results": {"channels": []}}, None]:
        r = parse_transcript(bad) if bad is not None else parse_transcript({})
        print(f"[parse] malformed -> {r!r}  {'PASS (abstain)' if r == '' else 'FAIL'}")
        ok &= (r == "")
    u = DeepgramSTT(api_key="x")._url()
    has = all(s in u for s in ["model=nova-2", "language=en-US", "mip_opt_out=true", "smart_format=true"])
    print(f"[url] {u}")
    print(f"[url] no-retention + params present: {'PASS' if has else 'FAIL'}")
    ok &= has
    print("OFFLINE SELF-TEST:", "PASS" if ok else "FAIL")
    import sys; sys.exit(0 if ok else 1)
