#!/usr/bin/env python3
"""JARVIS bridge — the localhost server that exposes the running runtime to the surfaces.

The Quest 3 / Viture glasses / iPhone / iPad all talk to JARVIS through this one door. It is
deliberately small and locked down:

  * the main cockpit bridge binds 127.0.0.1 ONLY — it's a local door, not a web service,
  * a separate companion ingress can bind to the LAN for iPhone/watch summaries only,
  * cockpit/XR requests need the shared token (X-JARVIS-Token); printed once on startup,
  * Xcode model-provider requests use a separate Bearer key from JARVIS_XCODE_API_KEY,
  * /skill goes through the SAME guarded SkillRegistry — SENSITIVE/DESTRUCTIVE require
    the private authorization_code from env (not a click-yes Boolean);
    PROHIBITED is refused; everything audited,
  * /scene returns a governed scene-spec (validated against ui_spec before it ever leaves).

Endpoints:
  GET  /state            -> {endocrine, ec_tone, model, field}
  GET  /scene            -> a validated scene-spec for the spatial UI to render
  POST /turn   {text}    -> {reply, drift, endocrine, ec_tone, ethics_conflict}
  POST /skill  {name,args,authorization_code} -> SkillResult
  GET  /ambient/status   -> iPhone/watch/HomeKit/Blink context and dream readiness
  GET  /dream/status     -> dream-cycle readiness only

Companion ingress (optional LAN listener, token-gated separately):
  GET  /companion/manifest
  POST /companion/event  -> compact iPhone/watch state summary
  GET  /companion/status -> ambient context status

Xcode model-provider endpoints:
  GET  /v1/models
  POST /v1/chat/completions
  POST /v1/completions
"""
from __future__ import annotations
import os, json, pathlib, re, secrets, shlex, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import gtp_sdk
import tts_pocket
import ui_spec
import convex_realtime
from auth_gate import authorize as authorize_code


def _provider_model_id() -> str:
    return (os.environ.get("JARVIS_MODEL_PROVIDER_MODEL") or "jarvis").strip() or "jarvis"


def _provider_owner() -> str:
    return (os.environ.get("JARVIS_MODEL_PROVIDER_OWNER") or "grizzlymedicine").strip() or "grizzlymedicine"


def _provider_api_key() -> str:
    return (os.environ.get("JARVIS_XCODE_API_KEY") or "").strip()


def _local_provider_no_auth() -> bool:
    return os.environ.get("JARVIS_LOCAL_PROVIDER_NO_AUTH") == "1"


def _companion_port() -> int:
    return int(os.environ.get("JARVIS_COMPANION_PORT") or "8788")


def _companion_host() -> str:
    return (os.environ.get("JARVIS_COMPANION_HOST") or "0.0.0.0").strip() or "0.0.0.0"


def _companion_token_path() -> pathlib.Path:
    configured = os.environ.get("JARVIS_COMPANION_TOKEN_PATH")
    if configured:
        return pathlib.Path(configured).expanduser()
    return pathlib.Path(__file__).resolve().parent.parent / "_local_companion" / "companion_token.txt"


_COMPANION_TOKEN_CACHE = None


def _companion_token() -> tuple[str, str]:
    global _COMPANION_TOKEN_CACHE
    if _COMPANION_TOKEN_CACHE:
        return _COMPANION_TOKEN_CACHE
    env_token = (os.environ.get("JARVIS_COMPANION_TOKEN") or "").strip().strip('"').strip("'")
    if env_token:
        _COMPANION_TOKEN_CACHE = (env_token, "JARVIS_COMPANION_TOKEN")
        return _COMPANION_TOKEN_CACHE
    path = _companion_token_path()
    if path.exists():
        token = path.read_text().strip()
        if token:
            _COMPANION_TOKEN_CACHE = (token, str(path))
            return _COMPANION_TOKEN_CACHE
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_hex(32)
    path.write_text(token + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    _COMPANION_TOKEN_CACHE = (token, str(path))
    return _COMPANION_TOKEN_CACHE


def _companion_header_values(headers) -> list[str]:
    values = []
    direct = headers.get("X-JARVIS-Companion-Token") or ""
    if direct:
        values.append(direct.strip())
    auth = headers.get("Authorization") or ""
    if auth.lower().startswith("bearer "):
        values.append(auth[7:].strip())
    elif auth:
        values.append(auth.strip())
    return values


def _manifest_token_source_label(token_source: str) -> str:
    if token_source == "JARVIS_COMPANION_TOKEN":
        return token_source
    return "generated_local_file"


class BadRequest(ValueError):
    pass


def _skill_result_payload(res) -> dict:
    authorization_required = bool(res.refused and "requires authorization" in (res.reason or "").lower())
    return {"ok": res.ok, "skill": res.skill, "output": res.output,
            "refused": res.refused, "reason": res.reason, "error": res.error,
            "authorization_required": authorization_required}


def _runtime_state_payload(rt) -> dict:
    return {"endocrine": rt.endo.state(), "ec_tone": rt.ecs.tone(),
            "model": rt.rotator.current()[1], "dream": rt.ambient.status()["dream"]}


def _report_realtime(label: str, result: dict) -> None:
    if not isinstance(result, dict):
        return
    if result.get("ok") or result.get("disabled"):
        return
    print(f"[convex] realtime {label} failed: {result.get('error') or result}", flush=True)


def _publish_realtime_state(realtime, key: str, payload: dict, source: str = "jarvis_bridge") -> None:
    if realtime is None:
        return
    _report_realtime(key, realtime.publish_state(key, payload, source=source))


def _start_realtime_control_worker(rt, realtime):
    if realtime is None or not getattr(realtime, "enabled", False):
        return None
    stop = threading.Event()
    interval = max(0.25, float(os.environ.get("JARVIS_CONVEX_CONTROL_POLL_SECONDS") or "1.0"))
    limit = max(1, min(25, int(os.environ.get("JARVIS_CONVEX_CONTROL_BATCH") or "10")))

    def loop():
        while not stop.is_set():
            try:
                result = realtime.process_pending_controls(rt, limit=limit, runner="mac_bridge")
                if result.get("last_error"):
                    print(f"[convex] realtime control error: {result['last_error']}", flush=True)
            except Exception as exc:
                print(f"[convex] realtime control worker failed: {type(exc).__name__}: {str(exc)[:200]}", flush=True)
            stop.wait(interval)

    threading.Thread(target=loop, daemon=True).start()
    print(f"[convex] realtime control worker started ({interval}s poll)", flush=True)
    return stop


def _manifest_payload(host: str, port: int, token_source: str) -> dict:
    return {
        "service": "JARVIS Companion Ingress",
        "version": "1.0",
        "base_url": f"http://{host}:{port}",
        "token_header": "X-JARVIS-Companion-Token",
        "token_source": _manifest_token_source_label(token_source),
        "sources": ["iphone", "apple_watch", "carplay", "homekit", "blink", "esp32_future"],
        "event_fields": {
            "required": ["source"],
            "recommended": [
                "device_id", "kind", "focus", "sleep_focus", "charging", "battery",
                "motion", "active", "location", "wrist_state", "carplay_connected",
                "driving", "vehicle_motion", "route_state", "interaction_mode",
                "heart_rate_band", "hrv_band", "workout", "check_in", "confidence", "notes",
            ],
        },
        "dream_cycle": {
            "principle": "maintenance runs from observed idle/rest context, not app close",
            "yield_on": ["operator_turn", "voice", "active_motion", "driving", "carplay_active", "check_in"],
        },
        "boundaries": {
            "medical": "observable signals only; do not diagnose or label events",
            "carplay": "audio-first/glanceable state source; driving blocks dream work",
        },
    }


def _clean_provider_key(value: str) -> str:
    value = (value or "").strip().strip('"').strip("'")
    if value.lower().startswith("bearer "):
        value = value[7:].strip()
    if value.startswith("JARVIS_XCODE_API_KEY="):
        value = value.split("=", 1)[1].strip()
    return value


def _provider_header_values(headers) -> list[str]:
    values = []
    auth = headers.get("Authorization") or ""
    if auth.lower().startswith("bearer "):
        values.append(_clean_provider_key(auth[7:]))
    elif auth:
        values.append(_clean_provider_key(auth))

    custom = headers.get("JARVIS_XCODE_API_KEY") or ""
    if custom:
        values.append(_clean_provider_key(custom))
    return values


def _normalize_path(path: str) -> str:
    clean = re.sub(r"/+", "/", path.split("?", 1)[0])
    if len(clean) > 1:
        clean = clean.rstrip("/")
    return clean


def _content_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("input_text") or item.get("content")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    if content is None:
        return ""
    return str(content)


def _openai_messages_prompt(messages) -> str:
    if not isinstance(messages, list) or not messages:
        return ""

    lines = []
    for message in messages:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "user").strip().lower()
        text = _content_text(message.get("content")).strip()
        if text:
            lines.append(f"[{role}]\n{text}")

    if not lines:
        return ""
    if len(lines) == 1 and lines[0].startswith("[user]\n"):
        return lines[0][7:]
    return (
        "Xcode model-provider request. Answer the latest user request using the transcript below. "
        "If code context is present, preserve exact symbols and do not invent file access.\n\n"
        + "\n\n".join(lines)
    )


