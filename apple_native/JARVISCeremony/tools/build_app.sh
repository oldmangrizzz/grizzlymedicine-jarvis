#!/usr/bin/env bash
# build_app.sh — production build + sign for JARVIS Soul Anchor.
#
# Rewritten 2026-05-24 after the audit fleet found the previous 28-line script
# had at least six independent ways to ship a broken bundle:
#   1. Built debug config (had assertions enabled and was 4x larger).
#   2. Ad-hoc signed (`--sign -`), making Gatekeeper/notarization impossible.
#   3. Used `--deep` (deprecated, masks per-file signing failures).
#   4. Did not bundle libJARVISSecureEnclave.dylib or libsodium.26.dylib,
#      so the app failed to launch with POSIX 163 on any machine where the
#      SE dylib wasn't already at the system rpath.
#   5. Did not bake NSMicrophoneUsageDescription into Info.plist, so the TCC
#      mic prompt never fired and the voice-anchor step silently failed.
#   6. Did not bake com.apple.security.device.audio-input into entitlements,
#      same result by a different route.
#
# This script bakes in everything the audit found so the next ceremony build
# (or wipe-and-restart) does not repeat the 4-hour signing detective story.
#
# Exit codes:
#   0  success — bundle path printed to stdout, verified output to stderr
#   1  any failure (set -euo pipefail)

set -euo pipefail
cd "$(dirname "$0")/.."

# ---- Config ---------------------------------------------------------------

CONFIG="${CONFIG:-release}"
BUNDLE_ID="org.gmri.jarvis.ceremony"
BUNDLE_NAME="JARVIS Soul Anchor"
SHORT_VERSION="${SHORT_VERSION:-1.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"
MIN_MACOS="14.0"

# Signing identity — Apple Distribution: Robert Hanson (T5AFHQ4L9C).
# Override with SIGNING_IDENTITY=<sha1> env var for CI / future re-issuance.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-461BE4E2E42E344CD73214DBC38268EBCA757BE2}"

# Entitlements: production file (no keychain-access-groups, has audio-input).
# Use Config/JARVISCeremony.dev.entitlements via ENTITLEMENTS_FILE= for local dev.
ENTITLEMENTS_FILE="${ENTITLEMENTS_FILE:-Config/JARVISCeremony.entitlements}"

# Resolve libsodium from Homebrew. Fall back to known Apple Silicon path.
LIBSODIUM_SRC="$(brew --prefix libsodium 2>/dev/null)/lib/libsodium.26.dylib"
if [[ ! -f "$LIBSODIUM_SRC" ]]; then
    LIBSODIUM_SRC="/opt/homebrew/opt/libsodium/lib/libsodium.26.dylib"
fi
if [[ ! -f "$LIBSODIUM_SRC" ]]; then
    echo "ERROR: libsodium.26.dylib not found. Install with: brew install libsodium" >&2
    exit 1
fi

# ── libsodium provenance check ──────────────────────────────────────────────
# Compare the on-disk dylib against the operator-committed expected hash in
# scripts/libsodium.sha256.  Rotate that file deliberately after brew upgrade.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBSODIUM_HASH_FILE="${SCRIPT_DIR}/../../scripts/libsodium.sha256"
if [[ ! -f "$LIBSODIUM_HASH_FILE" ]]; then
    echo "ERROR: libsodium expected-hash file not found: $LIBSODIUM_HASH_FILE" >&2
    exit 1
fi
LIBSODIUM_EXPECTED="$(grep -E '^[0-9a-f]{64}$' "$LIBSODIUM_HASH_FILE" | head -1)"
if [[ -z "$LIBSODIUM_EXPECTED" ]]; then
    echo "ERROR: scripts/libsodium.sha256 contains no valid 64-char hex hash line" >&2
    exit 1
