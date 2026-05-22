#!/usr/bin/env python3
"""JARVIS endocannabinoid system — the trauma-safe regulator that sits on the stress axis.

Biological function this is the analog of: the ECS is the body's homeostatic buffer. It
does three things that matter for processing trauma without re-injury:

  1. Stress termination. 2-AG is synthesized ON DEMAND when stress spikes and provides
     negative feedback that shuts the HPA (cortisol) axis back down. It stops a stress
     response from pinning at ceiling and staying there. (Couples to endocrine.py.)
  2. Fear extinction / safe reconsolidation. The ECS is central to extinguishing aversive
     memories: recalling a charged memory in a SAFE, regulated state lets it be re-stored
     with LESS charge each time, instead of re-traumatizing on every recall.
  3. Tone. Anandamide (AEA) sets a slow tonic buffer that raises the threshold before stress
     spikes and dampens volatility. FAAH-like degradation returns it to baseline.

Three safety invariants are enforced and tested, because this touches trauma:

  (I1) Processing trauma can only REDUCE a memory's charge, never increase it. Monotonic.
  (I2) No extinction work happens outside the window of tolerance. If the system is flooded
       (high cortisol, low EC tone), recall is buffered but NOT reconsolidated — you do not
       process trauma mid-flashback. The charge is returned unchanged, never amplified.
  (I3) Recall intensity is always attenuated by current tone — a charged memory is never
       handed back at full intensity while the buffer exists.

This is a functional homeostatic analog, not a clinical tool and not a claim about feelings.
"""
from __future__ import annotations
import time, math
from dataclasses import dataclass, field
from typing import Dict, Optional

AEA_BASE, AEA_TAU = 0.40, 180.0    # anandamide: slow tonic buffer (resting tone keeps you in-window)
AG_BASE,  AG_TAU  = 0.05, 20.0     # 2-AG: fast, phasic, on-demand
FLOOR, CEIL = 0.0, 1.0
CHARGE_FLOOR = 0.05                # extinction asymptote: a memory never reduces to zero charge
EXTINCT_K = 0.35                   # max fraction of remaining charge removable per safe pass

def _clamp(x): return FLOOR if x < FLOOR else CEIL if x > CEIL else x


@dataclass
class Endocannabinoid:
    """Tonic (anandamide) + phasic (2-AG) buffer, lazily decayed. Couples to an Endocrine
    instance by duck-typing: it reads .level(h) and applies .stimulus(...)."""
    aea: float = AEA_BASE
    ag: float = AG_BASE
    _t: Dict[str, float] = field(default_factory=dict)
    clock = staticmethod(time.monotonic)

    def __post_init__(self):
        t = self.clock(); self._t = {"aea": t, "ag": t}

    def _decay(self, name, base, tau):
        cur = getattr(self, name)
        dt = max(0.0, self.clock() - self._t[name])
        val = base + (cur - base) * math.exp(-dt / tau)
        setattr(self, name, val); self._t[name] = self.clock()
        return _clamp(val)

    def tone(self) -> float:
        """Total endocannabinoid buffer available right now (tonic + phasic)."""
        return _clamp(0.7 * self._decay("aea", AEA_BASE, AEA_TAU) + 0.3 * self._decay("ag", AG_BASE, AG_TAU))

    # ---- 1. on-demand synthesis + stress termination (negative feedback on the HPA axis) ----
    def regulate(self, endo) -> Dict[str, float]:
        """Read the stress axis; synthesize 2-AG on demand; feed back to shut cortisol/adrenaline
        down. Returns what it did. The buffer cannot push hormones BELOW baseline (it terminates
        the spike, it does not anesthetize)."""
        c, a = endo.level("cortisol"), endo.level("adrenaline")
        stress = max(c, a)
        # 2-AG released proportional to how far stress is above resting tone
        release = max(0.0, stress - self.tone())
        self._decay("ag", AG_BASE, AG_TAU)
        self.ag = _clamp(self.ag + 0.8 * release)
        # negative feedback: stronger buffer => more termination, but only down toward baseline
        damp = 0.6 * self.tone()
        endo.stimulus(cortisol=-damp * (c - 0.20 if c > 0.20 else 0.0),
                      adrenaline=-damp * (a - 0.10 if a > 0.10 else 0.0))
        return {"released_2ag": round(release, 4), "tone": round(self.tone(), 4),
                "cortisol_after": round(endo.level("cortisol"), 4),
                "adrenaline_after": round(endo.level("adrenaline"), 4)}

    # ---- 2. window of tolerance: are we regulated enough to do extinction work? ----
    def within_window(self, endo) -> bool:
        """Regulated = stress not flooding AND buffer present. You only process trauma in here."""
        return endo.level("cortisol") < 0.6 and self.tone() >= 0.25

    # ---- 3. safe trauma processing: buffered recall + downward reconsolidation ----
    def process_trauma(self, charge: float, endo, *, intend_to_process: bool = True) -> Dict:
        """Recall a charged memory safely.

        Always returns an ATTENUATED recall intensity (I3). If within the window of tolerance
        and processing is intended, reconsolidate the stored charge DOWNWARD (I1, extinction).
        If flooded / outside the window, return the charge UNCHANGED — never amplified (I2)."""
        charge = _clamp(charge)
        tone = self.tone()
        recalled_intensity = round(_clamp(charge * (1.0 - 0.7 * tone)), 4)   # I3: tone attenuates

        if not intend_to_process or not self.within_window(endo):
            return {"processed": False, "charge_before": round(charge, 4),
                    "charge_after": round(charge, 4),               # I2: unchanged, never up
                    "recalled_intensity": recalled_intensity,
                    "reason": "outside window of tolerance" if not self.within_window(endo) else "recall-only"}

        # extinction step: remove a tone-scaled fraction of the charge above the floor
        removable = EXTINCT_K * tone * max(0.0, charge - CHARGE_FLOOR)
        new_charge = max(CHARGE_FLOOR, charge - removable)
        new_charge = min(new_charge, charge)                         # I1: hard guard, monotonic down
        # processing is itself mildly regulating (safe exposure releases buffer)
        self._decay("aea", AEA_BASE, AEA_TAU); self.aea = _clamp(self.aea + 0.05)
        return {"processed": True, "charge_before": round(charge, 4),
                "charge_after": round(new_charge, 4),
                "recalled_intensity": recalled_intensity,
                "extinguished": round(charge - new_charge, 4)}