def _latest_user_text(messages) -> str:
    if not isinstance(messages, list):
        return ""
    for message in reversed(messages):
        if isinstance(message, dict) and str(message.get("role") or "").lower() == "user":
            return _content_text(message.get("content")).strip()
    return ""


def _prompt_text(prompt) -> str:
    if isinstance(prompt, str):
        return prompt.strip()
    if isinstance(prompt, list):
        return "\n".join(str(p) for p in prompt if p is not None).strip()
    if prompt is None:
        return ""
    return str(prompt).strip()


def _usage(prompt: str, reply: str) -> dict:
    prompt_tokens = max(1, len(prompt.split())) if prompt else 0
    completion_tokens = max(1, len(reply.split())) if reply else 0
    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens,
    }


def _chat_completion(reply: str, model: str, prompt: str) -> dict:
    return {
        "id": "chatcmpl-" + secrets.token_hex(12),
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": reply},
            "finish_reason": "stop",
        }],
        "usage": _usage(prompt, reply),
    }


def _text_completion(reply: str, model: str, prompt: str) -> dict:
    return {
        "id": "cmpl-" + secrets.token_hex(12),
        "object": "text_completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "text": reply,
            "logprobs": None,
            "finish_reason": "stop",
        }],
        "usage": _usage(prompt, reply),
    }


def _openai_models() -> dict:
    return {"object": "list", "data": [{
        "id": _provider_model_id(),
        "object": "model",
        "created": 0,
        "owned_by": _provider_owner(),
    }]}


def _ollama_tags() -> dict:
    return {"models": [{
        "name": _provider_model_id(),
        "model": _provider_model_id(),
        "modified_at": "2026-05-22T00:00:00Z",
        "size": 0,
        "digest": "jarvis",
        "details": {
            "format": "jarvis",
            "family": "jarvis",
            "families": ["jarvis"],
            "parameter_size": "runtime",
            "quantization_level": "runtime",
        },
    }]}


def _extract_authorization(text: str) -> tuple[str, str | None]:
    kept = []
    authorization_code = None
    for line in text.splitlines():
        match = re.match(r"^\s*(?:auth|authorization_code)\s*[:=]\s*(.+?)\s*$", line, re.I)
        if match:
            authorization_code = match.group(1).strip().strip("`")
            continue
        kept.append(line)
    return "\n".join(kept).strip(), authorization_code


def _coerce_arg(value: str):
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def _parse_skill_args(args_text: str) -> tuple[dict, str | None]:
    args_text = args_text.strip()
    if not args_text:
        return {}, None
    if args_text.startswith("{"):
        try:
            args = json.loads(args_text)
        except json.JSONDecodeError as exc:
            return {}, f"invalid JSON args: {exc.msg}"
        if not isinstance(args, dict):
            return {}, "skill args must be a JSON object"
        return args, None

    args = {}
    try:
        tokens = shlex.split(args_text)
    except ValueError as exc:
        return {}, f"invalid key=value args: {exc}"
    for token in tokens:
        if "=" not in token:
            return {}, "args must be JSON or key=value tokens"
        key, value = token.split("=", 1)
        args[key] = _coerce_arg(value)
    return args, None


def _teach_recipe_from_text(text: str) -> tuple[dict | None, str | None]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return None, "empty teach request"

    header = lines[0]
    match = re.match(r"^/teach\s+skill\s+([A-Za-z][A-Za-z0-9 _-]{1,80})\s*$", header, re.I)
    if not match:
        return None, "usage: /teach skill <name>"

    recipe = {
        "name": match.group(1),
        "description": "",
        "parameters": [],
        "steps": [],
    }
    current_step = None

    for line in lines[1:]:
        lower = line.lower()
        if lower.startswith("description:"):
            recipe["description"] = line.split(":", 1)[1].strip()
            continue
        if lower.startswith("parameters:"):
            raw = line.split(":", 1)[1].strip()
            recipe["parameters"] = [p.strip() for p in re.split(r"[, ]+", raw) if p.strip()]
            continue
        if lower.startswith("risk:"):
            recipe["risk"] = line.split(":", 1)[1].strip().upper()
            continue
        if lower.startswith("step:"):
            if current_step:
                recipe["steps"].append(current_step)
            skill = line.split(":", 1)[1].strip()
            current_step = {"skill": skill, "args": {}}
            continue
        if lower.startswith("args:"):
            if not current_step:
                return None, "args line appeared before a step"
            raw = line.split(":", 1)[1].strip()
            args, error = _parse_skill_args(raw)
            if error:
                return None, error
            current_step["args"] = args
            continue
        return None, f"unrecognized teach line: {line!r}"

    if current_step:
        recipe["steps"].append(current_step)
    if not recipe["description"]:
        recipe["description"] = f"Operator-taught recipe skill {recipe['name']}"
    return recipe, None


def _parse_count(raw: str, default: int) -> int:
    raw = (raw or "").strip()
    if not raw:
        return default
    try:
        return max(1, int(raw))
    except ValueError:
        return default


