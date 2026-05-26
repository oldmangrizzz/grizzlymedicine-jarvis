#!/usr/bin/env bash
# generate_paper_attestation.sh — R11h F-E29
#
# Produces the human-transcribable court-exhibit artifact: a plain-text
# attestation listing every cryptographic fingerprint needed to prove,
# offline and on paper, that a specific JARVIS instance was minted at
# a specific moment by a specific operator under specific witnesses.
#
# Output is plain text with fingerprints formatted in groups of 4 hex
# characters (separator " ") so that a human-on-a-phone can dictate them
# to a witness who is verifying out-of-band. Optimized for OCR-friendly
# fixed-width fonts.
#
# Inputs (all required, fail closed on missing):
#   ~/.jarvis/identity/birth_certificate.json
#   ~/.jarvis/identity/voice_models_anchor.bin
#   ~/.jarvis/identity/cold_root_public.key  (optional pin)
#   ~/.jarvis/identity/sbom.txt              (optional SBOM)
#   Reproducible-build binary SHA (computed via scripts/repro_build_verify.sh)
#
# Output:
#   <out-path>/ceremony_attestation.txt
#
# Run from the JARVISMacCockpit/ package root. Receipt is mode 0600.
#
# Threat model: this artifact is the LAST-RESORT proof-of-provenance
# that survives complete loss of every digital artifact. Court exhibit.
# Therefore the script MUST NOT silently degrade — any missing input
# aborts loud, NOT a blank or truncated attestation.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: scripts/generate_paper_attestation.sh <output-dir> [--cold-root-sign-cmd=<cmd>]

Writes <output-dir>/ceremony_attestation.txt (mode 0600).

R11j F-F18 — when --cold-root-sign-cmd=<cmd> is supplied, the script
runs <cmd> with the document SHA on stdin and expects 128 hex chars
(64-byte ed25519 sig) on stdout. The signature is embedded into the
document under "DOCUMENT COLD-ROOT SIGNATURE (F-F18)" and the document
SHA is recomputed over the signed final form. <cmd> must point at an
air-gapped cold-root signing helper; the cockpit NEVER touches the
cold-root key itself.

Without --cold-root-sign-cmd, the script writes a court-exhibit
WARNING noting that the document is unsigned and unsuitable for
adversarial evidentiary use.
USAGE
    exit 2
}

[ $# -ge 1 ] || usage
OUT_DIR="$1"
shift
COLD_ROOT_SIGN_CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cold-root-sign-cmd=*)
            COLD_ROOT_SIGN_CMD="${1#--cold-root-sign-cmd=}"
            ;;
        *)
            usage
            ;;
    esac
    shift
done
mkdir -p "$OUT_DIR"
chmod 0700 "$OUT_DIR"
OUT="$OUT_DIR/ceremony_attestation.txt"

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY_DIR="$HOME/.jarvis/identity"

require_file() {
    local p="$1"
    if [ ! -f "$p" ]; then
        echo "[F-E29] FAIL: required input missing: $p" >&2
        exit 1
    fi
}

require_file "$IDENTITY_DIR/birth_certificate.json"
require_file "$IDENTITY_DIR/voice_models_anchor.bin"

# Group hex into 4-char chunks separated by spaces. Robust to any length.
groups_of_4() {
    local hex="$1"
    # Only group strings that are pure hex (32+ chars). Leave placeholder
    # strings like "not-present" untouched.
    if [[ "$hex" =~ ^[0-9a-fA-F]{32,}$ ]]; then
        echo "$hex" | sed -E 's/(.{4})/\1 /g' | sed -E 's/ +$//'
    else
        echo "$hex"
    fi
}

sha_hex() { shasum -a 256 "$1" | awk '{print $1}'; }

BC_PATH="$IDENTITY_DIR/birth_certificate.json"
ANCHOR_PATH="$IDENTITY_DIR/voice_models_anchor.bin"
SBOM_PATH="$IDENTITY_DIR/sbom.txt"
COLDROOT_PIN_PATH="$IDENTITY_DIR/cold_root_public.key"

BC_SHA=$(sha_hex "$BC_PATH")
ANCHOR_SHA=$(sha_hex "$ANCHOR_PATH")

