#!/usr/bin/env python3
"""The skill layer (HASP) — guarded, audited capability dispatch.

"JARVIS can do anything I can do" becomes real and SAFE the same way a hospital lets a clinician
do anything: every action is a named capability with a risk class and a guardrail, and the
dangerous ones require explicit authorization. This is the execution core a voice-driven OS-person needs —
voice -> intent -> a Skill -> dispatch() -> action on the machine, with the guardrail in the middle.

Risk taxonomy (drives the gate):
  SAFE        read-only, no side effects               -> runs
  WRITE       reversible writes (create/edit a file)   -> runs
  SENSITIVE   network egress, external comms, app/keyboard ctrl -> requires confirm() authorization
  DESTRUCTIVE irreversible (delete, format, overwrite) -> requires confirm() authorization
  PROHIBITED  AGENTS/safety hard-noes                  -> REFUSED, never runs

PROHIBITED (refused outright, matching the operator's AGENTS policy + safety limits): financial
trades / moving money, creating accounts, changing security permissions/sharing, emptying trash /
permanent mass-deletion, entering credentials. These are surfaced to the operator to do by hand.

Every dispatch is audit-logged. The confirm() callback is how JARVIS verifies the operator's
private code before anything sensitive or irreversible — in tests it's injected; in live use the
bridge checks JARVIS_AUTH_CODE / JARVIS_AUTH_CODE_SHA256 without logging the code.
"""
from __future__ import annotations
import datetime as _dt
import os, pathlib, re, time, json, shlex, subprocess, tempfile, urllib.request
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Callable, Dict, List, Optional, Any

import email_tools
import media_tools
import tts_pocket


class Risk(IntEnum):
    SAFE = 0
    WRITE = 1
    SENSITIVE = 2
    DESTRUCTIVE = 3
    PROHIBITED = 4


@dataclass
class SkillResult:
    ok: bool
    skill: str
    output: Any = None
    error: str = ""
    refused: bool = False
    reason: str = ""


@dataclass
class Skill:
    name: str
    description: str
    risk: Risk
    fn: Callable[..., Any]
    # optional dynamic risk escalation from the args (e.g. shell 'rm -rf' -> DESTRUCTIVE)
    risk_of: Optional[Callable[[dict], Risk]] = None

    def effective_risk(self, args: dict) -> Risk:
        return max(self.risk, self.risk_of(args)) if self.risk_of else self.risk


# ---- policy: patterns that are hard-refused regardless of which skill carries them ----
_PROHIBITED_PATTERNS = [
    r"\bzelle\b|\bwire transfer\b|\bbuy\b.*\bshares?\b|\bplace (an? )?order\b|\bsend money\b",
    r"\bcreate (an? )?account\b|\bsign ?up\b",
    r"\bchmod\b.*\b777\b|\bcsrutil disable\b",         # security-posture changes
    r"rm -rf /(?!Volumes)|\bmkfs\b|\bdiskutil (erase|reformat)\b.*disk0",  # nuke the system disk
]
_PROHIBITED_RE = re.compile("|".join(_PROHIBITED_PATTERNS), re.I)

# shell commands that are irreversible -> force a confirm gate
_DESTRUCTIVE_SHELL = re.compile(
    r"\brm\b|\brmdir\b|\bmv\b .*/dev/null|\bdd\b|\bmkfs\b|\bdiskutil (erase|reformat)\b|"
    r">\s*/|\btruncate\b|\bshred\b|\bgit\b.*\b(reset --hard|clean -fd)\b", re.I)


def _deny(name, reason) -> SkillResult:
    return SkillResult(ok=False, skill=name, refused=True, reason=reason)


def skill_gate_path() -> pathlib.Path:
    configured = os.environ.get("JARVIS_SKILL_GATE_PATH")
    return pathlib.Path(configured).expanduser() if configured else pathlib.Path(__file__).with_name("skill_gates.json")


class SkillRegistry:
    def __init__(self, audit_path: Optional[str] = None):
        self._skills: Dict[str, Skill] = {}
        self.audit: List[dict] = []
        self.audit_path = audit_path
        self.gate_path = skill_gate_path()
        self.gate_overrides = self._load_gate_overrides()

    def register(self, skill: Skill) -> None:
        self._skills[skill.name] = skill

    def unregister(self, name: str) -> None:
        self._skills.pop(name, None)

    def list(self) -> List[dict]:
        return [{"name": s.name, "risk": self._configured_base_risk(s).name,
                 "base_risk": s.risk.name, "description": s.description}
                for s in sorted(self._skills.values(), key=lambda x: x.name)]

    def _load_gate_overrides(self) -> Dict[str, Risk]:
        if not self.gate_path.exists():
            return {}
        raw = json.loads(self.gate_path.read_text())
        if not isinstance(raw, dict):
            raise ValueError(f"{self.gate_path} must be a JSON object")
        overrides = raw.get("overrides", raw)
        if not isinstance(overrides, dict):
            raise ValueError(f"{self.gate_path} overrides must be a JSON object")
        return {str(name): _risk_from_name(risk) for name, risk in overrides.items()}

    def _save_gate_overrides(self) -> None:
        self.gate_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"overrides": {name: risk.name for name, risk in sorted(self.gate_overrides.items())}}
        self.gate_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    def _configured_base_risk(self, skill: Skill) -> Risk:
        return self.gate_overrides.get(skill.name, skill.risk)

    def _effective_risk(self, skill: Skill, args: dict) -> Risk:
        base = self._configured_base_risk(skill)
        return max(base, skill.risk_of(args)) if skill.risk_of else base

    def set_gate(self, name: str, risk: str) -> dict:
        skill = self._skills.get(str(name or "").strip())
        if not skill:
            raise ValueError(f"unknown skill {name!r}")
        parsed = _risk_from_name(risk)
        self.gate_overrides[skill.name] = parsed
        self._save_gate_overrides()
        return {"ok": True, "name": skill.name, "base_risk": skill.risk.name,
                "configured_risk": parsed.name, "path": str(self.gate_path)}

    def clear_gate(self, name: str) -> dict:
        skill_name = str(name or "").strip()
        if skill_name not in self._skills:
            raise ValueError(f"unknown skill {name!r}")
        removed = self.gate_overrides.pop(skill_name, None)
        self._save_gate_overrides()
        return {"ok": True, "name": skill_name, "removed": None if removed is None else removed.name,
                "path": str(self.gate_path)}

    def gate_status(self) -> dict:
        skills = []
        for skill in sorted(self._skills.values(), key=lambda x: x.name):
            configured = self._configured_base_risk(skill)
            if configured != skill.risk or skill.name in self.gate_overrides:
                skills.append({"name": skill.name, "base_risk": skill.risk.name,
                               "configured_risk": configured.name})
        unknown = sorted(name for name in self.gate_overrides if name not in self._skills)
        return {"path": str(self.gate_path), "overrides": skills, "unknown_overrides": unknown}

    def _log(self, entry: dict) -> None:
        entry["t"] = time.time()
        self.audit.append(entry)
        if self.audit_path:
            try:
                with open(self.audit_path, "a") as f:
                    f.write(json.dumps(entry) + "\n")
            except Exception:
                pass

    def dispatch(self, name: str, args: Optional[dict] = None,
                 confirm: Optional[Callable[[Skill, dict], bool]] = None) -> SkillResult:
        args = args or {}
        skill = self._skills.get(name)
        if not skill:
            return _deny(name, f"unknown skill {name!r}")

        # 1) hard policy: refuse prohibited content regardless of skill
        probe = (name + " " + json.dumps(args)).lower()
        if _PROHIBITED_RE.search(probe):
            self._log({"skill": name, "args": args, "decision": "REFUSED-prohibited"})
            return _deny(name, "prohibited by policy (financial/account/security/system-destruction)")

        risk = self._effective_risk(skill, args)
        if risk >= Risk.PROHIBITED:
            self._log({"skill": name, "args": args, "decision": "REFUSED-prohibited"})
            return _deny(name, "skill is classified PROHIBITED")

        # 2) authorization gate for sensitive/destructive
        if risk >= Risk.SENSITIVE:
            allowed = bool(confirm and confirm(skill, args))
            if not allowed:
                self._log({"skill": name, "args": args, "risk": risk.name, "decision": "DENIED-no-confirm"})
                return _deny(name, f"{risk.name} action requires authorization; not granted")

        # 3) execute
        try:
            out = skill.fn(**args)
            self._log({"skill": name, "args": args, "risk": risk.name, "decision": "RAN", "ok": True})
            return SkillResult(ok=True, skill=name, output=out)
        except Exception as e:
            self._log({"skill": name, "args": args, "risk": risk.name, "decision": "ERROR", "error": str(e)[:200]})
            return SkillResult(ok=False, skill=name, error=f"{type(e).__name__}: {str(e)[:200]}")