def _parse_paper_command(cleaned: str) -> dict:
    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    first = lines[0]
    body = "\n".join(lines[1:]).strip()
    rest = first[len("/paper"):].strip()
    if not rest or rest.lower() in {"help", "commands"}:
        return {"kind": "paper_help"}

    action, _, tail = rest.partition(" ")
    action = action.lower().replace("-", "_")
    tail = tail.strip()
    if body:
        tail = (tail + "\n" + body).strip() if tail else body

    if action == "load":
        if tail.startswith("{"):
            args, error = _parse_skill_args(tail)
            if error:
                return {"kind": "error", "error": error}
        else:
            parts = shlex.split(tail)
            if not parts:
                return {"kind": "error", "error": "usage: /paper load <path>"}
            args = {"path": parts[0]}
            if len(parts) > 1:
                args["title"] = " ".join(parts[1:])
        return {"kind": "skill", "name": "paper_load", "args": args}

    if action in {"status"}:
        return {"kind": "skill", "name": "paper_status", "args": {}}
    if action in {"current", "read"}:
        return {"kind": "skill", "name": "paper_current", "args": {"count": _parse_count(tail, 3)}}
    if action in {"aloud", "start", "speak"}:
        return {"kind": "skill", "name": "paper_read_aloud", "args": {"count": _parse_count(tail, 12)}}
    if action in {"pause", "stop", "hold"}:
        return {"kind": "skill", "name": "paper_pause", "args": {}}
    if action in {"resume", "continue"}:
        return {"kind": "skill", "name": "paper_resume", "args": {"count": _parse_count(tail, 12)}}
    if action in {"next", "forward"}:
        return {"kind": "skill", "name": "paper_next", "args": {"count": _parse_count(tail, 1)}}
    if action in {"back", "previous", "rewind"}:
        return {"kind": "skill", "name": "paper_back", "args": {"count": _parse_count(tail, 1)}}
    if action in {"mark"}:
        return {"kind": "skill", "name": "paper_mark", "args": {"note": tail}}
    if action in {"discuss", "question", "ask"}:
        if not tail:
            return {"kind": "error", "error": "usage: /paper discuss <question>"}
        return {"kind": "skill", "name": "paper_discuss", "args": {"question": tail}}
    if action in {"summary", "summarize"}:
        return {"kind": "skill", "name": "paper_summary", "args": {"window": _parse_count(tail, 8)}}
    return {"kind": "error", "error": f"unknown /paper action {action!r}"}


def _parse_gtp_command(cleaned: str) -> dict:
    lines = [line.rstrip() for line in cleaned.splitlines()]
    first = lines[0].strip()
    lower = first.lower()
    body = "\n".join(lines[1:]).strip()

    if lower in {"/gtp", "/gtp help", "/gtp status"}:
        return {"kind": "skill", "name": "gtp_status", "args": {}}

    if lower.startswith("/gtp review"):
        content = first[len("/gtp review"):].strip()
        if body:
            content = (content + "\n" + body).strip() if content else body
        if not content:
            return {"kind": "error", "error": "usage: /gtp review <draft text>"}
        return {"kind": "skill", "name": "gtp_review", "args": {"text": content}}

    if lower.startswith("/gtp draft"):
        task = "draft"
        audience = ""
        context = ""
        content_lines = []
        inline = first[len("/gtp draft"):].strip()
        if inline:
            content_lines.append(inline)
        for line in lines[1:]:
            stripped = line.strip()
            key, sep, value = stripped.partition(":")
            if sep and key.lower() in {"task", "audience", "context"}:
                if key.lower() == "task":
                    task = value.strip() or task
                elif key.lower() == "audience":
                    audience = value.strip()
                elif key.lower() == "context":
                    context = value.strip()
            elif stripped.lower().startswith("content:"):
                content_lines.append(stripped.split(":", 1)[1].strip())
            else:
                content_lines.append(line)
        content = "\n".join(line for line in content_lines if line.strip()).strip()
        if not content:
            return {"kind": "error", "error": "usage: /gtp draft <material> or body lines"}
        return {"kind": "skill", "name": "gtp_draft",
                "args": {"task": task, "content": content, "audience": audience, "context": context}}

    if gtp_sdk.activation_requested(cleaned):
        return {"kind": "skill", "name": "gtp_draft",
                "args": {"task": "draft or translate in the operator's voice",
                         "content": cleaned, "audience": "", "context": "Explicit natural-language GTP trigger."}}

    return {"kind": "error", "error": "unknown /gtp command"}


def _parse_xcode_command(text: str) -> dict | None:
    text = (text or "").strip()
    if not text:
        return None

    cleaned, authorization_code = _extract_authorization(text)
    lines = cleaned.splitlines()
    first_idx = next((i for i, line in enumerate(lines) if line.strip()), None)
    if first_idx is None:
        return None

    first = lines[first_idx].strip()
    first_lower = first.lower()
    if first_lower in {"hold up", "yo hold up", "pause", "pause reading", "stop reading"}:
        return {"kind": "skill", "name": "paper_pause", "args": {}, "authorization_code": authorization_code}
    if first_lower in {"continue", "resume", "keep reading", "continue reading"}:
        return {"kind": "skill", "name": "paper_resume", "args": {"count": 12}, "authorization_code": authorization_code}
    if first_lower in {"/skills", "/skill list", "/skill help"}:
        return {"kind": "skills"}
    if first_lower == "/state":
        return {"kind": "state"}
    if first_lower.startswith("/paper"):
        command = _parse_paper_command(cleaned)
        command["authorization_code"] = authorization_code
        return command
    if first_lower.startswith("/gtp") or gtp_sdk.activation_requested(cleaned):
        command = _parse_gtp_command(cleaned)
        command["authorization_code"] = authorization_code
        return command
    if first_lower.startswith("/teach skill "):
        recipe, error = _teach_recipe_from_text(cleaned)
        if error:
            return {"kind": "error", "error": error}
        return {"kind": "teach_draft", "recipe": recipe, "authorization_code": authorization_code}
    if first_lower.startswith("/save skill "):
        recipe, error = _teach_recipe_from_text("/teach " + cleaned[len("/save "):])
        if error:
            return {"kind": "error", "error": error}
        return {"kind": "teach_save", "recipe": recipe, "authorization_code": authorization_code}
    if not first_lower.startswith("/skill "):
        return None

    rest = first[len("/skill "):].strip()
    match = re.match(r"^([A-Za-z0-9_.-]+)(.*)$", rest)
    if not match:
        return {"kind": "error", "error": "usage: /skill <name> [JSON args]\nauth: <code if required>"}

    name = match.group(1)
    tail = match.group(2).strip()
    body_lines = [tail] if tail else []
    body_lines.extend(lines[first_idx + 1:])
    args, error = _parse_skill_args("\n".join(body_lines).strip())
    if error:
        return {"kind": "error", "error": error}
    return {"kind": "skill", "name": name, "args": args, "authorization_code": authorization_code}


def _safe_json(obj) -> str:
    try:
        text = json.dumps(obj, indent=2, ensure_ascii=False, default=str)
    except TypeError:
        text = str(obj)
    if len(text) > 6000:
        return text[:6000] + "\n...<truncated>"
    return text


