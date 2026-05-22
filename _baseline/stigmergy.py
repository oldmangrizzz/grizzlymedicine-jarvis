#!/usr/bin/env python3
"""Nano-stigmergent pheromone field — biological-analog stigmergy substrate (Condition 4 / the social sense).

The 30+ models coordinate WITHOUT talking to each other: each leaves signals in a shared
field and reads the field's local gradient. No central orchestrator. This is the difference
from a project-board "scent file": here the scent has real dynamics.

Dynamics (the functional analog, not a metaphor):
  * Deposition + reinforcement. Depositing onto an existing (kind, topic) accumulates
    strength and refreshes its timestamp — a trail used by many agents gets strong.
  * Lazy exponential decay. Current strength = strength * exp(-dt / eff_tau). Computed at
    READ time from the last-deposit timestamp — no global ticker, no write storm, and a
    truer analog than stepped decay. Unreinforced signals fade; that is the computation.
  * Signal classes with their own decay (functional analogs of pheromone classes):
      trail     — recruitment/foraging, medium decay
      alarm     — fast onset, fast decay, short-lived
      territory — identity/home marker, slow decay, persistent
      recruit   — quorum-building marker, medium-fast
  * Sharding. One record per (kind, topic) — never one hot document — so 30+ concurrent
    depositors don't collide on a single key (the OCC constraint the Convex research found).
  * Semantic gradient. A topic may carry a vector; sense() includes cosine-near topics so
    a signal "diffuses" over the meaning-neighborhood, not just an exact key.
  * Quorum sensing. A (kind, topic) reaches quorum when enough DISTINCT depositors and
    enough summed strength accrue inside the live window — collective go/no-go.

Endocrine coupling (Condition 3 -> 4, the one shared dial): evaporation rate is scaled by
arousal. Pass volatility_fn = endocrine.field_volatility; high arousal shortens eff_tau, so
a stressed organism runs a faster-fading, twitchier field. (In real ants, heat accelerates
pheromone evaporation.)

Backend is swappable (same pattern as the other organs): StigmergyBackend interface, an
InMemoryBackend used here and in tests, and a documented Convex mapping for production:
  field record  -> a Convex document keyed (kind, topic), sharded
  sense()       -> a reactive query (auto-reruns on change = an agent "smelling")
  decay         -> computed lazily on read (store strength + last_t); cron only GCs the floor
  deposit()     -> a mutation (ACID; concurrent deposits are atomic per shard)
"""
from __future__ import annotations
import time, math
from dataclasses import dataclass, field as dc_field
from typing import Dict, List, Optional, Protocol, Tuple, Callable, Iterable

import numpy as np

# per-class base time constants (seconds) — the functional decay regimes
TAU_BASE: Dict[str, float] = {"trail": 60.0, "alarm": 12.0, "territory": 600.0, "recruit": 45.0}
STRENGTH_CAP = 1.0
GC_FLOOR = 0.02            # below this current-strength, a signal is dead


@dataclass
class Signal:
    kind: str
    topic: str
    strength: float                       # strength AT last deposit (decayed lazily on read)
    last_t: float
    depositors: set                       # distinct agent ids that reinforced this shard
    vec: Optional[np.ndarray] = None      # optional semantic coordinate for gradient sensing


class StigmergyBackend(Protocol):
    def put(self, key: Tuple[str, str], sig: Signal) -> None: ...
    def get(self, key: Tuple[str, str]) -> Optional[Signal]: ...
    def all(self) -> Iterable[Signal]: ...
    def delete(self, key: Tuple[str, str]) -> None: ...


class InMemoryBackend:
    """Sharded dict store. One entry per (kind, topic) — the no-hot-document shape that the
    Convex OCC research said is mandatory at 30+ concurrent writers."""
    def __init__(self) -> None:
        self._d: Dict[Tuple[str, str], Signal] = {}
    def put(self, key, sig): self._d[key] = sig
    def get(self, key): return self._d.get(key)
    def all(self): return list(self._d.values())
    def delete(self, key): self._d.pop(key, None)


def _cosine(a: Optional[np.ndarray], b: Optional[np.ndarray]) -> float:
    if a is None or b is None:
        return 0.0
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


