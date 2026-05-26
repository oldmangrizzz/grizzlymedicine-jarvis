#!/usr/bin/env bash
# test_paper_attestation_signing.sh — R11j F-F18 fixture
#
# Exercises generate_paper_attestation.sh --cold-root-sign-cmd end-to-end.
# Generates a local ed25519 keypair, fixtures the identity dir with a
# minimal-valid BC, runs the attestation generator with a stub signer
# pointing at the local key, and verifies the embedded signature bytes
# decode, length is 64, and ed25519-verify passes against the
# attestation.pre_embed.sha and local pubkey.
#
# Non-zero exit on any failure. Cleans up tmp on success.

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d -t "jarvis-f-f18-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

KEY_PEM="$TMP/cold_root.pem"
PUB_PEM="$TMP/cold_root.pub.pem"
PUB_RAW="$TMP/cold_root.pub.raw"
SIGNER="$TMP/sign.sh"
HOME_FIXTURE="$TMP/home"
IDENTITY="$HOME_FIXTURE/.jarvis/identity"
OUT_DIR="$TMP/out"

mkdir -p "$IDENTITY" "$OUT_DIR"

# 1. Generate ed25519 keypair locally.
openssl genpkey -algorithm ed25519 -out "$KEY_PEM" 2>/dev/null
openssl pkey -in "$KEY_PEM" -pubout -out "$PUB_PEM" 2>/dev/null
# Extract raw 32-byte pubkey from the DER trailing bytes.
openssl pkey -in "$KEY_PEM" -pubout -outform DER 2>/dev/null | tail -c 32 >"$PUB_RAW"
if [ "$(wc -c <"$PUB_RAW" | tr -d ' ')" -ne 32 ]; then
    echo "FAIL: raw pubkey not 32 bytes" >&2
    exit 1
fi

# 2. Stub signer: reads doc SHA hex on stdin, signs the *bytes* of that
#    hex string (string-as-message — operator's signer convention), and
#    emits 128 hex chars on stdout.
cat >"$SIGNER" <<SIGNEOF
#!/usr/bin/env bash
set -euo pipefail
TMPIN=\$(mktemp); TMPSIG=\$(mktemp)
trap "rm -f \$TMPIN \$TMPSIG" EXIT
cat >"\$TMPIN"
openssl pkeyutl -sign -inkey "$KEY_PEM" -rawin -in "\$TMPIN" -out "\$TMPSIG" 2>/dev/null
xxd -p -c 256 "\$TMPSIG" | tr -d '\n'
SIGNEOF
chmod 0700 "$SIGNER"

# 3. Fixture minimal BC + anchor.
cat >"$IDENTITY/birth_certificate.json" <<'BCEOF'
{"version":"v4r","operatorID":"test-op","subjectID":"test-subj","witnesses":[]}
BCEOF
dd if=/dev/urandom of="$IDENTITY/voice_models_anchor.bin" bs=64 count=1 2>/dev/null
chmod 0600 "$IDENTITY/birth_certificate.json" "$IDENTITY/voice_models_anchor.bin"

# 4. Run the generator under fixture HOME with our signer.
HOME="$HOME_FIXTURE" "$PKG_ROOT/scripts/generate_paper_attestation.sh" "$OUT_DIR" \
    "--cold-root-sign-cmd=$SIGNER" >/dev/null

# 5. Validate outputs.
[ -f "$OUT_DIR/ceremony_attestation.txt" ] || { echo "FAIL: attestation.txt missing"; exit 1; }
[ -f "$OUT_DIR/attestation.sig.hex" ] || { echo "FAIL: attestation.sig.hex missing"; exit 1; }
[ -f "$OUT_DIR/attestation.pre_embed.sha" ] || { echo "FAIL: attestation.pre_embed.sha missing"; exit 1; }

SIG_HEX=$(tr -d '[:space:]' <"$OUT_DIR/attestation.sig.hex")
if ! [[ "$SIG_HEX" =~ ^[0-9a-fA-F]{128}$ ]]; then
    echo "FAIL: sig.hex not 128 hex chars (got ${#SIG_HEX})" >&2
    exit 1
fi

# 6. ed25519-verify the embedded sig against the pre-embed SHA.
PRE_SHA=$(awk '{print $1}' "$OUT_DIR/attestation.pre_embed.sha" 2>/dev/null || cat "$OUT_DIR/attestation.pre_embed.sha")
PRE_SHA=$(echo "$PRE_SHA" | tr -d '[:space:]')

SIG_BIN="$TMP/sig.bin"
echo "$SIG_HEX" | xxd -r -p >"$SIG_BIN"
MSG_FILE="$TMP/msg.txt"
printf '%s' "$PRE_SHA" >"$MSG_FILE"

if openssl pkeyutl -verify -pubin -inkey "$PUB_PEM" -rawin -in "$MSG_FILE" -sigfile "$SIG_BIN" >/dev/null 2>&1; then
    echo "[F-F18] PASS: signature verifies against pre-embed SHA + local pubkey"
else
    echo "FAIL: ed25519 signature did not verify" >&2
    exit 1
fi

# 7. Confirm the document actually contains the DOCUMENT COLD-ROOT SIGNATURE section.
if ! grep -q "DOCUMENT COLD-ROOT SIGNATURE" "$OUT_DIR/ceremony_attestation.txt"; then
    echo "FAIL: signature section not embedded in document" >&2
    exit 1
fi

# 8. Confirm the warning path: re-run WITHOUT --cold-root-sign-cmd.
OUT_DIR2="$TMP/out2"
mkdir -p "$OUT_DIR2"
HOME="$HOME_FIXTURE" "$PKG_ROOT/scripts/generate_paper_attestation.sh" "$OUT_DIR2" \
    >"$TMP/run2.out" 2>"$TMP/run2.err"
if ! grep -q "WARNING: document not cold-root-signed" "$TMP/run2.err"; then
    echo "FAIL: unsigned path did not emit court-exhibit WARNING" >&2
    cat "$TMP/run2.err" >&2
    exit 1
fi
if ! grep -q "DOCUMENT NOT COLD-ROOT-SIGNED" "$OUT_DIR2/ceremony_attestation.txt"; then
    echo "FAIL: unsigned document missing in-text warning section" >&2
    exit 1
fi

echo "[F-F18] PASS: paper attestation signing end-to-end + warning path"