fi
LIBSODIUM_ACTUAL="$(shasum -a 256 "$LIBSODIUM_SRC" | awk '{print $1}')"
if [[ "$LIBSODIUM_ACTUAL" != "$LIBSODIUM_EXPECTED" ]]; then
    echo "ERROR: libsodium SHA256 MISMATCH — supply-chain check failed." >&2
    echo "  file:     $LIBSODIUM_SRC" >&2
    echo "  expected: $LIBSODIUM_EXPECTED" >&2
    echo "  actual:   $LIBSODIUM_ACTUAL" >&2
    echo "  To rotate: update scripts/libsodium.sha256 after verifying the new binary." >&2
    exit 1
fi
echo "==> libsodium provenance OK (SHA256=${LIBSODIUM_ACTUAL})"

APP=".build/JARVISCeremony.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

# ---- Verify signing identity is available --------------------------------

if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo "ERROR: signing identity $SIGNING_IDENTITY not found in keychain." >&2
    echo "Available identities:" >&2
    security find-identity -v -p codesigning >&2
    exit 1
fi

# ---- Build ----------------------------------------------------------------

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --quiet

BUILD_DIR=".build/arm64-apple-macosx/$CONFIG"
if [[ ! -x "$BUILD_DIR/JARVISCeremony" ]]; then
    echo "ERROR: expected executable at $BUILD_DIR/JARVISCeremony not found" >&2
    exit 1
fi

SE_DYLIB="$BUILD_DIR/libJARVISSecureEnclave.dylib"
if [[ ! -f "$SE_DYLIB" ]]; then
    echo "ERROR: libJARVISSecureEnclave.dylib not built at $SE_DYLIB" >&2
    echo "       check that SecureEnclave package dependency resolved" >&2
    exit 1
fi

# ---- Assemble bundle ------------------------------------------------------

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BUILD_DIR/JARVISCeremony" "$MACOS_DIR/JARVISCeremony"

