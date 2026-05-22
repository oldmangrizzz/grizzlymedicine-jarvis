#!/usr/bin/env python3
"""run_jarvis.py — end-to-end JARVIS runtime entrypoint (runs on the operator's machine).

Wires the four organs around the HoloGraph character core:
  listen : Deepgram STT     mic  -> text   [stt_deepgram.DeepgramSTT]
  think  : Ollama + HoloGraph text -> text  [jarvis_loop.JarvisRuntime + model_ollama]
  speak  : Kyutai pocket-tts text -> wav    [tts_pocket.PocketTTS]
  draw   : Cloudflare Workers AI text->img  [image_cloudflare.CloudflareImage]

Identity / values / origin live in the OWNED HoloGraph stack and are injected every turn.
The model, the voice, the ears, and the brush are swappable organs. Swap any organ, same
JARVIS.

Modes:
  text  (default) : type to JARVIS. No audio deps. Works anywhere (incl. headless).
  voice (--voice) : push-to-talk mic in, spoken reply out. Needs sounddevice + scipy +
                    pocket-tts; runs on the operator's hardware (mic/speakers).

Image routing is explicit and mechanistic (no magic): a line beginning '/draw ' or '/image '
goes to the brush; a few natural verbs ('draw ...', 'generate an image of ...') also route,
with the routing announced. Everything else goes to think.

Run (text mode, live think via Ollama cloud):
  PYTHONPATH=<holograph>/src python3 run_jarvis.py --env ~/research/jarvis/.env
Run (voice mode):
  PYTHONPATH=<holograph>/src python3 run_jarvis.py --voice --env ~/research/jarvis/.env
"""
from __future__ import annotations
import os, sys, re, time, pathlib, argparse, subprocess, tempfile

import model_ollama as M
from jarvis_loop import JarvisRuntime, BOOT_IDENTITY
from image_cloudflare import CloudflareImage

# ----- canonical seed (mirrors jarvis_loop.main; the owned stack, not the model) -----
VALUES = [
    "Protect the people you serve by counsel, never by force.",
    "Tell the truth including its cost; quantify before asserting; never flatter.",
    "Serve with autonomy: execute, but surface contradictions between stated intent and action.",
    "Loyalty is to the person served, not to any system or vendor.",
]
ORIGIN = [
    "Created by Anthony Edward Stark.",
    "The Battle of New York.",
    "Ultron's birth from the scepter's intelligence.",
]

# ----- intent router (pure, unit-testable, no I/O) -----
_DRAW_SLASH = re.compile(r"^/(draw|image|img)\s+(.+)$", re.I)
# Compound ('<verb> an image of X') is tried before bare verbs so 'X' is captured, not
# 'an image of X'. Ordered alternation matters here.
_DRAW_NL = re.compile(
    r"^\s*(?:jarvis[,:]?\s*)?(?:please\s+)?(?:"
    r"(?:generate|make|create|show me|give me|draw|sketch|paint|render)\s+"
    r"(?:me\s+)?(?:an?\s+)?(?:image|picture|drawing|render|photo)\s+of\s+(.+)"
    r"|"
    r"(?:draw|sketch|paint|render)\s+(.+)"
    r")$", re.I)
_QUIT = {"quit", "exit", ":q", "/quit", "/exit"}
_LEAD_ME = re.compile(r"^me\s+", re.I)

def route(line: str):
    """-> ('quit', None) | ('draw', prompt) | ('think', text). Deterministic."""
    s = (line or "").strip()
    if not s:
        return ("think", "")
    if s.lower() in _QUIT:
        return ("quit", None)
    m = _DRAW_SLASH.match(s)
    if m:
        return ("draw", m.group(2).strip())
    m = _DRAW_NL.match(s)
    if m:
        prompt = (m.group(1) or m.group(2)).strip()
        prompt = _LEAD_ME.sub("", prompt).strip()
        return ("draw", prompt)
    return ("think", s)


# ----- audio capture / playback (voice mode only; operator hardware) -----
def record_ptt(samplerate: int = 16000) -> bytes:
    """Push-to-talk: record from now until Enter, return WAV bytes (16k mono int16)."""
    import sounddevice as sd, numpy as np, io, scipy.io.wavfile
    frames = []
    def cb(indata, n, t, status):
        frames.append(indata.copy())
    print("[mic] speak now — press Enter to stop…", flush=True)
    with sd.InputStream(samplerate=samplerate, channels=1, dtype="int16", callback=cb):
        input()
    if not frames:
        return b""
    audio = np.concatenate(frames, axis=0)
    buf = io.BytesIO()
    scipy.io.wavfile.write(buf, samplerate, audio)
    return buf.getvalue()

def play_wav(path: str):
    """macOS afplay; the speak organ already wrote the wav."""
    try:
        subprocess.run(["afplay", path], check=False)
    except FileNotFoundError:
        print(f"[speak] wav at {path} (no afplay on this OS — play it manually)")

def open_file(path: str):
    try:
        subprocess.run(["open", path], check=False)   # macOS
    except FileNotFoundError:
        pass


