#!/usr/bin/env python3
"""Persistent ambient context for companion-device and dream-cycle scheduling.

The iPhone/watch/CarPlay path feeds compact, operator-owned summaries into
JARVIS: Focus/Sleep state, charging, motion/rest, coarse location, watch-wrist
state, driving state, and check-in events. These are observable signals, not
diagnoses. The dream cycle uses them to decide when maintenance is safe to run
without relying on application close events.
"""
from __future__ import annotations

import json
import os
import pathlib
import time
from typing import Any, Dict, List, Optional


EVENT_LIMIT = 500
TEXT_LIMIT = 500
EXTRA_LIMIT = 30


def _default_path() -> pathlib.Path:
    configured = os.environ.get("JARVIS_AMBIENT_CONTEXT_PATH")
    if configured:
        return pathlib.Path(configured).expanduser()
    return pathlib.Path(__file__).with_name("ambient_context.json")


def _now() -> float:
    return time.time()


def _text(value: Any, limit: int = TEXT_LIMIT) -> str:
    return str(value or "").strip()[:limit]


def _boolish(value: Any) -> Optional[bool]:
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    lowered = str(value).strip().lower()
    if lowered in {"1", "true", "yes", "y", "on"}:
        return True
    if lowered in {"0", "false", "no", "n", "off"}:
        return False
    return None


def _float_between(value: Any, minimum: float, maximum: float) -> Optional[float]:
    if value in (None, ""):
        return None
    number = float(value)
    return max(minimum, min(maximum, number))


def _compact_extra(payload: Any) -> Dict[str, Any]:
    if not isinstance(payload, dict):
        return {}
    out: Dict[str, Any] = {}
    for key, value in payload.items():
        if len(out) >= EXTRA_LIMIT:
            break
        clean_key = _text(key, 80)
        if not clean_key:
            continue
        if isinstance(value, (str, int, float, bool)) or value is None:
            out[clean_key] = _text(value) if isinstance(value, str) else value
        elif isinstance(value, list):
            out[clean_key] = [_text(v, 120) for v in value[:20]]
        elif isinstance(value, dict):
            out[clean_key] = {str(k)[:80]: _text(v, 120) for k, v in list(value.items())[:20]}
        else:
            out[clean_key] = _text(value)
    return out


