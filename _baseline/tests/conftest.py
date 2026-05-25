"""Pytest configuration: ensure _baseline/ is on sys.path for all tests."""
import sys
import pathlib

# Add the _baseline directory to sys.path so tests can import modules directly.
_BASELINE = pathlib.Path(__file__).resolve().parent.parent
if str(_BASELINE) not in sys.path:
    sys.path.insert(0, str(_BASELINE))