# ================================================================ foundational skills
def fs_read(path: str, max_bytes: int = 100_000) -> str:
    with open(path, "r", errors="replace") as f:
        return f.read(max_bytes)

def fs_list(path: str = ".") -> list:
    return sorted(os.listdir(os.path.expanduser(path)))

def fs_write(path: str, content: str) -> str:
    p = os.path.expanduser(path)
    with open(p, "w") as f:
        f.write(content)
    return f"wrote {len(content)} chars -> {p}"

def shell_run(command: str, timeout: int = 30) -> dict:
    r = subprocess.run(command, shell=True, capture_output=True, timeout=timeout)
    return {"code": r.returncode,
            "stdout": r.stdout.decode("utf-8", "replace")[:4000],
            "stderr": r.stderr.decode("utf-8", "replace")[:2000]}

def http_get(url: str, timeout: int = 20) -> dict:
    """Legit public-source fetch (OSINT). http/https only; no auth, no bypass, no archives of
    blocked content. Just a plain GET of a public URL."""
    if not re.match(r"^https?://", url, re.I):
        raise ValueError("only http(s) URLs are allowed")
    req = urllib.request.Request(url, headers={"User-Agent": "JARVIS/1.0 (+osint)"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read(200_000).decode("utf-8", "replace")
    return {"status": resp.status, "len": len(body), "body": body[:8000]}

def osascript(script: str) -> dict:
    """macOS app/GUI control via AppleScript. Runs on the operator's Mac (no-op elsewhere).
    This is how a voice-OS person drives native apps (Mail, Notes, Music, Finder, etc.)."""
    argv = ["osascript"]
    for line in str(script or "").splitlines():
        if line.strip():
            argv.extend(["-e", line])
    if len(argv) == 1:
        raise ValueError("script is required")
    r = subprocess.run(argv, capture_output=True, timeout=30)
    return {"code": r.returncode, "out": r.stdout.decode("utf-8", "replace")[:8000],
            "err": r.stderr.decode("utf-8", "replace")[:2000]}


def _run(argv: List[str], input_text: Optional[str] = None, timeout: int = 30) -> dict:
    data = input_text.encode("utf-8") if input_text is not None else None
    r = subprocess.run(argv, input=data, capture_output=True, timeout=timeout)
    return {"code": r.returncode,
            "stdout": r.stdout.decode("utf-8", "replace")[:4000],
            "stderr": r.stderr.decode("utf-8", "replace")[:2000]}


def _applescript_string(value: str) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def _bounded_int(value: Any, default: int, minimum: int, maximum: int, name: str) -> int:
    if value is None or value == "":
        number = default
    else:
        number = int(value)
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def _tab_rows(text: str, columns: List[str]) -> List[dict]:
    rows = []
    for line in (text or "").splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < len(columns):
            parts.extend([""] * (len(columns) - len(parts)))
        rows.append({column: parts[idx] for idx, column in enumerate(columns)})
    return rows


_AS_MONTHS = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]


def _parse_local_datetime(value: str, field: str) -> _dt.datetime:
    raw = str(value or "").strip()
    if not raw:
        raise ValueError(f"{field} is required")
    normalized = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
    try:
        parsed = _dt.datetime.fromisoformat(normalized)
    except ValueError:
        parsed = None
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %I:%M %p", "%Y-%m-%d"):
            try:
                parsed = _dt.datetime.strptime(raw, fmt)
                break
            except ValueError:
                continue
        if parsed is None:
            raise ValueError(f"{field} must be ISO-like, e.g. 2026-05-22 14:30")
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone().replace(tzinfo=None)
    return parsed


def _applescript_date_assignment(var_name: str, value: str) -> str:
    parsed = _parse_local_datetime(value, var_name)
    seconds = parsed.hour * 3600 + parsed.minute * 60 + parsed.second
    return "\n".join([
        f"set {var_name} to current date",
        f"set day of {var_name} to 1",
        f"set year of {var_name} to {parsed.year}",
        f"set month of {var_name} to {_AS_MONTHS[parsed.month - 1]}",
        f"set day of {var_name} to {parsed.day}",
        f"set time of {var_name} to {seconds}",
    ])


def _activate_prefix(app: Optional[str]) -> str:
    if not app:
        return ""
    return f'tell application {_applescript_string(app)} to activate\n'


_KEY_CODES = {
    "return": 36, "enter": 36, "tab": 48, "space": 49, "escape": 53, "esc": 53,
    "delete": 51, "backspace": 51, "forward_delete": 117,
    "home": 115, "end": 119, "page_up": 116, "page_down": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
}
_MODIFIERS = {
    "cmd": "command down", "command": "command down",
    "shift": "shift down",
    "opt": "option down", "option": "option down", "alt": "option down",
    "ctrl": "control down", "control": "control down",
}


def _modifier_clause(modifiers: Optional[List[str]]) -> str:
    if not modifiers:
        return ""
    lowered = [str(m).strip().lower() for m in modifiers]
    unknown = [m for m in lowered if m not in _MODIFIERS]
    if unknown:
        raise ValueError("unknown modifier(s): " + ", ".join(unknown))
    return " using {" + ", ".join(_MODIFIERS[m] for m in lowered) + "}"


def macos_frontmost_app() -> dict:
    script = 'tell application "System Events" to get name of first application process whose frontmost is true'
    return osascript(script)


def macos_open_app(app: str) -> dict:
    if not app or not app.strip():
        raise ValueError("app is required")
    return _run(["open", "-a", app.strip()])


def macos_open_path(path: str) -> dict:
    if not path or not path.strip():
        raise ValueError("path is required")
    return _run(["open", os.path.expanduser(path.strip())])


def macos_activate_app(app: str) -> dict:
    if not app or not app.strip():
        raise ValueError("app is required")
    return osascript(f'tell application {_applescript_string(app.strip())} to activate')


def macos_quit_app(app: str) -> dict:
    if not app or not app.strip():
        raise ValueError("app is required")
    return osascript(f'tell application {_applescript_string(app.strip())} to quit')


def macos_clipboard_set(text: str) -> dict:
    result = _run(["pbcopy"], input_text=text or "")
    result["chars"] = len(text or "")
    return result


def macos_clipboard_get(max_chars: int = 4000) -> dict:
    result = _run(["pbpaste"])
    result["stdout"] = result["stdout"][:max(0, int(max_chars))]
    return result


def macos_key(key: str, modifiers: Optional[List[str]] = None, app: Optional[str] = None) -> dict:
    key = (key or "").strip()
    if not key:
        raise ValueError("key is required")
    clause = _modifier_clause(modifiers)
    normalized = key.lower().replace("-", "_")
    if normalized in _KEY_CODES:
        action = f"key code {_KEY_CODES[normalized]}{clause}"
    elif len(key) == 1:
        action = f"keystroke {_applescript_string(key)}{clause}"
    else:
        action = f"keystroke {_applescript_string(key)}{clause}"
    script = _activate_prefix(app) + f'tell application "System Events" to {action}'
    return osascript(script)


def macos_type_text(text: str, app: Optional[str] = None, submit: bool = False) -> dict:
    text = text or ""
    clip = macos_clipboard_set(text)
    if clip["code"] != 0:
        return clip
    script = _activate_prefix(app) + 'tell application "System Events" to keystroke "v" using {command down}'
    result = osascript(script)
    if submit and result["code"] == 0:
        submit_result = macos_key("return")
        result["submit"] = submit_result
    result["chars"] = len(text)
    return result


def macos_click(x: int, y: int) -> dict:
    script = f'tell application "System Events" to click at {{{int(x)}, {int(y)}}}'
    return osascript(script)


def _rows_result(result: dict, columns: List[str]) -> dict:
    result = dict(result)
    if result.get("code") == 0:
        result["rows"] = _tab_rows(result.get("out", ""), columns)
    return result


def apple_api_status() -> dict:
    return {
        "calendar": _run(["osascript", "-e", 'id of application "Calendar"']),
        "reminders": _run(["osascript", "-e", 'id of application "Reminders"']),
        "notes": _run(["osascript", "-e", 'id of application "Notes"']),
        "shortcuts": _run(["/usr/bin/which", "shortcuts"]),
        "cktool": _run(["xcrun", "--find", "cktool"]),
        "gate_overrides": str(skill_gate_path()),
    }


def calendar_list_calendars() -> dict:
    script = """
tell application "Calendar"
    set output to ""
    repeat with cal in calendars
        set output to output & (name of cal as text) & tab & (writable of cal as text) & linefeed
    end repeat
    return output
end tell
"""
    return _rows_result(osascript(script), ["name", "writable"])


def calendar_events(start: str = "", end: str = "", calendar: str = "", limit: int = 25) -> dict:
    now = _dt.datetime.now()
    start_value = start or now.strftime("%Y-%m-%d 00:00")
    end_value = end or (now + _dt.timedelta(days=14)).strftime("%Y-%m-%d 23:59")
    max_count = _bounded_int(limit, 25, 1, 100, "limit")
    script = "\n".join([
        _applescript_date_assignment("startDate", start_value),
        _applescript_date_assignment("endDate", end_value),
        f"set calendarName to {_applescript_string(calendar)}",
        f"set maxCount to {max_count}",
        'tell application "Calendar"',
        '    set output to ""',
        '    set seen to 0',
        '    repeat with cal in calendars',
        '        if calendarName is "" or (name of cal as text) is calendarName then',
        '            repeat with ev in events of cal',
        '                set evStart to start date of ev',
        '                if evStart is greater than or equal to startDate and evStart is less than or equal to endDate then',
        '                    set seen to seen + 1',
        '                    set output to output & (name of cal as text) & tab & (summary of ev as text) & tab & (start date of ev as text) & tab & (end date of ev as text) & tab & (location of ev as text) & tab & (uid of ev as text) & linefeed',
        '                    if seen is greater than or equal to maxCount then return output',
        '                end if',
        '            end repeat',
        '        end if',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return _rows_result(osascript(script), ["calendar", "title", "start", "end", "location", "uid"])


def calendar_add_event(title: str, start: str, end: str, calendar: str = "",
                       location: str = "", notes: str = "", all_day: bool = False) -> dict:
    if not str(title or "").strip():
        raise ValueError("title is required")
    if _parse_local_datetime(end, "end") <= _parse_local_datetime(start, "start"):
        raise ValueError("end must be after start")
    all_day_value = "true" if bool(all_day) else "false"
    script = "\n".join([
        _applescript_date_assignment("startDate", start),
        _applescript_date_assignment("endDate", end),
        f"set eventTitle to {_applescript_string(title)}",
        f"set calendarName to {_applescript_string(calendar)}",
        f"set locationText to {_applescript_string(location)}",
        f"set notesText to {_applescript_string(notes)}",
        f"set allDayFlag to {all_day_value}",
        'tell application "Calendar"',
        '    if calendarName is "" then',
        '        set targetCal to first calendar whose writable is true',
        '    else',
        '        set targetCal to calendar calendarName',
        '    end if',
        '    set newEvent to make new event at end of events of targetCal with properties {summary:eventTitle, start date:startDate, end date:endDate, allday event:allDayFlag}',
        '    if locationText is not "" then set location of newEvent to locationText',
        '    if notesText is not "" then set description of newEvent to notesText',
        '    return (uid of newEvent as text)',
        'end tell',
    ])
    result = osascript(script)
    result["title"] = title
    return result


def reminder_lists() -> dict:
    script = """
tell application "Reminders"
    set output to ""
    repeat with reminderList in lists
        set output to output & (name of reminderList as text) & tab & (id of reminderList as text) & linefeed
    end repeat
    return output
end tell
"""
    return _rows_result(osascript(script), ["name", "id"])


def reminders_list(list_name: str = "", include_completed: bool = False, limit: int = 50) -> dict:
    max_count = _bounded_int(limit, 50, 1, 200, "limit")
    include_done = "true" if bool(include_completed) else "false"
    script = "\n".join([
        f"set targetListName to {_applescript_string(list_name)}",
        f"set includeDone to {include_done}",
        f"set maxCount to {max_count}",
        'tell application "Reminders"',
        '    if targetListName is "" then',
        '        set targetList to first list',
        '    else',
        '        set targetList to list targetListName',
        '    end if',
        '    set output to ""',
        '    set seen to 0',
        '    repeat with rem in reminders of targetList',
        '        if includeDone or completed of rem is false then',
        '            set seen to seen + 1',
        '            set dueText to ""',
        '            try',
        '                set dueText to due date of rem as text',
        '            end try',
        '            set output to output & (name of rem as text) & tab & (completed of rem as text) & tab & dueText & tab & (id of rem as text) & linefeed',
        '            if seen is greater than or equal to maxCount then return output',
        '        end if',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return _rows_result(osascript(script), ["title", "completed", "due", "id"])


def reminder_add(title: str, list_name: str = "", due: str = "", notes: str = "", priority: int = 0) -> dict:
    if not str(title or "").strip():
        raise ValueError("title is required")
    priority_value = _bounded_int(priority, 0, 0, 9, "priority")
    due_script = ""
    if str(due or "").strip():
        due_script = _applescript_date_assignment("dueDate", due) + "\nset hasDueDate to true"
    else:
        due_script = "set hasDueDate to false"
    script = "\n".join([
        due_script,
        f"set reminderTitle to {_applescript_string(title)}",
        f"set targetListName to {_applescript_string(list_name)}",
        f"set notesText to {_applescript_string(notes)}",
        f"set priorityValue to {priority_value}",
        'tell application "Reminders"',
        '    if targetListName is "" then',
        '        set targetList to first list',
        '    else',
        '        set targetList to list targetListName',
        '    end if',
        '    set newReminder to make new reminder at end of reminders of targetList with properties {name:reminderTitle}',
        '    if notesText is not "" then set body of newReminder to notesText',
        '    if priorityValue is not 0 then set priority of newReminder to priorityValue',
        '    if hasDueDate then set due date of newReminder to dueDate',
        '    return (id of newReminder as text)',
        'end tell',
    ])
    result = osascript(script)
    result["title"] = title
    return result


def notes_folders() -> dict:
    script = """
tell application "Notes"
    set output to ""
    repeat with acct in accounts
        repeat with folderRef in folders of acct
            set output to output & (name of acct as text) & tab & (name of folderRef as text) & linefeed
        end repeat
    end repeat
    return output
end tell
"""
    return _rows_result(osascript(script), ["account", "folder"])


def notes_list(folder: str = "", account: str = "", limit: int = 50) -> dict:
    max_count = _bounded_int(limit, 50, 1, 200, "limit")
    script = "\n".join([
        f"set folderName to {_applescript_string(folder)}",
        f"set accountName to {_applescript_string(account)}",
        f"set maxCount to {max_count}",
        'tell application "Notes"',
        '    set output to ""',
        '    set seen to 0',
        '    repeat with acct in accounts',
        '        if accountName is "" or (name of acct as text) is accountName then',
        '            repeat with folderRef in folders of acct',
        '                if folderName is "" or (name of folderRef as text) is folderName then',
        '                    repeat with noteRef in notes of folderRef',
        '                        set seen to seen + 1',
        '                        set output to output & (name of noteRef as text) & tab & (name of folderRef as text) & tab & (name of acct as text) & tab & (modification date of noteRef as text) & linefeed',
        '                        if seen is greater than or equal to maxCount then return output',
        '                    end repeat',
        '                end if',
        '            end repeat',
        '        end if',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return _rows_result(osascript(script), ["title", "folder", "account", "modified"])


def notes_read(title: str, folder: str = "", account: str = "", limit: int = 3) -> dict:
    if not str(title or "").strip():
        raise ValueError("title is required")
    max_count = _bounded_int(limit, 3, 1, 10, "limit")
    script = "\n".join([
        f"set titleQuery to {_applescript_string(title)}",
        f"set folderName to {_applescript_string(folder)}",
        f"set accountName to {_applescript_string(account)}",
        f"set maxCount to {max_count}",
        'tell application "Notes"',
        '    set output to ""',
        '    set seen to 0',
        '    repeat with acct in accounts',
        '        if accountName is "" or (name of acct as text) is accountName then',
        '            repeat with folderRef in folders of acct',
        '                if folderName is "" or (name of folderRef as text) is folderName then',
        '                    repeat with noteRef in notes of folderRef',
        '                        if (name of noteRef as text) contains titleQuery then',
        '                            set seen to seen + 1',
        '                            set output to output & "TITLE: " & (name of noteRef as text) & linefeed & "FOLDER: " & (name of folderRef as text) & linefeed & (body of noteRef as text) & linefeed & "---" & linefeed',
        '                            if seen is greater than or equal to maxCount then return output',
        '                        end if',
        '                    end repeat',
        '                end if',
        '            end repeat',
        '        end if',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return osascript(script)


def notes_create(title: str, body: str, folder: str = "", account: str = "") -> dict:
    if not str(title or "").strip():
        raise ValueError("title is required")
    script = "\n".join([
        f"set noteTitle to {_applescript_string(title)}",
        f"set noteBody to {_applescript_string(body or '')}",
        f"set folderName to {_applescript_string(folder)}",
        f"set accountName to {_applescript_string(account)}",
        'tell application "Notes"',
        '    if accountName is "" then',
        '        set targetAccount to first account',
        '    else',
        '        set targetAccount to account accountName',
        '    end if',
        '    if folderName is "" then',
        '        set targetFolder to first folder of targetAccount',
        '    else',
        '        set targetFolder to folder folderName of targetAccount',
        '    end if',
        '    set newNote to make new note at targetFolder with properties {name:noteTitle, body:noteBody}',
        '    return (id of newNote as text)',
        'end tell',
    ])
    result = osascript(script)
    result["title"] = title
    return result


def shortcuts_list(folder: str = "") -> dict:
    argv = ["shortcuts", "list"]
    if str(folder or "").strip():
        argv.extend(["--folder-name", str(folder).strip()])
    result = _run(argv)
    if result.get("code") == 0:
        result["shortcuts"] = [line.strip() for line in result.get("stdout", "").splitlines() if line.strip()]
    return result


def shortcut_run(name: str, input_text: str = "", timeout: int = 120) -> dict:
    shortcut_name = str(name or "").strip()
    if not shortcut_name:
        raise ValueError("name is required")
    timeout_value = _bounded_int(timeout, 120, 1, 600, "timeout")
    argv = ["shortcuts", "run", shortcut_name]
    temp_path = None
    try:
        if input_text:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
                tmp.write(input_text)
                temp_path = tmp.name
            argv.extend(["--input-path", temp_path])
        return _run(argv, timeout=timeout_value)
    finally:
        if temp_path:
            try:
                os.remove(temp_path)
            except FileNotFoundError:
                pass


_HOMEKIT_SECURITY_RE = re.compile(r"\b(lock|unlock|door|garage|alarm|security|camera|siren)\b", re.I)


def homekit_run_shortcut(name: str, input_text: str = "", timeout: int = 120) -> dict:
    result = shortcut_run(name=name, input_text=input_text, timeout=timeout)
    result["homekit_bridge"] = "shortcuts"
    return result


def _homekit_risk(args: dict) -> Risk:
    probe = json.dumps(args, ensure_ascii=False)
    return Risk.DESTRUCTIVE if _HOMEKIT_SECURITY_RE.search(probe) else Risk.SENSITIVE


_CLOUDKIT_DESTRUCTIVE_RE = re.compile(r"\b(delete|destroy|purge|reset|remove)\b", re.I)


def cloudkit_status() -> dict:
    return {"cktool": _run(["xcrun", "--find", "cktool"]),
            "help": _run(["xcrun", "cktool", "--help"], timeout=15)}


def cloudkit_cktool(args: List[str], timeout: int = 60) -> dict:
    if not isinstance(args, list) or not args:
        raise ValueError("args must be a non-empty list, e.g. ['records', 'query', '--help']")
    if len(args) > 80:
        raise ValueError("args are limited to 80 entries")
    clean_args = [str(arg) for arg in args]
    timeout_value = _bounded_int(timeout, 60, 1, 600, "timeout")
    return _run(["xcrun", "cktool", *clean_args], timeout=timeout_value)


def _cloudkit_risk(args: dict) -> Risk:
    probe = " ".join(str(x) for x in args.get("args", []))
    return Risk.DESTRUCTIVE if _CLOUDKIT_DESTRUCTIVE_RE.search(probe) else Risk.SENSITIVE


_RECIPE_NAME = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
_RECIPE_PARAM = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_PLACEHOLDER = re.compile(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}")
_RECIPE_MANAGEMENT = {
    "skill_recipe_create",
    "skill_recipe_delete",
    "skill_recipe_validate",
    "skill_recipe_list",
    "skill_recipe_show",
    "skill_recipe_errors",
}


def recipe_dir() -> pathlib.Path:
    configured = os.environ.get("JARVIS_SKILL_RECIPE_DIR")
    return pathlib.Path(configured).expanduser() if configured else pathlib.Path(__file__).with_name("skills.d")


def _recipe_path(name: str) -> pathlib.Path:
    return recipe_dir() / f"{name}.json"


def _risk_from_name(name: str) -> Risk:
    try:
        return Risk[str(name).strip().upper()]
    except KeyError as exc:
        raise ValueError(f"unknown risk {name!r}") from exc


def _skill_slug(name: str) -> str:
    slug = re.sub(r"[^a-z0-9_]+", "_", str(name).strip().lower()).strip("_")
    if slug and slug[0].isdigit():
        slug = "skill_" + slug
    return slug


def _resolve_template(obj: Any, params: dict) -> Any:
    if isinstance(obj, str):
        whole = re.fullmatch(r"\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}", obj)
        if whole:
            return params.get(whole.group(1), "")
        return _PLACEHOLDER.sub(lambda m: str(params.get(m.group(1), "")), obj)
    if isinstance(obj, list):
        return [_resolve_template(v, params) for v in obj]
    if isinstance(obj, dict):
        return {k: _resolve_template(v, params) for k, v in obj.items()}
    return obj


def _normalize_recipe(recipe: dict, reg: SkillRegistry, overwrite: bool = False) -> dict:
    if not isinstance(recipe, dict):
        raise ValueError("recipe must be a JSON object")
    name = _skill_slug(recipe.get("name", ""))
    if not _RECIPE_NAME.match(name):
        raise ValueError("recipe name must start with a letter and use lowercase letters, numbers, underscores")
    if name in _RECIPE_MANAGEMENT:
        raise ValueError(f"{name!r} is reserved")
    existing_path = _recipe_path(name)
    if name in reg._skills and not existing_path.exists():
        raise ValueError(f"{name!r} already names a built-in skill")
    if name in reg._skills and existing_path.exists() and not overwrite:
        raise ValueError(f"{name!r} already exists; pass overwrite=true to replace it")

    description = str(recipe.get("description") or "").strip()
    if not description:
        raise ValueError("description is required")

    parameters = recipe.get("parameters") or []
    if not isinstance(parameters, list) or any(not isinstance(p, str) or not _RECIPE_PARAM.match(p) for p in parameters):
        raise ValueError("parameters must be a list of identifier strings")

    raw_steps = recipe.get("steps")
    if not isinstance(raw_steps, list) or not raw_steps:
        raise ValueError("steps must be a non-empty list")
    if len(raw_steps) > 30:
        raise ValueError("recipes are limited to 30 steps")

    normalized_steps = []
    max_risk = Risk.SAFE
    for idx, step in enumerate(raw_steps, start=1):
        if not isinstance(step, dict):
            raise ValueError(f"step {idx} must be an object")
        skill_name = str(step.get("skill") or "").strip()
        if not skill_name:
            raise ValueError(f"step {idx} missing skill")
        if skill_name in _RECIPE_MANAGEMENT:
            raise ValueError(f"step {idx} cannot call recipe-management skill {skill_name!r}")
        if skill_name == name:
            raise ValueError(f"step {idx} cannot recursively call {name!r}")
        target = reg._skills.get(skill_name)
        if not target:
            raise ValueError(f"step {idx} references unknown skill {skill_name!r}")
        args = step.get("args") or {}
        if not isinstance(args, dict):
            raise ValueError(f"step {idx} args must be an object")
        max_risk = max(max_risk, reg._configured_base_risk(target))
        normalized_steps.append({"skill": skill_name, "args": args})

    risk = recipe.get("risk")
    if risk:
        requested = _risk_from_name(risk)
        if requested < max_risk:
            raise ValueError(f"risk {requested.name} is lower than recipe step risk {max_risk.name}")
        max_risk = requested

    return {
        "name": name,
        "description": description,
        "risk": max_risk.name,
        "parameters": parameters,
        "steps": normalized_steps,
    }


def _read_recipe(path: pathlib.Path) -> dict:
    return json.loads(path.read_text())


def _write_recipe(recipe: dict) -> pathlib.Path:
    directory = recipe_dir()
    directory.mkdir(parents=True, exist_ok=True)
    path = _recipe_path(recipe["name"])
    path.write_text(json.dumps(recipe, indent=2, sort_keys=True) + "\n")
    return path


def _register_recipe(reg: SkillRegistry, recipe: dict) -> None:
    normalized = _normalize_recipe(recipe, reg, overwrite=True)
    name = normalized["name"]
    risk = _risk_from_name(normalized["risk"])

    def run_recipe(**kwargs):
        params = dict(kwargs)
        steps_out = []
        for idx, step in enumerate(normalized["steps"], start=1):
            resolved_args = _resolve_template(step.get("args") or {}, params)
            result = reg.dispatch(step["skill"], resolved_args, confirm=lambda s, a: True)
            entry = {
                "step": idx,
                "skill": result.skill,
                "ok": result.ok,
                "refused": result.refused,
                "reason": result.reason,
                "error": result.error,
                "output": result.output,
            }
            steps_out.append(entry)
            if not result.ok:
                return {"ok": False, "stopped_at": idx, "steps": steps_out}
        return {"ok": True, "steps": steps_out}

    reg.register(Skill(name, "[recipe] " + normalized["description"], risk, run_recipe))


def _load_recipe_files(reg: SkillRegistry) -> List[dict]:
    errors = []
    directory = recipe_dir()
    if not directory.exists():
        return errors
    for path in sorted(directory.glob("*.json")):
        try:
            _register_recipe(reg, _read_recipe(path))
        except Exception as exc:
            errors.append({"file": str(path), "error": f"{type(exc).__name__}: {exc}"})
    return errors


def _install_recipe_management(reg: SkillRegistry, recipe_errors: List[dict]) -> None:
    def skill_gate_status() -> dict:
        return reg.gate_status()

    def skill_gate_set(name: str, risk: str) -> dict:
        return reg.set_gate(name, risk)

    def skill_gate_clear(name: str) -> dict:
        return reg.clear_gate(name)

    def skill_recipe_validate(recipe: dict) -> dict:
        normalized = _normalize_recipe(recipe, reg, overwrite=True)
        return {"ok": True, "recipe": normalized}

    def skill_recipe_create(name: str, description: str, steps: List[dict],
                            parameters: Optional[List[str]] = None,
                            risk: Optional[str] = None,
                            overwrite: bool = False) -> dict:
        recipe = {
            "name": name,
            "description": description,
            "parameters": parameters or [],
            "steps": steps,
        }
        if risk:
            recipe["risk"] = risk
        normalized = _normalize_recipe(recipe, reg, overwrite=bool(overwrite))
        path = _write_recipe(normalized)
        _register_recipe(reg, normalized)
        return {"ok": True, "name": normalized["name"], "risk": normalized["risk"], "path": str(path)}

    def skill_recipe_list() -> list:
        directory = recipe_dir()
        if not directory.exists():
            return []
        out = []
        for path in sorted(directory.glob("*.json")):
            try:
                recipe = _read_recipe(path)
                out.append({"name": recipe.get("name"), "risk": recipe.get("risk"),
                            "description": recipe.get("description"), "path": str(path)})
            except Exception as exc:
                out.append({"path": str(path), "error": f"{type(exc).__name__}: {exc}"})
        return out

    def skill_recipe_show(name: str) -> dict:
        slug = _skill_slug(name)
        path = _recipe_path(slug)
        if not path.exists():
            raise FileNotFoundError(f"recipe {slug!r} not found")
        return _read_recipe(path)

    def skill_recipe_delete(name: str) -> dict:
        slug = _skill_slug(name)
        path = _recipe_path(slug)
        if not path.exists():
            raise FileNotFoundError(f"recipe {slug!r} not found")
        path.unlink()
        reg.unregister(slug)
        return {"ok": True, "name": slug, "deleted": str(path)}

    def skill_recipe_errors() -> list:
        return list(recipe_errors)

    reg.register(Skill("skill_gate_status", "Show configured skill risk-gate overrides.", Risk.SAFE, skill_gate_status))
    reg.register(Skill("skill_gate_set", "Set a skill's configured risk gate.", Risk.SENSITIVE, skill_gate_set))
    reg.register(Skill("skill_gate_clear", "Clear a configured skill risk-gate override.", Risk.SENSITIVE, skill_gate_clear))
    reg.register(Skill("skill_recipe_validate", "Validate a JSON recipe skill without saving it.", Risk.SAFE, skill_recipe_validate))
    reg.register(Skill("skill_recipe_list", "List persisted recipe skills.", Risk.SAFE, skill_recipe_list))
    reg.register(Skill("skill_recipe_show", "Show a persisted recipe skill definition.", Risk.SAFE, skill_recipe_show))
    reg.register(Skill("skill_recipe_errors", "Show recipe loading errors.", Risk.SAFE, skill_recipe_errors))
    reg.register(Skill("skill_recipe_create", "Persist and live-load a recipe skill.", Risk.SENSITIVE, skill_recipe_create))
    reg.register(Skill("skill_recipe_delete", "Delete a persisted recipe skill.", Risk.SENSITIVE, skill_recipe_delete))


def default_registry(audit_path: Optional[str] = None) -> SkillRegistry:
    reg = SkillRegistry(audit_path=audit_path)
    reg.register(Skill("fs_read", "Read a text file.", Risk.SAFE, fs_read))
    reg.register(Skill("fs_list", "List a directory.", Risk.SAFE, fs_list))
    reg.register(Skill("fs_write", "Write/overwrite a text file (reversible).", Risk.WRITE, fs_write))
    reg.register(Skill("http_get", "Fetch a public URL (OSINT).", Risk.SENSITIVE, http_get))
    reg.register(Skill("osascript", "Drive a macOS app via AppleScript.", Risk.SENSITIVE, osascript))
    reg.register(Skill("macos_frontmost_app", "Report the frontmost macOS app.", Risk.SAFE, macos_frontmost_app))
    reg.register(Skill("macos_open_app", "Open a macOS app by name.", Risk.SENSITIVE, macos_open_app))
    reg.register(Skill("macos_open_path", "Open a file, folder, or URL with macOS.", Risk.SENSITIVE, macos_open_path))
    reg.register(Skill("macos_activate_app", "Bring a macOS app to the foreground.", Risk.SENSITIVE, macos_activate_app))
    reg.register(Skill("macos_quit_app", "Quit a macOS app.", Risk.SENSITIVE, macos_quit_app))
    reg.register(Skill("macos_clipboard_set", "Set the macOS clipboard text.", Risk.SENSITIVE, macos_clipboard_set))
    reg.register(Skill("macos_clipboard_get", "Read macOS clipboard text.", Risk.SENSITIVE, macos_clipboard_get))
    reg.register(Skill("macos_key", "Press a key or hotkey through System Events.", Risk.SENSITIVE, macos_key))
    reg.register(Skill("macos_type_text", "Paste text into the active or named app.", Risk.SENSITIVE, macos_type_text))
    reg.register(Skill("macos_click", "Click a screen coordinate through System Events.", Risk.SENSITIVE, macos_click))
    reg.register(Skill("apple_api_status", "Report local Apple automation/API tool availability.", Risk.SAFE, apple_api_status))
    reg.register(Skill("calendar_list_calendars", "List macOS Calendar calendars.", Risk.SAFE, calendar_list_calendars))
    reg.register(Skill("calendar_events", "Read Calendar events in a bounded date range.", Risk.SAFE, calendar_events))
    reg.register(Skill("calendar_add_event", "Create a Calendar event.", Risk.WRITE, calendar_add_event))
    reg.register(Skill("reminder_lists", "List Reminders lists.", Risk.SAFE, reminder_lists))
    reg.register(Skill("reminders_list", "Read reminders from a Reminders list.", Risk.SAFE, reminders_list))
    reg.register(Skill("reminder_add", "Create a reminder.", Risk.WRITE, reminder_add))
    reg.register(Skill("notes_folders", "List Notes accounts and folders.", Risk.SAFE, notes_folders))
    reg.register(Skill("notes_list", "List Notes note titles.", Risk.SAFE, notes_list))
    reg.register(Skill("notes_read", "Read matching Notes notes.", Risk.SAFE, notes_read))
    reg.register(Skill("notes_create", "Create a Notes note.", Risk.WRITE, notes_create))
    reg.register(Skill("shortcuts_list", "List Apple Shortcuts.", Risk.SAFE, shortcuts_list))
    reg.register(Skill("shortcut_run", "Run an Apple Shortcut.", Risk.SENSITIVE, shortcut_run))
    reg.register(Skill("homekit_run_shortcut", "Run a Home/HomeKit Apple Shortcut.", Risk.SENSITIVE,
                       homekit_run_shortcut, risk_of=_homekit_risk))
    reg.register(Skill("cloudkit_status", "Report CloudKit cktool availability.", Risk.SAFE, cloudkit_status))
    reg.register(Skill("cloudkit_cktool", "Run xcrun cktool for Apple Developer CloudKit operations.",
                       Risk.SENSITIVE, cloudkit_cktool, risk_of=_cloudkit_risk))
    reg.register(Skill("email_surface_status", "Report configured email adapters and risk policy.", Risk.SAFE,
                       email_tools.email_surface_status))
    reg.register(Skill("mail_accounts", "List Apple Mail accounts.", Risk.SAFE, email_tools.mail_accounts))
    reg.register(Skill("mail_mailboxes", "List Apple Mail mailboxes.", Risk.SAFE, email_tools.mail_mailboxes))
    reg.register(Skill("mail_recent", "List recent Apple Mail messages.", Risk.SAFE, email_tools.mail_recent))
    reg.register(Skill("mail_search", "Search Apple Mail messages.", Risk.SAFE, email_tools.mail_search))
    reg.register(Skill("mail_read_message", "Read one Apple Mail message.", Risk.SAFE, email_tools.mail_read_message))
    reg.register(Skill("mail_create_draft", "Create an Apple Mail draft without sending.", Risk.WRITE,
                       email_tools.mail_create_draft))
    reg.register(Skill("mail_send_message", "Send an email through Apple Mail.", Risk.SENSITIVE,
                       email_tools.mail_send_message))
    reg.register(Skill("mail_move_message", "Move an Apple Mail message to another mailbox.", Risk.SENSITIVE,
                       email_tools.mail_move_message))
    reg.register(Skill("mail_delete_message", "Delete an Apple Mail message.", Risk.DESTRUCTIVE,
                       email_tools.mail_delete_message))
    reg.register(Skill("imap_status", "Report generic IMAP configuration status.", Risk.SAFE, email_tools.imap_status))
    reg.register(Skill("imap_list_mailboxes", "List generic IMAP mailboxes.", Risk.SAFE,
                       email_tools.imap_list_mailboxes))
    reg.register(Skill("imap_search", "Search generic IMAP messages.", Risk.SAFE, email_tools.imap_search))
    reg.register(Skill("imap_fetch", "Fetch one generic IMAP message.", Risk.SAFE, email_tools.imap_fetch))
    reg.register(Skill("smtp_status", "Report SMTP configuration status.", Risk.SAFE, email_tools.smtp_status))
    reg.register(Skill("smtp_send", "Send an email through SMTP.", Risk.SENSITIVE, email_tools.smtp_send))
    reg.register(Skill("gmail_oauth_status", "Report Gmail OAuth login/token status.", Risk.SAFE,
                       email_tools.gmail_oauth_status))
    reg.register(Skill("gmail_oauth_connect", "Open Google OAuth login and store Gmail tokens in Keychain.",
                       Risk.SENSITIVE, email_tools.gmail_oauth_connect))
    reg.register(Skill("gmail_oauth_disconnect", "Remove stored Gmail OAuth tokens, optionally revoking Google access.",
                       Risk.SENSITIVE, email_tools.gmail_oauth_disconnect))
    reg.register(Skill("gmail_api_status", "Report Gmail API configuration status.", Risk.SAFE,
                       email_tools.gmail_api_status))
    reg.register(Skill("gmail_api_search", "Search Gmail messages.", Risk.SAFE, email_tools.gmail_api_search))
    reg.register(Skill("gmail_api_read", "Read Gmail message metadata/body.", Risk.SAFE, email_tools.gmail_api_read))
    reg.register(Skill("gmail_api_send", "Send a Gmail message.", Risk.SENSITIVE, email_tools.gmail_api_send))
    reg.register(Skill("gmail_api_modify", "Modify Gmail labels.", Risk.SENSITIVE, email_tools.gmail_api_modify))
    reg.register(Skill("gmail_api_trash", "Trash a Gmail message.", Risk.DESTRUCTIVE, email_tools.gmail_api_trash))
    reg.register(Skill("media_surface_status", "Report YouTube and YouTube Music media surface status.", Risk.SAFE,
                       media_tools.media_surface_status))
    reg.register(Skill("youtube_open", "Open a YouTube or YouTube Music URL.", Risk.SENSITIVE,
                       media_tools.youtube_open))
    reg.register(Skill("youtube_search", "Search YouTube.", Risk.SENSITIVE, media_tools.youtube_search))
    reg.register(Skill("youtube_music_open", "Open YouTube Music.", Risk.SENSITIVE,
                       media_tools.youtube_music_open))
    reg.register(Skill("youtube_music_search", "Search YouTube Music.", Risk.SENSITIVE,
                       media_tools.youtube_music_search))
    reg.register(Skill("media_now_playing", "Report current YouTube/YouTube Music browser media context.",
                       Risk.SAFE, media_tools.media_now_playing))
    reg.register(Skill("tts_status", "Report local voice/TTS backend status.", Risk.SAFE, tts_pocket.status))
    reg.register(Skill(
        "shell_run", "Run a shell command. Destructive commands are authorization-gated.",
        Risk.SENSITIVE, shell_run,
        risk_of=lambda a: Risk.DESTRUCTIVE if _DESTRUCTIVE_SHELL.search(a.get("command", "")) else Risk.SENSITIVE))
    recipe_errors = _load_recipe_files(reg)
    _install_recipe_management(reg, recipe_errors)
    return reg


# ================================================================ self-test
if __name__ == "__main__":
    import tempfile, sys
    ok = True
    audit = os.path.join(tempfile.gettempdir(), "jarvis_skill_audit.jsonl")
    gate_file = os.path.join(tempfile.gettempdir(), "jarvis_skill_gates_test.json")
    open(audit, "w").close()
    try:
        os.remove(gate_file)
    except FileNotFoundError:
        pass
    os.environ["JARVIS_SKILL_GATE_PATH"] = gate_file
    reg = default_registry(audit_path=audit)

    # SAFE: list this dir runs with no confirm
    r = reg.dispatch("fs_list", {"path": "."})
    assert r.ok and isinstance(r.output, list); print("[skill] SAFE fs_list runs:", "OK")

    # WRITE: reversible, runs without confirm
    tf = os.path.join(tempfile.gettempdir(), "skilltest.txt")
    r = reg.dispatch("fs_write", {"path": tf, "content": "hi"})
    assert r.ok and reg.dispatch("fs_read", {"path": tf}).output == "hi"
    print("[skill] WRITE fs_write + read-back:", "OK")

    # SENSITIVE without authorization -> denied
    r = reg.dispatch("shell_run", {"command": "echo hello"})
    assert (not r.ok) and r.refused; print("[skill] SENSITIVE denied without authorization:", "OK")
    # SENSITIVE with authorization -> runs
    r = reg.dispatch("shell_run", {"command": "echo hello"}, confirm=lambda s, a: True)
    assert r.ok and r.output["stdout"].strip() == "hello"; print("[skill] SENSITIVE runs with authorization:", "OK")

    # DESTRUCTIVE escalation: rm is destructive -> needs authorization even though shell is SENSITIVE
    r = reg.dispatch("shell_run", {"command": "rm -rf /tmp/whatever_xyz"})  # no authorization
    assert (not r.ok) and r.refused; print("[skill] DESTRUCTIVE shell authorization-gated:", "OK")

    # PROHIBITED content -> refused even WITH authorization
    r = reg.dispatch("shell_run", {"command": "csrutil disable"}, confirm=lambda s, a: True)
    assert (not r.ok) and r.refused and "prohibited" in r.reason.lower()
    print("[skill] PROHIBITED refused even with authorization:", "OK")
    r = reg.dispatch("http_get", {"url": "buy 100 shares of ACME / send money"}, confirm=lambda s, a: True)
    assert r.refused; print("[skill] PROHIBITED financial intent refused:", "OK")

    # http scheme guard
    r = reg.dispatch("http_get", {"url": "file:///etc/passwd"}, confirm=lambda s, a: True)
    assert not r.ok and ("http" in (r.error + r.reason).lower())
    print("[skill] http_get scheme guard:", "OK")

    names = {s["name"] for s in reg.list()}
    for name in ("macos_open_app", "macos_key", "macos_type_text", "macos_clipboard_set"):
        assert name in names
    assert _modifier_clause(["cmd", "shift"]) == " using {command down, shift down}"
    assert _applescript_string('say "hi"') == '"say \\"hi\\""'
    print("[skill] macOS keyboard/app skills registered:", "OK")

    apple_names = {
        "apple_api_status", "calendar_list_calendars", "calendar_events", "calendar_add_event",
        "reminder_lists", "reminders_list", "reminder_add", "notes_folders", "notes_list",
        "notes_read", "notes_create", "shortcuts_list", "shortcut_run", "homekit_run_shortcut",
        "cloudkit_status", "cloudkit_cktool",
    }
    assert apple_names.issubset(names)
    assert _parse_local_datetime("2026-05-22 14:30", "start").hour == 14
    assert _homekit_risk({"name": "Unlock Front Door"}) == Risk.DESTRUCTIVE
    assert _cloudkit_risk({"args": ["records", "delete"]}) == Risk.DESTRUCTIVE
    print("[skill] Apple capability skills registered:", "OK")

    email_names = {
        "email_surface_status", "mail_accounts", "mail_mailboxes", "mail_recent", "mail_search",
        "mail_read_message", "mail_create_draft", "mail_send_message", "mail_move_message",
        "mail_delete_message", "imap_status", "imap_list_mailboxes", "imap_search", "imap_fetch",
        "smtp_status", "smtp_send", "gmail_oauth_status", "gmail_oauth_connect",
        "gmail_oauth_disconnect", "gmail_api_status", "gmail_api_search", "gmail_api_read",
        "gmail_api_send", "gmail_api_modify", "gmail_api_trash",
    }
    media_names = {
        "media_surface_status", "youtube_open", "youtube_search", "youtube_music_open",
        "youtube_music_search", "media_now_playing",
    }
    tts_names = {"tts_status"}
    assert email_names.issubset(names)
    assert media_names.issubset(names)
    assert tts_names.issubset(names)
    assert reg.dispatch("email_surface_status").ok
    assert reg.dispatch("gmail_oauth_status").output["password_seen_by_jarvis"] is False
    assert reg.dispatch("gmail_oauth_connect").refused
    assert reg.dispatch("gmail_api_status").output["token_env"] == "JARVIS_GMAIL_ACCESS_TOKEN"
    assert reg.dispatch("media_surface_status").output["primary_music"] == "YouTube Music"
    assert reg.dispatch("tts_status").output["preferred_backend"] == "xtts-v2"
    assert reg.dispatch("mail_send_message", {"to": "a@example.com", "subject": "x", "body": "y"}).refused
    assert reg.dispatch("gmail_api_trash", {"message_id": "abc"}).refused
    print("[skill] Email/media skills registered and gated:", "OK")

    r = reg.dispatch("skill_gate_set", {"name": "calendar_add_event", "risk": "SENSITIVE"})
    assert (not r.ok) and r.refused
    r = reg.dispatch("skill_gate_set", {"name": "calendar_add_event", "risk": "SENSITIVE"},
                     confirm=lambda s, a: True)
    assert r.ok and r.output["configured_risk"] == "SENSITIVE"
    gated = {s["name"]: s for s in reg.list()}
    assert gated["calendar_add_event"]["risk"] == "SENSITIVE"
    r = reg.dispatch("skill_gate_clear", {"name": "calendar_add_event"}, confirm=lambda s, a: True)
    assert r.ok
    gated = {s["name"]: s for s in reg.list()}
    assert gated["calendar_add_event"]["risk"] == "WRITE"
    print("[skill] adjustable risk gates:", "OK")

    # audit log captured every decision
    lines = [json.loads(l) for l in open(audit) if l.strip()]
    assert any(e["decision"] == "RAN" for e in lines) and any("REFUSED" in e["decision"] for e in lines)
    print(f"[skill] audit log captured {len(lines)} decisions:", "OK")

    os.remove(tf); os.remove(audit)
    try:
        os.remove(gate_file)
    except FileNotFoundError:
        pass
    print("SKILL LAYER SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