class AmbientContext:
    def __init__(self, path: Optional[str] = None):
        self.path = pathlib.Path(path).expanduser() if path else _default_path()
        self.data = self._load()

    def _load(self) -> Dict[str, Any]:
        if not self.path.exists():
            return {
                "policy": {
                    "source": "operator-owned iPhone/watch/CarPlay/HomeKit/Blink summaries",
                    "medical_boundary": "observable signals only; do not diagnose or label events",
                    "carplay_boundary": "driving context is treated as active-use context with glanceable/audio-first output",
                    "dream_scheduler": "run maintenance from idle/rest context, not app close",
                    "raw_healthkit_default": "off; companion app should send bands/summaries unless explicitly changed",
                },
                "devices": {},
                "events": [],
                "dream": {
                    "last_micro_dream_at": None,
                    "last_deep_dream_at": None,
                    "last_transition_dream_at": None,
                    "micro_idle_minutes": 7,
                    "deep_idle_minutes": 45,
                    "deep_overdue_hours": 20,
                },
                "runtime": {
                    "last_operator_activity_at": None,
                    "last_runtime_event": None,
                },
            }
        data = json.loads(self.path.read_text())
        if not isinstance(data, dict):
            raise ValueError(f"{self.path} must contain a JSON object")
        data.setdefault("policy", {})
        data.setdefault("devices", {})
        data.setdefault("events", [])
        data.setdefault("dream", {})
        data.setdefault("runtime", {})
        data["policy"].setdefault("source", "operator-owned iPhone/watch/CarPlay/HomeKit/Blink summaries")
        data["policy"].setdefault("medical_boundary", "observable signals only; do not diagnose or label events")
        data["policy"].setdefault("carplay_boundary", "driving context is treated as active-use context with glanceable/audio-first output")
        data["policy"].setdefault("dream_scheduler", "run maintenance from idle/rest context, not app close")
        data["policy"].setdefault("raw_healthkit_default", "off; companion app should send bands/summaries unless explicitly changed")
        data["dream"].setdefault("micro_idle_minutes", 7)
        data["dream"].setdefault("deep_idle_minutes", 45)
        data["dream"].setdefault("deep_overdue_hours", 20)
        return data

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self.data, indent=2, sort_keys=True) + "\n")

    def ingest_event(
        self,
        source: str,
        device_id: str = "",
        kind: str = "state",
        timestamp: Optional[float] = None,
        focus: str = "",
        sleep_focus: Any = None,
        charging: Any = None,
        battery: Any = None,
        motion: str = "",
        active: Any = None,
        location: str = "",
        wrist_state: str = "",
        carplay_connected: Any = None,
        driving: Any = None,
        vehicle_motion: str = "",
        route_state: str = "",
        interaction_mode: str = "",
        heart_rate_band: str = "",
        hrv_band: str = "",
        workout: str = "",
        check_in: str = "",
        confidence: Any = None,
        notes: str = "",
        extra: Any = None,
        **unknown: Any,
    ) -> Dict[str, Any]:
        src = _text(source, 80)
        if not src:
            raise ValueError("source is required")
        ts = float(timestamp) if timestamp not in (None, "") else _now()
        event = {
            "source": src,
            "device_id": _text(device_id or src, 120),
            "kind": _text(kind or "state", 80),
            "timestamp": ts,
            "focus": _text(focus, 120),
            "sleep_focus": _boolish(sleep_focus),
            "charging": _boolish(charging),
            "battery": _float_between(battery, 0.0, 100.0),
            "motion": _text(motion, 120).lower(),
            "active": _boolish(active),
            "location": _text(location, 160).lower(),
            "wrist_state": _text(wrist_state, 120).lower(),
            "carplay_connected": _boolish(carplay_connected),
            "driving": _boolish(driving),
            "vehicle_motion": _text(vehicle_motion, 120).lower(),
            "route_state": _text(route_state, 120).lower(),
            "interaction_mode": _text(interaction_mode, 120).lower(),
            "heart_rate_band": _text(heart_rate_band, 120).lower(),
            "hrv_band": _text(hrv_band, 120).lower(),
            "workout": _text(workout, 120).lower(),
            "check_in": _text(check_in, 160).lower(),
            "confidence": _float_between(confidence, 0.0, 1.0),
            "notes": _text(notes),
            "extra": _compact_extra(extra if extra is not None else unknown),
        }
        device_key = event["device_id"] or src
        self.data.setdefault("devices", {})[device_key] = event
        events = self.data.setdefault("events", [])
        events.append(event)
        del events[:-EVENT_LIMIT]
        self._save()
        return {"ok": True, "event": event, "dream": self.dream_readiness(), "path": str(self.path)}

    def record_runtime_activity(self, event: str = "operator_turn") -> Dict[str, Any]:
        now = _now()
        self.data.setdefault("runtime", {})["last_operator_activity_at"] = now
        self.data.setdefault("runtime", {})["last_runtime_event"] = _text(event, 120)
        self._save()
        return {"ok": True, "last_operator_activity_at": now}

    def mark_dream(self, kind: str = "micro", summary: str = "", source: str = "jarvis") -> Dict[str, Any]:
        clean_kind = _text(kind or "micro", 40).lower()
        if clean_kind not in {"micro", "deep", "transition"}:
            raise ValueError("kind must be micro, deep, or transition")
        now = _now()
        key = {
            "micro": "last_micro_dream_at",
            "deep": "last_deep_dream_at",
            "transition": "last_transition_dream_at",
        }[clean_kind]
        dream = self.data.setdefault("dream", {})
        dream[key] = now
        event = {
            "source": _text(source, 80) or "jarvis",
            "device_id": "jarvis",
            "kind": f"dream_{clean_kind}",
            "timestamp": now,
            "notes": _text(summary),
            "extra": {},
        }
        events = self.data.setdefault("events", [])
        events.append(event)
        del events[:-EVENT_LIMIT]
        self._save()
        return {"ok": True, "kind": clean_kind, "timestamp": now, "dream": self.dream_readiness()}

    def latest(self, source: str = "") -> Dict[str, Any]:
        if source:
            needle = _text(source, 80).lower()
            for event in reversed(self.data.get("events", [])):
                if str(event.get("source", "")).lower() == needle:
                    return dict(event)
            return {}
        events = self.data.get("events", [])
        return dict(events[-1]) if events else {}

    def status(self) -> Dict[str, Any]:
        return {
            "path": str(self.path),
            "policy": dict(self.data.get("policy", {})),
            "devices": dict(self.data.get("devices", {})),
            "runtime": dict(self.data.get("runtime", {})),
            "dream": self.dream_readiness(),
            "event_count": len(self.data.get("events", [])),
            "latest": self.latest(),
        }

    def _recent_events(self, window_seconds: float) -> List[Dict[str, Any]]:
        cutoff = _now() - window_seconds
        return [e for e in self.data.get("events", []) if float(e.get("timestamp") or 0) >= cutoff]

    def dream_readiness(self) -> Dict[str, Any]:
        now = _now()
        dream = self.data.setdefault("dream", {})
        runtime = self.data.setdefault("runtime", {})
        last_activity = runtime.get("last_operator_activity_at")
        idle_seconds = None if not last_activity else max(0.0, now - float(last_activity))
        recent = self._recent_events(15 * 60)
        latest_by_device = list(self.data.get("devices", {}).values())
        observations = recent + latest_by_device

        active_signals = []
        quiet_signals = []
        for event in observations:
            kind = str(event.get("kind") or "").lower()
            motion = str(event.get("motion") or "").lower()
            focus = str(event.get("focus") or "").lower()
            location = str(event.get("location") or "").lower()
            check_in = str(event.get("check_in") or "").lower()
            vehicle_motion = str(event.get("vehicle_motion") or "").lower()
            route_state = str(event.get("route_state") or "").lower()
            interaction_mode = str(event.get("interaction_mode") or "").lower()
            if event.get("active") is True or kind in {"operator_turn", "voice", "screen_active"}:
                active_signals.append(f"{event.get('source')}:active")
            if motion in {"walking", "running", "driving", "workout", "high", "lab_active"}:
                active_signals.append(f"{event.get('source')}:motion={motion}")
            if event.get("driving") is True:
                active_signals.append(f"{event.get('source')}:driving")
            if event.get("carplay_connected") is True and vehicle_motion not in {"parked", "stopped", "idle"}:
                active_signals.append(f"{event.get('source')}:carplay")
            if vehicle_motion in {"moving", "driving", "highway", "city", "traffic"}:
                active_signals.append(f"{event.get('source')}:vehicle={vehicle_motion}")
            if route_state in {"navigating", "rerouting", "guidance_active"}:
                active_signals.append(f"{event.get('source')}:route={route_state}")
            if interaction_mode in {"carplay", "driving"} and vehicle_motion not in {"parked", "stopped", "idle"}:
                active_signals.append(f"{event.get('source')}:mode={interaction_mode}")
            if check_in in {"needs_attention", "responded", "awake"}:
                active_signals.append(f"{event.get('source')}:check_in={check_in}")
            if event.get("sleep_focus") is True or focus in {"sleep", "do not disturb", "dnd", "rest"}:
                quiet_signals.append(f"{event.get('source')}:focus={focus or 'sleep'}")
            if event.get("charging") is True:
                quiet_signals.append(f"{event.get('source')}:charging")
            if motion in {"still", "resting", "low", "none", "sleeping"}:
                quiet_signals.append(f"{event.get('source')}:motion={motion}")
            if location in {"home", "bedroom", "office", "lab"}:
                quiet_signals.append(f"{event.get('source')}:location={location}")

        micro_idle = float(dream.get("micro_idle_minutes") or 7) * 60
        deep_idle = float(dream.get("deep_idle_minutes") or 45) * 60
        last_deep = dream.get("last_deep_dream_at")
        deep_age = None if not last_deep else max(0.0, now - float(last_deep))
        deep_overdue = deep_age is None or deep_age >= float(dream.get("deep_overdue_hours") or 20) * 3600
        idle_for_micro = idle_seconds is not None and idle_seconds >= micro_idle
        idle_for_deep = idle_seconds is not None and idle_seconds >= deep_idle
        quiet_enough = bool(quiet_signals) and not active_signals
        micro_ready = idle_for_micro and not active_signals
        deep_ready = idle_for_deep and quiet_enough and deep_overdue
        return {
            "micro_ready": micro_ready,
            "deep_ready": deep_ready,
            "quiet_enough": quiet_enough,
            "deep_overdue": deep_overdue,
            "idle_seconds": idle_seconds,
            "active_signals": sorted(set(active_signals)),
            "quiet_signals": sorted(set(quiet_signals)),
            "last_micro_dream_at": dream.get("last_micro_dream_at"),
            "last_deep_dream_at": dream.get("last_deep_dream_at"),
            "last_transition_dream_at": dream.get("last_transition_dream_at"),
            "decision_boundary": "observable context only; no clinical interpretation",
        }

    def context_lines(self) -> List[str]:
        lines = [
            "Ambient companion policy: iPhone/watch/HomeKit/Blink inputs are observable context "
            "signals for continuity, support, and dream-cycle timing; do not infer diagnoses from them."
        ]
        readiness = self.dream_readiness()
        lines.append(
            "Dream readiness: "
            f"micro_ready={readiness['micro_ready']}; deep_ready={readiness['deep_ready']}; "
            f"quiet_enough={readiness['quiet_enough']}; active_signals={readiness['active_signals']}; "
            f"quiet_signals={readiness['quiet_signals']}."
        )
        for device_id, event in sorted(self.data.get("devices", {}).items())[:6]:
            lines.append(
                f"Companion {device_id}: source={event.get('source')}; kind={event.get('kind')}; "
                f"focus={event.get('focus') or 'unknown'}; sleep_focus={event.get('sleep_focus')}; "
                f"charging={event.get('charging')}; motion={event.get('motion') or 'unknown'}; "
                f"location={event.get('location') or 'unknown'}; carplay={event.get('carplay_connected')}; "
                f"driving={event.get('driving')}; vehicle={event.get('vehicle_motion') or 'unknown'}."
            )
        return lines