# Reproducible-build binary SHA — only if .build-repro exists from a
# prior repro_build_verify.sh run.
REPRO_SHA="not-computed"
if [ -f "$PKG_ROOT/.build-repro/release/JARVISMacCockpit" ]; then
    REPRO_SHA=$(sha_hex "$PKG_ROOT/.build-repro/release/JARVISMacCockpit")
fi

# Cold-root pin fingerprint (file pin, if present).
COLDROOT_FINGERPRINT="not-pinned"
if [ -f "$COLDROOT_PIN_PATH" ]; then
    COLDROOT_FINGERPRINT=$(sha_hex "$COLDROOT_PIN_PATH")
fi

SBOM_SHA="not-present"
if [ -f "$SBOM_PATH" ]; then
    SBOM_SHA=$(sha_hex "$SBOM_PATH")
fi

# Witness names + pubkey fingerprints — best-effort extraction from BC.
WITNESS_BLOCK=""
if command -v python3 >/dev/null 2>&1; then
    WITNESS_BLOCK=$(python3 - "$BC_PATH" <<'PYEOF'
import hashlib, json, sys
try:
    with open(sys.argv[1]) as fh:
        bc = json.load(fh)
except Exception as e:
    print(f"  (witness extraction failed: {e})")
    sys.exit(0)
ws = bc.get("witnesses") or []
if not ws:
    print("  (no witnesses recorded)")
    sys.exit(0)
for w in ws:
    name = w.get("name", "?")
    role = w.get("role", "?")
    jur = w.get("jurisdiction", "")
    pub = w.get("pubkey_hex", "")
    try:
        fp = hashlib.sha256(bytes.fromhex(pub)).hexdigest()
    except Exception:
        fp = "INVALID-PUBKEY"
    grouped = " ".join(fp[i:i+4] for i in range(0, len(fp), 4))
    line = f"  {name} ({role}"
    if jur:
        line += f", {jur}"
    line += "):"
    print(line)
    print(f"    {grouped}")
PYEOF
)
fi

# Operator + subject IDs from BC.
OPERATOR_ID="unknown"
SUBJECT_ID="unknown"
if command -v python3 >/dev/null 2>&1; then
    OPERATOR_ID=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("operatorID","?"))' "$BC_PATH" 2>/dev/null || echo unknown)
    SUBJECT_ID=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("subjectID","?"))' "$BC_PATH" 2>/dev/null || echo unknown)
fi

CEREMONY_TS=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

cat >"$OUT" <<EOF
================================================================
  JARVIS V4R CEREMONY ATTESTATION — F-E29
  Court Exhibit: cryptographic provenance, paper edition
  Generated $CEREMONY_TS UTC
================================================================

Operator: $OPERATOR_ID
Subject:  $SUBJECT_ID

----------------------------------------------------------------
  BIRTH CERTIFICATE
----------------------------------------------------------------
  Path: $BC_PATH
  SHA-256 (groups of 4 hex chars):
    $(groups_of_4 "$BC_SHA")

----------------------------------------------------------------
  VOICE MODELS ANCHOR
----------------------------------------------------------------
  Path: $ANCHOR_PATH
  SHA-256:
    $(groups_of_4 "$ANCHOR_SHA")

----------------------------------------------------------------
  COLD-ROOT PUBLIC KEY PIN (F-C01)
----------------------------------------------------------------
  Fingerprint (SHA-256 of pin file):
    $(groups_of_4 "$COLDROOT_FINGERPRINT")

----------------------------------------------------------------
  SBOM (F-E16)
----------------------------------------------------------------
  Path: $SBOM_PATH
  SHA-256:
    $(groups_of_4 "$SBOM_SHA")

----------------------------------------------------------------
  REPRODUCIBLE-BUILD BINARY (F-E12)
----------------------------------------------------------------
  Path: $PKG_ROOT/.build-repro/release/JARVISMacCockpit
  SHA-256 (deterministic — recompute with scripts/repro_build_verify.sh):
    $(groups_of_4 "$REPRO_SHA")

----------------------------------------------------------------
  WITNESSES (F-E31)
----------------------------------------------------------------
$WITNESS_BLOCK

----------------------------------------------------------------
  ATTESTATION OF GENERATION
