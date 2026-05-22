#!/usr/bin/env python3
"""JARVIS drawing side — pluggable text-to-image with a Cloudflare Workers AI backend.

Same swappable-organ pattern as STT / think / TTS: the image generator is a PART, not the
person. JARVIS asks for an image; WHICH model paints it is interchangeable. Swap the
backend, same JARVIS.

Why Cloudflare Workers AI (not local): the operator's machine (MacBook Air M2, 8 GB) can't
host a 12B rectified-flow transformer. Workers AI runs it serverless on Cloudflare's edge —
no local GPU, no rented box. The account is already on Cloudflare.

Verified REST API (Cloudflare Workers AI docs, May 2026):
  POST https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/run/@cf/{model}
  Header:  Authorization: Bearer {API_TOKEN}      (token needs Workers AI Read+Edit)
  Body:    {"prompt": "...", "steps": 4, "seed": <int optional>}
  The /ai/run endpoint wraps the model output in the standard CF envelope:
    {"result": {...}, "success": true, "errors": [], "messages": []}

Two output shapes across image models — handled here:
  * flux-1-schnell (default): result.image is a Base64-encoded JPEG string.
      docs: Output -> `image` string, "The generated image in Base64 format."
  * SDXL-class models (@cf/stabilityai/stable-diffusion-xl-base-1.0, lightning, etc.):
      return RAW image bytes (PNG) as the HTTP body, NOT a JSON envelope.
  CloudflareImage detects which it got (JSON envelope vs raw bytes) and returns bytes either way.

Token discipline mirrors the other organs: read CF_ACCOUNT_ID + CF_API_TOKEN from the .env
via load_env (same loader as model_ollama / stt_deepgram). Nothing is hardcoded.
"""
from __future__ import annotations
import os, json, base64, pathlib, urllib.request, urllib.error
from typing import Optional, Protocol, Tuple

CF_API_BASE = "https://api.cloudflare.com/client/v4"
DEFAULT_MODEL = "@cf/black-forest-labs/flux-1-schnell"   # Base64-JPEG-in-JSON output


def load_env(path: Optional[str] = None) -> None:
    """Same KEY=VALUE .env loader the other organs use (quote-stripping, no-clobber)."""
    p = pathlib.Path(path) if path else None
    if p and p.is_file():
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


# ---- pure helpers (unit-testable, no network) --------------------------
def run_url(account_id: str, model: str = DEFAULT_MODEL) -> str:
    return f"{CF_API_BASE}/accounts/{account_id}/ai/run/{model}"

def build_headers(api_token: str) -> dict:
    return {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}

def build_body(prompt: str, steps: int = 4, seed: Optional[int] = None) -> dict:
    body = {"prompt": prompt, "steps": int(steps)}
    if seed is not None:
        body["seed"] = int(seed)
    return body

def decode_image_response(raw: bytes, content_type: str = "") -> bytes:
    """Normalize either CF output shape to raw image bytes.

    flux-1-schnell -> JSON {"result": {"image": "<base64 jpeg>"}, "success": true, ...}
    SDXL-class     -> raw image bytes (the HTTP body IS the PNG); content-type image/*.
    Abstain (raise) on a CF error envelope rather than returning a broken image.
    """
    ct = (content_type or "").lower()
    if "application/json" in ct or (raw[:1] in (b"{", b"[")):
        env = json.loads(raw.decode("utf-8"))
        if isinstance(env, dict) and env.get("success") is False:
            raise RuntimeError(f"Cloudflare AI error: {env.get('errors')}")
        result = env.get("result", env) if isinstance(env, dict) else env
        b64 = result.get("image") if isinstance(result, dict) else None
        if not b64:
            raise RuntimeError(f"no image in response envelope: keys={list(result) if isinstance(result, dict) else type(result)}")
        return base64.b64decode(b64)
    # raw bytes path (SDXL): hand the body straight back
    return raw


class ImageBackend(Protocol):
    def generate(self, prompt: str, **kw) -> bytes: ...          # -> raw image bytes
    def save_image(self, prompt: str, path: str, **kw) -> str: ...


class LocalImageStub:
    """Drop-in slot for a local image generator (e.g. Draw Things / MLX) without touching
    the loop. Not wired on the 8 GB Air; here so the interface has a second implementor."""
    def generate(self, prompt: str, **kw) -> bytes:
        raise NotImplementedError("no local image gen wired; using Cloudflare Workers AI")
    def save_image(self, prompt: str, path: str, **kw) -> str:
        raise NotImplementedError