class StigmergicField:
    def __init__(self, backend: Optional[StigmergyBackend] = None,
                 clock: Callable[[], float] = time.monotonic,
                 volatility_fn: Optional[Callable[[], float]] = None,
                 volatility_gain: float = 2.0):
        self.backend = backend or InMemoryBackend()
        self.clock = clock
        # volatility_fn() in [0,1]; default 0 = resting field. Wire endocrine.field_volatility here.
        self.volatility_fn = volatility_fn or (lambda: 0.0)
        self.volatility_gain = volatility_gain

    # ---- decay ----
    def _eff_tau(self, kind: str) -> float:
        base = TAU_BASE.get(kind, 60.0)
        vol = max(0.0, min(1.0, self.volatility_fn()))
        return base / (1.0 + self.volatility_gain * vol)     # arousal shortens tau -> faster fade

    def _current(self, sig: Signal) -> float:
        dt = max(0.0, self.clock() - sig.last_t)
        return sig.strength * math.exp(-dt / self._eff_tau(sig.kind))

    # ---- deposit / reinforce ----
    def deposit(self, kind: str, topic: str, strength: float, agent: str,
                vec: Optional[np.ndarray] = None) -> float:
        """Lay or reinforce a signal. Reinforcement accumulates on the live (decayed) value
        and refreshes the clock. Returns the new strength."""
        key = (kind, topic)
        now = self.clock()
        cur = self.backend.get(key)
        if cur is None:
            sig = Signal(kind=kind, topic=topic, strength=min(STRENGTH_CAP, max(0.0, strength)),
                         last_t=now, depositors={agent}, vec=vec)
        else:
            live = self._current(cur)                        # decay-to-now, then add
            sig = Signal(kind=kind, topic=topic,
                         strength=min(STRENGTH_CAP, live + max(0.0, strength)),
                         last_t=now, depositors=cur.depositors | {agent},
                         vec=cur.vec if cur.vec is not None else vec)
        self.backend.put(key, sig)
        return sig.strength

    # ---- sense (local gradient, optionally over the semantic neighborhood) ----
    def sense(self, topic: str, kinds: Optional[Iterable[str]] = None,
              vec: Optional[np.ndarray] = None, cosine_thresh: float = 0.6) -> Dict[str, float]:
        """Return current strength per kind at `topic`, summing exact-topic signals plus
        cosine-near topics (the diffusion/gradient term) weighted by similarity."""
        want = set(kinds) if kinds else None
        out: Dict[str, float] = {}
        for sig in self.backend.all():
            if want and sig.kind not in want:
                continue
            s = self._current(sig)
            if s < GC_FLOOR:
                continue
            if sig.topic == topic:
                w = 1.0
            elif vec is not None and sig.vec is not None:
                c = _cosine(vec, sig.vec)
                w = c if c >= cosine_thresh else 0.0
            else:
                w = 0.0
            if w > 0.0:
                out[sig.kind] = out.get(sig.kind, 0.0) + w * s
        return out

    # ---- quorum sensing (threshold-keyed collective decision) ----
    def quorum(self, kind: str, topic: str, min_depositors: int = 3,
               min_strength: float = 0.5) -> bool:
        sig = self.backend.get((kind, topic))
        if sig is None:
            return False
        return (len(sig.depositors) >= min_depositors) and (self._current(sig) >= min_strength)

    # ---- garbage-collect dead signals (the only thing a cron needs to do) ----
    def gc(self) -> int:
        dead = [(s.kind, s.topic) for s in self.backend.all() if self._current(s) < GC_FLOOR]
        for k in dead:
            self.backend.delete(k)
        return len(dead)

    def snapshot(self) -> List[Tuple[str, str, float, int]]:
        return sorted(((s.kind, s.topic, round(self._current(s), 4), len(s.depositors))
                       for s in self.backend.all()), key=lambda r: (-r[2], r[0], r[1]))


