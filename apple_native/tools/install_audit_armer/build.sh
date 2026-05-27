#!/usr/bin/env bash
# build.sh — V4R R11l α.3.1 (F-KE03 in-threat-model coverage).
#
# Operator-side build for the JARVISAuditArmer LaunchDaemon helper.
# S3 posture (Fork 3 locked 2026-05-26): no vendor trust, no Apple
# Developer-ID notarization — the operator builds from source on the
# operator's own machine, signs locally with --sign - (ad-hoc) or with
# the operator's own self-signed key when available, and installs via
# the companion install.sh.
#
# Usage:
#   ./build.sh                 # ad-hoc-signed local build (--sign -)
#   ./build.sh --sign "ID"     # local-key-signed build (replace ID with
#                              # operator's codesign identity name)
#
# Output: ./build/jarvis-audit-armer (Mach-O executable, signed).

set -euo pipefail

cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "${1:-}" == "--sign" && -n "${2:-}" ]]; then
    SIGN_IDENTITY="$2"
fi

BUILD_DIR="$(pwd)/build"
SRC_DIR="$(pwd)/JARVISAuditArmerHelper"
OUT_BIN="${BUILD_DIR}/jarvis-audit-armer"

mkdir -p "${BUILD_DIR}"

echo "==> Compiling jarvis-audit-armer (Swift)"
swiftc \
    -O \
    -target arm64e-apple-macos14.0 \
    -swift-version 5 \
    -o "${OUT_BIN}" \
    "${SRC_DIR}/SFAppendArmerXPCProtocol.swift" \
    "${SRC_DIR}/JARVISAuditArmer.swift" \
    "${SRC_DIR}/main.swift"

echo "==> Hardened-runtime + library-validation entitlements (inline plist)"
ENT_PLIST="${BUILD_DIR}/entitlements.plist"
cat > "${ENT_PLIST}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
PLIST

echo "==> Codesigning with identity: ${SIGN_IDENTITY}"
codesign \
    --force \
    --sign "${SIGN_IDENTITY}" \
    --options runtime \
    --entitlements "${ENT_PLIST}" \
    --timestamp=none \
    "${OUT_BIN}"

echo "==> Verifying signature"
codesign --display --verbose=2 "${OUT_BIN}" 2>&1 | sed 's/^/    /'

echo "==> Build complete: ${OUT_BIN}"
echo "==> Next: sudo ./install.sh"
