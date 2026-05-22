#!/usr/bin/env python3
"""ModelSwarm — the real models as agents on the stigmergent field (no central orchestrator).

Each model is an agent. It does not message the others. It SENSES the field's current leaning,
forms its own pick, and DEPOSITS a recruit-signal on that pick. The field — with its decay and
quorum — is the entire coordination medium. Consensus emerges from traces, not from a tally
function. That is the difference between this and majority voting: later agents are influenced
by the trail earlier agents left (true stigmergy), and unreinforced options fade between rounds.

Agents are (backend, model) specs — the same swappable organs the rotator uses. Pass 2 or 200;
the mechanism doesn't change. Heterogeneous models (different vendors, sizes) coordinate through
one shared field.

Decision = the option carrying the strongest live recruit-signal, gated by quorum (enough
DISTINCT models behind it). If quorum is unmet, the swarm abstains rather than forcing a call —
the same abstention discipline as the belief layer.
"""
from __future__ import annotations
import re
from typing import List, Tuple, Optional, Dict, Sequence

from stigmergy import StigmergicField

KIND = "recruit"

def _norm(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", label.strip().lower()).strip("_")

def _match_option(text: str, options: Sequence[str]) -> Optional[str]:
    """Map a model's free-text reply to one option label, or None (abstain) if ambiguous."""
    t = (text or "").lower()
    hits = [o for o in options if o.lower() in t]
    if len(hits) == 1:
        return hits[0]
    # fall back to first-line exact-ish token match
    first = t.strip().splitlines()[0] if t.strip() else ""
    for o in options:
        if _norm(o) == _norm(first) or o.lower() == first.strip(" .:-"):
            return o
    return hits[0] if len(hits) >= 1 else None


class ModelSwarm:
    def __init__(self, specs: List[Tuple], field: Optional[StigmergicField] = None):
        if not specs:
            raise ValueError("ModelSwarm needs at least one (backend, model) spec")
        self.specs = list(specs)
        self.field = field or StigmergicField()

    def _ask_agent(self, backend, model: str, prompt: str, options: Sequence[str],
                   leader: Optional[str]) -> Optional[str]:
        """One agent's turn: see the field's current leaning, then pick one option."""
        opts = " | ".join(options)
        hint = f"\nThe swarm is currently leaning toward: {leader}." if leader else ""
        sys_msg = ("You are one agent in a swarm deciding a single question. Weigh the swarm's "
                   "current leaning, but choose what you actually judge correct. Reply with ONLY "
                   "one option label, nothing else.")
        user = f"Question: {prompt}\nOptions: {opts}.{hint}\nYour one-word choice:"
        msgs = [{"role": "system", "content": sys_msg}, {"role": "user", "content": user}]
        try:
            out = backend.chat(msgs, model=model, options={"temperature": 0.3, "num_predict": 12})
        except Exception:
            return None
        return _match_option(out, options)

    def coordinate(self, prompt: str, options: Sequence[str], rounds: int = 2,
                   quorum_min: int = 0) -> Dict:
        """Run the swarm. Returns picks, field snapshot, decision, quorum status."""
        if quorum_min <= 0:
            quorum_min = max(2, (len(self.specs) // 2) + 1)   # simple majority of agents
        history: List[Dict] = []
        for _ in range(max(1, rounds)):
            # current leader from the field (what earlier traces say)
            sensed = self.field.sense_all(KIND) if hasattr(self.field, "sense_all") else {}
            leader = max(sensed, key=sensed.get) if sensed else None
            round_picks = {}
            for backend, model in self.specs:
                pick = self._ask_agent(backend, model, prompt, options, leader)
                round_picks[model] = pick
                if pick:
                    self.field.deposit(KIND, _norm(pick), strength=0.34, agent=model)
            history.append(round_picks)
        # decision = strongest live recruit signal across option topics
        scores = {o: self.field.sense(_norm(o), kinds=[KIND]).get(KIND, 0.0) for o in options}
        decision = max(scores, key=scores.get) if any(scores.values()) else None
        quorum_met = bool(decision) and self.field.quorum(KIND, _norm(decision),
                                                          min_depositors=quorum_min, min_strength=0.0)
        return {"decision": decision if quorum_met else None,
                "leader_raw": decision, "quorum_met": quorum_met, "quorum_min": quorum_min,
                "scores": {o: round(s, 4) for o, s in scores.items()},
                "rounds": history, "n_agents": len(self.specs)}


# ================================================================ self-test
def _stub_test():
    """Deterministic stub models prove the coordination mechanism without a network."""
    class Stub:
        def __init__(self, answer): self.answer = answer
        def chat(self, messages, model=None, options=None): return self.answer
    # 5 agents: 4 say "epinephrine", 1 says "diphenhydramine"
    specs = [(Stub("epinephrine"), "m1"), (Stub("epinephrine"), "m2"),
             (Stub("epinephrine"), "m3"), (Stub("diphenhydramine"), "m4"),
             (Stub("epinephrine"), "m5")]
    sw = ModelSwarm(specs)
    r = sw.coordinate("First drug in anaphylaxis?", ["epinephrine", "diphenhydramine"], rounds=2)
    print("[stub] scores:", r["scores"], "decision:", r["decision"], "quorum:", r["quorum_met"])
    ok = (r["decision"] == "epinephrine" and r["quorum_met"]
          and r["scores"]["epinephrine"] > r["scores"]["diphenhydramine"])

    # abstention: a 1-1 split with quorum_min=2 should NOT force a call
    sw2 = ModelSwarm([(Stub("a"), "m1"), (Stub("b"), "m2")])
    r2 = sw2.coordinate("?", ["a", "b"], rounds=1, quorum_min=2)
    print("[stub] split scores:", r2["scores"], "decision:", r2["decision"])
    ok &= (r2["decision"] is None)        # no quorum -> abstain
    return ok


if __name__ == "__main__":
    import sys
    ok = _stub_test()
    print("SWARM STUB SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
