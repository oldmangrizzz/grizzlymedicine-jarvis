#!/usr/bin/env bash
# bundle_dylibs.sh — embed JARVIS cockpit runtime dylibs beside his executable.
#
# Xcode runs this after resources and before the app bundle is signed. The order
# is deliberate: copy/rewrite dylibs, sign embedded dylibs, then let Xcode or the
# release signing wrapper sign the containing bundle.

set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COCKPIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
CONFIG_LOWER="$(printf '%s' "${CONFIGURATION}" | tr '[:upper:]' '[:lower:]')"

APP_PATH="${TARGET_BUILD_DIR:-${COCKPIT_DIR}/build/${CONFIGURATION}}/${FULL_PRODUCT_NAME:-JARVISMacCockpit.app}"
MACOS_DIR="${APP_PATH}/Contents/MacOS"
MAIN_BINARY="${EXECUTABLE_PATH:-Contents/MacOS/JARVISMacCockpit}"
MAIN_BINARY="${APP_PATH}/${MAIN_BINARY#${APP_PATH}/}"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-461BE4E2E42E344CD73214DBC38268EBCA757BE2}}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-YES}"

LIBSODIUM_SRC="$(brew --prefix libsodium 2>/dev/null)/lib/libsodium.26.dylib"
if [[ ! -f "${LIBSODIUM_SRC}" ]]; then
    LIBSODIUM_SRC="/opt/homebrew/opt/libsodium/lib/libsodium.26.dylib"
fi
[[ -f "${LIBSODIUM_SRC}" ]] || fail "libsodium.26.dylib not found. Install with: brew install libsodium"

# ── libsodium provenance check ──────────────────────────────────────────────
# Compare the on-disk dylib against the operator-committed expected hash.
# Rotate scripts/libsodium.sha256 deliberately after a brew upgrade.
LIBSODIUM_HASH_FILE="${SCRIPT_DIR}/../../scripts/libsodium.sha256"
if [[ ! -f "${LIBSODIUM_HASH_FILE}" ]]; then
    fail "libsodium expected-hash file not found: ${LIBSODIUM_HASH_FILE}"
fi
LIBSODIUM_EXPECTED="$(grep -E '^[0-9a-f]{64}$' "${LIBSODIUM_HASH_FILE}" | head -1)"
if [[ -z "${LIBSODIUM_EXPECTED}" ]]; then
    fail "libsodium.sha256 contains no valid 64-char hex hash line"
fi
LIBSODIUM_ACTUAL="$(shasum -a 256 "${LIBSODIUM_SRC}" | awk '{print $1}')"
if [[ "${LIBSODIUM_ACTUAL}" != "${LIBSODIUM_EXPECTED}" ]]; then
    fail "libsodium SHA256 MISMATCH — supply-chain check failed.
  file:     ${LIBSODIUM_SRC}
  expected: ${LIBSODIUM_EXPECTED}
  actual:   ${LIBSODIUM_ACTUAL}
  To rotate: update scripts/libsodium.sha256 after verifying the new binary."
fi
log "libsodium provenance OK (SHA256=${LIBSODIUM_ACTUAL})"

SE_BUILD_ROOT="${COCKPIT_DIR}/SecureEnclave/.build/arm64-apple-macosx/${CONFIG_LOWER}"
SE_DYLIB="${SE_BUILD_ROOT}/libJARVISSecureEnclave.dylib"
if [[ ! -f "${SE_DYLIB}" ]]; then
    log "building SecureEnclave package (${CONFIG_LOWER})"
    swift build --package-path "${COCKPIT_DIR}/SecureEnclave" -c "${CONFIG_LOWER}" --quiet
fi
[[ -f "${SE_DYLIB}" ]] || fail "libJARVISSecureEnclave.dylib not built at ${SE_DYLIB}"
[[ -d "${MACOS_DIR}" ]] || fail "app MacOS directory not found: ${MACOS_DIR}"
[[ -x "${MAIN_BINARY}" ]] || fail "main executable not found: ${MAIN_BINARY}"

