#!/usr/bin/env python3
"""Convex realtime spine for app-facing JARVIS state.

Convex is the live shared state layer: app clients subscribe to queries, while
the Mac bridge publishes runtime state and processes queued control requests
through the same HASP SkillRegistry. Authorization codes are never written to
Convex; SENSITIVE/DESTRUCTIVE requests complete with authorization_required and
must be retried through the local token-gated bridge.
"""
from __future__ import annotations

import os
import time
from typing import Any, Dict, Iterable, Optional


class ConvexRealtime:
    def __init__(self, url: Optional[str] = None, token: Optional[str] = None, client=None,
                 enabled: Optional[bool] = None):
        self.url = url or os.environ.get("CONVEX_URL")
        self.token = token or os.environ.get("JARVIS_CONVEX_REALTIME_TOKEN", "").strip()
        self.enabled = bool(self.url and self.token) if enabled is None else bool(enabled)
        self.last_error = ""
        if not self.enabled:
            self.client = None
        elif client is not None:
            self.client = client
        else:
            from convex import ConvexClient
            self.client = ConvexClient(self.url)

    @classmethod
    def from_env(cls):
        configured = bool(os.environ.get("CONVEX_URL"))
        token_configured = bool(os.environ.get("JARVIS_CONVEX_REALTIME_TOKEN", "").strip())
        enabled = configured and token_configured and os.environ.get("JARVIS_CONVEX_REALTIME", "1") != "0"
        return cls(enabled=enabled)

    def _disabled(self) -> Dict[str, Any]:
        return {"ok": False, "disabled": True,
                "reason": "CONVEX_URL/JARVIS_CONVEX_REALTIME_TOKEN not configured or realtime disabled"}

    def _with_token(self, args: Dict[str, Any]) -> Dict[str, Any]:
        out = {key: value for key, value in args.items() if value is not None}
        out["clientToken"] = self.token
        return out

    def _mutation(self, name: str, args: Dict[str, Any]) -> Dict[str, Any]:
        if not self.enabled or self.client is None:
            return self._disabled()
        try:
            out = self.client.mutation(name, self._with_token(args))
            self.last_error = ""
            return out if isinstance(out, dict) else {"ok": True, "output": out}
        except Exception as exc:
            self.last_error = f"{type(exc).__name__}: {str(exc)[:300]}"
            return {"ok": False, "error": self.last_error}

    def _query(self, name: str, args: Dict[str, Any]) -> Any:
        if not self.enabled or self.client is None:
            return []
        try:
            out = self.client.query(name, self._with_token(args))
            self.last_error = ""
            return out
        except Exception as exc:
            self.last_error = f"{type(exc).__name__}: {str(exc)[:300]}"
            return []

    def publish_state(self, key: str, payload: Dict[str, Any], source: str = "jarvis_bridge") -> Dict[str, Any]:
        return self._mutation("realtime:publishState", {
            "key": str(key),
            "source": source,
            "updatedAt": time.time(),
            "payload": payload,
        })

    def publish_skill_catalog(self, skills: Iterable[Dict[str, Any]], key: str = "default") -> Dict[str, Any]:
        return self._mutation("realtime:publishSkillCatalog", {
            "key": key,
            "updatedAt": time.time(),
            "skills": list(skills),
        })

    def publish_ambient_event(self, event: Dict[str, Any], dream: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        payload = dict(event)
        return self._mutation("realtime:publishAmbientEvent", {
            "source": str(payload.get("source") or "unknown"),
            "deviceId": str(payload.get("device_id") or payload.get("deviceId") or payload.get("source") or "unknown"),
            "kind": str(payload.get("kind") or "state"),
            "timestamp": float(payload.get("timestamp") or time.time()),
            "personId": _optional_text(payload.get("person_id") or payload.get("personId")),
            "memoryScopeId": _optional_text(payload.get("memory_scope_id") or payload.get("memoryScopeId")),
            "payload": payload,
            "dream": dream,
        })

    def publish_skill_result(self, result: Dict[str, Any], request_id: Optional[str] = None) -> Dict[str, Any]:
        payload = dict(result)
        if request_id:
            payload["request_id"] = request_id
        return self.publish_state("latest_skill_result", payload)

    def pending_control_requests(self, limit: int = 20):
        return self._query("realtime:pendingControlRequests", {"limit": int(limit)}) or []

    def claim_control_request(self, request_id: str, runner: str = "mac_bridge") -> Optional[Dict[str, Any]]:
        out = self._mutation("realtime:claimControlRequest", {
            "requestId": request_id,
            "runner": runner,
            "claimedAt": time.time(),
        })
        return out if out else None

    def complete_control_request(self, request_id: str, result: Dict[str, Any]) -> Dict[str, Any]:
        status = "done" if result.get("ok") else "refused" if result.get("refused") else "error"
        return self._mutation("realtime:completeControlRequest", {
            "requestId": request_id,
            "status": status,
            "completedAt": time.time(),
            "ok": bool(result.get("ok")),
            "output": result.get("output"),
            "refused": bool(result.get("refused")),
            "reason": _optional_text(result.get("reason")),
            "error": _optional_text(result.get("error")),
            "authorizationRequired": bool(result.get("authorization_required")),
        })

    def process_pending_controls(self, runtime, limit: int = 10, runner: str = "mac_bridge") -> Dict[str, Any]:
        processed = []
        for request in self.pending_control_requests(limit=limit):
            request_id = str(request.get("requestId") or "")
            if not request_id:
                continue
            claimed = self.claim_control_request(request_id, runner=runner)
            if not claimed:
                continue
            name = request.get("name")
            args = request.get("args") if isinstance(request.get("args"), dict) else {}
            if name == "jarvis_turn":
                text = str(args.get("text") or "").strip()
                out = runtime.turn(user_text=text) if text else {"error": "no text"}
                result = {
                    "ok": not bool(out.get("error")),
                    "skill": "jarvis_turn",
                    "output": out,
                    "refused": False,
                    "reason": "",
                    "error": out.get("error"),
                    "authorization_required": False,
                }
            else:
                res = runtime.skill(name, args, confirm=lambda _skill, _args: False)
                result = {
                    "ok": res.ok,
                    "skill": res.skill,
                    "output": res.output,
                    "refused": res.refused,
                    "reason": res.reason,
                    "error": res.error,
                    "authorization_required": bool(res.refused and "requires authorization" in (res.reason or "").lower()),
                }
            completion = self.complete_control_request(request_id, result)
            processed.append({"request_id": request_id, "skill": result["skill"], "completion": completion})
        return {"ok": True, "processed": processed, "last_error": self.last_error}

    def status(self) -> Dict[str, Any]:
        return {"enabled": self.enabled, "url_configured": bool(self.url),
                "token_configured": bool(self.token), "last_error": self.last_error}


def _optional_text(value: Any) -> Optional[str]:
    text = str(value or "").strip()
    return text or None


if __name__ == "__main__":
    class MockConvex:
        def __init__(self):
            self.mutations = []
            self.pending = [{
                "requestId": "req-1",
                "status": "pending",
                "name": "recall_origin",
                "args": {},
            }]

        def mutation(self, name, args):
            self.mutations.append((name, dict(args)))
            if name == "realtime:claimControlRequest":
                return {"requestId": args["requestId"], "status": "running"}
            if name == "realtime:completeControlRequest":
                return {"ok": True, "requestId": args["requestId"], "status": args["status"]}
            return {"ok": True}

        def query(self, name, args):
            if name == "realtime:pendingControlRequests":
                return list(self.pending)
            return []

    class Result:
        ok = True
        skill = "recall_origin"
        output = ["The Battle of New York."]
        refused = False
        reason = ""
        error = ""

    class Runtime:
        def skill(self, name, args, confirm=None):
            assert confirm is not None
            return Result()

    spine = ConvexRealtime(client=MockConvex(), token="test-token", enabled=True)
    assert spine.publish_state("tts", {"backend": "xtts-v2"})["ok"]
    assert spine.publish_ambient_event({"source": "watch", "device_id": "watch", "kind": "state"})["ok"]
    out = spine.process_pending_controls(Runtime())
    assert out["processed"][0]["request_id"] == "req-1"
    print("CONVEX REALTIME OFFLINE TEST: PASS")