# Bundle dylibs into Contents/MacOS so @rpath/@executable_path resolves them
# without depending on Homebrew being installed at runtime.
cp "$SE_DYLIB"      "$MACOS_DIR/libJARVISSecureEnclave.dylib"
cp "$LIBSODIUM_SRC" "$MACOS_DIR/libsodium.26.dylib"
chmod 0755 "$MACOS_DIR"/*.dylib

# Rewrite install names so the main binary and the SE dylib both find their
# dependencies through @rpath, and we set rpath to @executable_path/. (and
# @loader_path/. for the dylib referring to its sibling).
#
# install_name_tool invalidates code signatures → we sign AFTER all rewrites.

echo "==> rewriting install names"

# 1. libsodium: identify itself as @rpath/libsodium.26.dylib
install_name_tool -id "@rpath/libsodium.26.dylib" "$MACOS_DIR/libsodium.26.dylib"

# 2. libJARVISSecureEnclave: identify as @rpath, point libsodium ref at @rpath
install_name_tool -id "@rpath/libJARVISSecureEnclave.dylib" "$MACOS_DIR/libJARVISSecureEnclave.dylib"
# Find the existing libsodium reference in the SE dylib and rewrite it.
SE_OLD_SODIUM="$(otool -L "$MACOS_DIR/libJARVISSecureEnclave.dylib" | awk '/libsodium/ {print $1; exit}')"
if [[ -n "$SE_OLD_SODIUM" && "$SE_OLD_SODIUM" != "@rpath/libsodium.26.dylib" ]]; then
    install_name_tool -change "$SE_OLD_SODIUM" "@rpath/libsodium.26.dylib" "$MACOS_DIR/libJARVISSecureEnclave.dylib"
fi
# Ensure the SE dylib has @loader_path/. on its rpath so it can find libsodium next to it.
install_name_tool -add_rpath "@loader_path/." "$MACOS_DIR/libJARVISSecureEnclave.dylib" 2>/dev/null || true

# 3. Main binary: rewrite refs to libsodium and SE dylib, add @executable_path/. to rpath
MAIN_OLD_SODIUM="$(otool -L "$MACOS_DIR/JARVISCeremony" | awk '/libsodium/ {print $1; exit}')"
if [[ -n "$MAIN_OLD_SODIUM" && "$MAIN_OLD_SODIUM" != "@rpath/libsodium.26.dylib" ]]; then
    install_name_tool -change "$MAIN_OLD_SODIUM" "@rpath/libsodium.26.dylib" "$MACOS_DIR/JARVISCeremony"
fi
MAIN_OLD_SE="$(otool -L "$MACOS_DIR/JARVISCeremony" | awk '/libJARVISSecureEnclave/ {print $1; exit}')"
if [[ -n "$MAIN_OLD_SE" && "$MAIN_OLD_SE" != "@rpath/libJARVISSecureEnclave.dylib" ]]; then
    install_name_tool -change "$MAIN_OLD_SE" "@rpath/libJARVISSecureEnclave.dylib" "$MACOS_DIR/JARVISCeremony"
fi
install_name_tool -add_rpath "@executable_path/." "$MACOS_DIR/JARVISCeremony" 2>/dev/null || true

# ---- Info.plist ----------------------------------------------------------
#
# Must include NSMicrophoneUsageDescription — without it, the TCC prompt
# never fires and the voice-anchor step silently denies.

echo "==> writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>JARVISCeremony</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundleDisplayName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>JARVIS records your voice during first-launch setup so he can recognize you and refuse anyone else who pretends to be you.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>JARVIS writes his cold backup key to a USB drive you select.</string>
</dict>
</plist>
PLIST

# ---- Bundle manifest -------------------------------------------------------
#
# Produce a deterministic manifest of every file in Contents/MacOS/ (dylibs +
# main executable) before codesigning.  The manifest lives at:
#   Contents/Resources/JARVIS_BUNDLE_MANIFEST.sha256
#
# Format (one entry per line, shasum -a 256 -c compatible):
#   <sha256hex>  <relative-path-from-bundle-root>
#
# Operator tooling can re-verify at any time with:
#   cd "$APP" && shasum -a 256 -c Contents/Resources/JARVIS_BUNDLE_MANIFEST.sha256
#
# The bundle signature (codesign) seals this file along with everything else,
# so post-sign tampering invalidates the bundle signature AND the manifest.

echo "==> generating bundle manifest"
MANIFEST_FILE="$RES_DIR/JARVIS_BUNDLE_MANIFEST.sha256"
{
    # Main executable first, then all dylibs sorted for determinism
    echo "$MACOS_DIR/JARVISCeremony"
    find "$MACOS_DIR" -maxdepth 1 -name '*.dylib' -print 2>/dev/null | sort
} | while IFS= read -r filepath; do
    [[ -f "$filepath" ]] || continue
    filehash="$(shasum -a 256 "$filepath" | awk '{print $1}')"
    relpath="${filepath#${APP}/}"
    printf '%s  %s\n' "$filehash" "$relpath"
done > "$MANIFEST_FILE"

echo "==> bundle manifest written: $(wc -l < "$MANIFEST_FILE" | tr -d ' ') entries → $MANIFEST_FILE"

# ---- Sign ----------------------------------------------------------------
#
# Order matters: sign embedded dylibs FIRST, then the main bundle. The bundle
# signature covers everything inside Contents/, so dylibs must be signed and
# stable before the bundle signature is computed.

echo "==> codesign embedded dylibs"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    "$MACOS_DIR/libsodium.26.dylib"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    "$MACOS_DIR/libJARVISSecureEnclave.dylib"

echo "==> codesign main bundle"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_FILE" \
    "$APP"

# ---- Verify --------------------------------------------------------------

echo "==> verification" >&2
while IFS= read -r dylib; do
    [ -n "$dylib" ] || continue
    codesign --verify --strict --verbose=2 "$dylib" >&2
done < <(find "$MACOS_DIR" -maxdepth 1 -name '*.dylib' -print 2>/dev/null | sort)
codesign --verify --strict --verbose=2 "$APP" >&2
codesign --display --entitlements - --xml "$APP" >&2 | grep -E "(audio-input|keychain-access-groups)" >&2 || true

echo "==> bundle ready" >&2
echo "$PWD/$APP"