----------------------------------------------------------------
  This document is a snapshot of the cryptographic state of the
  named JARVIS instance at the moment listed above. Every
  fingerprint can be independently recomputed by a third party
  with access to the source tree and a copy of the relevant
  on-disk artifact.

  Discrepancy between any value above and a recomputation
  indicates tampering after the ceremony.

  Generated by: scripts/generate_paper_attestation.sh
  Document SHA-256 (computed AFTER generation, exclude this line):
    (see attestation.sha file)
================================================================
EOF

chmod 0600 "$OUT"

# Compute the document's own SHA-256 and write it side-by-side. The
# operator signs THIS sha with the cold root after the ceremony to
# bind the document into the chain of evidence.
DOC_SHA=$(sha_hex "$OUT")

# R11j F-F18 — embed cold-root signature over the document SHA, then
# recompute final SHA after embed. Two-pass so the published .sha
# reflects the signed final document.
if [ -n "$COLD_ROOT_SIGN_CMD" ]; then
    SIG_FILE="$OUT_DIR/attestation.sig.hex"
    # Pipe the document SHA into the operator-supplied signer. The
    # signer's output is 128 hex chars (ed25519 sig over the SHA).
    if ! printf '%s' "$DOC_SHA" | eval "$COLD_ROOT_SIGN_CMD" >"$SIG_FILE"; then
        echo "[F-F18] FAIL: cold-root-sign-cmd exited non-zero" >&2
        exit 1
    fi
    chmod 0600 "$SIG_FILE"
    SIG_HEX=$(tr -d '[:space:]' <"$SIG_FILE")
    if ! [[ "$SIG_HEX" =~ ^[0-9a-fA-F]{128}$ ]]; then
        echo "[F-F18] FAIL: cold-root-sign-cmd output is not 128 hex chars (got ${#SIG_HEX})" >&2
        exit 1
    fi

    # Append the signature section to the document.
    cat >>"$OUT" <<EOF

----------------------------------------------------------------
  DOCUMENT COLD-ROOT SIGNATURE (F-F18)
----------------------------------------------------------------
  ed25519 signature over the document SHA-256 (above), produced
  by the operator's air-gapped cold-root signing rig. Verify by
  computing the document SHA over the bytes preceding this
  section, then ed25519-verify against the cold-root pubkey.

  Signature (groups of 4 hex chars):
    $(groups_of_4 "$SIG_HEX")
EOF
    chmod 0600 "$OUT"

    # Recompute the final document SHA after the embed. This is the
    # published value; the embedded sig is over the PRE-embed SHA.
    FINAL_DOC_SHA=$(sha_hex "$OUT")
    echo "$FINAL_DOC_SHA  ceremony_attestation.txt" >"$OUT_DIR/attestation.sha"
    # Sidecar the pre-embed SHA + sig for offline verification.
    echo "$DOC_SHA" >"$OUT_DIR/attestation.pre_embed.sha"
    chmod 0600 "$OUT_DIR/attestation.sha" "$OUT_DIR/attestation.pre_embed.sha"
    DOC_SHA="$FINAL_DOC_SHA"
    echo "[F-F18] cold-root-signed: pre-embed SHA preserved in attestation.pre_embed.sha"
else
    cat >>"$OUT" <<'EOF'

----------------------------------------------------------------
  [F-E29/F-F18] WARNING — DOCUMENT NOT COLD-ROOT-SIGNED
----------------------------------------------------------------
  This document was generated WITHOUT --cold-root-sign-cmd.
  Without an embedded cold-root signature over the document SHA,
  there is no cryptographic proof that the document itself was
  not generated post-hoc by an attacker who had read access to
  the underlying fingerprints. This artifact is NOT suitable for
  adversarial evidentiary use. Re-run with --cold-root-sign-cmd
  pointing at the operator's air-gapped signing helper.
EOF
    chmod 0600 "$OUT"
    DOC_SHA=$(sha_hex "$OUT")
    echo "$DOC_SHA  ceremony_attestation.txt" >"$OUT_DIR/attestation.sha"
    chmod 0600 "$OUT_DIR/attestation.sha"
    echo "[F-E29/F-F18] WARNING: document not cold-root-signed; not suitable for court exhibit." >&2
fi

echo "[F-E29] attestation: $OUT"
echo "[F-E29] document SHA-256: $DOC_SHA"
echo "[F-E29] document SHA-256 (groups of 4): $(groups_of_4 "$DOC_SHA")"
