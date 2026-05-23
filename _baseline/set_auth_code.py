#!/usr/bin/env python3
"""Set JARVIS_AUTH_CODE_SHA256 in ~/research/jarvis/.env without storing the raw code."""
from __future__ import annotations

import getpass
from pathlib import Path

from auth_gate import hash_code, normalize_code


ENV_PATH = Path.home() / "research/jarvis/.env"


def set_env_key(path: Path, key: str, value: str) -> None:
    lines = path.read_text().splitlines() if path.exists() else []
    out = []
    replaced = False
    removed_plain = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("JARVIS_AUTH_CODE="):
            removed_plain = True
            continue
        if stripped.startswith(f"{key}="):
            out.append(f"{key}={value}")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(f"{key}={value}")
    path.write_text("\n".join(out).rstrip() + "\n")
    if removed_plain:
        print("Removed plaintext JARVIS_AUTH_CODE.")


def main() -> int:
    first = getpass.getpass("Private JARVIS authorization code: ")
    second = getpass.getpass("Repeat authorization code: ")
    if normalize_code(first) != normalize_code(second):
        print("Codes did not match after speech-tolerant normalization.")
        return 1
    if len(normalize_code(first)) < 6:
        print("Code too short after normalization; use at least 6 letters/digits.")
        return 1
    set_env_key(ENV_PATH, "JARVIS_AUTH_CODE_SHA256", hash_code(first))
    print(f"Stored JARVIS_AUTH_CODE_SHA256 in {ENV_PATH}; raw code was not written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