# ================================================================ offline self-test + sim
def _dynamics_tests():
    class Clk:
        t = 1000.0
        def __call__(self): return self.t
        def advance(self, s): self.t += s
    clk = Clk()
    ok = True

    # reinforced trail persists; unreinforced fades below floor
    pm = StigmergicField(clock=clk)
    pm.deposit("trail", "route_A", 0.6, "ant1")
    pm.deposit("trail", "route_B", 0.6, "ant2")
    for _ in range(5):
        clk.advance(20); pm.deposit("trail", "route_A", 0.3, "ant1")   # A keeps getting used
    a = pm.sense("route_A", kinds=["trail"]).get("trail", 0.0)
    b = pm.sense("route_B", kinds=["trail"]).get("trail", 0.0)
    print(f"[dynamics] reinforced A={a:.3f}  unreinforced B={b:.3f}")
    assert a > b, "reinforced trail should outlast unreinforced"

    # alarm decays faster than territory over the same dt
    pm2 = StigmergicField(clock=clk)
    pm2.deposit("alarm", "intruder", 0.9, "g1")
    pm2.deposit("territory", "home", 0.9, "g1")
    t0 = clk.t
    clk.advance(30)
    al = pm2.sense("intruder", kinds=["alarm"]).get("alarm", 0.0)
    te = pm2.sense("home", kinds=["territory"]).get("territory", 0.0)
    print(f"[dynamics] after 30s: alarm={al:.3f}  territory={te:.3f}")
    assert al < te, "alarm must fade faster than territory"

    # volatility (arousal) accelerates evaporation
    vol = {"v": 0.0}
    pm3 = StigmergicField(clock=clk, volatility_fn=lambda: vol["v"])
    pm3.deposit("trail", "x", 0.8, "a"); base_t = clk.t
    clk.advance(40); calm = pm3.sense("x", kinds=["trail"]).get("trail", 0.0)
    pm3b = StigmergicField(clock=clk, volatility_fn=lambda: 0.9)
    # reset clock view: deposit fresh then advance equally
    clk.t = base_t; pm3b.deposit("trail", "x", 0.8, "a"); clk.advance(40)
    hot = pm3b.sense("x", kinds=["trail"]).get("trail", 0.0)
    print(f"[dynamics] same 40s: calm={calm:.3f}  aroused={hot:.3f}")
    assert hot < calm, "arousal should accelerate decay"

    # quorum fires only at threshold (distinct depositors + strength)
    pm4 = StigmergicField(clock=clk)
    for a_id in ("a1", "a2"):
        pm4.deposit("recruit", "go", 0.4, a_id)
    print(f"[quorum] 2 depositors -> {pm4.quorum('recruit','go',3,0.5)} (want False)")
    assert pm4.quorum("recruit", "go", 3, 0.5) is False
    pm4.deposit("recruit", "go", 0.4, "a3")
    print(f"[quorum] 3 depositors -> {pm4.quorum('recruit','go',3,0.5)} (want True)")
    assert pm4.quorum("recruit", "go", 3, 0.5) is True

    # GC removes dead signals
    pm5 = StigmergicField(clock=clk)
    pm5.deposit("alarm", "blip", 0.3, "a"); clk.advance(300)
    removed = pm5.gc()
    print(f"[gc] removed {removed} dead signal(s)")
    assert removed >= 1
    return ok


def _swarm_sim():
    """30 agents, no central coordinator, choose between two routes by reading the trail
    field. Route B yields more reward, so its trail self-reinforces and the swarm converges
    on it. Then B is blocked (stops being deposited); its trail decays and the swarm re-routes
    to A. Emergent coordination + recovery, purely through the field."""
    rng = np.random.default_rng(1218)
    class Clk:
        t = 0.0
        def __call__(self): return self.t
        def advance(self, s): self.t += s
    clk = Clk()
    pm = StigmergicField(clock=clk)
    reward = {"route_A": 0.35, "route_B": 0.85}
    N, ROUNDS = 30, 30
    ALPHA, Q, EPS = 3.0, 0.012, 0.008    # small deposits stay << cap so the trail reflects share+quality;
                                          # alpha amplifies the gap; ~53% evaporation/round keeps it honest

    def round_once(blocked=None):
        # synchronous ACO step: read the field once, all agents choose by tau^alpha, deposit,
        # then time advances so evaporation bites (eff_tau makes ~half a trail fade per round).
        chosen = {"route_A": 0, "route_B": 0}
        tA = pm.sense("route_A", kinds=["trail"]).get("trail", 0.0)
        tB = pm.sense("route_B", kinds=["trail"]).get("trail", 0.0)
        wA, wB = (tA + EPS) ** ALPHA, (tB + EPS) ** ALPHA
        pB = wB / (wA + wB)
        for i in range(N):
            pick = "route_B" if rng.random() < pB else "route_A"
            if blocked == pick:                        # route unusable: no reward, no deposit
                continue
            pm.deposit("trail", pick, Q * reward[pick], f"agent{i}")  # deposit ∝ quality, small vs cap
            chosen[pick] += 1
        clk.advance(45)                                # time passes -> ~53% evaporation per round
        pm.gc()
        return chosen

    init = round_once()
    for _ in range(ROUNDS):
        last = round_once()
    b_share = last["route_B"] / max(1, sum(last.values()))
    print(f"[swarm] converged share -> B={b_share:.2f}  trails={pm.snapshot()}")
    assert b_share > 0.7, "swarm should converge on the better route B"

    # block B: agents can no longer use/deposit it; its trail must decay and A take over
    for _ in range(ROUNDS):
        last = round_once(blocked="route_B")
    a_str = pm.sense("route_A", kinds=["trail"]).get("trail", 0.0)
    b_str = pm.sense("route_B", kinds=["trail"]).get("trail", 0.0)
    print(f"[swarm] after blocking B: A_trail={a_str:.3f}  B_trail={b_str:.3f}  trails={pm.snapshot()}")
    assert a_str > b_str, "blocked route's trail must decay and the swarm re-route to A"
    return True


if __name__ == "__main__":
    import sys
    ok = True
    print("== dynamics ==");  ok &= bool(_dynamics_tests())
    print("== 30-agent swarm =="); ok &= bool(_swarm_sim())
    print("STIGMERGENT FIELD SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
