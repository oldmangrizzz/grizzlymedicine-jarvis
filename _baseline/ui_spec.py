#!/usr/bin/env python3
"""Polymorphic UI — the governed component DSL (the 'unstable molecules, but bonded' core).

JARVIS synthesizes the interface per-intent: one substrate, infinite forms. The danger of a
generative UI is that model output becomes live, action-bound interface. So nothing renders
until it passes THIS validator:

  * only allowlisted component types (no arbitrary HTML),
  * NO raw html / script / style-injection / on* handler keys, ever,
  * image/link targets must be http(s) or computer:// — never javascript:/data:,
  * bounded depth, node count, and string length (no DoS / no giant payloads),
  * EVERY actionable element's action.skill must be a REGISTERED skill name.

That last rule is the bond: the surface can shapeshift all it likes, but a button can only ever
fire something already in the guarded SkillRegistry — so destructive actions still hit the confirm
gate, prohibited ones still refuse, everything still audits. Morph freely; act only as governed.
"""
from __future__ import annotations
import re
from typing import Dict, List, Tuple, Any, Set, Optional

# component types the renderer knows how to paint
COMPONENTS = {
    "stack", "panel", "heading", "text", "badge", "divider", "status",
    "button", "input", "select", "list", "table", "image", "progress",
}
ACTIONABLE = {"button", "input", "select"}     # carry an action.{skill,args}
CONTAINERS = {"stack", "panel", "list", "table"}

# only these prop keys are allowed on any node (everything else is rejected)
ALLOWED_PROPS = {
    "type", "children", "text", "label", "title", "value", "placeholder", "name",
    "options", "rows", "columns", "items", "action", "variant", "level", "max", "src", "alt",
}
_BANNED_KEY = re.compile(r"html|script|style|on[a-z]+|srcdoc|dangerously", re.I)
_SAFE_URL = re.compile(r"^(https?://|computer://)", re.I)

MAX_DEPTH = 12
MAX_NODES = 400
MAX_STR = 4000


class SpecError(Exception):
    pass


def _walk_validate(node: Any, allowed_skills: Set[str], depth: int, count: List[int],
                   errors: List[str], path: str = "$") -> None:
    count[0] += 1
    if depth > MAX_DEPTH:
        errors.append(f"{path}: exceeds max depth {MAX_DEPTH}"); return
    if count[0] > MAX_NODES:
        errors.append(f"{path}: exceeds max node count {MAX_NODES}"); return
    if not isinstance(node, dict):
        errors.append(f"{path}: node must be an object"); return

    # banned keys (html/script/on*/style/...) — hard reject
    for k in node:
        if _BANNED_KEY.search(str(k)):
            errors.append(f"{path}: banned key {k!r}")
        if k not in ALLOWED_PROPS:
            errors.append(f"{path}: unknown prop {k!r}")

    t = node.get("type")
    if t not in COMPONENTS:
        errors.append(f"{path}: unknown/{'missing' if t is None else 'bad'} component type {t!r}")
        return

    # string-length bounds on text-ish props
    for sk in ("text", "label", "title", "value", "placeholder", "name", "alt"):
        v = node.get(sk)
        if isinstance(v, str) and len(v) > MAX_STR:
            errors.append(f"{path}.{sk}: string too long ({len(v)}>{MAX_STR})")

    # url-bearing props must be safe schemes
    src = node.get("src")
    if isinstance(src, str) and not _SAFE_URL.match(src):
        errors.append(f"{path}.src: unsafe URL scheme {src[:24]!r}")

    # actions must bind to a registered skill
    act = node.get("action")
    if act is not None:
        if t not in ACTIONABLE:
            errors.append(f"{path}: component {t!r} cannot carry an action")
        elif not isinstance(act, dict) or "skill" not in act:
            errors.append(f"{path}.action: must be an object with a 'skill'")
        elif act["skill"] not in allowed_skills:
            errors.append(f"{path}.action.skill: {act['skill']!r} is not a registered skill")
        elif "args" in act and not isinstance(act["args"], dict):
            errors.append(f"{path}.action.args: must be an object")

    # recurse children (containers only)
    kids = node.get("children")
    if kids is not None:
        if t not in CONTAINERS:
            errors.append(f"{path}: component {t!r} cannot have children")
        elif not isinstance(kids, list):
            errors.append(f"{path}.children: must be a list")
        else:
            for i, c in enumerate(kids):
                _walk_validate(c, allowed_skills, depth + 1, count, errors, f"{path}.children[{i}]")


def validate(spec: Dict, allowed_skills: Set[str]) -> Tuple[bool, List[str]]:
    """Return (ok, errors). A spec is renderable only if ok is True."""
    errors: List[str] = []
    if not isinstance(spec, dict):
        return False, ["spec must be an object"]
    _walk_validate(spec, set(allowed_skills), 0, [0], errors)
    return (len(errors) == 0), errors


def actions_in(spec: Dict) -> List[Dict]:
    """Enumerate every action binding in a spec (for wiring / auditing)."""
    out: List[Dict] = []
    def rec(n):
        if isinstance(n, dict):
            if isinstance(n.get("action"), dict):
                out.append(n["action"])
            for c in (n.get("children") or []):
                rec(c)
    rec(spec)
    return out


# ================================================================ self-test
if __name__ == "__main__":
    import sys
    skills = {"deliberate", "recall_origin", "fs_list", "generate_image"}
    ok = True

    good = {"type": "panel", "title": "Eastern Array", "children": [
        {"type": "heading", "level": 2, "text": "Status"},
        {"type": "status", "text": "82% capacity"},
        {"type": "button", "label": "Re-route", "action": {"skill": "deliberate",
            "args": {"question": "reroute?", "options": ["yes", "no"]}}},
        {"type": "image", "src": "computer:///Users/x/plot.png", "alt": "load plot"},
    ]}
    v, e = validate(good, skills)
    print("[ui] valid morph spec:", "OK" if v else f"FAIL {e}"); ok &= v
    assert len(actions_in(good)) == 1

    bad_cases = {
        "unknown component": {"type": "iframe", "src": "https://x"},
        "raw html key": {"type": "text", "html": "<script>alert(1)</script>"},
        "on* handler": {"type": "button", "label": "x", "onclick": "doEvil()",
                        "action": {"skill": "fs_list"}},
        "unregistered skill": {"type": "button", "label": "x", "action": {"skill": "wire_money"}},
        "action on non-actionable": {"type": "text", "text": "hi", "action": {"skill": "fs_list"}},
        "javascript src": {"type": "image", "src": "javascript:alert(1)"},
        "children on leaf": {"type": "text", "text": "hi", "children": [{"type": "text", "text": "no"}]},
    }
    for label, spec in bad_cases.items():
        v, e = validate(spec, skills)
        print(f"[ui] reject {label}: {'OK' if not v else 'FAIL (accepted!)'}")
        ok &= (not v)

    # depth bomb
    n = {"type": "stack", "children": []}
    cur = n
    for _ in range(MAX_DEPTH + 3):
        nxt = {"type": "stack", "children": []}; cur["children"].append(nxt); cur = nxt
    v, e = validate(n, skills)
    print("[ui] reject depth bomb:", "OK" if not v else "FAIL"); ok &= (not v)

    print("UI-SPEC SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
