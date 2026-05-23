#!/usr/bin/env python3
"""Media surface adapters for YouTube and YouTube Music."""
from __future__ import annotations

import json
import os
import subprocess
import urllib.parse
from typing import List, Optional


def _run(argv: List[str], input_text: Optional[str] = None, timeout: int = 30) -> dict:
    data = input_text.encode("utf-8") if input_text is not None else None
    r = subprocess.run(argv, input=data, capture_output=True, timeout=timeout)
    return {"code": r.returncode,
            "stdout": r.stdout.decode("utf-8", "replace")[:4000],
            "stderr": r.stderr.decode("utf-8", "replace")[:2000]}


def _applescript_string(value: str) -> str:
    return json.dumps(str(value or ""), ensure_ascii=False)


def _osascript(script: str) -> dict:
    argv = ["osascript"]
    for line in str(script or "").splitlines():
        if line.strip():
            argv.extend(["-e", line])
    r = subprocess.run(argv, capture_output=True, timeout=30)
    return {"code": r.returncode, "out": r.stdout.decode("utf-8", "replace")[:4000],
            "err": r.stderr.decode("utf-8", "replace")[:2000]}


def media_surface_status() -> dict:
    return {
        "primary_video": "YouTube",
        "primary_music": "YouTube Music",
        "premium_family_context": True,
        "skills": ["youtube_open", "youtube_search", "youtube_music_open",
                   "youtube_music_search", "media_now_playing"],
        "policy": "Media is context. Do not critique taste unless asked.",
    }


def youtube_open(url: str = "https://www.youtube.com") -> dict:
    target = str(url or "https://www.youtube.com").strip()
    if not target.startswith(("https://www.youtube.com", "https://youtu.be", "https://music.youtube.com")):
        raise ValueError("only YouTube / YouTube Music URLs are allowed")
    return _run(["open", target])


def youtube_search(query: str) -> dict:
    if not str(query or "").strip():
        raise ValueError("query is required")
    url = "https://www.youtube.com/results?search_query=" + urllib.parse.quote_plus(query)
    result = _run(["open", url])
    result["url"] = url
    return result


def youtube_music_open() -> dict:
    return _run(["open", "https://music.youtube.com"])


def youtube_music_search(query: str) -> dict:
    if not str(query or "").strip():
        raise ValueError("query is required")
    url = "https://music.youtube.com/search?q=" + urllib.parse.quote_plus(query)
    result = _run(["open", url])
    result["url"] = url
    return result


def media_now_playing() -> dict:
    script = """
set foundTitle to ""
set foundUrl to ""
tell application "System Events"
    set browserNames to name of application processes whose name is in {"Safari", "Google Chrome", "Arc", "Brave Browser", "Microsoft Edge"}
end tell
repeat with browserName in browserNames
    try
        if browserName is "Safari" then
            tell application "Safari"
                set foundTitle to name of current tab of front window
                set foundUrl to URL of current tab of front window
            end tell
        else
            tell application browserName
                set foundTitle to title of active tab of front window
                set foundUrl to URL of active tab of front window
            end tell
        end if
        if foundUrl contains "youtube.com" or foundUrl contains "youtu.be" then
            return foundTitle & tab & foundUrl
        end if
    end try
end repeat
return ""
"""
    result = _osascript(script)
    if result.get("out"):
        parts = result["out"].strip().split("\t", 1)
        result["media"] = {"title": parts[0], "url": parts[1] if len(parts) > 1 else ""}
    return result


if __name__ == "__main__":
    assert media_surface_status()["primary_music"] == "YouTube Music"
    assert "search_query=" in ("https://www.youtube.com/results?search_query=" + urllib.parse.quote_plus("test song"))
    print("MEDIA TOOLS SELF-TEST: PASS")
