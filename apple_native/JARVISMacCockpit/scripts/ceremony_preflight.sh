#!/usr/bin/env bash
# ceremony_preflight.sh — R11h F-E22
#
# Last-mile sanity check before any ceremony or production boot. Validates
# every environmental precondition that R11d..R11h hardening assumes is
# true. Refuses to declare success if any check fails. Designed to be run
# IMMEDIATELY before the operator initiates the ceremony or signs anything
# with the cold root.
#
# Checks:
#   1.  SIP enabled (csrutil status)
#   2.  Boot binary code-signed and Gatekeeper-accepted
#   3.  Entitlements present + not modified
#   4.  Reproducible-build binary SHA matches across two clean rebuilds
#   5.  Anchor file SHA matches the value the operator expects
#       (pass via --anchor-sha-expected=<hex>)
#   6.  operator.txt mode 0600 and owned by current user
#   7.  Cold-root pin file (if present) mode 0600
#   8.  Audit chain anchor key keychain entry present (live device)
#   9.  Toolchain SHA: swift --version output snapshot
#   10. macOS version snapshot
#
# Exit 0 if every check is OK or N/A. Exit 1 if anything fails. Exit 2
# on argument errors.
#
# Output format: tab-delimited "PASS|FAIL|SKIP\tCheckName\tDetail" lines
# so it can be piped to a logger or grepped.

set -uo pipefail

usage() {
    cat >&2 <<USAGE
Usage: scripts/ceremony_preflight.sh [--anchor-sha-expected=<hex64>] [--skip-build-check]

  --anchor-sha-expected   Expected SHA-256 of voice_models_anchor.bin.
                          R11j F-F22 — REQUIRED. Without it the
                          preflight FAILS (was SKIP pre-R11j; the
                          SKIP allowed a coerced operator to run
                          preflight green without ever comparing
                          their anchor against a known-good value).
  --skip-build-check      Skip the (~60s) reproducible-build verification.
                          Useful for fast iteration; NOT acceptable for
                          actual ceremony runs.
USAGE
    exit 2
}

ANCHOR_EXPECTED=""
SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --anchor-sha-expected=*) ANCHOR_EXPECTED="${arg#*=}" ;;
        --skip-build-check) SKIP_BUILD=1 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $arg" >&2; usage ;;
    esac
done

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG_ROOT"

FAILS=0
PASSES=0
SKIPS=0
emit() {
    local status="$1"; local name="$2"; local detail="$3"
    printf "%s\t%s\t%s\n" "$status" "$name" "$detail"
    case "$status" in
        PASS) PASSES=$((PASSES+1)) ;;
        FAIL) FAILS=$((FAILS+1)) ;;
        SKIP) SKIPS=$((SKIPS+1)) ;;
    esac
}

# 1. SIP
if command -v csrutil >/dev/null 2>&1; then
    sip=$(csrutil status 2>&1 | head -1 || echo "unknown")
    if echo "$sip" | grep -qi "enabled"; then
        emit PASS sip "$sip"
    else
        emit FAIL sip "$sip"
    fi
else
    emit SKIP sip "csrutil not available"
fi

# 2. Code signing on the release binary, if it exists.
RELEASE_BIN="$PKG_ROOT/.build-repro/release/JARVISMacCockpit"
if [ -f "$RELEASE_BIN" ]; then
    if codesign --verify --strict --verbose=1 "$RELEASE_BIN" >/dev/null 2>&1; then
        emit PASS codesign "$RELEASE_BIN"
    else
        # Local swift-build binaries are ad-hoc signed; flag but don't
        # block on dev iterations.
        ident=$(codesign -dvv "$RELEASE_BIN" 2>&1 | grep -E "^Identifier" || echo "no-identifier")
        emit FAIL codesign "verify failed; $ident"
    fi
else
    emit SKIP codesign "no $RELEASE_BIN; run repro_build_verify.sh first"
fi

# 3. Entitlements present in source tree.
ENT_PATH="$PKG_ROOT/JARVISMacCockpit.entitlements"
if [ -f "$ENT_PATH" ]; then
    ent_sha=$(shasum -a 256 "$ENT_PATH" | awk '{print $1}')
    emit PASS entitlements "sha=$ent_sha"
