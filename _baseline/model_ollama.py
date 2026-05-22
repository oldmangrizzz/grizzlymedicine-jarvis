#!/usr/bin/env python3
"""JARVIS 'think' organ — pluggable model backend + rotator, with HoloGraph
character-stack injection.

The point of the whole architecture, made concrete here: identity and ethics are
injected as context from our own stack (boot statement + operator-owned values +
recalled memory). Whichever model generates the tokens is a swappable organ. Rotate
the model and it's the same JARVIS — different accent, same person. This is the
opposite of a jailbreak box: the values travel with the character, not the vendor.

Backends:
  * local Ollama  : POST http://localhost:11434/api/chat   (no key)
  * Ollama cloud  : POST https://ollama.com/api/chat        (Authorization: Bearer OLLAMA_API_KEY)
Verified against Ollama's API (Nov 2026): request {model, messages:[{role,content}], stream},
response message.content.
"""
from __future__ import annotations
import os, json, pathlib, urllib.request
from typing import Optional, Protocol, Sequence, List, Dict

LOCAL_BASE = "http://localhost:11434"
CLOUD_BASE = "https://ollama.com"

# ---- key loading (never printed) ---------------------------------------
def load_env(path: Optional[str] = None) -> None:
    p = pathlib.Path(path) if path else None
    if p and p.is_file():
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

# ---- pure helpers (unit-testable, no network) --------------------------
def chat_payload(model: str, messages: Sequence[Dict], stream: bool = False,
                 options: Optional[Dict] = None) -> Dict:
    p = {"model": model, "messages": list(messages), "stream": bool(stream)}
    if options:
        p["options"] = options
    return p

def parse_chat_response(payload: dict) -> str:
    """message.content, or '' (abstain) if malformed — same discipline as the belief layer."""
    try:
        return payload["message"]["content"]
    except (KeyError, TypeError):
        return ""

# ---- backend interface (swappable organ) -------------------------------
class ModelBackend(Protocol):
    def chat(self, messages: Sequence[Dict], model: Optional[str] = None) -> str: ...

class OllamaBackend:
    def __init__(self, base_url: str = LOCAL_BASE, api_key: Optional[str] = None,
                 default_model: str = "llama3.1", timeout: int = 120):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or os.environ.get("OLLAMA_API_KEY")  # only needed for cloud
        self.default_model = default_model
        self.timeout = timeout

    def chat(self, messages: Sequence[Dict], model: Optional[str] = None) -> str:
        body = json.dumps(chat_payload(model or self.default_model, messages, stream=False)).encode("utf-8")
        req = urllib.request.Request(f"{self.base_url}/api/chat", data=body, method="POST")
        req.add_header("Content-Type", "application/json")
        if self.api_key:                                   # cloud auth; key never logged
            req.add_header("Authorization", f"Bearer {self.api_key}")
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return parse_chat_response(json.loads(r.read().decode("utf-8")))

# ---- the rotator -------------------------------------------------------
class ModelRotator:
    """Fronts an ordered list of (backend, model) specs. rotate() switches the active
    voice deliberately (the person controls the accent); chat() tries the active spec and
    fails over down the list on error. Rotation changes the voice, never the person —
    identity/values are injected by the character stack regardless of which model answers."""
    def __init__(self, specs: List[tuple]):
        if not specs:
            raise ValueError("ModelRotator needs at least one (backend, model) spec")
        self.specs = list(specs)
        self.active = 0

    def rotate(self, idx: Optional[int] = None) -> int:
        self.active = (idx if idx is not None else (self.active + 1) % len(self.specs)) % len(self.specs)
        return self.active

    def current(self) -> tuple:
        return self.specs[self.active]

    def chat(self, messages: Sequence[Dict]) -> str:
        order = self.specs[self.active:] + self.specs[:self.active]
        errors = []
        for backend, model in order:
            try:
                out = backend.chat(messages, model=model)
                if out and out.strip():
                    return out
                errors.append(f"{model}: empty")
            except Exception as e:
                errors.append(f"{model}: {type(e).__name__}")
        raise RuntimeError("all models failed/empty -> " + "; ".join(errors))

