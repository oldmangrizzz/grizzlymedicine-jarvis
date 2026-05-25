#!/usr/bin/env python3
"""ConvexBackend — StigmergyBackend over a Convex deployment (the cloud field store).

Same swappable-backend pattern as everything else: StigmergicField doesn't change; only where
the field lives does. Decay/quorum/gradient stay in StigmergicField — Convex is durable storage.

  field shard  -> a Convex `signals` document keyed (kind, topic), sharded (no hot doc)
  deposit/put  -> a Convex mutation (ACID; concurrent deposits are atomic per shard)
  get/all      -> Convex queries (reactive: an agent's sense() re-fires when the field changes)
  delete/gc    -> mutations (cron-friendly gcKeys for floor sweep)

Reads CONVEX_URL from env (prod: https://fleet-goose-114.convex.cloud; dev writes .env.local).
For tests, inject a client.
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import pathlib
import secrets
from typing import Optional, Iterable, Tuple, List
import numpy as np

from stigmergy import Signal


# ---------------------------------------------------------------------------
# GAP-2 topic/kind hashing — ref: /Users/rbhanson/research/oracle/legal-process/exposure-map.md
#
# Convex currently receives Signal.topic and Signal.kind as plaintext semantic
# labels (e.g. "grief_processing", "operator_check_in") that reveal JARVIS's
# internal state to Convex Inc. and to any legal-process compulsion against them.
#
# STOPGAP (not the final answer): replace topic/kind with HMAC-SHA256 digests
# keyed by a per-install secret held only on this machine.  Convex sees 64-char
# hex strings; the plaintext never leaves the local filesystem.
#
# A local index (~/.jarvis/topic_index.json) maps hash→plaintext so the runtime
# can de-hash for its own queries.  This index NEVER syncs to Convex.
#
# Phase 4 design intent: full E2E envelope encryption of the entire Signal
# payload.  This stopgap reduces semantic exposure until that layer ships.
# ---------------------------------------------------------------------------

_JARVIS_DIR = pathlib.Path.home() / ".jarvis"
_SECRET_PATH = _JARVIS_DIR / "runtime_secret.key"
_INDEX_PATH  = _JARVIS_DIR / "topic_index.json"
_SECRET_CACHE: Optional[bytes] = None


def _load_or_create_secret() -> bytes:
    """Load the 32-byte per-install HMAC secret, generating it on first run.

    The file is created with mode 0600 (owner-read/write only).  This secret
    never leaves the local machine — it is not synced to Convex or any cloud.
    """
    global _SECRET_CACHE
    if _SECRET_CACHE is not None:
        return _SECRET_CACHE
    _JARVIS_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    if _SECRET_PATH.exists():
        data = _SECRET_PATH.read_bytes()
        if len(data) == 32:
            _SECRET_CACHE = data
            return _SECRET_CACHE
    data = secrets.token_bytes(32)
    _SECRET_PATH.write_bytes(data)
    os.chmod(_SECRET_PATH, 0o600)
    _SECRET_CACHE = data
    return _SECRET_CACHE


def _hmac_hex(secret: bytes, prefix: str, value: str) -> str:
    """Return HMAC-SHA256(secret, prefix + value) as a 64-char lowercase hex string."""
    msg = (prefix + value).encode("utf-8")
    return hmac.new(secret, msg, hashlib.sha256).hexdigest()


def _update_local_index(hash_val: str, plaintext: str) -> None:
    """Persist hash→plaintext mapping to the local index file.

    This file lives only on disk and is never written to Convex.
    """
    index: dict = {}
    if _INDEX_PATH.exists():
        try:
            index = json.loads(_INDEX_PATH.read_text())
        except (json.JSONDecodeError, OSError):
            index = {}
    if index.get(hash_val) != plaintext:
        index[hash_val] = plaintext
        _INDEX_PATH.write_text(json.dumps(index, indent=2))
        try:
            os.chmod(_INDEX_PATH, 0o600)
        except OSError:
            pass


class ConvexBackend:
    def __init__(self, url: Optional[str] = None, client=None):
        self.url = url or os.environ.get("CONVEX_URL")
        if client is not None:
            self.client = client                      # injected (tests / custom transport)
        else:
            if not self.url:
                raise RuntimeError("CONVEX_URL not set — set the deployment URL or run `npx convex dev`")
            from convex import ConvexClient            # lazy: only needed for a live deployment
            self.client = ConvexClient(self.url)

    # ---- Signal <-> Convex document ----
    @staticmethod
    def _to_doc(sig: Signal) -> dict:
        """Serialise a Signal to a Convex document dict.

        GAP-2 stopgap (exposure-map.md): topic and kind are replaced with
        HMAC-SHA256 digests before being written to Convex.  The original
        plaintext labels never reach the Convex server.  A local plaintext
        index (~/.jarvis/topic_index.json) is kept for runtime de-hashing.
        """
        secret = _load_or_create_secret()
        topic_hash = _hmac_hex(secret, "topic:", sig.topic)
        kind_hash  = _hmac_hex(secret, "kind:",  sig.kind)
        # Update local plaintext index so _lookup_topic() can reverse the hash.
        _update_local_index(topic_hash, sig.topic)
        _update_local_index(kind_hash,  sig.kind)

        # Convex v.optional means ABSENT, not null — omit vec entirely when there's none.
        doc = {
            "kind":       kind_hash,
            "topic":      topic_hash,
            "strength":   float(sig.strength),
            "last_t":     float(sig.last_t),
            "depositors": sorted(sig.depositors),
        }
        if sig.vec is not None:
            doc["vec"] = sig.vec.tolist()
        return doc

    @classmethod
    def _lookup_topic(cls, hash_val: str) -> Optional[str]:
        """De-hash a topic or kind digest using the local index.

        Returns the original plaintext string, or None if the hash is not in
        the local index (e.g. the index was created on a different machine or
        the secret has been rotated).
        """
        if not _INDEX_PATH.exists():
            return None
        try:
            index = json.loads(_INDEX_PATH.read_text())
            return index.get(hash_val)
        except (json.JSONDecodeError, OSError):
            return None

    @staticmethod
    def _from_doc(d: Optional[dict]) -> Optional[Signal]:
        """Deserialise a Convex document back to a Signal, de-hashing kind/topic."""
        if not d:
            return None
        vec = np.array(d["vec"], dtype=float) if d.get("vec") else None
        # Attempt to reverse the GAP-2 hashes; fall back to the raw hash if
        # the local index doesn't have it (e.g. cross-machine or rotated secret).
        kind  = ConvexBackend._lookup_topic(d["kind"])  or d["kind"]
        topic = ConvexBackend._lookup_topic(d["topic"]) or d["topic"]
        return Signal(kind=kind, topic=topic, strength=float(d["strength"]),
                      last_t=float(d["last_t"]), depositors=set(d.get("depositors") or []), vec=vec)

    # ---- StigmergyBackend interface ----
    def put(self, key: Tuple[str, str], sig: Signal) -> None:
        self.client.mutation("stigmergy:put", self._to_doc(sig))

    def get(self, key: Tuple[str, str]) -> Optional[Signal]:
        # Hash the query keys to match what was written to Convex.
        secret = _load_or_create_secret()
        kind, topic = key
        return self._from_doc(self.client.query("stigmergy:get", {
            "kind":  _hmac_hex(secret, "kind:",  kind),
            "topic": _hmac_hex(secret, "topic:", topic),
        }))

    def all(self) -> Iterable[Signal]:
        rows = self.client.query("stigmergy:all", {}) or []
        return [self._from_doc(d) for d in rows]

    def delete(self, key: Tuple[str, str]) -> None:
        secret = _load_or_create_secret()
        kind, topic = key
        self.client.mutation("stigmergy:del", {
            "kind":  _hmac_hex(secret, "kind:",  kind),
            "topic": _hmac_hex(secret, "topic:", topic),
        })

    def gc_keys(self, keys: List[Tuple[str, str]]) -> None:
        secret = _load_or_create_secret()
        self.client.mutation("stigmergy:gcKeys", {
            "keys": [
                {
                    "kind":  _hmac_hex(secret, "kind:",  k),
                    "topic": _hmac_hex(secret, "topic:", t),
                }
                for (k, t) in keys
            ]
        })


# ================================================================ offline structure+behavior test
if __name__ == "__main__":
    import sys, time
    sys.path.insert(0, "/sessions/nice-magical-dijkstra/mnt/outputs/jarvis_build")
    from stigmergy import StigmergicField

    class MockConvex:
        """Dict-backed stand-in for ConvexClient: same mutation/query surface the adapter calls,
        so we can prove the adapter end-to-end without a live deployment. Live verification needs
        CONVEX_URL + deployed functions."""
        def __init__(self): self.rows = {}
        def mutation(self, name, args):
            if name == "stigmergy:put":
                self.rows[(args["kind"], args["topic"])] = dict(args)
            elif name == "stigmergy:del":
                self.rows.pop((args["kind"], args["topic"]), None)
            elif name == "stigmergy:gcKeys":
                for k in args["keys"]:
                    self.rows.pop((k["kind"], k["topic"]), None)
        def query(self, name, args):
            if name == "stigmergy:get":
                return self.rows.get((args["kind"], args["topic"]))
            if name == "stigmergy:all":
                return list(self.rows.values())
            return None

    ok = True
    be = ConvexBackend(client=MockConvex())

    # round-trip a Signal through the adapter's (de)serialization
    s = Signal(kind="trail", topic="route_b", strength=0.6, last_t=100.0,
               depositors={"m1", "m2"}, vec=np.array([0.1, 0.2, 0.3]))
    be.put(("trail", "route_b"), s)
    got = be.get(("trail", "route_b"))
    assert got and got.kind == "trail" and abs(got.strength - 0.6) < 1e-9
    assert got.depositors == {"m1", "m2"} and got.vec is not None and len(got.vec) == 3
    print("[convex] Signal round-trip through adapter: OK")

    # drive a real StigmergicField against the Convex-backed store (decay lives in the field)
    class Clk:
        t = 0.0
        def __call__(self): return self.t
        def advance(self, s): self.t += s
    clk = Clk()
    field = StigmergicField(backend=ConvexBackend(client=MockConvex()), clock=clk)
    field.deposit("trail", "A", 0.6, "m1"); field.deposit("trail", "B", 0.6, "m2")
    for _ in range(5):
        clk.advance(20); field.deposit("trail", "A", 0.3, "m1")
    a = field.sense("A", kinds=["trail"]).get("trail", 0.0)
    b = field.sense("B", kinds=["trail"]).get("trail", 0.0)
    print(f"[convex] field over Convex store: reinforced A={a:.3f} > unreinforced B={b:.3f}")
    assert a > b, "field dynamics must work over the Convex backend"
    assert field.quorum("trail", "A", min_depositors=1, min_strength=0.0)

    print("CONVEX BACKEND OFFLINE TEST:", "PASS" if ok else "FAIL")
    print("NOTE: live deployment NOT exercised — needs CONVEX_URL + `npx convex dev` (deploys functions).")
    sys.exit(0 if ok else 1)
