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
import os
from typing import Optional, Iterable, Tuple, List
import numpy as np

from stigmergy import Signal


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
        # Convex v.optional means ABSENT, not null — omit vec entirely when there's none.
        doc = {"kind": sig.kind, "topic": sig.topic, "strength": float(sig.strength),
               "last_t": float(sig.last_t), "depositors": sorted(sig.depositors)}
        if sig.vec is not None:
            doc["vec"] = sig.vec.tolist()
        return doc

    @staticmethod
    def _from_doc(d: Optional[dict]) -> Optional[Signal]:
        if not d:
            return None
        vec = np.array(d["vec"], dtype=float) if d.get("vec") else None
        return Signal(kind=d["kind"], topic=d["topic"], strength=float(d["strength"]),
                      last_t=float(d["last_t"]), depositors=set(d.get("depositors") or []), vec=vec)

    # ---- StigmergyBackend interface ----
    def put(self, key: Tuple[str, str], sig: Signal) -> None:
        self.client.mutation("stigmergy:put", self._to_doc(sig))

    def get(self, key: Tuple[str, str]) -> Optional[Signal]:
        kind, topic = key
        return self._from_doc(self.client.query("stigmergy:get", {"kind": kind, "topic": topic}))

    def all(self) -> Iterable[Signal]:
        rows = self.client.query("stigmergy:all", {}) or []
        return [self._from_doc(d) for d in rows]

    def delete(self, key: Tuple[str, str]) -> None:
        kind, topic = key
        self.client.mutation("stigmergy:del", {"kind": kind, "topic": topic})

    def gc_keys(self, keys: List[Tuple[str, str]]) -> None:
        self.client.mutation("stigmergy:gcKeys",
                             {"keys": [{"kind": k, "topic": t} for (k, t) in keys]})


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