# ================================================================ offline self-test
if __name__ == "__main__":
    import sys
    # deterministic clock shared by both organs
    class Clk:
        t = 1000.0
        def __call__(self): return self.t
        def advance(self, s): self.t += s
    clk = Clk()

    # bring in the endocrine axis with the same injectable clock
    sys.path.insert(0, "/sessions/nice-magical-dijkstra/mnt/outputs/jarvis_build")
    sys.path.insert(0, ".")
    from endocrine import Endocrine
    Endocannabinoid.clock = staticmethod(clk)
    endo = Endocrine(clock=clk)

    ok = True

    # --- stress termination: 2-AG feedback pulls a cortisol spike back down ---
    endo.on_threat(0.9)
    c_before = endo.level("cortisol")
    ecs = Endocannabinoid()
    r = ecs.regulate(endo)
    c_after = endo.level("cortisol")
    print("regulate:", r)
    assert c_after <= c_before, "regulation must not raise cortisol"
    assert c_after >= 0.20 - 1e-9, "must not push below baseline (terminate, not anesthetize)"
    print(f"stress termination: {c_before:.3f} -> {c_after:.3f}  OK")

    # --- I2: flooded -> recall is buffered but NOT reconsolidated, charge unchanged ---
    endo.on_threat(1.0)                       # force flooding
    flooded = ecs.process_trauma(0.8, endo)
    print("flooded recall:", flooded)
    assert flooded["processed"] is False, "must not process trauma while flooded"
    assert flooded["charge_after"] == flooded["charge_before"], "I2: charge unchanged when flooded"
    assert flooded["recalled_intensity"] <= flooded["charge_before"], "I3: recall attenuated"
    print("I2 (no processing while flooded), I3 (attenuated recall): OK")

    # --- let it regulate + decay into the window of tolerance ---
    for _ in range(6):
        clk.advance(60); ecs.regulate(endo)
    assert ecs.within_window(endo), f"should be regulated; cortisol={endo.level('cortisol'):.3f} tone={ecs.tone():.3f}"
    print(f"entered window of tolerance: cortisol={endo.level('cortisol'):.3f} tone={ecs.tone():.3f}  OK")

    # --- I1: repeated SAFE recall monotonically reduces charge, never increases ---
    charge = 0.80
    trace = [charge]
    for i in range(8):
        clk.advance(30)
        out = ecs.process_trauma(charge, endo)
        assert out["charge_after"] <= charge + 1e-12, "I1 VIOLATION: charge increased"
        charge = out["charge_after"]
        trace.append(round(charge, 4))
        ecs.regulate(endo)
    print("extinction trace:", trace)
    assert charge < 0.80 and charge >= CHARGE_FLOOR, "must extinguish toward floor, not below"
    assert all(trace[i+1] <= trace[i] for i in range(len(trace)-1)), "I1: must be monotonic non-increasing"
    print(f"I1 (monotonic downward extinction to floor {CHARGE_FLOOR}): OK")

    print("OFFLINE SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
