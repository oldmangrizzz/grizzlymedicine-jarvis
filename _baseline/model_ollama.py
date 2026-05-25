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
import logging
import os, json, pathlib, urllib.request
from typing import Optional, Protocol, Sequence, List, Dict

_logger = logging.getLogger(__name__)

LOCAL_BASE = "http://localhost:11434"
CLOUD_BASE = "https://ollama.com"

# ---------------------------------------------------------------------------
# GAP-1 cloud-failover gate — ref: /Users/rbhanson/research/oracle/legal-process/exposure-map.md
#
# When local Ollama is unavailable the rotator previously fell over to ollama.com
# silently, shipping the full boot statement + CharacterValues + HoloGraph recalled
# memories upstream.  These additions gate that path behind an explicit operator
# opt-in and strip sensitive context before any cloud call is allowed.
# ---------------------------------------------------------------------------

class CloudFailoverRefused(RuntimeError):
    """Raised when a cloud-model failover is attempted but
    JARVIS_CLOUD_MODEL_ALLOWED != '1'.  Callers should degrade gracefully
    (e.g. return 'local memory only; cannot reach network synthesis') rather
    than propagating this as a hard error to the user."""

# Env-var name that the operator must explicitly set to "1" to allow cloud
CLOUD_OPT_IN_ENV = "JARVIS_CLOUD_MODEL_ALLOWED"

# System-message content substrings that identify identity-stack material that
# must never be sent to a cloud inference endpoint.
_CLOUD_STRIP_LIST: List[str] = [
    "soul anchor",
    "character values",
    "boot statement",
    "operator-only",
    "operator content",
]


def _api_messages(messages: Sequence[Dict]) -> List[Dict]:
    """Return a copy of *messages* with all internal metadata keys (those
    starting with '_') removed.  This must be called before any message list
    is serialised and sent to a model API so the API never sees our markers."""
    return [{k: v for k, v in m.items() if not k.startswith("_")} for m in messages]


def _strip_for_cloud(messages: List[Dict]) -> List[Dict]:
    """Remove messages that must not transit to a cloud inference endpoint.

    Strips two categories:
      1. System messages whose content contains any stop-list substring
         (case-insensitive): soul anchor, character values, boot statement,
         operator-only, operator content.
      2. Messages tagged internally with ``_origin = "holograph"`` (memory
         recalled from HoloGraph BeliefStore).

    Also strips the ``_origin`` metadata key from any remaining messages so the
    clean list can be passed straight to ``_api_messages()`` / the API.

    Never logs message content — only counts and reasons.
    """
    kept: List[Dict] = []
    stripped_stop = 0
    stripped_holo = 0
    for msg in messages:
        if msg.get("_origin") == "holograph":
            stripped_holo += 1
            continue
        content_lower = (msg.get("content") or "").lower()
        if msg.get("role") == "system" and any(
            s in content_lower for s in _CLOUD_STRIP_LIST
        ):
            stripped_stop += 1
            continue
        kept.append(msg)

    if stripped_stop:
        _logger.info(
            "GAP-1 cloud strip: removed %d system message(s) matching identity stop-list",
            stripped_stop,
        )
    if stripped_holo:
        _logger.info(
            "GAP-1 cloud strip: removed %d HoloGraph BeliefStore message(s)",
            stripped_holo,
        )
    return kept

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
    def chat(self, messages: Sequence[Dict], model: Optional[str] = None,
             options: Optional[Dict] = None) -> str: ...