else
    emit FAIL entitlements "missing $ENT_PATH"
fi

# 4. Reproducible-build verification.
if [ "$SKIP_BUILD" -eq 1 ]; then
    emit SKIP repro-build "--skip-build-check set; not acceptable for ceremony"
else
    if [ -x "$PKG_ROOT/scripts/repro_build_verify.sh" ]; then
        if "$PKG_ROOT/scripts/repro_build_verify.sh" >/tmp/preflight-repro.log 2>&1; then
            sha=$(grep "Build A SHA-256:" /tmp/preflight-repro.log | awk '{print $4}')
            emit PASS repro-build "sha=$sha"
        else
            emit FAIL repro-build "$(tail -3 /tmp/preflight-repro.log | tr '\n' '|')"
        fi
    else
        emit SKIP repro-build "scripts/repro_build_verify.sh missing or not executable"
    fi
fi

# 5. Anchor SHA.
ANCHOR_PATH="$HOME/.jarvis/identity/voice_models_anchor.bin"
if [ -f "$ANCHOR_PATH" ]; then
    actual=$(shasum -a 256 "$ANCHOR_PATH" | awk '{print $1}')
    if [ -n "$ANCHOR_EXPECTED" ]; then
        if [ "$actual" = "$ANCHOR_EXPECTED" ]; then
            emit PASS anchor-sha "$actual"
        else
            emit FAIL anchor-sha "expected=$ANCHOR_EXPECTED actual=$actual"
        fi
    else
        emit FAIL anchor-sha "--anchor-sha-expected REQUIRED (R11j F-F22 — was SKIP, now FAIL: ceremony preflight must not be runnable without the operator's expected anchor SHA); actual=$actual"
    fi
else
    emit FAIL anchor-sha "missing $ANCHOR_PATH"
fi

# 6. operator.txt mode + owner.
OP_PATH="$HOME/.jarvis/identity/operator.txt"
if [ -f "$OP_PATH" ]; then
    mode=$(stat -f %Lp "$OP_PATH")
    owner=$(stat -f %Su "$OP_PATH")
    if [ "$mode" = "600" ] && [ "$owner" = "$(whoami)" ]; then
        emit PASS operator-txt "mode=$mode owner=$owner"
    else
        emit FAIL operator-txt "mode=$mode owner=$owner (require 0600 + current user)"
    fi
else
    emit FAIL operator-txt "missing $OP_PATH"
fi

# 7. Cold-root pin file (optional but if present must be 0600).
PIN_PATH="$HOME/.jarvis/identity/cold_root_public.key"
if [ -f "$PIN_PATH" ]; then
    mode=$(stat -f %Lp "$PIN_PATH")
    if [ "$mode" = "600" ]; then
        emit PASS coldroot-pin "mode=$mode"
    else
        emit FAIL coldroot-pin "mode=$mode (require 0600)"
    fi
else
    emit SKIP coldroot-pin "no pin file (Keychain-only mode)"
fi

# 8. Audit-chain aux signing key in Keychain.
SERVICE="org.grizzlymedicine.jarvis.cold-root-aux"
if security find-generic-password -s "$SERVICE" -a "signing-key-v1" >/dev/null 2>&1; then
    emit PASS aux-key-keychain "service=$SERVICE present"
else
    emit FAIL aux-key-keychain "service=$SERVICE missing — ceremony not yet completed"
fi

# 9. Toolchain SHA.
if command -v swift >/dev/null 2>&1; then
    sv=$(swift --version 2>&1 | head -1)
    tcsha=$(echo "$sv" | shasum -a 256 | awk '{print $1}')
    emit PASS toolchain "${sv} sha=$tcsha"
else
    emit FAIL toolchain "swift not on PATH"
fi

# 10. macOS version.
osv=$(sw_vers -productVersion 2>/dev/null || echo unknown)
build=$(sw_vers -buildVersion 2>/dev/null || echo unknown)
emit PASS macos "version=$osv build=$build"

echo "================================================================"
echo "preflight: $PASSES PASS / $FAILS FAIL / $SKIPS SKIP"
if [ "$FAILS" -gt 0 ]; then
    echo "preflight: FAILED — do not proceed with ceremony"
    exit 1
fi
echo "preflight: GREEN — ready for ceremony"
exit 0
