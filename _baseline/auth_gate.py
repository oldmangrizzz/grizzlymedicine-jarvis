#!/usr/bin/env python3
"""Code-word authorization for sensitive/destructive skill dispatch.

The bridge token proves the request came from the local cockpit. This code proves
the operator intentionally authorized a high-risk action. The code is never logged;
store either JARVIS_AUTH_CODE or JARVIS_AUTH_CODE_SHA256 in ~/research/jarvis/.env.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
from typing import Optional


_DIGIT_WORDS = {
    "zero": "0",
    "one": "1",
    "two": "2",
    "too": "2",
    "to": "2",
    "three": "3",
    "four": "4",
    "for": "4",
    "five": "5",
    "six": "6",
    "seven": "7",
    "eight": "8",
    "ate": "8",
    "nine": "9",
}


def normalize_code(code: Optional[str]) -> str:
    """Speech-tolerant matching: lowercase, digit words -> digits, keep alnum only."""
    if not code:
        return ""
    tokens = re.findall(r"[a-zA-Z0-9]+", code.lower())
    return "".join(_DIGIT_WORDS.get(t, t) for t in tokens)


def _configured_plaintext() -> str:
    return normalize_code(os.environ.get("JARVIS_AUTH_CODE"))


def _configured_hash() -> str:
    return (os.environ.get("JARVIS_AUTH_CODE_SHA256") or "").strip().lower()


def configured() -> bool:
    return bool(_configured_plaintext() or _configured_hash())


def hash_code(code: str) -> str:
    return hashlib.sha256(normalize_code(code).encode("utf-8")).hexdigest()


def authorize(code: Optional[str]) -> bool:
    candidate = normalize_code(code)
    if not candidate:
        return False

    expected_hash = _configured_hash()
    if expected_hash:
        return hmac.compare_digest(hashlib.sha256(candidate.encode("utf-8")).hexdigest(), expected_hash)

    expected_plain = _configured_plaintext()
    return bool(expected_plain) and hmac.compare_digest(candidate, expected_plain)


if __name__ == "__main__":
    assert normalize_code("Blue seven tango") == "blue7tango"
    assert normalize_code("BLUE-7 TANGO") == "blue7tango"
    assert hash_code("Blue seven tango") == hash_code("blue-7-tango")
    print("AUTH GATE SELF-TEST: PASS")
