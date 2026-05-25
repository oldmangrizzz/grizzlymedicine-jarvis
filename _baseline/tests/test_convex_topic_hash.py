"""Tests for GAP-2 Convex topic/kind HMAC hashing in ConvexBackend._to_doc().

Ref: /Users/rbhanson/research/oracle/legal-process/exposure-map.md — GAP-2
     /Users/rbhanson/research/jarvis/_baseline/convex_backend.py

These tests verify:
  1. _to_doc() returns a 64-char hex hash for topic, not the plaintext label.
  2. Same topic on two calls produces the same hash (deterministic).
  3. Different topics produce different hashes.
  4. _lookup_topic() de-hashes back to the original plaintext.
  5. ~/.jarvis/runtime_secret.key exists with mode 0600 after first call.
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import pathlib
import stat
import pytest
import numpy as np

# We need to import from the _baseline parent; conftest.py sets up sys.path.
import convex_backend as CB
from convex_backend import (
    ConvexBackend,
    _load_or_create_secret,
    _hmac_hex,
    _SECRET_PATH,
    _INDEX_PATH,
    _SECRET_CACHE,
)
from stigmergy import Signal


# ---------------------------------------------------------------------------
# Fixture: reset the secret cache between tests so each test gets a clean state
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def reset_secret_cache():
    """Clear the module-level secret cache before each test."""
    CB._SECRET_CACHE = None
    yield
    CB._SECRET_CACHE = None


def _make_signal(topic: str, kind: str = "trail") -> Signal:
    return Signal(kind=kind, topic=topic, strength=0.5, last_t=1.0,
                  depositors={"test-agent"}, vec=None)


# ---------------------------------------------------------------------------
# Test 1: topic in _to_doc() is a 64-char hex string, NOT the plaintext
# ---------------------------------------------------------------------------

def test_to_doc_hashes_topic():
    """_to_doc() writes a 64-char hex hash for topic, not 'operator_check_in'."""
    sig = _make_signal("operator_check_in")
    doc = ConvexBackend._to_doc(sig)

    assert doc["topic"] != "operator_check_in", (
        "plaintext topic must not reach Convex"
    )
    assert len(doc["topic"]) == 64, "HMAC-SHA256 hex digest must be 64 chars"
    # Verify it is valid hex
    int(doc["topic"], 16)


# ---------------------------------------------------------------------------
# Test 2: topic in _to_doc() is a 64-char hex string, NOT the plaintext (kind too)
# ---------------------------------------------------------------------------

def test_to_doc_hashes_kind():
    """_to_doc() writes a 64-char hex hash for kind, not the plaintext."""
    sig = _make_signal("some_topic", kind="grief_processing")
    doc = ConvexBackend._to_doc(sig)

    assert doc["kind"] != "grief_processing", (
        "plaintext kind must not reach Convex"
    )
    assert len(doc["kind"]) == 64
    int(doc["kind"], 16)


# ---------------------------------------------------------------------------
# Test 3: deterministic — same topic → same hash on two calls
# ---------------------------------------------------------------------------

def test_to_doc_deterministic():
    """Two calls with the same topic produce the same hash."""
    sig = _make_signal("operator_check_in")
    doc1 = ConvexBackend._to_doc(sig)
    doc2 = ConvexBackend._to_doc(sig)

    assert doc1["topic"] == doc2["topic"], (
        "topic hash must be deterministic across calls"
    )
    assert doc1["kind"] == doc2["kind"]


# ---------------------------------------------------------------------------
# Test 4: different topics → different hashes
# ---------------------------------------------------------------------------

def test_to_doc_different_topics_differ():
    """Different topic labels produce different hashes (collision resistance check)."""
    doc_a = ConvexBackend._to_doc(_make_signal("operator_check_in"))
    doc_b = ConvexBackend._to_doc(_make_signal("grief_processing"))

    assert doc_a["topic"] != doc_b["topic"], (
        "distinct topic labels must not collide"
    )


# ---------------------------------------------------------------------------
# Test 5: _lookup_topic() de-hashes back to original plaintext
# ---------------------------------------------------------------------------

def test_lookup_topic_round_trips():
    """After _to_doc(), _lookup_topic(hash) returns the original plaintext."""
    sig = _make_signal("operator_check_in")
    doc = ConvexBackend._to_doc(sig)

    recovered = ConvexBackend._lookup_topic(doc["topic"])
    assert recovered == "operator_check_in", (
        f"_lookup_topic returned {recovered!r}, expected 'operator_check_in'"
    )
    # kind as well
    recovered_kind = ConvexBackend._lookup_topic(doc["kind"])
    assert recovered_kind == "trail"


# ---------------------------------------------------------------------------
# Test 6: runtime_secret.key exists with mode 0600 after first call
# ---------------------------------------------------------------------------

def test_secret_key_file_permissions():
    """~/.jarvis/runtime_secret.key is created with mode 0600 on first use."""
    # Ensure the secret is loaded/created
    secret = _load_or_create_secret()
    assert len(secret) == 32, "Secret must be 32 bytes"
    assert _SECRET_PATH.exists(), f"Secret file not found at {_SECRET_PATH}"

    mode = stat.filemode(_SECRET_PATH.stat().st_mode)
    # mode string looks like '-rw-------' for 0600
    assert mode == "-rw-------", (
        f"Expected mode -rw------- (0600) but got {mode!r} on {_SECRET_PATH}"
    )


# ---------------------------------------------------------------------------
# Test 7: full round-trip through MockConvex — Signal in, Signal out, topic preserved
# ---------------------------------------------------------------------------

def test_round_trip_through_mock_convex():
    """ConvexBackend put+get round-trips a Signal with plaintext kind/topic intact."""

    class MockConvex:
        def __init__(self): self.rows = {}
        def mutation(self, name, args):
            if name == "stigmergy:put":
                self.rows[(args["kind"], args["topic"])] = dict(args)
        def query(self, name, args):
            if name == "stigmergy:get":
                return self.rows.get((args["kind"], args["topic"]))
            return None

    be = ConvexBackend(client=MockConvex())
    sig = Signal(kind="trail", topic="operator_check_in", strength=0.7,
                 last_t=99.0, depositors={"a1"}, vec=None)
    be.put(("trail", "operator_check_in"), sig)
    got = be.get(("trail", "operator_check_in"))

    assert got is not None
    assert got.topic == "operator_check_in"
    assert got.kind  == "trail"
    assert abs(got.strength - 0.7) < 1e-9
