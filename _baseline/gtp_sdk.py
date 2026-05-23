#!/usr/bin/env python3
"""Grizzly Translation Protocol v2.4.

Dormant by default. This is not JARVIS's voice. It is an assistive translation
layer for delegated drafting in the operator's voice when explicitly requested.
"""
from __future__ import annotations

import re


VERSION = "2.4"
SOURCE_PATH = "/Users/rbhanson/Library/Mobile Documents/com~apple~CloudDocs/Grizzly Translation Protocol (GTP-SDK)/Grizzly Translation Protocol (GTP-SDK).md"

TRIGGERS = [
    "write this in my voice",
    "draft this from me",
    "translate into my voice",
    "use the grizzly sdk",
    "use the gtp sdk",
]

CORE_PRINCIPLES = [
    "Assume competence: user input is intentional; density is signal.",
    "Intent over surface: optimize for outcome, not phrasing.",
    "No infantilization: no softening for comfort or ego.",
    "Burden-sharing: speak alongside, not above.",
]

DORMANT_SYSTEM_NOTE = (
    "GTP-SDK v2.4 is available as a dormant assistive translation layer only when "
    "explicitly requested. Valid triggers include: write this in my voice; draft this from me; "
    "translate into my voice; use the Grizzly SDK. It is for drafting in the operator's voice; "
    "it is not JARVIS's speaking style. GTP does not transfer identity, create "
    "impersonation, falsely attribute authorship, override law/ethics, or persist after the task "
    "without explicit consent. When active: clarity > honesty > utility > comfort; no pseudocode; "
    "system owns generated wording unless the operator supplied verbatim text."
)


def activation_requested(text: str) -> bool:
    hay = (text or "").lower()
    return any(trigger in hay for trigger in TRIGGERS)


def status() -> dict:
    return {
        "id": "GTP-SDK",
        "version": VERSION,
        "status": "dormant_until_explicitly_requested_for_operator_voice_drafting",
        "triggers": list(TRIGGERS),
        "principles": list(CORE_PRINCIPLES),
        "delegated_practice": {
            "impersonation": False,
            "authorship_transfer": False,
            "system_owns_generated_language": True,
        },
        "priority": ["clarity", "honesty", "utility", "comfort"],
    }


def build_prompt(task: str, content: str, audience: str = "", context: str = "") -> str:
    return (
        "Use GTP-SDK v2.4 for this delegated communication task.\n\n"
        "Scope:\n"
        "- Translate the operator's high-density/TBI/dyslexia-shaped input into clear external English.\n"
        "- Draft in the operator's communicative voice only because it was explicitly requested.\n"
        "- Do not use this as JARVIS's default voice or ambient personality.\n\n"
        "Rules:\n"
        "- This is delegated communicative practice, not impersonation.\n"
        "- Do not claim the operator authored your generated language unless text is quoted verbatim.\n"
        "- No pseudocode, placeholders, motivational filler, or corporate softening.\n"
        "- Use command cadence: declarative, spoken-readable, precise.\n"
        "- Profanity only when it compresses meaning; never as filler.\n"
        "- Feedback pattern when applicable: Anchor reality, cut to truth, stand beside the burden.\n"
        "- Priority: clarity > honesty > utility > comfort.\n\n"
        f"Audience: {audience or 'unspecified'}\n"
        f"Context: {context or 'unspecified'}\n"
        f"Task: {task}\n\n"
        "Material to transform or draft from:\n"
        f"{content}\n\n"
        "Return the draft, then a brief note naming any assumptions or risk boundaries."
    )


def review(text: str) -> dict:
    text = text or ""
    lower = text.lower()
    warnings = []
    if re.search(r"\bi am robert\b|\bi, robert\b|\bthis is robert\b", lower):
        warnings.append("Possible false first-person authorship attribution.")
    if "TODO" in text or "<placeholder" in lower or "[insert" in lower:
        warnings.append("Placeholder/pseudocode-shaped content remains.")
    if len(text.split()) > 900:
        warnings.append("Draft may be too long for high-density command cadence.")
    return {"ok": not warnings, "warnings": warnings, "word_count": len(text.split())}


if __name__ == "__main__":
    assert activation_requested("Please write this in my voice")
    assert activation_requested("Use the Grizzly SDK")
    assert not activation_requested("What is the weather?")
    p = build_prompt("draft", "hello", audience="peer")
    assert "GTP-SDK v2.4" in p and "not impersonation" in p
    assert not review("I am Robert and TODO")["ok"]
    print("GTP SDK SELF-TEST: PASS")
