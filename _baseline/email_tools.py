#!/usr/bin/env python3
"""Email adapters for JARVIS.

The target surface is "all of it": Mail.app, generic IMAP/SMTP, and Gmail API
when OAuth is configured. Read/search/list/draft are non-destructive; send,
move, delete, and remote mutation are risk-gated by the skill registry.
"""
from __future__ import annotations

import base64
import email
import hashlib
import http.server
import imaplib
import json
import os
import re
import secrets
import shlex
import smtplib
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage
from email.parser import BytesParser
from email.policy import default as EMAIL_POLICY
from typing import Any, Dict, List, Optional


_GMAIL_KEYCHAIN_SERVICE = "JARVIS Gmail OAuth"
_GMAIL_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
_GMAIL_REVOKE_ENDPOINT = "https://oauth2.googleapis.com/revoke"
_DEFAULT_GMAIL_SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.send",
]
_ALLOWED_GMAIL_SCOPES = {
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.send",
    "https://www.googleapis.com/auth/gmail.compose",
    "https://www.googleapis.com/auth/gmail.labels",
}


def _run(argv: List[str], input_text: Optional[str] = None, timeout: int = 30) -> dict:
    data = input_text.encode("utf-8") if input_text is not None else None
    r = subprocess.run(argv, input=data, capture_output=True, timeout=timeout)
    return {"code": r.returncode,
            "stdout": r.stdout.decode("utf-8", "replace")[:8000],
            "stderr": r.stderr.decode("utf-8", "replace")[:2000]}


def _applescript_string(value: str) -> str:
    return json.dumps(str(value or ""), ensure_ascii=False)


def _osascript(script: str) -> dict:
    argv = ["osascript"]
    for line in str(script or "").splitlines():
        if line.strip():
            argv.extend(["-e", line])
    if len(argv) == 1:
        raise ValueError("script is required")
    r = subprocess.run(argv, capture_output=True, timeout=45)
    return {"code": r.returncode, "out": r.stdout.decode("utf-8", "replace")[:12000],
            "err": r.stderr.decode("utf-8", "replace")[:3000]}


def _bounded_int(value: Any, default: int, minimum: int, maximum: int, name: str) -> int:
    if value in (None, ""):
        number = default
    else:
        number = int(value)
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def _split_recipients(value: str) -> List[str]:
    if not value:
        return []
    return [part.strip() for part in re.split(r"[,;]", value) if part.strip()]


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


def _rows_result(result: dict, columns: List[str]) -> dict:
    result = dict(result)
    if result.get("code") == 0:
        result["rows"] = _tab_rows(result.get("out", ""), columns)
    return result


def _mail_recipient_lines(kind: str, recipients: str) -> List[str]:
    cls = {
        "to": "to recipient",
        "cc": "cc recipient",
        "bcc": "bcc recipient",
    }[kind]
    return [
        f'make new {cls} at end of {kind} recipients with properties {{address:{_applescript_string(addr)}}}'
        for addr in _split_recipients(recipients)
    ]


def _gmail_keychain_account() -> str:
    return os.environ.get("JARVIS_GMAIL_KEYCHAIN_ACCOUNT", "default").strip() or "default"


def _security_not_found(result: subprocess.CompletedProcess) -> bool:
    stderr = result.stderr.decode("utf-8", "replace").lower()
    return result.returncode == 44 or "could not be found" in stderr


def _keychain_exists(service: str, account: str) -> bool:
    result = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account],
                            capture_output=True, timeout=10)
    if result.returncode == 0:
        return True
    if _security_not_found(result):
        return False
    raise RuntimeError("Keychain lookup failed: " + result.stderr.decode("utf-8", "replace")[:500])


def _keychain_get(service: str, account: str) -> Optional[str]:
    result = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                            capture_output=True, timeout=10)
    if result.returncode == 0:
        return result.stdout.decode("utf-8", "replace")
    if _security_not_found(result):
        return None
    raise RuntimeError("Keychain read failed: " + result.stderr.decode("utf-8", "replace")[:500])


def _keychain_set(service: str, account: str, value: str) -> None:
    result = subprocess.run(["security", "add-generic-password", "-U", "-s", service, "-a", account, "-w", value],
                            capture_output=True, timeout=10)
    if result.returncode != 0:
        raise RuntimeError("Keychain write failed: " + result.stderr.decode("utf-8", "replace")[:500])


