#!/usr/bin/env python3
"""
gen_token_ref.py — Build-time helper: generate reference token IDs from pocket-tts.

Outputs tests/token_ref.json with one entry per oracle prompt.
Run once at configure time (requires the jarvis .venv active).

Usage:
    python tools/gen_token_ref.py \
        --prompts /Users/rbhanson/research/oracle/voice/prompts.json \
        --out tests/token_ref.json
"""
import argparse
import json
import sys
from pathlib import Path

try:
    from pocket_tts.conditioners.text import SentencePieceTokenizer
    from pocket_tts.utils.config import CONFIGS_DIR, load_config
except ImportError:
    sys.exit("pocket-tts not importable. Activate venv first.")

DEFAULT_PROMPTS = "/Users/rbhanson/research/oracle/voice/prompts.json"
DEFAULT_OUT = str(Path(__file__).parent.parent / "tests" / "token_ref.json")

# Tokenizer path from english_2026-04 config
import os
from pocket_tts.utils.config import CONFIGS_DIR, load_config
cfg = load_config("english_2026-04")
TOKENIZER_PATH = cfg.flow_lm.lookup_table.tokenizer_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompts", default=DEFAULT_PROMPTS)
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    tok = SentencePieceTokenizer(4000, TOKENIZER_PATH)

    prompts = json.load(open(args.prompts))["prompts"]
    ref = []
    for p in prompts:
        ids = tok(p["text"]).tokens[0].tolist()
        ref.append({"idx": p["idx"], "text": p["text"], "token_ids": ids})

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    json.dump(ref, open(args.out, "w"), indent=2)
    print(f"Wrote {len(ref)} entries to {args.out}")


if __name__ == "__main__":
    main()