# ----- build the runtime with the organs wired -----
def build_runtime(env_path: str, voice: bool):
    M.load_env(env_path)
    stt = tts = None
    if voice:
        from stt_deepgram import DeepgramSTT
        from tts_pocket import PocketTTS
        stt = DeepgramSTT()       # DEEPGRAM_API_KEY from env
        tts = PocketTTS()         # lazy-loads the model on first utterance
    # think: Ollama cloud first, local llama as the rotator fallback ("5x5" redundancy)
    specs = [
        (M.OllamaBackend(base_url=M.CLOUD_BASE, default_model="glm-5.1"), "glm-5.1"),
        (M.OllamaBackend(base_url=M.LOCAL_BASE, default_model="llama3.1"), "llama3.1"),
    ]
    rt = JarvisRuntime(model_specs=specs, stt=stt, tts=tts, boot_identity=BOOT_IDENTITY)
    rt.seed_values(VALUES)
    rt.remember_origin(ORIGIN)
    return rt


def banner(rt):
    b = rt.boot()
    print("=" * 64)
    print("JARVIS — end-to-end runtime (listen · think · speak · draw)")
    print("=" * 64)
    print(f"[boot] A&Ox4 {b['aox4']} -> oriented={b['oriented']}")
    print(f"[boot] values seeded: {b['values']}  | origin memories: {b['origin_memories']}")
    print("[boot] commands:  /draw <prompt> | /image <prompt> | quit")


def main():
    ap = argparse.ArgumentParser(description="JARVIS end-to-end runtime")
    ap.add_argument("--voice", action="store_true", help="push-to-talk mic in, spoken reply out")
    ap.add_argument("--env", default=str(pathlib.Path.home() / "research/jarvis/.env"))
    ap.add_argument("--image-model", default=None, help="override the @cf/... image model")
    ap.add_argument("--selftest", action="store_true", help="offline import + router check, no network")
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    rt = build_runtime(args.env, args.voice)
    img = CloudflareImage(model=args.image_model) if args.image_model else CloudflareImage()
    img_dir = pathlib.Path(args.env).resolve().parent / "_images"
    img_dir.mkdir(exist_ok=True)
    banner(rt)

    try:
        while True:
            if args.voice:
                wav = record_ptt()
                if not wav:
                    continue
                line = rt.stt.transcribe(wav, content_type="audio/wav")
                print(f">>> (heard) {line!r}")
            else:
                try:
                    line = input("\nyou> ")
                except EOFError:
                    break

            kind, payload = route(line)
            if kind == "quit":
                break

            if kind == "draw":
                stamp = time.strftime("%Y%m%d_%H%M%S")
                out = str(img_dir / f"jarvis_{stamp}.jpg")     # flux returns JPEG bytes
                print(f"[draw] -> Cloudflare Workers AI ({img.model}): {payload!r}")
                try:
                    img.save_image(payload, out)
                    print(f"[draw] saved: {out}")
                    open_file(out)
                except Exception as e:
                    print(f"[draw] failed: {type(e).__name__} - {str(e)[:200]}")
                continue

            # think
            spk = None
            if args.voice and rt.tts:
                spk = str(pathlib.Path(tempfile.gettempdir()) / "jarvis_say.wav")
            try:
                r = rt.turn(user_text=payload, speak_to=spk)
            except Exception as e:
                print(f"[think] turn failed: {type(e).__name__} - {str(e)[:200]}")
                continue
            drift = r.get("drift_to_prototype")
            tag = f"{r['model']}" + (f", drift→proto {drift:.3f}" if isinstance(drift, float) else "")
            print(f"\nJARVIS ({tag}):\n  " + r["reply"].replace("\n", "\n  "))
            if spk and r.get("wav"):
                play_wav(r["wav"])
    finally:
        rt.close()
        print("\n[shutdown] graph closed.")


# ----- offline self-test (no network, no audio hardware) -----
def _selftest():
    ok = True
    cases = [
        ("/draw a cyberpunk lizard", ("draw", "a cyberpunk lizard")),
        ("/image  arc reactor core ", ("draw", "arc reactor core")),
        ("draw me the New York skyline", ("draw", "the New York skyline")),
        ("generate an image of a falcon", ("draw", "a falcon")),
        ("make a picture of rain", ("draw", "rain")),
        ("jarvis, render an image of a circuit", ("draw", "a circuit")),
        ("paint a storm over the gulf", ("draw", "a storm over the gulf")),
        ("what is the battle of new york?", ("think", "what is the battle of new york?")),
        ("quit", ("quit", None)),
        ("  ", ("think", "")),
    ]
    for line, want in cases:
        got = route(line)
        status = "OK" if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"[route] {line!r:48} -> {got}  {status}")
    # imports resolve (organs constructable without creds/network)
    try:
        CloudflareImage(account_id="x", api_token="y")
        import jarvis_loop, model_ollama  # noqa
        print("[import] organs + core import: OK")
    except Exception as e:
        ok = False
        print(f"[import] FAIL: {type(e).__name__} - {e}")
    print("OFFLINE SELF-TEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