def _keychain_delete(service: str, account: str) -> bool:
    result = subprocess.run(["security", "delete-generic-password", "-s", service, "-a", account],
                            capture_output=True, timeout=10)
    if result.returncode == 0:
        return True
    if _security_not_found(result):
        return False
    raise RuntimeError("Keychain delete failed: " + result.stderr.decode("utf-8", "replace")[:500])


def _gmail_client_config(require_client_id: bool = True, fallback_client_id: str = "") -> dict:
    client_id = os.environ.get("JARVIS_GMAIL_CLIENT_ID", "").strip() or fallback_client_id
    client_secret = os.environ.get("JARVIS_GMAIL_CLIENT_SECRET", "").strip()
    if require_client_id and not client_id:
        raise ValueError("Gmail OAuth is not configured; set JARVIS_GMAIL_CLIENT_ID")
    return {
        "client_id": client_id,
        "client_secret": client_secret,
        "client_id_env": "JARVIS_GMAIL_CLIENT_ID",
        "client_secret_env": "JARVIS_GMAIL_CLIENT_SECRET",
    }


def _gmail_scopes(scopes: Optional[Any] = None) -> List[str]:
    if scopes in (None, "", []):
        raw = os.environ.get("JARVIS_GMAIL_SCOPES", "").strip()
        items = re.split(r"[\s,]+", raw) if raw else list(_DEFAULT_GMAIL_SCOPES)
    elif isinstance(scopes, str):
        items = re.split(r"[\s,]+", scopes.strip())
    elif isinstance(scopes, (list, tuple)):
        items = [str(item).strip() for item in scopes]
    else:
        raise ValueError("scopes must be a string or list")
    clean: List[str] = []
    for item in items:
        if not item:
            continue
        if item not in _ALLOWED_GMAIL_SCOPES:
            raise ValueError(f"unsupported Gmail OAuth scope: {item}")
        if item not in clean:
            clean.append(item)
    if not clean:
        raise ValueError("at least one Gmail OAuth scope is required")
    return clean


def _code_verifier() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(48)).decode("ascii").rstrip("=")


