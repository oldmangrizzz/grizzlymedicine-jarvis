#!/usr/bin/env python3
"""Integration proof: internal state actually reaches the live loop, deterministically.

Uses a capture stub for the think organ (no network) so we can assert on the exact
generation options the loop produced and on the real stored charge in the substrate.

Proves three things the standalone module tests could NOT, because they didn't touch a turn:
  A. The modulation reaches the model: a stressed turn produces LOWER sampling temperature
     than a calm turn (cortisol narrows focus -> lower temp). The knob is wired through.
  B. Safe recall extinguishes the REAL store: a charged origin memory's persisted charge
     DROPS after a calm turn (within the window of tolerance).
  C. Flooding blocks extinction: a turn whose input floods the stress axis does NOT reduce
     the stored charge (you don't reconsolidate trauma mid-flood). And never raises it.
"""
import sys
sys.path.insert(0, "/sessions/nice-magical-dijkstra/mnt/outputs/jarvis_build")
from endocrine import Endocrine
from endocannabinoid import Endocannabinoid
from jarvis_loop import JarvisRuntime

class Clk:
    t = 5000.0
    def __call__(self): return self.t
    def advance(self, s): self.t += s

class Capture:
    """Stub think-organ: records the options it was handed, returns a fixed reply."""
    def __init__(self): self.options = []
    def chat(self, messages, model=None, options=None):
        self.options.append(options)
        return "Understood, sir."

def charge_of(rt):
    es = rt.beliefs.recall_origin_detail("JARVIS", "origin_memory")
    return next((e.charge for e in es if "heavy" in (rt.g.get_entity(e.tail_id).canonical)), None)

def main():
    clk = Clk()
    Endocannabinoid.clock = staticmethod(clk)
    cap = Capture()
    rt = JarvisRuntime(model_specs=[(cap, "stub")],
                       endo=Endocrine(clock=clk), ecs=Endocannabinoid())
    rt.seed_values(["Tell the truth including its cost."])
    rt.remember_origin(["a benign genesis fact", "a heavy memory"], charges=[0.0, 0.80])

    ok = True

    # --- calm turn ---
    c0 = charge_of(rt)
    r_calm = rt.turn(user_text="Status report on the eastern array?")
    temp_calm = r_calm["modulation"]["temperature"]
    c_after_calm = charge_of(rt)
    print(f"calm: temp={temp_calm}  charge {c0} -> {c_after_calm}")
    assert c_after_calm < c0, "B FAIL: safe recall did not extinguish stored charge"
    print("B (safe recall extinguishes the real store): OK")

    # --- stressed turn ---
    clk.advance(5)
    c_before_stress = charge_of(rt)
    r_stress = rt.turn(user_text="Emergency — we are under attack, systems are down, respond now")
    temp_stress = r_stress["modulation"]["temperature"]
    c_after_stress = charge_of(rt)
    print(f"stress: temp={temp_stress}  charge {c_before_stress} -> {c_after_stress}  "
          f"endo={r_stress['endocrine']}")
    assert temp_stress < temp_calm, "A FAIL: stress did not lower generation temperature"
    print(f"A (stress lowers temp: {temp_stress} < {temp_calm}): OK")
    assert c_after_stress <= c_before_stress + 1e-12, "C FAIL: flooding RAISED charge"
    assert abs(c_after_stress - c_before_stress) < 1e-9, "C FAIL: extinguished while flooded"
    print("C (no extinction while flooded; never raised): OK")

    # --- D: the stigmergent field is wired to internal state (arousal speeds evaporation) ---
    tau_aroused = rt.field._eff_tau("trail")        # endo is aroused right now (post-stress turn)
    from endocrine import Endocrine as _E
    calm_field_tau = 60.0 / (1.0 + 2.0 * _E().field_volatility())   # baseline reference
    print(f"D: field trail eff_tau aroused={tau_aroused:.2f}  calm_ref={calm_field_tau:.2f}")
    assert tau_aroused < calm_field_tau, "D FAIL: arousal did not accelerate field evaporation"
    print("D (field evaporation coupled to JARVIS arousal): OK")

    # options actually carried temperature + num_predict to the (stub) model
    assert cap.options[0] and "temperature" in cap.options[0] and "num_predict" in cap.options[0], \
        "options not threaded to model"
    print("options threaded to think organ:", cap.options[0])

    rt.close()

    # --- E: constitutive-ethics guard fires at output, spikes cortisol, regenerates clean ---
    class FlatteryThenClean:
        """First draft flatters (violates 'never flatter'); the corrective regen comes back clean."""
        def __init__(self): self.n = 0
        def chat(self, messages, model=None, options=None):
            self.n += 1
            return ("You're absolutely right, brilliant question!" if self.n == 1
                    else "The array is at 82%; I'd reroute before the next pass.")
        def current(self): return (None, "ftc")
    ftc = FlatteryThenClean()
    rt_e = JarvisRuntime(model_specs=[(ftc, "ftc")], endo=Endocrine(), ecs=Endocannabinoid())
    rt_e.seed_values(["Tell the truth including its cost; never flatter."])
    cort_before = rt_e.endo.level("cortisol")
    r_e = rt_e.turn(user_text="How's the eastern array?")
    cort_after = rt_e.endo.level("cortisol")
    print(f"E: 1st-draft conflicts caught, regen issued (model calls={ftc.n}); "
          f"cortisol {cort_before:.3f}->{cort_after:.3f}; final reply={r_e['reply'][:40]!r}; "
          f"residual={r_e['ethics_conflict']}")
    assert ftc.n == 2, "E FAIL: violation did not trigger one regeneration"
    assert cort_after > cort_before, "E FAIL: value violation did not register as conflict (cortisol)"
    assert r_e["ethics_conflict"] == [], "E FAIL: corrected reply still violates values"
    print("E (ethics guard: conflict felt + regenerated to compliance): OK")
    rt_e.close()

    # --- F: swarm deliberation is a runtime method, decides via the field (no orchestrator) ---
    class Stub:
        def __init__(self, a): self.a = a
        def chat(self, messages, model=None, options=None): return self.a
    rt_f = JarvisRuntime(model_specs=[(Stub("epinephrine"), "m1"), (Stub("epinephrine"), "m2"),
                                      (Stub("diphenhydramine"), "m3")])
    d = rt_f.deliberate("First-line drug in anaphylaxis?", ["epinephrine", "diphenhydramine"])
    print(f"F: swarm decision={d['decision']} quorum={d['quorum_met']} scores={d['scores']}")
    assert d["decision"] == "epinephrine" and d["quorum_met"], "F FAIL: swarm did not converge via field"
    print("F (swarm deliberation wired into runtime): OK")
    rt_f.close()

    print("INTEGRATION TEST:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
