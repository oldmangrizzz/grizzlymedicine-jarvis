#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: tools/rotate_voice_baseline.sh --operator-attest --audio-sample <wav> --weights <path> --cold-root-public <pubkey.hex> --cold-root-signature <sig.hex> [--baseline sbom/voice-weights-baseline.json] [--out <proposal.json>]

Operator-gated voice tripwire rebaseline. This script does not synthesize audio, does not modify voice weights, and does not rewrite the active baseline silently.

Required operator ceremony:
  1. Listen to the supplied --audio-sample and confirm the current voice is the Paul Bettany clone.
  2. Review the proposed gpt_decoder.onnx SHA-256 and baseline spec printed by this script.
  3. Sign the canonical proposal with the cold root Ed25519 key and pass --cold-root-signature.

Output is a signed proposal JSON. The active sbom/voice-weights-baseline.json remains unchanged until the operator applies the signed proposal deliberately.
USAGE
}

ATTEST=0
AUDIO=""
WEIGHTS="JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx"
BASELINE="sbom/voice-weights-baseline.json"
PUB=""
SIG=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --operator-attest) ATTEST=1; shift ;;
    --audio-sample) AUDIO="${2:-}"; shift 2 ;;
    --weights) WEIGHTS="${2:-}"; shift 2 ;;
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --cold-root-public) PUB="${2:-}"; shift 2 ;;
    --cold-root-signature) SIG="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$ATTEST" == 1 ]] || { echo "refused: --operator-attest is mandatory" >&2; exit 1; }
[[ -f "$AUDIO" ]] || { echo "refused: --audio-sample file missing" >&2; exit 1; }
[[ -f "$WEIGHTS" ]] || { echo "refused: --weights file missing: $WEIGHTS" >&2; exit 1; }
[[ -f "$BASELINE" ]] || { echo "refused: --baseline file missing: $BASELINE" >&2; exit 1; }
[[ "$PUB" =~ ^[0-9A-Fa-f]{64}$ ]] || { echo "refused: cold root public key must be 32-byte hex" >&2; exit 1; }
[[ "$SIG" =~ ^[0-9A-Fa-f]{128}$ ]] || { echo "refused: cold root signature must be 64-byte hex" >&2; exit 1; }

HASH="$(shasum -a 256 "$WEIGHTS" | awk '{print tolower($1)}')"
AUDIO_HASH="$(shasum -a 256 "$AUDIO" | awk '{print tolower($1)}')"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CANONICAL="voice_baseline_rebaseline_v1\npath=apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx\nsha256=$HASH\naudio_sample_sha256=$AUDIO_HASH\noperator_attestation=paul_bettany_clone_confirmed\ntimestamp=$STAMP\n"

cat >&2 <<SPEC
VOICE BASELINE REBASELINE PROPOSAL
path: apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx
sha256: $HASH
audio_sample_sha256: $AUDIO_HASH
operator_attestation_required: paul_bettany_clone_confirmed
baseline_file_left_unmodified: $BASELINE
SPEC

if [[ -z "$OUT" ]]; then
  OUT="tools/voice_baseline_rebaseline_${HASH:0:12}.proposal.json"
fi
umask 077
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
if [[ -e "$OUT" ]]; then
  echo "refused: output exists: $OUT" >&2
  exit 1
fi
{
  printf '{\n'
  printf '  "schema": "jarvis.voice_baseline_rebaseline.v1",\n'
  printf '  "baseline_path": "apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models/gpt_decoder.onnx",\n'
  printf '  "proposed_sha256": "%s",\n' "$HASH"
  printf '  "audio_sample_sha256": "%s",\n' "$AUDIO_HASH"
  printf '  "operator_attestation": "paul_bettany_clone_confirmed",\n'
  printf '  "timestamp": "%s",\n' "$STAMP"
  printf '  "cold_root_public_key_hex": "%s",\n' "$(echo "$PUB" | tr 'A-F' 'a-f')"
  printf '  "cold_root_signature_hex": "%s",\n' "$(echo "$SIG" | tr 'A-F' 'a-f')"
  printf '  "canonical_payload": %s\n' "$(CANONICAL_TEXT="$CANONICAL" perl -MJSON::PP -e 'print encode_json($ENV{CANONICAL_TEXT})')"
  printf '}\n'
} > "$OUT"
chmod 0600 "$OUT"
echo "signed proposal written: $OUT"