if __name__ == "__main__":
    import tempfile

    p = pathlib.Path(tempfile.gettempdir()) / "jarvis_ambient_context_test.json"
    p.unlink(missing_ok=True)
    ctx = AmbientContext(str(p))
    assert ctx.status()["policy"]["medical_boundary"].startswith("observable")
    ctx.record_runtime_activity("turn")
    ctx.data["runtime"]["last_operator_activity_at"] = time.time() - 60 * 60
    out = ctx.ingest_event(
        source="apple_watch",
        device_id="watch",
        kind="state",
        focus="sleep",
        sleep_focus=True,
        charging=True,
        motion="resting",
        location="home",
        confidence=0.9,
    )
    assert out["ok"]
    ready = ctx.dream_readiness()
    assert ready["micro_ready"] is True
    assert ready["quiet_enough"] is True
    assert ready["decision_boundary"].startswith("observable")
    mark = ctx.mark_dream("deep", "test consolidation")
    assert mark["ok"] and ctx.status()["dream"]["last_deep_dream_at"]
    assert any("Companion watch" in line for line in ctx.context_lines())
    drive = ctx.ingest_event(
        source="carplay",
        device_id="iphone-carplay",
        kind="state",
        carplay_connected=True,
        driving=True,
        vehicle_motion="moving",
        route_state="navigating",
        interaction_mode="carplay",
        confidence=1.0,
    )
    assert drive["ok"]
    assert ctx.dream_readiness()["deep_ready"] is False
    assert any("carplay" in signal for signal in ctx.dream_readiness()["active_signals"])
    p.unlink(missing_ok=True)
    print("AMBIENT CONTEXT SELF-TEST: PASS")