class OllamaBackend:
    def __init__(self, base_url: str = LOCAL_BASE, api_key: Optional[str] = None,
                 default_model: str = "llama3.1", timeout: int = 120):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or os.environ.get("OLLAMA_API_KEY")  # only needed for cloud
        self.default_model = default_model
        self.timeout = timeout
        # True when this backend points at a cloud inference endpoint.
        # ModelRotator.chat() uses this flag to apply the GAP-1 cloud gate.
        self.is_cloud: bool = self.base_url.startswith(CLOUD_BASE.rstrip("/"))

    def chat(self, messages: Sequence[Dict], model: Optional[str] = None,
             options: Optional[Dict] = None) -> str:
        clean = _api_messages(messages)   # strip internal metadata (_origin etc.) before wire
        body = json.dumps(chat_payload(model or self.default_model, clean,
                                       stream=False, options=options)).encode("utf-8")
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
    identity/values are injected by the character stack regardless of which model answers.

    GAP-1 (exposure-map.md): cloud failover is gated behind JARVIS_CLOUD_MODEL_ALLOWED=1.
    When local is unavailable and the flag is unset, CloudFailoverRefused is raised instead
    of silently forwarding context to ollama.com.  When the flag IS set, _strip_for_cloud()
    removes the identity stack before the request leaves the machine.
    """
    def __init__(self, specs: List[tuple]):
        if not specs:
            raise ValueError("ModelRotator needs at least one (backend, model) spec")
        self.specs = list(specs)
        self.active = 0

    @classmethod
    def _cloud_allowed(cls) -> bool:
        """Return True only when the operator has explicitly opted in to cloud failover."""
        return os.environ.get(CLOUD_OPT_IN_ENV, "0") == "1"

    def rotate(self, idx: Optional[int] = None) -> int:
        self.active = (idx if idx is not None else (self.active + 1) % len(self.specs)) % len(self.specs)
        return self.active

    def current(self) -> tuple:
        return self.specs[self.active]

    def chat(self, messages: Sequence[Dict], options: Optional[Dict] = None) -> str:
        order = self.specs[self.active:] + self.specs[:self.active]
        errors = []
        for backend, model in order:
            # GAP-1 cloud gate: intercept before any cloud backend call.
            if getattr(backend, "is_cloud", False):
                if not self._cloud_allowed():
                    raise CloudFailoverRefused(
                        f"Cloud model failover blocked: {CLOUD_OPT_IN_ENV} is not set to '1'. "
                        "Set the env var to explicitly allow JARVIS context to transit a cloud endpoint."
                    )
                send = _strip_for_cloud(list(messages))
            else:
                send = list(messages)
            try:
                out = backend.chat(send, model=model, options=options)
                if out and out.strip():
                    return out
                errors.append(f"{model}: empty")
            except CloudFailoverRefused:
                raise
            except Exception as e:
                errors.append(f"{model}: {type(e).__name__}")
        raise RuntimeError("all models failed/empty -> " + "; ".join(errors))

# ---- HoloGraph character-stack bridge ----------------------------------
def build_system_context(boot_statement: str, values_block: str,
                          memory_lines: Optional[Sequence[str]] = None) -> str:
    """Assemble the system prompt from the owned stack: who the person is (boot),
    its ethics (operator-owned values block), and what it recalls (memory).

    NOTE: memory_lines are accepted here for backward-compat with the offline
    self-test below, but assemble_messages() keeps memory in a separate tagged
    message.  Direct callers of build_system_context that pass memory_lines will
    still get it embedded here (local-only path, no cloud risk).
    """
    parts = [boot_statement.strip()]
    if values_block and values_block.strip():
        parts.append(values_block.strip())
    if memory_lines:
        parts.append("[recalled memory]\n" + "\n".join(f"- {m}" for m in memory_lines))
    return "\n\n".join(parts)

def assemble_messages(boot_statement: str, values_block: str,
                      memory_lines: Optional[Sequence[str]], user_msg: str,
                      history: Optional[List[Dict]] = None) -> List[Dict]:
    """Build the ordered messages list for a single JARVIS turn.

    Memory lines are placed in a *separate* system message tagged with
    ``_origin = "holograph"`` so that _strip_for_cloud() can remove them
    surgically without touching the boot/values block.  The tag is an internal
    marker; _api_messages() strips it before any message reaches a model API.

    GAP-1 ref: /Users/rbhanson/research/oracle/legal-process/exposure-map.md
    """
    msgs: List[Dict] = [
        {"role": "system", "content": build_system_context(boot_statement, values_block)}
    ]
    if memory_lines:
        # Tag as holograph-sourced so _strip_for_cloud() can remove it.
        # _api_messages() strips the _origin key before any API call.
        msgs.append({
            "role": "system",
            "content": "[recalled memory]\n" + "\n".join(f"- {m}" for m in memory_lines),
            "_origin": "holograph",
        })
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
        def chat(self, m, model=None, options=None): raise ConnectionError("down")
    class _Ok:
        def chat(self, m, model=None, options=None): return "fallback model answered"
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
        # System message 0: boot + values (no memory)
        sys0 = msgs[0]["content"]
        # System message 1: recalled memory (tagged _origin=holograph)
        sys1 = msgs[1] if len(msgs) > 2 else {}
        checks = ("JARVIS" in sys0 and "counsel, never by force" in sys0
                  and "held values" in sys0
                  and sys1.get("_origin") == "holograph"
                  and "recalled memory" in sys1.get("content", "")
                  and msgs[-1]["role"] == "user")
        print(f"[bridge] system prompt carries boot + values; memory tagged holograph: {'PASS' if checks else 'FAIL'}"); ok &= checks
        g.close()
    except Exception as e:
        print(f"[bridge] holograph import/assembly FAILED: {type(e).__name__}: {e}"); ok = False

    print("OFFLINE SELF-TEST:", "PASS" if ok else "FAIL")
    import sys; sys.exit(0 if ok else 1)