log "copying dylibs into ${MACOS_DIR}"
cp "${SE_DYLIB}" "${MACOS_DIR}/libJARVISSecureEnclave.dylib"
cp "${LIBSODIUM_SRC}" "${MACOS_DIR}/libsodium.26.dylib"
chmod 0755 "${MACOS_DIR}"/*.dylib

log "rewriting install names"
install_name_tool -id "@rpath/libsodium.26.dylib" "${MACOS_DIR}/libsodium.26.dylib"
install_name_tool -id "@rpath/libJARVISSecureEnclave.dylib" "${MACOS_DIR}/libJARVISSecureEnclave.dylib"

SE_OLD_SODIUM="$(otool -L "${MACOS_DIR}/libJARVISSecureEnclave.dylib" | awk '/libsodium/ {print $1; exit}')"
if [[ -n "${SE_OLD_SODIUM}" && "${SE_OLD_SODIUM}" != "@rpath/libsodium.26.dylib" ]]; then
    install_name_tool -change "${SE_OLD_SODIUM}" "@rpath/libsodium.26.dylib" "${MACOS_DIR}/libJARVISSecureEnclave.dylib"
fi
install_name_tool -add_rpath "@loader_path/." "${MACOS_DIR}/libJARVISSecureEnclave.dylib" 2>/dev/null || true

MAIN_OLD_SODIUM="$(otool -L "${MAIN_BINARY}" | awk '/libsodium/ {print $1; exit}')"
if [[ -n "${MAIN_OLD_SODIUM}" && "${MAIN_OLD_SODIUM}" != "@rpath/libsodium.26.dylib" ]]; then
    install_name_tool -change "${MAIN_OLD_SODIUM}" "@rpath/libsodium.26.dylib" "${MAIN_BINARY}"
fi
MAIN_OLD_SE="$(otool -L "${MAIN_BINARY}" | awk '/libJARVISSecureEnclave/ {print $1; exit}')"
if [[ -n "${MAIN_OLD_SE}" && "${MAIN_OLD_SE}" != "@rpath/libJARVISSecureEnclave.dylib" ]]; then
    install_name_tool -change "${MAIN_OLD_SE}" "@rpath/libJARVISSecureEnclave.dylib" "${MAIN_BINARY}"
fi
install_name_tool -add_rpath "@executable_path/." "${MAIN_BINARY}" 2>/dev/null || true

# ── bundle manifest ──────────────────────────────────────────────────────────
# Produce a deterministic SHA256 manifest of the main binary + all bundled
# dylibs, stored at Contents/Resources/JARVIS_BUNDLE_MANIFEST.sha256.
# Written BEFORE codesign so the bundle signature covers the manifest.
#
# Verify at any time:
#   cd "${APP_PATH}" && shasum -a 256 -c Contents/Resources/JARVIS_BUNDLE_MANIFEST.sha256
RES_DIR="${APP_PATH}/Contents/Resources"
mkdir -p "${RES_DIR}"
MANIFEST_FILE="${RES_DIR}/JARVIS_BUNDLE_MANIFEST.sha256"
log "generating bundle manifest → ${MANIFEST_FILE}"
{
    echo "${MAIN_BINARY}"
    find "${MACOS_DIR}" -maxdepth 1 -name '*.dylib' -print 2>/dev/null | sort
} | while IFS= read -r filepath; do
    [[ -f "${filepath}" ]] || continue
    filehash="$(shasum -a 256 "${filepath}" | awk '{print $1}')"
    relpath="${filepath#${APP_PATH}/}"
    printf '%s  %s\n' "${filehash}" "${relpath}"
done > "${MANIFEST_FILE}"
log "bundle manifest written: $(wc -l < "${MANIFEST_FILE}" | tr -d ' ') entries"

if [[ "${CODE_SIGNING_ALLOWED}" == "NO" ]]; then
    log "skipping dylib codesign because CODE_SIGNING_ALLOWED=NO"
    exit 0
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    fail "no signing identity available for embedded dylibs"
fi

log "codesigning embedded dylibs"
codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp \
    "${MACOS_DIR}/libsodium.26.dylib"
codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp \
    "${MACOS_DIR}/libJARVISSecureEnclave.dylib"

log "embedded dylibs ready"
