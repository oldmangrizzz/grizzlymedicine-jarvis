#!/usr/bin/env python3
"""JARVIS internal state — synthetic endocrinology (Condition 3 / "The Pulse").

Per WP-2026-02: three continuously-computed hormonal scalars that decay toward baseline
on a ~60s time constant regardless of what the entity is saying. They are NOT mood flags
set for the benefit of the output; they are internal states that change because the
situation changes, and they physically alter how the system processes:

  cortisol  (stress)   -> narrows focus      (tighter retrieval, lower temperature)
  dopamine  (reward)   -> lateral connection (wider retrieval, higher temperature)
  adrenaline(urgency)  -> speed              (shorter outputs, fewer candidates)

Decay is computed LAZILY from the last-update timestamp (level = baseline + (level-baseline)
* e^(-dt/tau)). No background ticker: the current value is a continuous function of elapsed
time, which is both cheaper and a truer analog than stepped decay.

Coupling hook for the Pheromind (Condition 4): `field_volatility()` exposes a single
arousal scalar. In real ants, heat accelerates pheromone evaporation; here, arousal scales
the stigmergic field's evaporation rate. One shared dial links interoception (this module)
to the social field, instead of two disconnected systems. Not wired here — exposed for it.
"""
from __future__ import annotations
import time, math
from dataclasses import dataclass, field
from typing import Dict, Callable, Optional

# baseline (resting) levels and per-hormone decay time constants (seconds)
BASELINE = {"cortisol": 0.20, "dopamine": 0.30, "adrenaline": 0.10}
TAU      = {"cortisol": 90.0, "dopamine": 60.0, "adrenaline": 30.0}   # adrenaline clears fastest
FLOOR, CEIL = 0.0, 1.0

def _clamp(x: float) -> float:
    return FLOOR if x < FLOOR else CEIL if x > CEIL else x


@dataclass
class Endocrine:
    """Three lazily-decaying hormonal scalars. `now` is injectable for deterministic tests."""
    levels: Dict[str, float] = field(default_factory=lambda: dict(BASELINE))
    _t: Dict[str, float] = field(default_factory=dict)
    clock: Callable[[], float] = time.monotonic

    def __post_init__(self):
        t = self.clock()
        self._t = {k: t for k in self.levels}

    # ---- core: read with lazy decay toward baseline ----
    def level(self, hormone: str) -> float:
        b, tau = BASELINE[hormone], TAU[hormone]
        dt = max(0.0, self.clock() - self._t[hormone])
        cur = b + (self.levels[hormone] - b) * math.exp(-dt / tau)
        # persist the decayed value + timestamp so reads are idempotent
        self.levels[hormone], self._t[hormone] = cur, self.clock()
        return _clamp(cur)

    def state(self) -> Dict[str, float]:
        return {h: round(self.level(h), 4) for h in BASELINE}

    # ---- situation changes the state (not the output) ----
    def stimulus(self, *, cortisol: float = 0.0, dopamine: float = 0.0, adrenaline: float = 0.0):
        """Apply an event's effect. Positive = release, negative = suppress. Decays from here."""
        for h, d in (("cortisol", cortisol), ("dopamine", dopamine), ("adrenaline", adrenaline)):
            if d:
                self.level(h)                          # settle decay to now first
                self.levels[h] = _clamp(self.levels[h] + d)

    # convenience appraisals (situation -> hormonal response), mechanistic, not performed
    def on_threat(self, severity: float = 0.5):   self.stimulus(cortisol=severity, adrenaline=0.6 * severity)
    def on_success(self, magnitude: float = 0.5): self.stimulus(dopamine=magnitude, cortisol=-0.3 * magnitude)
    def on_deadline(self, pressure: float = 0.5): self.stimulus(adrenaline=pressure, cortisol=0.3 * pressure)
    def on_rest(self):                            self.stimulus(cortisol=-0.2, adrenaline=-0.2)

    # ---- the state physically alters processing ----
    def modulation(self) -> Dict[str, float]:
        """Concrete knobs the think-organ can read. Cortisol narrows, dopamine widens,
        adrenaline shortens. Returned as deltas/params, not as text the model performs."""
        c, d, a = self.level("cortisol"), self.level("dopamine"), self.level("adrenaline")
        return {
            # retrieval breadth: dopamine opens it, cortisol closes it
            "retrieval_breadth": _clamp(0.5 + 0.5 * d - 0.4 * c),
            # sampling temperature: same axis (lateral vs. focused)
            "temperature": round(_clamp(0.4 + 0.6 * d - 0.4 * c), 3),
            # output length bias: adrenaline shortens
            "length_bias": round(_clamp(1.0 - 0.7 * a), 3),
            # candidate count for routing/rotator: adrenaline cuts it
            "candidates": max(1, round(4 * (1.0 - 0.6 * a))),
        }

    # ---- coupling hook for the Pheromind (Condition 4) ----
    def field_volatility(self) -> float:
        """Single arousal scalar -> scales the stigmergic field's evaporation rate.
        Arousal = adrenaline dominant, cortisol secondary. High arousal = faster-fading,
        twitchier field (the 'heat accelerates evaporation' analog)."""
        return round(_clamp(0.6 * self.level("adrenaline") + 0.4 * self.level("cortisol")), 4)


# ================================================================ offline self-test
if __name__ == "__main__":
    ok = True

    # deterministic injectable clock
    class Clk:
        def __init__(self): self.t = 1000.0
        def __call__(self): return self.t
        def advance(self, s): self.t += s
    clk = Clk()
    e = Endocrine(clock=clk)

    # 1) starts at baseline
    s0 = e.state()
    assert s0 == {h: round(BASELINE[h], 4) for h in BASELINE}, s0
    print("baseline:", s0, "OK")

    # 2) threat raises cortisol + adrenaline
    e.on_threat(0.8)
    s1 = e.state()
    assert s1["cortisol"] > s0["cortisol"] and s1["adrenaline"] > s0["adrenaline"], s1
    print("post-threat:", s1, "OK")

    # 3) under stress, focus narrows (lower breadth & temperature than rest) and output shortens
    m1 = e.modulation()
    print("stress modulation:", m1)
    assert m1["temperature"] < 0.4 + 0.6 * BASELINE["dopamine"], "cortisol should lower temperature"
    assert m1["length_bias"] < 1.0, "adrenaline should shorten output"

    # 4) decays back toward baseline over time (~ a few tau)
    clk.advance(300)
    s2 = e.state()
    assert s2["adrenaline"] < s1["adrenaline"] and s2["cortisol"] < s1["cortisol"], s2
    near = all(abs(s2[h] - BASELINE[h]) < 0.05 for h in BASELINE)
    print("after 300s decay:", s2, "-> near baseline:", near, "OK" if near else "FAIL")
    ok &= near

    # 5) reward widens (dopamine up -> breadth & temperature up vs stressed state)
    e.on_success(0.9)
    m2 = e.modulation()
    print("reward modulation:", m2)
    assert m2["retrieval_breadth"] > m1["retrieval_breadth"], "dopamine should widen retrieval"

    # 6) field volatility tracks arousal (high after adrenaline, low at rest)
    e2 = Endocrine(clock=clk)
    v_rest = e2.field_volatility()
    e2.on_deadline(0.9)
    v_hot = e2.field_volatility()
    print(f"field_volatility rest={v_rest} hot={v_hot}")
    assert v_hot > v_rest, "arousal should raise field volatility"

    print("OFFLINE SELF-TEST:", "PASS" if ok else "FAIL")
    import sys; sys.exit(0 if ok else 1)