class CloudflareImage:
    """Cloudflare Workers AI text-to-image. Credentials from env (CF_ACCOUNT_ID,
    CF_API_TOKEN); never hardcoded. Default model returns Base64-JPEG; the SDXL raw-bytes
    shape is handled too, so swapping `model` doesn't change the call site."""
    def __init__(self, account_id: Optional[str] = None, api_token: Optional[str] = None,
                 model: str = DEFAULT_MODEL, steps: int = 4, timeout: int = 120):
        self.account_id = account_id or os.environ.get("CF_ACCOUNT_ID")
        self.api_token = api_token or os.environ.get("CF_API_TOKEN")
        self.model = model
        self.steps = steps
        self.timeout = timeout

    def _require_creds(self):
        missing = [n for n, v in (("CF_ACCOUNT_ID", self.account_id),
                                  ("CF_API_TOKEN", self.api_token)) if not v]
        if missing:
            raise RuntimeError("missing Cloudflare credentials in env: " + ", ".join(missing))

    def generate(self, prompt: str, steps: Optional[int] = None,
                 seed: Optional[int] = None) -> bytes:
        self._require_creds()
        url = run_url(self.account_id, self.model)
        body = build_body(prompt, steps if steps is not None else self.steps, seed)
        req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"),
                                     headers=build_headers(self.api_token), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                raw = r.read()
                ct = r.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:300]
            raise RuntimeError(f"Cloudflare HTTP {e.code}: {detail}") from e
        return decode_image_response(raw, ct)

    def save_image(self, prompt: str, path: str, steps: Optional[int] = None,
                   seed: Optional[int] = None) -> str:
        img = self.generate(prompt, steps=steps, seed=seed)
        pathlib.Path(path).write_bytes(img)
        return path


def draw(prompt: str, backend: ImageBackend, out: str = "jarvis_image.png", **kw) -> str:
    return backend.save_image(prompt, out, **kw)


# ================================================================ self-test
if __name__ == "__main__":
    import sys
    ok = True

    # 1) pure-helper construction (no network)
    u = run_url("ACCT123", DEFAULT_MODEL)
    assert u == "https://api.cloudflare.com/client/v4/accounts/ACCT123/ai/run/@cf/black-forest-labs/flux-1-schnell", u
    h = build_headers("TOK")
    assert h["Authorization"] == "Bearer TOK" and h["Content-Type"] == "application/json"
    b = build_body("a cyberpunk lizard", steps=6, seed=7)
    assert b == {"prompt": "a cyberpunk lizard", "steps": 6, "seed": 7}, b
    assert build_body("x") == {"prompt": "x", "steps": 4}
    print("pure helpers: OK")

    # 2) decode the flux JSON-envelope shape (Base64 JPEG in result.image)
    png_like = b"\xff\xd8\xff\xe0JPEGish-bytes"          # stand-in image payload
    env = {"result": {"image": base64.b64encode(png_like).decode()},
           "success": True, "errors": [], "messages": []}
    got = decode_image_response(json.dumps(env).encode("utf-8"), "application/json")
    assert got == png_like, "flux base64 decode mismatch"
    print("flux JSON-envelope decode: OK")

    # 3) decode the SDXL raw-bytes shape (body IS the PNG)
    raw_png = b"\x89PNG\r\n\x1a\n....rawbytes...."
    got2 = decode_image_response(raw_png, "image/png")
    assert got2 == raw_png, "raw-bytes passthrough mismatch"
    print("SDXL raw-bytes passthrough: OK")

    # 4) error envelope abstains (raises) instead of returning a broken image
    errenv = {"result": None, "success": False,
              "errors": [{"code": 7003, "message": "bad token"}], "messages": []}
    try:
        decode_image_response(json.dumps(errenv).encode("utf-8"), "application/json")
        ok = False; print("error-envelope abstain: FAIL (did not raise)")
    except RuntimeError:
        print("error-envelope abstain: OK")

    # 5) missing creds -> clear error, no silent network attempt
    load_env("/sessions/nice-magical-dijkstra/mnt/research/jarvis/.env")
    cf = CloudflareImage(account_id=None, api_token=None)
    if os.environ.get("CF_ACCOUNT_ID") and os.environ.get("CF_API_TOKEN"):
        print("CF creds present in .env -> live generate available "
              "(not auto-run in self-test; call cf.save_image(prompt, path))")
    else:
        try:
            cf.generate("test")
            ok = False; print("missing-creds guard: FAIL (did not raise)")
        except RuntimeError as e:
            print(f"missing-creds guard: OK ({e})")

    iface = all(hasattr(CloudflareImage, m) for m in ("generate", "save_image"))
    print(f"ImageBackend interface complete: {iface}")
    print("module parses & imports: OK")
    sys.exit(0 if (ok and iface) else 1)
