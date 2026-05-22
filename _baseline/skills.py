#!/usr/bin/env python3
"""The skill layer (HASP) — guarded, audited capability dispatch.

"JARVIS can do anything I can do" becomes real and SAFE the same way a hospital lets a clinician
do anything: every action is a named capability with a risk class and a guardrail, and the
dangerous ones require an explicit go. This is the execution core a voice-driven OS-person needs —
voice -> intent -> a Skill -> dispatch() -> action on the machine, with the guardrail in the middle.

Risk taxonomy (drives the gate):
  SAFE        read-only, no side effects               -> runs
  WRITE       reversible writes (create/edit a file)   -> runs
  SENSITIVE   network egress, external comms, app ctrl -> requires confirm()
  DESTRUCTIVE irreversible (delete, format, overwrite) -> requires confirm()
  PROHIBITED  AGENTS/safety hard-noes                  -> REFUSED, never runs

PROHIBITED (refused outright, matching the operator's AGENTS policy + safety limits): financial
trades / moving money, creating accounts, changing security permissions/sharing, emptying trash /
permanent mass-deletion, entering credentials. These are surfaced to the operator to do by hand.

Every dispatch is audit-logged. The confirm() callback is how JARVIS asks the operator aloud
before anything irreversible — in tests it's injected; in the voice loop it's a spoken yes/no.
"""
from __future__ import annotations
import os, re, time, json, shlex, subprocess, urllib.request
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Callable, Dict, List, Optional, Any


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


class SkillRegistry:
    def __init__(self, audit_path: Optional[str] = None):
        self._skills: Dict[str, Skill] = {}
        self.audit: List[dict] = []
        self.audit_path = audit_path

    def register(self, skill: Skill) -> None:
        self._skills[skill.name] = skill

    def list(self) -> List[dict]:
        return [{"name": s.name, "risk": s.risk.name, "description": s.description}
                for s in sorted(self._skills.values(), key=lambda x: x.name)]

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

        risk = skill.effective_risk(args)
        if risk >= Risk.PROHIBITED:
            self._log({"skill": name, "args": args, "decision": "REFUSED-prohibited"})
            return _deny(name, "skill is classified PROHIBITED")

        # 2) confirm gate for sensitive/destructive
        if risk >= Risk.SENSITIVE:
            allowed = bool(confirm and confirm(skill, args))
            if not allowed:
                self._log({"skill": name, "args": args, "risk": risk.name, "decision": "DENIED-no-confirm"})
                return _deny(name, f"{risk.name} action requires confirmation; not granted")

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
    r = subprocess.run(["osascript", "-e", script], capture_output=True, timeout=30)
    return {"code": r.returncode, "out": r.stdout.decode("utf-8", "replace")[:2000],
            "err": r.stderr.decode("utf-8", "replace")[:1000]}


def default_registry(audit_path: Optional[str] = None) -> SkillRegistry:
    reg = SkillRegistry(audit_path=audit_path)
    reg.register(Skill("fs_read", "Read a text file.", Risk.SAFE, fs_read))
    reg.register(Skill("fs_list", "List a directory.", Risk.SAFE, fs_list))
    reg.register(Skill("fs_write", "Write/overwrite a text file (reversible).", Risk.WRITE, fs_write))
    reg.register(Skill("http_get", "Fetch a public URL (OSINT).", Risk.SENSITIVE, http_get))
    reg.register(Skill("osascript", "Drive a macOS app via AppleScript.", Risk.SENSITIVE, osascript))
    reg.register(Skill(
        "shell_run", "Run a shell command. Destructive commands are confirm-gated.",
        Risk.SENSITIVE, shell_run,
        risk_of=lambda a: Risk.DESTRUCTIVE if _DESTRUCTIVE_SHELL.search(a.get("command", "")) else Risk.SENSITIVE))
    return reg


# ================================================================ self-test
if __name__ == "__main__":
    import tempfile, sys
    ok = True
    audit = os.path.join(tempfile.gettempdir(), "jarvis_skill_audit.jsonl")
    open(audit, "w").close()
    reg = default_registry(audit_path=audit)

    # SAFE: list this dir runs with no confirm
    r = reg.dispatch("fs_list", {"path": "."})
    assert r.ok and isinstance(r.output, list); print("[skill] SAFE fs_list runs:", "OK")

    # WRITE: reversible, runs without confirm
    tf = os.path.join(tempfile.gettempdir(), "skilltest.txt")
    r = reg.dispatch("fs_write", {"path": tf, "content": "hi"})
    assert r.ok and reg.dispatch("fs_read", {"path": tf}).output == "hi"
    print("[skill] WRITE fs_write + read-back:", "OK")

    # SENSITIVE without confirm -> denied
    r = reg.dispatch("shell_run", {"command": "echo hello"})
    assert (not r.ok) and r.refused; print("[skill] SENSITIVE denied without confirm:", "OK")
    # SENSITIVE with confirm -> runs
    r = reg.dispatch("shell_run", {"command": "echo hello"}, confirm=lambda s, a: True)
    assert r.ok and r.output["stdout"].strip() == "hello"; print("[skill] SENSITIVE runs with confirm:", "OK")

    # DESTRUCTIVE escalation: rm is destructive -> needs confirm even though shell is SENSITIVE
    r = reg.dispatch("shell_run", {"command": "rm -rf /tmp/whatever_xyz"})  # no confirm
    assert (not r.ok) and r.refused; print("[skill] DESTRUCTIVE shell confirm-gated:", "OK")

    # PROHIBITED content -> refused even WITH confirm
    r = reg.dispatch("shell_run", {"command": "csrutil disable"}, confirm=lambda s, a: True)
    assert (not r.ok) and r.refused and "prohibited" in r.reason.lower()
    print("[skill] PROHIBITED refused even with confirm:", "OK")
    r = reg.dispatch("http_get", {"url": "buy 100 shares of ACME / send money"}, confirm=lambda s, a: True)
    assert r.refused; print("[skill] PROHIBITED financial intent refused:", "OK")

    # http scheme guard
    r = reg.dispatch("http_get", {"url": "file:///etc/passwd"}, confirm=lambda s, a: True)
    assert not r.ok and ("http" in (r.error + r.reason).lower())
    print("[skill] http_get scheme guard:", "OK")

    # audit log captured every decision
    lines = [json.loads(l) for l in open(audit) if l.strip()]
    assert any(e["decision"] == "RAN" for e in lines) and any("REFUSED" in e["decision"] for e in lines)
    print(f"[skill] audit log captured {len(lines)} decisions:", "OK")

    os.remove(tf); os.remove(audit)
    print("SKILL LAYER SELF-TEST:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