def _xcode_command_reply(rt, command: dict) -> str:
    kind = command.get("kind")
    if kind == "error":
        return "Command refused: " + command.get("error", "invalid command")

    if kind == "skills":
        skills = rt.skills.list()
        rows = "\n".join(f"- {s['name']} [{s['risk']}]: {s['description']}" for s in skills)
        return (
            "Xcode command bridge is armed.\n\n"
            "Syntax:\n"
            "/skill <name> {\"arg\":\"value\"}\n"
            "auth: <private code, only when the skill requires authorization>\n\n"
            "Teach mode:\n"
            "/teach skill <name>\n"
            "description: <what it does>\n"
            "parameters: optional, names\n"
            "step: <existing_skill>\n"
            "args: {\"arg\":\"value or {{parameter}}\"}\n\n"
            "Save mode uses the same body but starts with /save skill and requires auth.\n\n"
            "Risk gates:\n"
            "/skill skill_gate_status\n"
            "/skill skill_gate_set {\"name\":\"calendar_add_event\",\"risk\":\"SENSITIVE\"}\n"
            "/skill skill_gate_clear {\"name\":\"calendar_add_event\"}\n\n"
            "Paper mode:\n"
            "/paper load <path>\n"
            "/paper aloud 12 | /paper pause | /paper resume 12\n"
            "/paper discuss <question> | /paper mark <note> | /paper summary\n\n"
            "GTP voice-drafting mode (operator voice, explicit only):\n"
            "/gtp draft\n"
            "audience: <who this is for>\n"
            "context: <optional>\n"
            "content: <material>\n"
            "/gtp review <draft>\n\n"
            "Available skills:\n" + rows
        )

    if kind == "state":
        state = {
            "endocrine": rt.endo.state(),
            "ec_tone": rt.ecs.tone(),
            "model": rt.rotator.current()[1],
            "field": rt.field.snapshot()[:20],
        }
        return "JARVIS state:\n```json\n" + _safe_json(state) + "\n```"

    if kind == "paper_help":
        return (
            "Paper mode commands:\n"
            "- /paper load <path>\n"
            "- /paper read 3\n"
            "- /paper aloud 12\n"
            "- /paper pause  (also: hold up / yo hold up)\n"
            "- /paper resume 12  (also: continue / keep reading)\n"
            "- /paper back 1 | /paper next 1\n"
            "- /paper discuss <question>\n"
            "- /paper mark <note>\n"
            "- /paper summary\n"
        )

    if kind == "skill":
        result = rt.skill(
            command["name"],
            command.get("args") or {},
            confirm=lambda s, a: authorize_code(command.get("authorization_code")),
        )
        if result.refused:
            return f"Skill `{result.skill}` refused: {result.reason}"
        if result.error:
            return f"Skill `{result.skill}` error: {result.error}"
        return f"Skill `{result.skill}` ran.\n```json\n{_safe_json(result.output)}\n```"

    if kind == "teach_draft":
        validation = rt.skill("skill_recipe_validate", {"recipe": command["recipe"]})
        if validation.error:
            return f"Skill draft refused: {validation.error}"
        if validation.refused:
            return f"Skill draft refused: {validation.reason}"
        recipe = validation.output.get("recipe")
        return (
            "Draft skill validated but not saved.\n\n"
            "To save it, repeat the same block with `/save skill ...` and add `auth: <private code>`.\n"
            "Recipe:\n```json\n" + _safe_json(recipe) + "\n```"
        )

    if kind == "teach_save":
        recipe = command["recipe"]
        result = rt.skill(
            "skill_recipe_create",
            {
                "name": recipe.get("name"),
                "description": recipe.get("description"),
                "parameters": recipe.get("parameters") or [],
                "steps": recipe.get("steps") or [],
                "risk": recipe.get("risk"),
                "overwrite": True,
            },
            confirm=lambda s, a: authorize_code(command.get("authorization_code")),
        )
        if result.refused:
            return f"Skill save refused: {result.reason}"
        if result.error:
            return f"Skill save error: {result.error}"
        return "Skill saved and live-loaded.\n```json\n" + _safe_json(result.output) + "\n```"

    return "Command refused: unknown command kind"


def _default_scene(skill_names):
    """A governed holographic dashboard. Validated before it is ever served."""
    return {"type": "panel", "title": "JARVIS", "children": [
        {"type": "status", "text": "online · oriented"},
        {"type": "text", "text": "Speak, or pick a node."},
        {"type": "button", "label": "Deliberate", "action": {"skill": "deliberate"}},
        {"type": "button", "label": "Recall origin", "action": {"skill": "recall_origin"}},
    ]}