def _code_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def _oauth_token_request(form: Dict[str, str]) -> dict:
    data = urllib.parse.urlencode(form).encode("utf-8")
    req = urllib.request.Request(_GMAIL_TOKEN_ENDPOINT, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")[:1000]
        raise RuntimeError(f"Google OAuth token request failed: HTTP {exc.code} {raw}") from exc
    return json.loads(raw) if raw else {}


def _gmail_token_payload_from_keychain() -> Optional[dict]:
    raw = _keychain_get(_GMAIL_KEYCHAIN_SERVICE, _gmail_keychain_account())
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("Stored Gmail OAuth token is not valid JSON; disconnect and reconnect Gmail") from exc
    if not isinstance(payload, dict):
        raise RuntimeError("Stored Gmail OAuth token has invalid shape; disconnect and reconnect Gmail")
    return payload


def _public_gmail_token_status(payload: dict) -> dict:
    return {
        "access_token_stored": bool(payload.get("access_token")),
        "refresh_token_stored": bool(payload.get("refresh_token")),
        "expires_at": payload.get("expires_at"),
        "scope": payload.get("scope", ""),
        "token_type": payload.get("token_type", ""),
    }


def _merge_token_response(tokens: dict, existing: Optional[dict] = None,
                          client_id: str = "", scopes: Optional[List[str]] = None) -> dict:
    payload = dict(existing or {})
    if tokens.get("access_token"):
        payload["access_token"] = tokens["access_token"]
    if tokens.get("refresh_token"):
        payload["refresh_token"] = tokens["refresh_token"]
    if tokens.get("token_type"):
        payload["token_type"] = tokens["token_type"]
    if tokens.get("scope"):
        payload["scope"] = tokens["scope"]
    elif scopes:
        payload["scope"] = " ".join(scopes)
    if client_id:
        payload["client_id"] = client_id
    if tokens.get("expires_in"):
        payload["expires_at"] = int(time.time()) + max(0, int(tokens["expires_in"]) - 60)
    payload["updated_at"] = int(time.time())
    return payload


def _save_gmail_token_payload(payload: dict) -> None:
    _keychain_set(_GMAIL_KEYCHAIN_SERVICE, _gmail_keychain_account(), json.dumps(payload, sort_keys=True))


def _refresh_gmail_access_token(payload: dict, save: bool) -> dict:
    refresh_token = str(payload.get("refresh_token") or "").strip()
    if not refresh_token:
        raise ValueError("Stored Gmail OAuth token has no refresh token; run gmail_oauth_connect again")
    cfg = _gmail_client_config(True, fallback_client_id=str(payload.get("client_id") or ""))
    form = {
        "client_id": cfg["client_id"],
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }
    if cfg["client_secret"]:
        form["client_secret"] = cfg["client_secret"]
    refreshed = _merge_token_response(_oauth_token_request(form), existing=payload, client_id=cfg["client_id"])
    if save:
        _save_gmail_token_payload(refreshed)
    return refreshed


def email_surface_status() -> dict:
    return {
        "target": "all_email_surfaces",
        "adapters": {
            "apple_mail": {
                "available": _run(["osascript", "-e", 'id of application "Mail"']),
                "read": ["mail_accounts", "mail_mailboxes", "mail_recent", "mail_search", "mail_read_message"],
                "write": ["mail_create_draft"],
                "gated": ["mail_send_message", "mail_move_message", "mail_delete_message"],
            },
            "imap": imap_status(),
            "smtp": smtp_status(),
            "gmail_api": gmail_api_status(),
        },
        "policy": {
            "read_search_triage": "not send/delete/move; available without high-risk auth once account permissions exist",
            "draft": "write local/remote draft only",
            "send_move_delete": "auth-gated",
        },
    }


# ------------------------------------------------------------------ Apple Mail
def mail_accounts() -> dict:
    script = """
tell application "Mail"
    set output to ""
    repeat with acct in accounts
        set output to output & (name of acct as text) & tab & (enabled of acct as text) & linefeed
    end repeat
    return output
end tell
"""
    return _rows_result(_osascript(script), ["name", "enabled"])


def mail_mailboxes(account: str = "") -> dict:
    script = "\n".join([
        f"set accountName to {_applescript_string(account)}",
        'tell application "Mail"',
        '    set output to ""',
        '    repeat with acct in accounts',
        '        if accountName is "" or (name of acct as text) is accountName then',
        '            repeat with boxRef in mailboxes of acct',
        '                set output to output & (name of acct as text) & tab & (name of boxRef as text) & linefeed',
        '            end repeat',
        '        end if',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return _rows_result(_osascript(script), ["account", "mailbox"])


def mail_recent(mailbox: str = "", limit: int = 10) -> dict:
    max_count = _bounded_int(limit, 10, 1, 100, "limit")
    script = "\n".join([
        f"set mailboxName to {_applescript_string(mailbox)}",
        f"set maxCount to {max_count}",
        'tell application "Mail"',
        '    if mailboxName is "" then',
        '        set targetMessages to messages of inbox',
        '    else',
        '        set targetMessages to messages of mailbox mailboxName',
        '    end if',
        '    set output to ""',
        '    set seen to 0',
        '    repeat with msgRef in targetMessages',
        '        set seen to seen + 1',
        '        set output to output & (id of msgRef as text) & tab & (sender of msgRef as text) & tab & (subject of msgRef as text) & tab & (date received of msgRef as text) & tab & (read status of msgRef as text) & linefeed',
        '        if seen is greater than or equal to maxCount then return output',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return _rows_result(_osascript(script), ["id", "sender", "subject", "date_received", "read"])


def mail_search(query: str, mailbox: str = "", limit: int = 20, include_body: bool = False) -> dict:
    if not str(query or "").strip():
        raise ValueError("query is required")
    max_count = _bounded_int(limit, 20, 1, 100, "limit")
    body_line = 'set haystack to haystack & " " & (content of msgRef as text)' if include_body else ''
    script = "\n".join([
        f"set queryText to {_applescript_string(query).lower()}",
        f"set mailboxName to {_applescript_string(mailbox)}",
        f"set maxCount to {max_count}",
        'tell application "Mail"',
        '    if mailboxName is "" then',
        '        set targetMessages to messages of inbox',
        '    else',
        '        set targetMessages to messages of mailbox mailboxName',
        '    end if',
        '    set output to ""',
        '    set seen to 0',
        '    repeat with msgRef in targetMessages',
        '        set haystack to ((sender of msgRef as text) & " " & (subject of msgRef as text))',
        f'        {body_line}',
        '        ignoring case',
        '            if haystack contains queryText then',
        '                set seen to seen + 1',
        '                set output to output & (id of msgRef as text) & tab & (sender of msgRef as text) & tab & (subject of msgRef as text) & tab & (date received of msgRef as text) & linefeed',
        '                if seen is greater than or equal to maxCount then return output',
        '            end if',
        '        end ignoring',
        '    end repeat',
        '    return output',
        'end tell',
    ])
    return _rows_result(_osascript(script), ["id", "sender", "subject", "date_received"])


def mail_read_message(message_id: str, mailbox: str = "") -> dict:
    if not str(message_id or "").strip():
        raise ValueError("message_id is required")
    script = "\n".join([
        f"set wantedId to {_applescript_string(message_id)}",
        f"set mailboxName to {_applescript_string(mailbox)}",
        'tell application "Mail"',
        '    if mailboxName is "" then',
        '        set targetMessages to messages of inbox',
        '    else',
        '        set targetMessages to messages of mailbox mailboxName',
        '    end if',
        '    repeat with msgRef in targetMessages',
        '        if (id of msgRef as text) is wantedId then',
        '            return "FROM: " & (sender of msgRef as text) & linefeed & "SUBJECT: " & (subject of msgRef as text) & linefeed & "DATE: " & (date received of msgRef as text) & linefeed & linefeed & (content of msgRef as text)',
        '        end if',
        '    end repeat',
        '    error "message id not found in selected mailbox"',
        'end tell',
    ])
    return _osascript(script)


def mail_create_draft(to: str, subject: str, body: str, cc: str = "", bcc: str = "", visible: bool = True) -> dict:
    if not _split_recipients(to):
        raise ValueError("at least one to recipient is required")
    visible_text = "true" if bool(visible) else "false"
    recipient_lines = _mail_recipient_lines("to", to) + _mail_recipient_lines("cc", cc) + _mail_recipient_lines("bcc", bcc)
    script = "\n".join([
        'tell application "Mail"',
        f'    set newMessage to make new outgoing message with properties {{subject:{_applescript_string(subject)}, content:{_applescript_string(body)}, visible:{visible_text}}}',
        '    tell newMessage',
        *("        " + line for line in recipient_lines),
        '    end tell',
        '    return (id of newMessage as text)',
        'end tell',
    ])
    result = _osascript(script)
    result["draft_only"] = True
    return result


def mail_send_message(to: str, subject: str, body: str, cc: str = "", bcc: str = "") -> dict:
    if not _split_recipients(to):
        raise ValueError("at least one to recipient is required")
    recipient_lines = _mail_recipient_lines("to", to) + _mail_recipient_lines("cc", cc) + _mail_recipient_lines("bcc", bcc)
    script = "\n".join([
        'tell application "Mail"',
        f'    set newMessage to make new outgoing message with properties {{subject:{_applescript_string(subject)}, content:{_applescript_string(body)}, visible:false}}',
        '    tell newMessage',
        *("        " + line for line in recipient_lines),
        '    end tell',
        '    send newMessage',
        '    return "sent"',
        'end tell',
    ])
    return _osascript(script)


def mail_move_message(message_id: str, target_mailbox: str, source_mailbox: str = "") -> dict:
    if not str(message_id or "").strip():
        raise ValueError("message_id is required")
    if not str(target_mailbox or "").strip():
        raise ValueError("target_mailbox is required")
    script = "\n".join([
        f"set wantedId to {_applescript_string(message_id)}",
        f"set sourceName to {_applescript_string(source_mailbox)}",
        f"set targetName to {_applescript_string(target_mailbox)}",
        'tell application "Mail"',
        '    if sourceName is "" then',
        '        set targetMessages to messages of inbox',
        '    else',
        '        set targetMessages to messages of mailbox sourceName',
        '    end if',
        '    repeat with msgRef in targetMessages',
        '        if (id of msgRef as text) is wantedId then',
        '            move msgRef to mailbox targetName',
        '            return "moved"',
        '        end if',
        '    end repeat',
        '    error "message id not found in selected mailbox"',
        'end tell',
    ])
    return _osascript(script)


def mail_delete_message(message_id: str, mailbox: str = "") -> dict:
    if not str(message_id or "").strip():
        raise ValueError("message_id is required")
    script = "\n".join([
        f"set wantedId to {_applescript_string(message_id)}",
        f"set mailboxName to {_applescript_string(mailbox)}",
        'tell application "Mail"',
        '    if mailboxName is "" then',
        '        set targetMessages to messages of inbox',
        '    else',
        '        set targetMessages to messages of mailbox mailboxName',
        '    end if',
        '    repeat with msgRef in targetMessages',
        '        if (id of msgRef as text) is wantedId then',
        '            delete msgRef',
        '            return "deleted"',
        '        end if',
        '    end repeat',
        '    error "message id not found in selected mailbox"',
        'end tell',
    ])
    return _osascript(script)


# ------------------------------------------------------------------ IMAP / SMTP
def _imap_config() -> Dict:
    return {
        "host": os.environ.get("JARVIS_IMAP_HOST", "").strip(),
        "port": int(os.environ.get("JARVIS_IMAP_PORT") or "993"),
        "user": os.environ.get("JARVIS_IMAP_USER", "").strip(),
        "password": os.environ.get("JARVIS_IMAP_PASSWORD", ""),
        "ssl": os.environ.get("JARVIS_IMAP_SSL", "1") != "0",
    }


def imap_status() -> dict:
    cfg = _imap_config()
    return {"configured": bool(cfg["host"] and cfg["user"] and cfg["password"]),
            "host": cfg["host"], "user_configured": bool(cfg["user"]),
            "password_configured": bool(cfg["password"]), "ssl": cfg["ssl"]}


def _imap_connect():
    cfg = _imap_config()
    if not (cfg["host"] and cfg["user"] and cfg["password"]):
        raise ValueError("IMAP is not configured; set JARVIS_IMAP_HOST, JARVIS_IMAP_USER, JARVIS_IMAP_PASSWORD")
    client = imaplib.IMAP4_SSL(cfg["host"], cfg["port"]) if cfg["ssl"] else imaplib.IMAP4(cfg["host"], cfg["port"])
    client.login(cfg["user"], cfg["password"])
    return client


def imap_list_mailboxes() -> dict:
    client = _imap_connect()
    try:
        status, boxes = client.list()
        if status != "OK":
            raise RuntimeError(f"IMAP LIST returned {status}")
        decoded = [box.decode("utf-8", "replace") for box in boxes or []]
        return {"mailboxes": decoded}
    finally:
        client.logout()


def _parse_message_headers(raw: bytes, imap_id: bytes) -> dict:
    msg = BytesParser(policy=EMAIL_POLICY).parsebytes(raw)
    return {
        "imap_id": imap_id.decode("ascii", "replace"),
        "from": str(msg.get("From", "")),
        "to": str(msg.get("To", "")),
        "subject": str(msg.get("Subject", "")),
        "date": str(msg.get("Date", "")),
        "message_id": str(msg.get("Message-ID", "")),
    }


def imap_search(query: str = "ALL", mailbox: str = "INBOX", limit: int = 20) -> dict:
    max_count = _bounded_int(limit, 20, 1, 100, "limit")
    client = _imap_connect()
    try:
        status, _ = client.select(mailbox, readonly=True)
        if status != "OK":
            raise RuntimeError(f"IMAP SELECT returned {status}")
        terms = shlex.split(query or "ALL") or ["ALL"]
        status, data = client.search(None, *terms)
        if status != "OK":
            raise RuntimeError(f"IMAP SEARCH returned {status}")
        ids = (data[0] or b"").split()[-max_count:]
        messages = []
        for imap_id in reversed(ids):
            status, fetched = client.fetch(imap_id, "(BODY.PEEK[HEADER])")
            if status == "OK" and fetched and isinstance(fetched[0], tuple):
                messages.append(_parse_message_headers(fetched[0][1], imap_id))
        return {"mailbox": mailbox, "query": query, "messages": messages}
    finally:
        client.logout()


def _message_text(msg) -> str:
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and not part.get_filename():
                return part.get_content()
        for part in msg.walk():
            if part.get_content_type() == "text/html" and not part.get_filename():
                return part.get_content()
        return ""
    return msg.get_content()


def imap_fetch(imap_id: str, mailbox: str = "INBOX", max_chars: int = 12000) -> dict:
    if not str(imap_id or "").strip():
        raise ValueError("imap_id is required")
    char_limit = _bounded_int(max_chars, 12000, 100, 50000, "max_chars")
    client = _imap_connect()
    try:
        status, _ = client.select(mailbox, readonly=True)
        if status != "OK":
            raise RuntimeError(f"IMAP SELECT returned {status}")
        status, fetched = client.fetch(str(imap_id), "(BODY.PEEK[])")
        if status != "OK" or not fetched or not isinstance(fetched[0], tuple):
            raise RuntimeError(f"IMAP FETCH returned {status}")
        msg = BytesParser(policy=EMAIL_POLICY).parsebytes(fetched[0][1])
        body = _message_text(msg)
        return {"headers": _parse_message_headers(fetched[0][1], str(imap_id).encode()),
                "body": body[:char_limit], "truncated": len(body) > char_limit}
    finally:
        client.logout()


def _smtp_config() -> Dict:
    return {
        "host": os.environ.get("JARVIS_SMTP_HOST", "").strip(),
        "port": int(os.environ.get("JARVIS_SMTP_PORT") or "587"),
        "user": os.environ.get("JARVIS_SMTP_USER", "").strip(),
        "password": os.environ.get("JARVIS_SMTP_PASSWORD", ""),
        "from": os.environ.get("JARVIS_SMTP_FROM", os.environ.get("JARVIS_SMTP_USER", "")).strip(),
        "starttls": os.environ.get("JARVIS_SMTP_STARTTLS", "1") != "0",
    }


def smtp_status() -> dict:
    cfg = _smtp_config()
    return {"configured": bool(cfg["host"] and cfg["user"] and cfg["password"] and cfg["from"]),
            "host": cfg["host"], "from_configured": bool(cfg["from"]),
            "user_configured": bool(cfg["user"]), "password_configured": bool(cfg["password"])}


def smtp_send(to: str, subject: str, body: str, cc: str = "", bcc: str = "") -> dict:
    cfg = _smtp_config()
    if not (cfg["host"] and cfg["user"] and cfg["password"] and cfg["from"]):
        raise ValueError("SMTP is not configured; set JARVIS_SMTP_HOST, USER, PASSWORD, FROM")
    recipients = _split_recipients(to) + _split_recipients(cc) + _split_recipients(bcc)
    if not recipients:
        raise ValueError("at least one recipient is required")
    msg = EmailMessage()
    msg["From"] = cfg["from"]
    msg["To"] = ", ".join(_split_recipients(to))
    if cc:
        msg["Cc"] = ", ".join(_split_recipients(cc))
    msg["Subject"] = subject or ""
    msg.set_content(body or "")
    with smtplib.SMTP(cfg["host"], cfg["port"], timeout=30) as server:
        if cfg["starttls"]:
            server.starttls()
        server.login(cfg["user"], cfg["password"])
        server.send_message(msg, from_addr=cfg["from"], to_addrs=recipients)
    return {"sent": True, "recipients": recipients}


# ------------------------------------------------------------------ Gmail REST
def gmail_oauth_status() -> dict:
    cfg = _gmail_client_config(False)
    account = _gmail_keychain_account()
    keychain_present = _keychain_exists(_GMAIL_KEYCHAIN_SERVICE, account)
    env_access = bool(os.environ.get("JARVIS_GMAIL_ACCESS_TOKEN", "").strip())
    env_refresh = bool(os.environ.get("JARVIS_GMAIL_REFRESH_TOKEN", "").strip())
    return {
        "configured": bool(env_access or env_refresh or keychain_present),
        "client_configured": bool(cfg["client_id"]),
        "client_id_env": cfg["client_id_env"],
        "client_secret_configured": bool(cfg["client_secret"]),
        "client_secret_env": cfg["client_secret_env"],
        "keychain_service": _GMAIL_KEYCHAIN_SERVICE,
        "keychain_account": account,
        "keychain_token_present": keychain_present,
        "env_access_token_configured": env_access,
        "env_refresh_token_configured": env_refresh,
        "default_scopes": list(_DEFAULT_GMAIL_SCOPES),
        "password_seen_by_jarvis": False,
        "flow": "browser OAuth -> Google login/autofill/passkey -> localhost callback -> Keychain OAuth tokens",
    }


def gmail_oauth_connect(timeout_seconds: int = 180, local_port: int = 0,
                        scopes: Optional[Any] = None, prompt: str = "consent select_account") -> dict:
    timeout = _bounded_int(timeout_seconds, 180, 30, 600, "timeout_seconds")
    port = _bounded_int(local_port, 0, 0, 65535, "local_port")
    scope_list = _gmail_scopes(scopes)
    cfg = _gmail_client_config(True)
    state = secrets.token_urlsafe(32)
    verifier = _code_verifier()
    captured: Dict[str, str] = {}

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:
            return

        def do_GET(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/oauth2callback":
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Not found")
                return
            params = urllib.parse.parse_qs(parsed.query)
            captured["state"] = params.get("state", [""])[0]
            captured["code"] = params.get("code", [""])[0]
            captured["error"] = params.get("error", [""])[0]
            ok = bool(captured.get("code")) and captured.get("state") == state
            self.send_response(200 if ok else 400)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            if ok:
                body = "<html><body><h1>Gmail connected to JARVIS.</h1><p>You can close this window.</p></body></html>"
            else:
                body = "<html><body><h1>Gmail authorization failed.</h1><p>Return to JARVIS.</p></body></html>"
            self.wfile.write(body.encode("utf-8"))

    with http.server.HTTPServer(("127.0.0.1", port), CallbackHandler) as server:
        actual_port = server.server_address[1]
        redirect_uri = f"http://127.0.0.1:{actual_port}/oauth2callback"
        params = {
            "client_id": cfg["client_id"],
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": " ".join(scope_list),
            "access_type": "offline",
            "include_granted_scopes": "true",
            "state": state,
            "code_challenge": _code_challenge(verifier),
            "code_challenge_method": "S256",
        }
        if prompt:
            params["prompt"] = prompt
        auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(params)
        opened = _run(["open", auth_url], timeout=10)
        if opened["code"] != 0:
            raise RuntimeError("Could not open Google OAuth page: " + opened.get("stderr", ""))
        deadline = time.monotonic() + timeout
        server.timeout = 1
        while not captured.get("code") and not captured.get("error") and time.monotonic() < deadline:
            server.handle_request()

    if captured.get("error"):
        raise RuntimeError("Google OAuth refused authorization: " + captured["error"])
    if not captured.get("code"):
        raise TimeoutError("Timed out waiting for Google OAuth callback")
    if captured.get("state") != state:
        raise RuntimeError("Google OAuth state mismatch; refusing callback")
    form = {
        "client_id": cfg["client_id"],
        "code": captured["code"],
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }
    if cfg["client_secret"]:
        form["client_secret"] = cfg["client_secret"]
    payload = _merge_token_response(_oauth_token_request(form), client_id=cfg["client_id"], scopes=scope_list)
    _save_gmail_token_payload(payload)
    public = _public_gmail_token_status(payload)
    public.update({
        "connected": True,
        "keychain_service": _GMAIL_KEYCHAIN_SERVICE,
        "keychain_account": _gmail_keychain_account(),
        "password_seen_by_jarvis": False,
    })
    return public


def gmail_oauth_disconnect(revoke: bool = False) -> dict:
    payload = _gmail_token_payload_from_keychain()
    revoked = False
    if revoke and payload:
        token = str(payload.get("access_token") or payload.get("refresh_token") or "")
        if token:
            data = urllib.parse.urlencode({"token": token}).encode("utf-8")
            req = urllib.request.Request(_GMAIL_REVOKE_ENDPOINT, data=data, method="POST")
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            try:
                with urllib.request.urlopen(req, timeout=30):
                    revoked = True
            except urllib.error.HTTPError as exc:
                raw = exc.read().decode("utf-8", "replace")[:1000]
                raise RuntimeError(f"Google OAuth revoke failed: HTTP {exc.code} {raw}") from exc
    deleted = _keychain_delete(_GMAIL_KEYCHAIN_SERVICE, _gmail_keychain_account())
    return {"disconnected": True, "local_keychain_deleted": deleted, "google_token_revoked": revoked}


def gmail_api_status() -> dict:
    oauth = gmail_oauth_status()
    token = os.environ.get("JARVIS_GMAIL_ACCESS_TOKEN", "").strip()
    return {"configured": bool(token or oauth["configured"]),
            "token_env": "JARVIS_GMAIL_ACCESS_TOKEN",
            "refresh_token_env": "JARVIS_GMAIL_REFRESH_TOKEN",
            "oauth": oauth,
            "implemented": ["gmail_oauth_status", "gmail_oauth_connect", "gmail_oauth_disconnect",
                            "gmail_api_search", "gmail_api_read", "gmail_api_send", "gmail_api_modify", "gmail_api_trash"]}


def _gmail_token() -> str:
    token = os.environ.get("JARVIS_GMAIL_ACCESS_TOKEN", "").strip()
    if not token:
        payload = _gmail_token_payload_from_keychain()
        if payload and payload.get("access_token") and int(payload.get("expires_at") or 0) > int(time.time()) + 60:
            return str(payload["access_token"])
        if payload and payload.get("refresh_token"):
            return str(_refresh_gmail_access_token(payload, save=True)["access_token"])
        refresh = os.environ.get("JARVIS_GMAIL_REFRESH_TOKEN", "").strip()
        if refresh:
            return str(_refresh_gmail_access_token({"refresh_token": refresh}, save=False)["access_token"])
        raise ValueError("Gmail API is not configured; run gmail_oauth_connect or set JARVIS_GMAIL_ACCESS_TOKEN")
    return token


def _gmail_request(method: str, path: str, params: Optional[dict] = None, body: Optional[dict] = None) -> dict:
    url = "https://gmail.googleapis.com/gmail/v1/users/me/" + path.lstrip("/")
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method.upper())
    req.add_header("Authorization", "Bearer " + _gmail_token())
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8", "replace")
    return json.loads(raw) if raw else {}


def gmail_api_search(query: str = "in:inbox", max_results: int = 10) -> dict:
    limit = _bounded_int(max_results, 10, 1, 100, "max_results")
    return _gmail_request("GET", "messages", {"q": query or "in:inbox", "maxResults": limit})


def _gmail_headers(payload: dict) -> dict:
    headers = {}
    for item in payload.get("headers", []) or []:
        name = item.get("name")
        if name:
            headers[name.lower()] = item.get("value", "")
    return headers


def gmail_api_read(message_id: str, format: str = "metadata") -> dict:
    if not str(message_id or "").strip():
        raise ValueError("message_id is required")
    fmt = format if format in {"minimal", "metadata", "full", "raw"} else "metadata"
    msg = _gmail_request("GET", f"messages/{urllib.parse.quote(message_id)}", {"format": fmt})
    headers = _gmail_headers(msg.get("payload", {}))
    return {"id": msg.get("id"), "threadId": msg.get("threadId"), "labelIds": msg.get("labelIds", []),
            "snippet": msg.get("snippet", ""), "headers": headers, "raw": msg.get("raw") if fmt == "raw" else None}


def _gmail_raw_message(to: str, subject: str, body: str, cc: str = "", bcc: str = "") -> str:
    recipients = _split_recipients(to)
    if not recipients:
        raise ValueError("at least one to recipient is required")
    msg = EmailMessage()
    msg["To"] = ", ".join(recipients)
    if cc:
        msg["Cc"] = ", ".join(_split_recipients(cc))
    if bcc:
        msg["Bcc"] = ", ".join(_split_recipients(bcc))
    msg["Subject"] = subject or ""
    msg.set_content(body or "")
    return base64.urlsafe_b64encode(msg.as_bytes()).decode("ascii").rstrip("=")


def gmail_api_send(to: str, subject: str, body: str, cc: str = "", bcc: str = "") -> dict:
    return _gmail_request("POST", "messages/send", body={"raw": _gmail_raw_message(to, subject, body, cc, bcc)})


def gmail_api_modify(message_id: str, add_labels: Optional[List[str]] = None, remove_labels: Optional[List[str]] = None) -> dict:
    if not str(message_id or "").strip():
        raise ValueError("message_id is required")
    return _gmail_request("POST", f"messages/{urllib.parse.quote(message_id)}/modify",
                          body={"addLabelIds": add_labels or [], "removeLabelIds": remove_labels or []})


def gmail_api_trash(message_id: str) -> dict:
    if not str(message_id or "").strip():
        raise ValueError("message_id is required")
    return _gmail_request("POST", f"messages/{urllib.parse.quote(message_id)}/trash")


if __name__ == "__main__":
    assert _split_recipients("a@example.com; b@example.com, c@example.com") == [
        "a@example.com", "b@example.com", "c@example.com"]
    assert imap_status()["configured"] in {True, False}
    assert smtp_status()["configured"] in {True, False}
    assert gmail_oauth_status()["password_seen_by_jarvis"] is False
    assert gmail_api_status()["token_env"] == "JARVIS_GMAIL_ACCESS_TOKEN"
    assert _gmail_scopes("https://www.googleapis.com/auth/gmail.modify") == [
        "https://www.googleapis.com/auth/gmail.modify"]
    verifier = _code_verifier()
    assert verifier and _code_challenge(verifier)
    raw = _gmail_raw_message("a@example.com", "Subject", "Body")
    assert raw and "+" not in raw and "/" not in raw
    print("EMAIL TOOLS SELF-TEST: PASS")
