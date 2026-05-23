#!/usr/bin/env python3
"""Persistent audio-scene and music-regulation context for JARVIS.

Music is not treated as noise by default. In this environment it is often a
regulation signal for ADHD/autism, so the audio front-end must separate speech,
music, and other sound before deciding what reaches the model.
"""
from __future__ import annotations

import json
import os
import pathlib
import time
from typing import Any, Dict, List, Optional


def _default_path() -> pathlib.Path:
    configured = os.environ.get("JARVIS_AUDIO_CONTEXT_PATH")
    return pathlib.Path(configured).expanduser() if configured else pathlib.Path(__file__).with_name("audio_context.json")


def _string_list(value: Optional[List[str]]) -> List[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError("expected a list of strings")
    return [str(item).strip() for item in value if str(item).strip()]


def _bounded_confidence(value: Any) -> float:
    if value in (None, ""):
        return 0.0
    return max(0.0, min(1.0, float(value)))


class AudioContext:
    def __init__(self, path: Optional[str] = None):
        self.path = pathlib.Path(path).expanduser() if path else _default_path()
        self.data = self._load()

    def _load(self) -> Dict:
        if not self.path.exists():
            return {
                "policy": {
                    "music_is_regulation_signal": True,
                    "do_not_treat_music_as_speech": True,
                    "sentry_requires_wakeword": True,
                    "audio_frontend": "pending_raw_audio_classifier",
                    "real_time_strategy": "streaming_features_and_scene_state_not_full_song_llm_analysis",
                    "hot_path_budget_ms": 250,
                    "llm_receives": "compact scene labels, transcript, deltas, and explicit music questions only",
                },
                "music_profiles": {},
                "scene": {
                    "speech": "unknown",
                    "music": "unknown",
                    "noise": "unknown",
                    "source": "unset",
                    "confidence": 0.0,
                    "updated_at": None,
                },
                "history": [],
            }
        data = json.loads(self.path.read_text())
        if not isinstance(data, dict):
            raise ValueError(f"{self.path} must contain a JSON object")
        data.setdefault("policy", {})
        data.setdefault("music_profiles", {})
        data.setdefault("scene", {})
        data.setdefault("history", [])
        return data

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=2, sort_keys=True) + "\n")

    def status(self) -> Dict:
        return {
            "path": str(self.path),
            "policy": dict(self.data.get("policy", {})),
            "scene": dict(self.data.get("scene", {})),
            "music_profiles": dict(self.data.get("music_profiles", {})),
        }

    def realtime_plan(self) -> Dict:
        return {
            "principle": "JARVIS does not process whole songs with an LLM in the hot path.",
            "hot_path": [
                "Capture 20-50 ms audio frames from the selected device.",
                "Run VAD/wakeword/speech-vs-music-vs-noise locally on rolling windows.",
                "Debounce scene changes and keep a compact current audio state.",
                "Send only transcript plus scene labels/deltas into JARVIS turns.",
            ],
            "music_path": [
                "Treat music as regulation context, not interference by default.",
                "Use Now Playing/ShazamKit metadata when available instead of re-analyzing the whole song.",
                "Extract lightweight features such as loudness, tempo band, speech overlap, and genre/scene class.",
                "Run deeper song analysis only when explicitly requested.",
            ],
            "target_latency": {
                "wakeword_or_vad_ms": "under 100",
                "scene_label_update_ms": "250-1000",
                "llm_added_latency_ms": "0 unless an actual utterance or explicit audio question arrives",
            },
            "path": str(self.path),
        }

    def scene_update(self, speech: str = "unknown", music: str = "unknown", noise: str = "unknown",
                     confidence: float = 0.0, source: str = "manual", notes: str = "",
                     track: str = "", artist: str = "", volume: str = "") -> Dict:
        scene = {
            "speech": str(speech or "unknown").strip().lower(),
            "music": str(music or "unknown").strip().lower(),
            "noise": str(noise or "unknown").strip().lower(),
            "confidence": _bounded_confidence(confidence),
            "source": str(source or "manual").strip(),
            "notes": str(notes or "").strip(),
            "track": str(track or "").strip(),
            "artist": str(artist or "").strip(),
            "volume": str(volume or "").strip(),
            "updated_at": time.time(),
        }
        self.data["scene"] = scene
        history = self.data.setdefault("history", [])
        history.append(scene)
        del history[:-100]
        self._save()
        return {"ok": True, "scene": scene, "path": str(self.path)}

    def music_profile_set(self, person: str = "operator", purpose: str = "", always_on: bool = True,
                          notes: str = "", genres: Optional[List[str]] = None,
                          sensitivities: Optional[List[str]] = None,
                          preferred_volume: str = "", discussion_style: str = "") -> Dict:
        key = str(person or "operator").strip() or "operator"
        profile = {
            "person": key,
            "purpose": str(purpose or "").strip(),
            "always_on": bool(always_on),
            "notes": str(notes or "").strip(),
            "genres": _string_list(genres),
            "sensitivities": _string_list(sensitivities),
            "preferred_volume": str(preferred_volume or "").strip(),
            "discussion_style": str(discussion_style or "").strip(),
            "updated_at": time.time(),
        }
        self.data.setdefault("music_profiles", {})[key.lower()] = profile
        self._save()
        return {"ok": True, "profile": profile, "path": str(self.path)}

    def music_profile_show(self, person: str = "operator") -> Dict:
        key = str(person or "operator").strip().lower() or "operator"
        profile = self.data.get("music_profiles", {}).get(key)
        if not profile:
            raise KeyError(f"unknown music profile {person!r}")
        return {"profile": profile, "path": str(self.path)}

    def context_lines(self) -> List[str]:
        lines = [
            "Audio policy: music is a regulation signal in this environment, not default noise; "
            "separate speech, music, and other sound before reasoning. Real-time path uses "
            "streaming local classification and compact scene state, not full-song LLM analysis."
        ]
        scene = self.data.get("scene", {})
        if scene.get("updated_at"):
            lines.append(
                "Current audio scene: "
                f"speech={scene.get('speech', 'unknown')}; music={scene.get('music', 'unknown')}; "
                f"noise={scene.get('noise', 'unknown')}; track={scene.get('track') or 'unknown'}; "
                f"artist={scene.get('artist') or 'unknown'}; source={scene.get('source') or 'unknown'}."
            )
        profiles = self.data.get("music_profiles", {})
        for profile in profiles.values():
            person = profile.get("person") or "operator"
            purpose = profile.get("purpose") or "regulation"
            always = "usually on" if profile.get("always_on") else "situational"
            lines.append(f"Music profile for {person}: {always}; purpose={purpose}; notes={profile.get('notes') or 'none'}.")
        return lines


if __name__ == "__main__":
    import tempfile

    p = pathlib.Path(tempfile.gettempdir()) / "jarvis_audio_context_test.json"
    p.unlink(missing_ok=True)
    ctx = AudioContext(str(p))
    assert ctx.status()["policy"]["music_is_regulation_signal"] is True
    assert "whole songs" in ctx.realtime_plan()["principle"]
    ctx.music_profile_set(person="operator", purpose="ADHD/autism regulation", genres=["lofi"], notes="usually on")
    ctx.scene_update(speech="absent", music="present", noise="low", confidence=0.9, track="test")
    lines = ctx.context_lines()
    assert any("music is a regulation signal" in line for line in lines)
    assert any("operator" in line for line in lines)
    p.unlink(missing_ok=True)
    print("AUDIO CONTEXT SELF-TEST: PASS")