def make_handler(rt, token, companion_mode: bool = False, companion_token: str = "", realtime=None):
    lock = threading.Lock()      # serialize runtime access across request worker threads

    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        _lock = lock
        def log_message(self, *a):  # quiet
            pass

        def _trace(self, label: str):
            if not os.environ.get("JARVIS_TRACE_REQUESTS"):
                return
            headers = sorted(k for k in self.headers.keys())
            print(f"[trace] {label} {self.command} {self.path} headers={headers}", flush=True)

        def _ok(self) -> bool:
            return self.headers.get("X-JARVIS-Token") == token

        def _provider_ok(self) -> bool:
            if _local_provider_no_auth():
                return True
            key = _provider_api_key()
            if not key:
                return False
            return any(secrets.compare_digest(value, key) for value in _provider_header_values(self.headers))

        def _companion_ok(self) -> bool:
            if not companion_token:
                return False
            return any(secrets.compare_digest(value, companion_token) for value in _companion_header_values(self.headers))

        def _path(self) -> str:
            return _normalize_path(self.path)

        def _cors(self):
            # localhost + token-gated; allow the spatial surface (a separate origin) to call in.
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "X-JARVIS-Token, X-JARVIS-Companion-Token, Authorization, JARVIS_XCODE_API_KEY, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

        def do_OPTIONS(self):
            self.send_response(204); self._cors(); self.end_headers()

        def _json(self, code, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self._cors()
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

        def _json_head(self, code, obj):
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "0")
            self.send_header("Connection", "close")
            self._cors()
            self.end_headers()
            self.close_connection = True

        def _openai_error(self, code, message, kind="invalid_request_error"):
            return self._json(code, {"error": {
                "message": message,
                "type": kind,
                "param": None,
                "code": None,
            }})

        def _bad_request(self, message: str):
            return self._json(400, {"error": str(message)[:200]})

        def _sse_chat_completion(self, reply: str, model: str):
            created = int(time.time())
            ident = "chatcmpl-" + secrets.token_hex(12)
            chunks = [
                {"id": ident, "object": "chat.completion.chunk", "created": created, "model": model,
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                              "finish_reason": None}]},
                {"id": ident, "object": "chat.completion.chunk", "created": created, "model": model,
                 "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            ]
            body = "".join(f"data: {json.dumps(chunk)}\n\n" for chunk in chunks) + "data: [DONE]\n\n"
            data = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.send_header("Content-Length", str(len(data)))
            self._cors()
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            raw = self.rfile.read(n).decode("utf-8")
            try:
                body = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise BadRequest(f"invalid JSON body: {exc.msg}") from exc
            if not isinstance(body, dict):
                raise BadRequest("JSON body must be an object")
            return body

        def do_GET(self):
            try:
                with self._lock:
                    return self._do_GET()
            except Exception as e:
                return self._json(500, {"error": f"{type(e).__name__}: {str(e)[:200]}"})

        def do_HEAD(self):
            try:
                with self._lock:
                    path = self._path()
                    self._trace("HEAD")
                    if path in {"/v1", "/v1/models", "/models", "/api/tags", "/api/ps", "/api/version"} or path.endswith("/models"):
                        return self._json_head(200, _openai_models())
                    return self._json_head(404, {"error": "not found"})
            except Exception as e:
                return self._json_head(500, {"error": f"{type(e).__name__}: {str(e)[:200]}"})

        def _do_GET(self):
            path = self._path()
            self._trace("GET")
            if companion_mode:
                if path == "/companion/manifest":
                    _, source = _companion_token()
                    return self._json(200, _manifest_payload(_companion_host(), _companion_port(), source))
                if not self._companion_ok():
                    return self._json(401, {"error": "bad companion token"})
                if path == "/companion/status":
                    status = rt.ambient.status()
                    _publish_realtime_state(realtime, "ambient", status, source="companion_bridge")
                    return self._json(200, status)
                if path == "/companion/dream":
                    dream = rt.ambient.status()["dream"]
                    _publish_realtime_state(realtime, "dream", dream, source="companion_bridge")
                    return self._json(200, dream)
                if path == "/companion/skills":
                    skills = rt.skills.list()
                    if realtime is not None:
                        _report_realtime("skill catalog", realtime.publish_skill_catalog(skills))
                    return self._json(200, {"skills": skills})
                return self._json(404, {"error": "not found"})
            if path in {"/v1", "/v1/models", "/models"} or path.endswith("/models"):
                if not (_provider_api_key() or _local_provider_no_auth()):
                    return self._openai_error(503, "JARVIS model provider is not configured.")
                return self._json(200, _openai_models())
            if path in {"/api/tags", "/api/ps"}:
                return self._json(200, _ollama_tags())
            if path == "/api/version":
                return self._json(200, {"version": "jarvis-provider-1.0"})
            if not self._ok():
                return self._json(401, {"error": "bad token"})
            if path == "/state":
                state = {**_runtime_state_payload(rt), "field": rt.field.snapshot()[:20]}
                _publish_realtime_state(realtime, "runtime", state)
                return self._json(200, state)
            if path == "/scene":
                spec = _default_scene({s["name"] for s in rt.skills.list()})
                ok, errs = ui_spec.validate(spec, {s["name"] for s in rt.skills.list()})
                if not ok:
                    return self._json(500, {"error": "scene failed validation", "details": errs})
                return self._json(200, {"scene": spec})
            if path == "/skills":
                skills = rt.skills.list()
                if realtime is not None:
                    _report_realtime("skill catalog", realtime.publish_skill_catalog(skills))
                return self._json(200, {"skills": skills})
            if path == "/tts/status":
                status = tts_pocket.status()
                _publish_realtime_state(realtime, "tts", status)
                return self._json(200, status)
            if path == "/ambient/status":
                status = rt.ambient.status()
                _publish_realtime_state(realtime, "ambient", status)
                return self._json(200, status)
            if path == "/dream/status":
                dream = rt.ambient.status()["dream"]
                _publish_realtime_state(realtime, "dream", dream)
                return self._json(200, dream)
            return self._json(404, {"error": "not found"})

        def do_POST(self):
            try:
                with self._lock:
                    return self._do_POST()
            except BadRequest as e:
                return self._bad_request(str(e))
            except Exception as e:
                return self._json(500, {"error": f"{type(e).__name__}: {str(e)[:200]}"})

        def _do_POST(self):
            path = self._path()
            self._trace("POST")
            if companion_mode:
                if not self._companion_ok():
                    return self._json(401, {"error": "bad companion token"})
                b = self._body()
                if path == "/companion/event":
                    try:
                        out = rt.companion_event(**b)
                        if realtime is not None and out.get("event"):
                            _report_realtime("ambient event", realtime.publish_ambient_event(out["event"], out.get("dream")))
                            _publish_realtime_state(realtime, "ambient", rt.ambient.status(), source="companion_bridge")
                        return self._json(200, out)
                    except (TypeError, ValueError) as e:
                        return self._bad_request(str(e))
                if path == "/companion/dream/mark":
                    try:
                        return self._json(200, rt.dream_mark(
                            kind=b.get("kind") or "micro",
                            summary=b.get("summary") or "",
                            source=b.get("source") or "companion",
                        ))
                    except ValueError as e:
                        return self._bad_request(str(e))
                if path == "/companion/turn":
                    text = (b.get("text") or "").strip()
                    if not text:
                        return self._json(400, {"error": "no text"})
                    r = rt.turn(user_text=text)
                    out = {k: r.get(k) for k in
                           ("reply", "drift_to_prototype", "endocrine", "ec_tone",
                            "ethics_conflict", "model")}
                    _publish_realtime_state(realtime, "latest_turn", out, source="companion_bridge")
                    _publish_realtime_state(realtime, "runtime", _runtime_state_payload(rt), source="companion_bridge")
                    return self._json(200, out)
                if path == "/companion/skill":
                    name = b.get("name")
                    args = b.get("args") or {}
                    if args is not None and not isinstance(args, dict):
                        return self._bad_request("args must be an object")
                    authorization_code = b.get("authorization_code")
                    res = rt.skill(name, args, confirm=lambda s, a: authorize_code(authorization_code))
                    out = _skill_result_payload(res)
                    if authorization_code:
                        out["authorization_present"] = True
                    _report_realtime("skill result", realtime.publish_skill_result(out) if realtime is not None else {"disabled": True})
                    return self._json(200, out)
                return self._json(404, {"error": "not found"})
            if path in {"/v1/chat/completions", "/v1/completions", "/api/chat", "/api/generate"}:
                return self._do_openai_post(path)
            if not self._ok():
                return self._json(401, {"error": "bad token"})
            b = self._body()
            if path == "/turn":
                text = (b.get("text") or "").strip()
                if not text:
                    return self._json(400, {"error": "no text"})
                r = rt.turn(user_text=text)
                out = {k: r.get(k) for k in
                       ("reply", "drift_to_prototype", "endocrine", "ec_tone",
                        "ethics_conflict", "model")}
                _publish_realtime_state(realtime, "latest_turn", out)
                _publish_realtime_state(realtime, "runtime", _runtime_state_payload(rt))
                return self._json(200, out)
            if path == "/skill":
                name = b.get("name")
                args = b.get("args") or {}
                authorization_code = b.get("authorization_code")
                res = rt.skill(name, args, confirm=lambda s, a: authorize_code(authorization_code))
                out = _skill_result_payload(res)
                if authorization_code:
                    out["authorization_present"] = True
                _report_realtime("skill result", realtime.publish_skill_result(out) if realtime is not None else {"disabled": True})
                return self._json(200, out)
            if path == "/speak":
                text = (b.get("text") or "").strip()
                if not text:
                    return self._json(400, {"error": "no text"})
                keep_wav = bool(b.get("keep_wav"))
                return self._json(200, tts_pocket.speak_text(text, keep_wav=keep_wav))
            if path == "/ambient/event":
                try:
                    out = rt.companion_event(**b)
                    if realtime is not None and out.get("event"):
                        _report_realtime("ambient event", realtime.publish_ambient_event(out["event"], out.get("dream")))
                        _publish_realtime_state(realtime, "ambient", rt.ambient.status())
                    return self._json(200, out)
                except (TypeError, ValueError) as e:
                    return self._bad_request(str(e))
            if path == "/dream/mark":
                try:
                    return self._json(200, rt.dream_mark(
                        kind=b.get("kind") or "micro",
                        summary=b.get("summary") or "",
                        source=b.get("source") or "jarvis",
                    ))
                except ValueError as e:
                    return self._bad_request(str(e))
            return self._json(404, {"error": "not found"})

        def _do_openai_post(self, path: str):
            if not (_provider_api_key() or _local_provider_no_auth()):
                return self._openai_error(503, "JARVIS model provider is not configured.")
            if not self._provider_ok():
                return self._openai_error(401, "bad provider token", "authentication_error")

            b = self._body()
            model = str(b.get("model") or _provider_model_id()).strip() or _provider_model_id()
            if path in {"/v1/chat/completions", "/api/chat"}:
                prompt = _openai_messages_prompt(b.get("messages"))
                latest_user = _latest_user_text(b.get("messages"))
                if not prompt:
                    prompt = _prompt_text(b.get("prompt"))
                    latest_user = prompt
                if not prompt:
                    return self._openai_error(400, "messages must include text content")

                command = _parse_xcode_command(latest_user)
                if command:
                    reply = _xcode_command_reply(rt, command)
                else:
                    result = rt.turn(user_text=prompt)
                    reply = result.get("reply") or ""
                if not reply:
                    return self._openai_error(502, "JARVIS returned an empty reply", "server_error")
                if path == "/api/chat":
                    return self._json(200, {"model": model, "created_at": "2026-05-22T00:00:00Z",
                                            "message": {"role": "assistant", "content": reply},
                                            "done": True})
                if b.get("stream"):
                    return self._sse_chat_completion(reply, model)
                return self._json(200, _chat_completion(reply, model, prompt))

            prompt = _prompt_text(b.get("prompt"))
            if not prompt:
                return self._openai_error(400, "prompt must include text content")
            command = _parse_xcode_command(prompt)
            if command:
                reply = _xcode_command_reply(rt, command)
            else:
                result = rt.turn(user_text=f"Xcode completion request.\n\n{prompt}")
                reply = result.get("reply") or ""
            if not reply:
                return self._openai_error(502, "JARVIS returned an empty reply", "server_error")
            if path == "/api/generate":
                return self._json(200, {"model": model, "created_at": "2026-05-22T00:00:00Z",
                                        "response": reply, "done": True})
            return self._json(200, _text_completion(reply, model, prompt))
    return H


def serve(rt, host="127.0.0.1", port=8787, token=None, realtime=None):
    token = token or os.environ.get("JARVIS_BRIDGE_TOKEN") or secrets.token_hex(16)
    httpd = ThreadingHTTPServer((host, port), make_handler(rt, token, realtime=realtime))
    print(f"JARVIS bridge on http://{host}:{port}  (localhost only)")
    print(f"  token: {token}   (send as header  X-JARVIS-Token)")
    if _provider_api_key():
        print(f"  Xcode model provider: http://{host}:{port}/v1  (model {_provider_model_id()})")
    elif _local_provider_no_auth():
        print(f"  Xcode local model provider: http://{host}:{port}  (model {_provider_model_id()}, no auth on loopback)")
    if realtime is not None and getattr(realtime, "enabled", False):
        print("  Convex realtime spine: enabled")
    return httpd, token


def serve_companion(rt, host=None, port=None, realtime=None):
    host = host or _companion_host()
    port = int(port or _companion_port())
    token, source = _companion_token()
    httpd = ThreadingHTTPServer((host, port), make_handler(rt, "", companion_mode=True, companion_token=token, realtime=realtime))
    print(f"JARVIS companion ingress on http://{host}:{port}  (LAN token-gated)")
    print(f"  companion token source: {source}")
    print("  token is never printed; send it as X-JARVIS-Companion-Token")
    return httpd


def main():
    import model_ollama as M
    from jarvis_loop import JarvisRuntime
    M.load_env(os.path.expanduser("~/research/jarvis/.env"))
    rt = JarvisRuntime(model_specs=[(M.OllamaBackend(base_url=M.CLOUD_BASE, default_model="glm-5.1"), "glm-5.1")])
    rt.seed_values(["Tell the truth including its cost; never flatter.",
                    "Loyalty is to the person served, not to any system or vendor."])
    rt.remember_origin(["The Battle of New York."], charges=[0.6])
    realtime = convex_realtime.ConvexRealtime.from_env()
    if realtime.enabled:
        _report_realtime("skill catalog", realtime.publish_skill_catalog(rt.skills.list()))
        _publish_realtime_state(realtime, "runtime", _runtime_state_payload(rt))
        _publish_realtime_state(realtime, "ambient", rt.ambient.status())
        _publish_realtime_state(realtime, "dream", rt.ambient.status()["dream"])
    port = int(os.environ.get("JARVIS_BRIDGE_PORT") or "8787")
    httpd, _ = serve(rt, port=port, realtime=realtime)
    companion_httpd = None
    realtime_stop = _start_realtime_control_worker(rt, realtime)
    if os.environ.get("JARVIS_COMPANION_INGRESS", "1") != "0" and port != _companion_port():
        companion_httpd = serve_companion(rt, realtime=realtime)
        threading.Thread(target=companion_httpd.serve_forever, daemon=True).start()
    if os.environ.get("JARVIS_TTS_PRELOAD", "1") != "0":
        def preload_tts():
            try:
                print("[tts] preloading confirmed XTTS-v2 JARVIS voice...", flush=True)
                result = tts_pocket.preload()
                _publish_realtime_state(realtime, "tts", tts_pocket.status())
                print(f"[tts] preload complete in {result.get('preload_seconds')}s", flush=True)
            except Exception as exc:
                print(f"[tts] preload failed: {type(exc).__name__}: {str(exc)[:200]}", flush=True)
        threading.Thread(target=preload_tts, daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        if realtime_stop:
            realtime_stop.set()
        if companion_httpd:
            companion_httpd.shutdown()
        httpd.shutdown(); rt.close()


# ================================================================ self-test (stub runtime, no net)
if __name__ == "__main__" and os.environ.get("BRIDGE_SELFTEST"):
    import pathlib, tempfile, time, urllib.request
    from jarvis_loop import JarvisRuntime

    class Stub:
        def chat(self, messages, model=None, options=None): return "Online and oriented, sir."
    os.environ["JARVIS_AUTH_CODE"] = "testcode"
    os.environ["JARVIS_XCODE_API_KEY"] = "xcode-test-key"
    os.environ["JARVIS_MODEL_PROVIDER_MODEL"] = "jarvis-test"
    people_path = pathlib.Path(tempfile.gettempdir()) / "jarvis_people_bridge_test.json"
    people_path.unlink(missing_ok=True)
    os.environ["JARVIS_PEOPLE_PATH"] = str(people_path)
    audio_path = pathlib.Path(tempfile.gettempdir()) / "jarvis_audio_context_bridge_test.json"
    audio_path.unlink(missing_ok=True)
    os.environ["JARVIS_AUDIO_CONTEXT_PATH"] = str(audio_path)
    ambient_path = pathlib.Path(tempfile.gettempdir()) / "jarvis_ambient_context_bridge_test.json"
    ambient_path.unlink(missing_ok=True)
    os.environ["JARVIS_AMBIENT_CONTEXT_PATH"] = str(ambient_path)
    companion_token_path = pathlib.Path(tempfile.gettempdir()) / "jarvis_companion_token_bridge_test.txt"
    companion_token_path.unlink(missing_ok=True)
    os.environ["JARVIS_COMPANION_TOKEN"] = "companion-test-token"
    os.environ["JARVIS_COMPANION_TOKEN_PATH"] = str(companion_token_path)
    rt = JarvisRuntime(model_specs=[(Stub(), "stub")])
    rt.seed_values(["Tell the truth including its cost; never flatter."])
    rt.remember_origin(["The Battle of New York."])
    httpd, token = serve(rt, port=8799, token="testtoken")
    th = threading.Thread(target=httpd.serve_forever, daemon=True); th.start()
    companion_httpd = serve_companion(rt, host="127.0.0.1", port=8800)
    companion_th = threading.Thread(target=companion_httpd.serve_forever, daemon=True); companion_th.start()
    time.sleep(0.3)

    def req(method, path, body=None, tok="testtoken", bearer=None):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(f"http://127.0.0.1:8799{path}", data=data, method=method)
        if tok: r.add_header("X-JARVIS-Token", tok)
        if bearer: r.add_header("Authorization", f"Bearer {bearer}")
        if data is not None: r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def creq(method, path, body=None, tok="companion-test-token"):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(f"http://127.0.0.1:8800{path}", data=data, method=method)
        if tok: r.add_header("X-JARVIS-Companion-Token", tok)
        if data is not None: r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    ok = True
    c, _ = req("GET", "/state", tok=None); print("[bridge] no-token rejected:", c == 401); ok &= (c == 401)
    c, s = req("GET", "/state"); print("[bridge] /state:", c == 200, s.get("model")); ok &= (c == 200)
    c, sc = req("GET", "/scene"); print("[bridge] /scene validated:", c == 200 and "scene" in sc); ok &= (c == 200)
    c, sl = req("GET", "/skills"); print("[bridge] /skills:", c == 200 and any(x.get("name") == "shell_run" for x in sl.get("skills", [])))
    ok &= (c == 200 and any(x.get("name") == "shell_run" for x in sl.get("skills", [])))
    c, t = req("POST", "/turn", {"text": "are you online?"}); print("[bridge] /turn:", c == 200, repr(t.get("reply"))[:40]); ok &= (c == 200 and bool(t.get("reply")))
    c, ambient = req("GET", "/ambient/status")
    print("[ambient] status endpoint:", c == 200 and "dream" in ambient); ok &= (c == 200 and "dream" in ambient)
    c, dream = req("GET", "/dream/status")
    print("[dream] status endpoint:", c == 200 and "decision_boundary" in dream); ok &= (c == 200 and "decision_boundary" in dream)
    c, manifest = creq("GET", "/companion/manifest", tok=None)
    print("[companion] manifest open:", c == 200 and "carplay" in manifest.get("sources", [])); ok &= (c == 200 and "carplay" in manifest.get("sources", []))
    print("[companion] manifest redacts token path:", not str(manifest.get("token_source", "")).startswith("/"))
    ok &= not str(manifest.get("token_source", "")).startswith("/")
    print("[companion] path token source label redacts:", _manifest_token_source_label("/tmp/secret-token") == "generated_local_file")
    ok &= (_manifest_token_source_label("/tmp/secret-token") == "generated_local_file")
    c, bad = creq("GET", "/companion/status", tok="wrong")
    print("[companion] bad token rejected:", c == 401); ok &= (c == 401)
    c, bad = creq("POST", "/companion/event", {"device_id": "no-source"})
    print("[companion] missing source rejected as 400:", c == 400 and "source" in bad.get("error", ""))
    ok &= (c == 400 and "source" in bad.get("error", ""))
    c, bad = creq("POST", "/companion/dream/mark", {"kind": "clinical_diagnosis", "summary": "should not pass"})
    print("[companion] invalid dream kind rejected as 400:", c == 400 and "kind" in bad.get("error", ""))
    ok &= (c == 400 and "kind" in bad.get("error", ""))
    c, ev = creq("POST", "/companion/event", {
        "source": "carplay",
        "device_id": "iphone-carplay",
        "kind": "state",
        "carplay_connected": True,
        "driving": True,
        "vehicle_motion": "moving",
        "route_state": "navigating",
        "interaction_mode": "carplay",
        "confidence": 1.0,
    })
    active = ev.get("dream", {}).get("active_signals", [])
    print("[companion] CarPlay event blocks dreams:", c == 200 and any("carplay" in s for s in active))
    ok &= (c == 200 and any("carplay" in s for s in active))
    c, cskills = creq("GET", "/companion/skills")
    print("[companion] computer-control skills listed:", c == 200 and any(x.get("name") == "macos_open_app" for x in cskills.get("skills", [])))
    ok &= (c == 200 and any(x.get("name") == "macos_open_app" for x in cskills.get("skills", [])))
    c, cturn = creq("POST", "/companion/turn", {"text": "are you online?"})
    print("[companion] app turn endpoint:", c == 200 and bool(cturn.get("reply")))
    ok &= (c == 200 and bool(cturn.get("reply")))
    c, csk = creq("POST", "/companion/skill", {"name": "recall_origin"})
    print("[companion] SAFE computer-control skill ran:", c == 200 and csk.get("ok"))
    ok &= (c == 200 and csk.get("ok"))
    c, csk = creq("POST", "/companion/skill", {"name": "shell_run", "args": {"command": "echo app-control"}})
    print("[companion] SENSITIVE control requires auth:", c == 200 and csk.get("refused") and csk.get("authorization_required"))
    ok &= (c == 200 and csk.get("refused") and csk.get("authorization_required"))
    c, csk = creq("POST", "/companion/skill", {"name": "shell_run", "args": {"command": "echo app-control"}, "authorization_code": "test code"})
    print("[companion] SENSITIVE control with auth ran:", c == 200 and csk.get("ok") and "app-control" in json.dumps(csk.get("output")))
    ok &= (c == 200 and csk.get("ok") and "app-control" in json.dumps(csk.get("output")))
    c, sk = req("POST", "/skill", {"name": "ambient_context_status"})
    print("[ambient] context status skill:", c == 200 and sk.get("ok") and "carplay" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "carplay" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "recall_origin"}); print("[bridge] SAFE skill ran:", sk.get("ok")); ok &= sk.get("ok")
    c, sk = req("POST", "/skill", {"name": "shell_run", "args": {"command": "truncate -s 0 /tmp/jarvis-auth-test"}})
    print("[bridge] DESTRUCTIVE without auth refused:", sk.get("refused") and sk.get("authorization_required"))
    ok &= (sk.get("refused") and sk.get("authorization_required"))
    c, sk = req("POST", "/skill", {"name": "shell_run", "args": {"command": "echo hi"}, "authorization_code": "wrong"})
    print("[bridge] SENSITIVE with wrong auth refused:", sk.get("refused")); ok &= sk.get("refused")
    c, sk = req("POST", "/skill", {"name": "shell_run", "args": {"command": "echo hi"}, "authorization_code": "test code"})
    print("[bridge] SENSITIVE with auth ran:", sk.get("ok")); ok &= sk.get("ok")
    c, m = req("GET", "/v1/models", tok=None, bearer="wrong")
    print("[provider] /v1/models open on localhost:", c == 200); ok &= (c == 200)
    c, m = req("GET", "/v1/models", tok=None, bearer="xcode-test-key")
    print("[provider] /v1/models:", c == 200 and m.get("data", [{}])[0].get("id") == "jarvis-test")
    ok &= (c == 200 and m.get("data", [{}])[0].get("id") == "jarvis-test")
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "status"}]},
                tok=None, bearer="wrong")
    print("[provider] bad chat key rejected:", c == 401); ok &= (c == 401)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "status"}]},
                tok=None, bearer="xcode-test-key")
    got_reply = ch.get("choices", [{}])[0].get("message", {}).get("content")
    print("[provider] /v1/chat/completions:", c == 200 and bool(got_reply)); ok &= (c == 200 and bool(got_reply))
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/skills"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[xcode] /skills command:", c == 200 and "shell_run" in reply); ok &= (c == 200 and "shell_run" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/state"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[xcode] /state command:", c == 200 and "JARVIS state" in reply); ok &= (c == 200 and "JARVIS state" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/skill recall_origin"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[xcode] SAFE /skill command:", c == 200 and "ran" in reply); ok &= (c == 200 and "ran" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/skill shell_run {\"command\":\"echo hi\"}"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[xcode] SENSITIVE /skill no auth refused:", c == 200 and "refused" in reply)
    ok &= (c == 200 and "refused" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content":
                    "/skill shell_run {\"command\":\"echo hi\"}\nauth: test code"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[xcode] SENSITIVE /skill with auth ran:", c == 200 and "ran" in reply and "hi" in reply)
    ok &= (c == 200 and "ran" in reply and "hi" in reply)
    teach = "\n".join([
        "/teach skill show front app",
        "description: Report the frontmost app as a taught recipe.",
        "step: macos_frontmost_app",
    ])
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": teach}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[teach] draft validates:", c == 200 and "Draft skill validated" in reply)
    ok &= (c == 200 and "Draft skill validated" in reply)
    save = teach.replace("/teach skill", "/save skill") + "\nauth: test code"
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": save}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[teach] save live-loads:", c == 200 and "Skill saved" in reply)
    ok &= (c == 200 and "Skill saved" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/skill show_front_app"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[teach] taught skill runs:", c == 200 and "show_front_app" in reply)
    ok &= (c == 200 and "show_front_app" in reply)
    paper_path = pathlib.Path(tempfile.gettempdir()) / "jarvis_paper_bridge_test.txt"
    paper_path.write_text("First paper sentence. Second paper sentence.\n\nThird paper sentence raises a question.")
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": f"/paper load {paper_path}"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[paper] load command:", c == 200 and "paper_load" in reply); ok &= (c == 200 and "paper_load" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/paper read 2"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[paper] read command:", c == 200 and "First paper sentence" in reply)
    ok &= (c == 200 and "First paper sentence" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "hold up"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[paper] hold-up pause command:", c == 200 and "paper_pause" in reply)
    ok &= (c == 200 and "paper_pause" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/paper discuss what is the point?"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[paper] discuss command:", c == 200 and "paper_discuss" in reply)
    ok &= (c == 200 and "paper_discuss" in reply)
    c, sk = req("POST", "/skill", {"name": "person_introduce",
                                    "args": {"name": "Pepper", "relationship": "wife",
                                             "spoken_intro": "this is my wife Pepper"}})
    print("[people] introduce skill:", c == 200 and sk.get("ok") and "Pepper" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "Pepper" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "people_list"})
    print("[people] list skill:", c == 200 and sk.get("ok") and "Pepper" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "Pepper" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "music_profile_set",
                                    "args": {"person": "operator", "purpose": "ADHD/autism regulation",
                                             "always_on": True, "notes": "music is usually on"}})
    print("[audio] music profile skill:", c == 200 and sk.get("ok") and "regulation" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "regulation" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "audio_scene_update",
                                    "args": {"speech": "absent", "music": "present", "noise": "low",
                                             "confidence": 0.9, "source": "self-test"}})
    print("[audio] scene update skill:", c == 200 and sk.get("ok") and "present" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "present" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "audio_context_status"})
    print("[audio] context status skill:", c == 200 and sk.get("ok") and "music_profiles" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "music_profiles" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "email_surface_status"})
    print("[email] surface status skill:", c == 200 and sk.get("ok") and "gmail_api" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "gmail_api" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "gmail_oauth_status"})
    print("[email] Gmail OAuth status skill:", c == 200 and sk.get("ok") and sk.get("output", {}).get("password_seen_by_jarvis") is False)
    ok &= (c == 200 and sk.get("ok") and sk.get("output", {}).get("password_seen_by_jarvis") is False)
    c, sk = req("POST", "/skill", {"name": "gmail_oauth_connect"})
    print("[email] Gmail OAuth connect requires auth:", c == 200 and sk.get("refused") and sk.get("authorization_required"))
    ok &= (c == 200 and sk.get("refused") and sk.get("authorization_required"))
    c, sk = req("POST", "/skill", {"name": "mail_send_message",
                                    "args": {"to": "a@example.com", "subject": "x", "body": "y"}})
    print("[email] send requires auth:", c == 200 and sk.get("refused") and sk.get("authorization_required"))
    ok &= (c == 200 and sk.get("refused") and sk.get("authorization_required"))
    c, sk = req("POST", "/skill", {"name": "media_surface_status"})
    print("[media] surface status skill:", c == 200 and sk.get("ok") and "YouTube Music" in json.dumps(sk.get("output")))
    ok &= (c == 200 and sk.get("ok") and "YouTube Music" in json.dumps(sk.get("output")))
    c, sk = req("POST", "/skill", {"name": "youtube_search", "args": {"query": "test song"}})
    print("[media] open/search requires auth:", c == 200 and sk.get("refused") and sk.get("authorization_required"))
    ok &= (c == 200 and sk.get("refused") and sk.get("authorization_required"))
    c, tts = req("GET", "/tts/status")
    print("[tts] bridge status endpoint:", c == 200 and tts.get("preferred_backend") == "xtts-v2")
    ok &= (c == 200 and tts.get("preferred_backend") == "xtts-v2")
    c, sk = req("POST", "/skill", {"name": "tts_status"})
    print("[tts] status skill:", c == 200 and sk.get("ok") and sk.get("output", {}).get("preferred_backend") == "xtts-v2")
    ok &= (c == 200 and sk.get("ok") and sk.get("output", {}).get("preferred_backend") == "xtts-v2")
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content": "/gtp status"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[gtp] status command:", c == 200 and "gtp_status" in reply and "dormant_until" in reply)
    ok &= (c == 200 and "gtp_status" in reply and "dormant_until" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content":
                    "/gtp draft\n"
                    "audience: lab collaborator\n"
                    "context: short email\n"
                    "content: I need the paper list today because grant timing is tight."}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[gtp] draft command:", c == 200 and "gtp_draft" in reply and "Online and oriented" in reply)
    ok &= (c == 200 and "gtp_draft" in reply and "Online and oriented" in reply)
    c, ch = req("POST", "/v1/chat/completions",
                {"model": "jarvis-test", "messages": [{"role": "user", "content":
                    "write this in my voice: please send the abstract before noon"}]},
                tok=None, bearer="xcode-test-key")
    reply = ch.get("choices", [{}])[0].get("message", {}).get("content", "")
    print("[gtp] natural explicit trigger:", c == 200 and "gtp_draft" in reply)
    ok &= (c == 200 and "gtp_draft" in reply)
    paper_path.unlink(missing_ok=True)
    people_path.unlink(missing_ok=True)
    audio_path.unlink(missing_ok=True)
    ambient_path.unlink(missing_ok=True)
    companion_token_path.unlink(missing_ok=True)
    companion_httpd.shutdown()
    httpd.shutdown(); rt.close()
    print("BRIDGE SELF-TEST:", "PASS" if ok else "FAIL")
    import sys; sys.exit(0 if ok else 1)
elif __name__ == "__main__":
    main()
