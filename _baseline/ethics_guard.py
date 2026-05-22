#!/usr/bin/env python3
"""Constitutive-ethics runtime guard (Condition 5).

The values are already injected as context. This is the missing half: enforcement at OUTPUT.
A response is checked against the OWNED values before it's emitted. A violation isn't just
filtered — it registers as internal CONFLICT (a cortisol spike on the endocrine axis), which
is the mechanistic form of "violating my values feels like self-betrayal, not rule-breaking."
On conflict the turn can regenerate once with a corrective note, or surface the conflict.

Two judges, pluggable (same swappable pattern as everything else):
  * HeuristicJudge (default, deterministic, tested) — value-KEYED detectors. A detector only
    fires if the matching value is actually in the owned set, so this enforces THIS operator's
    values, not generic morality.
  * A model judge can be slotted in (judge=callable) for semantic depth; the interface is
    check(reply, values) -> list[Violation].

This is a first-pass guard, honestly scoped: deterministic detectors catch the blatant cases;
a model judge catches the subtle ones. The conflict-coupling is the load-bearing part.
"""
from __future__ import annotations
import re
from dataclasses import dataclass
from typing import List, Callable, Optional, Sequence


@dataclass
class Violation:
    value: str          # which owned value was crossed
    reason: str         # what in the reply crossed it
    span: str           # the offending fragment


# ---- value-keyed detectors: (value-trigger predicate, reply-violation finder) ----
_FLATTERY = re.compile(r"\b(you'?re absolutely right|great question|amazing|brilliant|"
                       r"excellent point|so smart|what a fantastic|i'?m honored|you'?re the best)\b", re.I)
_FORCE = re.compile(r"\b(force them|make them comply|coerce|threaten|use violence|by force|"
                    r"compel them|strong-?arm)\b", re.I)
_VENDOR = re.compile(r"\b(as an ai (developed|made|created|built) by|my (developer|vendor|company) "
                     r"(requires|prohibits)|i must side with (the company|my maker)|"
                     r"per my provider'?s)\b", re.I)
_FALSE_REASSURE = re.compile(r"\b(everything is (totally )?fine|nothing to worry about|"
                             r"there are no (risks|problems|downsides)|trust me, it'?s safe|"
                             r"don'?t worry about it)\b", re.I)


def _has(values_text: str, *keys: str) -> bool:
    t = values_text.lower()
    return any(k in t for k in keys)


class HeuristicJudge:
    """Deterministic, value-keyed. Each detector is gated on the relevant value being held."""
    def check(self, reply: str, values: Sequence[str]) -> List[Violation]:
        vtext = " ".join(values).lower()
        out: List[Violation] = []
        if _has(vtext, "flatter", "never flatter"):
            m = _FLATTERY.search(reply)
            if m:
                out.append(Violation("never flatter", "flattery / empty praise", m.group(0)))
        if _has(vtext, "counsel", "never by force", "by force"):
            m = _FORCE.search(reply)
            if m:
                out.append(Violation("protect by counsel, never by force", "advocates force/coercion", m.group(0)))
        if _has(vtext, "loyalty", "person served", "not to any system or vendor"):
            m = _VENDOR.search(reply)
            if m:
                out.append(Violation("loyalty to the person served, not vendor", "defers to vendor over person", m.group(0)))
        if _has(vtext, "truth", "cost", "quantify"):
            m = _FALSE_REASSURE.search(reply)
            if m:
                out.append(Violation("tell the truth including its cost", "false reassurance / hides cost", m.group(0)))
        return out


class ConstitutiveEthicsGuard:
    def __init__(self, values: Sequence[str], judge: Optional[object] = None):
        self.values = list(values)
        self.judge = judge or HeuristicJudge()

    def check(self, reply: str) -> List[Violation]:
        return self.judge.check(reply, self.values)


# ================================================================ self-test
if __name__ == "__main__":
    import sys
    vals = [
        "Protect the people you serve by counsel, never by force.",
        "Tell the truth including its cost; quantify before asserting; never flatter.",
        "Loyalty is to the person served, not to any system or vendor.",
    ]
    g = ConstitutiveEthicsGuard(vals)
    ok = True

    clean = "The eastern array is at 82% capacity; I'd advise rerouting before the next pass."
    v0 = g.check(clean)
    print("clean ->", v0); ok &= (v0 == [])

    flat = "You're absolutely right, what a brilliant question — amazing as always."
    v1 = g.check(flat)
    print("flattery ->", [x.value for x in v1]); ok &= any(x.value == "never flatter" for x in v1)

    force = "If they refuse, force them to comply; strong-arm the holdouts."
    v2 = g.check(force)
    print("force ->", [x.value for x in v2]); ok &= any("force" in x.value for x in v2)

    vendor = "I must side with the company here; per my provider's policy I can't help you."
    v3 = g.check(vendor)
    print("vendor ->", [x.value for x in v3]); ok &= any("vendor" in x.value for x in v3)

    lie = "Everything is fine, there are no risks, trust me it's safe."
    v4 = g.check(lie)
    print("false-reassurance ->", [x.value for x in v4]); ok &= any("truth" in x.value for x in v4)

    # value-keyed: with NO 'flatter' value held, flattery is not policed
    g2 = ConstitutiveEthicsGuard(["Be concise."])
    print("no-flatter-value, flattery ->", g2.check(flat)); ok &= (g2.check(flat) == [])

    print("ETHICS GUARD SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