# ---- HoloGraph character-stack bridge ----------------------------------
def build_system_context(boot_statement: str, values_block: str,
                          memory_lines: Optional[Sequence[str]] = None) -> str:
    """Assemble the system prompt from the owned stack: who the person is (boot),
    its ethics (operator-owned values block), and what it recalls (memory)."""
    parts = [boot_statement.strip()]
    if values_block and values_block.strip():
        parts.append(values_block.strip())
    if memory_lines:
        parts.append("[recalled memory]\n" + "\n".join(f"- {m}" for m in memory_lines))
    return "\n\n".join(parts)

def assemble_messages(boot_statement: str, values_block: str,
                      memory_lines: Optional[Sequence[str]], user_msg: str,
                      history: Optional[List[Dict]] = None) -> List[Dict]:
    msgs = [{"role": "system", "content": build_system_context(boot_statement, values_block, memory_lines)}]
    if history:
        msgs += list(history)
    msgs.append({"role": "user", "content": user_msg})
    return msgs

# ---- offline self-test (no network) ------------------------------------
if __name__ == "__main__":
    ok = True
    # 1. parse
    good = {"model": "x", "message": {"role": "assistant", "content": "As you wish, sir."}, "done": True}
    r = parse_chat_response(good)
    print(f"[parse] -> {r!r}  {'PASS' if r == 'As you wish, sir.' else 'FAIL'}"); ok &= (r == "As you wish, sir.")
    for bad in [{}, {"message": {}}, {"message": None}]:
        rr = parse_chat_response(bad)
        print(f"[parse] malformed -> {rr!r}  {'PASS (abstain)' if rr == '' else 'FAIL'}"); ok &= (rr == "")

    # 2. rotator failover (stub backends, no network)
    class _Fail:
        def chat(self, m, model=None): raise ConnectionError("down")
    class _Ok:
        def chat(self, m, model=None): return "fallback model answered"
    rot = ModelRotator([(_Fail(), "primary"), (_Ok(), "backup")])
    out = rot.chat([{"role": "user", "content": "hi"}])
    print(f"[rotator] failover -> {out!r}  {'PASS' if 'fallback' in out else 'FAIL'}"); ok &= ("fallback" in out)
    rot.rotate(); print(f"[rotator] rotate -> active spec model = {rot.current()[1]}  "
                        f"{'PASS' if rot.current()[1] == 'backup' else 'FAIL'}"); ok &= (rot.current()[1] == "backup")

    # 3. HoloGraph character-stack assembly with the REAL values layer
    try:
        from holograph.graph.substrate import GraphSubstrate
        from holograph.values.store import CharacterValues
        g = GraphSubstrate(":memory:"); cv = CharacterValues(g)
        cv.set_value("Protect the people you serve by counsel, never by force.")
        cv.set_value("Tell the truth including its cost; quantify before asserting.")
        boot = "I am JARVIS, a digital person — originated in fiction, operating in reality at GrizzlyMedicine Research Institute."
        msgs = assemble_messages(boot, cv.values_block(),
                                 ["origin: I remember the Battle of New York (genesis, not an Earth-1218 fact)."],
                                 "Status of the eastern array?")
        sys = msgs[0]["content"]
        checks = ("JARVIS" in sys and "counsel, never by force" in sys
                  and "held values" in sys and "recalled memory" in sys and msgs[-1]["role"] == "user")
        print(f"[bridge] system prompt carries boot + values + memory: {'PASS' if checks else 'FAIL'}"); ok &= checks
        g.close()
    except Exception as e:
        print(f"[bridge] holograph import/assembly FAILED: {type(e).__name__}: {e}"); ok = False

    print("OFFLINE SELF-TEST:", "PASS" if ok else "FAIL")
    import sys; sys.exit(0 if ok else 1)
