"""Tests for GAP-1 cloud-failover gate in ModelRotator.

Ref: /Users/rbhanson/research/oracle/legal-process/exposure-map.md — GAP-1
     /Users/rbhanson/research/jarvis/_baseline/model_ollama.py

These tests verify:
  1. With JARVIS_CLOUD_MODEL_ALLOWED unset (or "0"), a cloud-backend failover
     raises CloudFailoverRefused — never calls the cloud API.
  2. With JARVIS_CLOUD_MODEL_ALLOWED="1", the cloud backend IS called, but
     messages with stop-list content and _origin=holograph are stripped first.
  3. Env var set explicitly to "0" still refuses.
"""
from __future__ import annotations
import os
import pytest

import model_ollama as M
from model_ollama import (
    CloudFailoverRefused,
    CLOUD_OPT_IN_ENV,
    ModelRotator,
    OllamaBackend,
    CLOUD_BASE,
    _strip_for_cloud,
    assemble_messages,
)


# ---------------------------------------------------------------------------
# Stub backends
# ---------------------------------------------------------------------------

class _LocalFail:
    """Simulates a local Ollama instance that is down."""
    is_cloud = False

    def chat(self, messages, model=None, options=None):
        raise ConnectionError("local Ollama not reachable")


class _CloudCapture:
    """Simulates a cloud backend — records what messages it received."""
    is_cloud = True
    received: list | None = None

    def __init__(self):
        self.received = None

    def chat(self, messages, model=None, options=None):
        self.received = list(messages)
        return "cloud response"


# ---------------------------------------------------------------------------
# Helper: messages that exercise every strip category
# ---------------------------------------------------------------------------

def _build_test_messages():
    """Build a realistic messages list for strip testing."""
    return [
        # Should be stripped: contains stop-list term "boot statement"
        {"role": "system", "content": "This is the boot statement for JARVIS identity."},
        # Should be stripped: contains "character values"
        {"role": "system", "content": "Operator-owned character values block follows."},
        # Should be stripped: _origin = "holograph"
        {"role": "system", "content": "[recalled memory]\n- origin: genesis memory",
         "_origin": "holograph"},
        # Should be KEPT: ordinary system message, no stop-list, no holograph tag
        {"role": "system", "content": "You are a helpful assistant."},
        # Should be KEPT: user message
        {"role": "user", "content": "Hello JARVIS"},
    ]


# ---------------------------------------------------------------------------
# Test 1: cloud refused when env var is unset
# ---------------------------------------------------------------------------

def test_cloud_refused_when_env_unset(monkeypatch):
    """CloudFailoverRefused is raised when local is down and opt-in env var is absent."""
    monkeypatch.delenv(CLOUD_OPT_IN_ENV, raising=False)

    cloud = _CloudCapture()
    rot = ModelRotator([(_LocalFail(), "local-model"), (cloud, "cloud-model")])
    msgs = [{"role": "user", "content": "hi"}]

    with pytest.raises(CloudFailoverRefused):
        rot.chat(msgs)

    # Cloud backend must never have been called
    assert cloud.received is None


# ---------------------------------------------------------------------------
# Test 2: env var explicitly "0" — still refused
# ---------------------------------------------------------------------------

def test_cloud_refused_when_env_zero(monkeypatch):
    """Explicit JARVIS_CLOUD_MODEL_ALLOWED=0 still refuses cloud failover."""
    monkeypatch.setenv(CLOUD_OPT_IN_ENV, "0")

    cloud = _CloudCapture()
    rot = ModelRotator([(_LocalFail(), "local-model"), (cloud, "cloud-model")])

    with pytest.raises(CloudFailoverRefused):
        rot.chat([{"role": "user", "content": "hi"}])

    assert cloud.received is None


# ---------------------------------------------------------------------------
# Test 3: env var "1" — cloud called with stop-list messages stripped
# ---------------------------------------------------------------------------

def test_cloud_allowed_strips_sensitive_messages(monkeypatch):
    """When opt-in is set, cloud is called but stop-list and holograph messages are removed."""
    monkeypatch.setenv(CLOUD_OPT_IN_ENV, "1")

    cloud = _CloudCapture()
    rot = ModelRotator([(_LocalFail(), "local-model"), (cloud, "cloud-model")])
    msgs = _build_test_messages()

    result = rot.chat(msgs)
    assert result == "cloud response"
    assert cloud.received is not None

    # stop-list items must not appear in any sent message's content
    stop_terms = ["boot statement", "character values", "soul anchor",
                  "operator-only", "operator content"]
    for msg in cloud.received:
        content_lower = msg.get("content", "").lower()
        for term in stop_terms:
            assert term not in content_lower, (
                f"Stop-list term '{term}' leaked into cloud message: {msg['content']!r}"
            )

    # holograph-tagged messages must not appear
    for msg in cloud.received:
        assert msg.get("_origin") != "holograph", (
            "HoloGraph-tagged message leaked to cloud"
        )

    # The internal _origin key must be stripped from ALL remaining messages
    for msg in cloud.received:
        assert "_origin" not in msg, f"_origin metadata key leaked to cloud API: {msg}"

    # The safe "helpful assistant" system message and user message must survive
    roles_and_content = [(m["role"], m["content"]) for m in cloud.received]
    assert ("system", "You are a helpful assistant.") in roles_and_content
    assert any(r == "user" for r, _ in roles_and_content)


# ---------------------------------------------------------------------------
# Test 4: assemble_messages tags memory with _origin=holograph
# ---------------------------------------------------------------------------

def test_assemble_messages_tags_memory():
    """assemble_messages() places memory in a separate message tagged _origin=holograph."""
    msgs = assemble_messages(
        boot_statement="I am JARVIS.",
        values_block="Integrity above all.",
        memory_lines=["genesis: Battle of New York"],
        user_msg="Status?",
    )
    # First message: boot + values, no memory, no holograph tag
    assert msgs[0]["role"] == "system"
    assert "_origin" not in msgs[0]
    assert "genesis" not in msgs[0]["content"]

    # Second message: memory, tagged holograph
    assert msgs[1]["role"] == "system"
    assert msgs[1].get("_origin") == "holograph"
    assert "genesis" in msgs[1]["content"]

    # Last message: user
    assert msgs[-1]["role"] == "user"


# ---------------------------------------------------------------------------
# Test 5: _strip_for_cloud detail — each stop-list term triggers removal
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("term", [
    "soul anchor",
    "character values",
    "boot statement",
    "operator-only",
    "operator content",
])
def test_strip_removes_each_stop_term(term):
    """Every entry in the stop-list causes the containing system message to be removed."""
    msgs = [
        {"role": "system", "content": f"This contains {term} material."},
        {"role": "user",   "content": "hi"},
    ]
    result = _strip_for_cloud(msgs)
    # system message stripped; user message kept
    assert len(result) == 1
    assert result[0]["role"] == "user"


def test_strip_removes_holograph_tagged():
    """Messages with _origin=holograph are stripped regardless of content."""
    msgs = [
        {"role": "system", "content": "Safe content", "_origin": "holograph"},
        {"role": "user",   "content": "hi"},
    ]
    result = _strip_for_cloud(msgs)
    assert len(result) == 1
    assert result[0]["role"] == "user"


# ---------------------------------------------------------------------------
# Test 6: OllamaBackend.is_cloud flag set correctly
# ---------------------------------------------------------------------------

def test_is_cloud_flag():
    local = OllamaBackend(base_url="http://localhost:11434")
    cloud = OllamaBackend(base_url=CLOUD_BASE)
    assert local.is_cloud is False
    assert cloud.is_cloud is True
