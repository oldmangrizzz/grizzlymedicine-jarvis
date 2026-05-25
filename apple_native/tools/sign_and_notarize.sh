#!/usr/bin/env bash
# sign_and_notarize.sh — sign, notarize, and staple JARVISMacCockpit.app.
#
# Default signing identity:
#   Apple Distribution: Robert Hanson (T5AFHQ4L9C)
#   SHA1: 461BE4E2E42E344CD73214DBC38268EBCA757BE2
# Override for CI/re-issued certificates with:
#   SIGNING_IDENTITY=<sha1-or-common-name>
#
# Required notarytool profile (default AC_PASSWORD):
#   xcrun notarytool store-credentials AC_PASSWORD \
#     --apple-id <apple-id> --team-id T5AFHQ4L9C --password <app-specific-password>
# Override with NOTARY_PROFILE=<profile>.
#
# Dry run without credentials or mutation:
#   bash jarvis/apple_native/tools/sign_and_notarize.sh --dry-run --app path/to/JARVISMacCockpit.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_NATIVE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_APP="${APPLE_NATIVE_DIR}/JARVISMacCockpit/build/Release/JARVISMacCockpit.app"
ENTITLEMENTS="${APPLE_NATIVE_DIR}/JARVISMacCockpit/JARVISMacCockpit.entitlements"
APP_PATH="${DEFAULT_APP}"
WORK_DIR=""
DRY_RUN=0
SKIP_SUBMIT=0
SIGNING_IDENTITY="${SIGNING_IDENTITY:-461BE4E2E42E344CD73214DBC38268EBCA757BE2}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"

usage() {
    cat <<'USAGE'
Sign, notarize, and staple JARVISMacCockpit.app.

Options:
  --app <path>       .app bundle to sign/notarize.
  --work-dir <path>  Workspace for notarization zip/logs. Default: <app-dir>/.notarization.
  --dry-run          Print planned commands and validate local inputs; do not sign, submit, or staple.
  --skip-submit      Sign and verify only; do not submit to Apple or staple.
  --help             Show this help.

Environment:
  SIGNING_IDENTITY   Default: Apple Distribution SHA1 461BE4E2E42E344CD73214DBC38268EBCA757BE2.
  NOTARY_PROFILE     Default: AC_PASSWORD. Create it with xcrun notarytool store-credentials.
USAGE
}

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) [[ $# -ge 2 ]] || fail "--app requires a path"; APP_PATH="$2"; shift 2 ;;
        --work-dir) [[ $# -ge 2 ]] || fail "--work-dir requires a path"; WORK_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-submit) SKIP_SUBMIT=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

if [[ ! -d "${APP_PATH}" ]]; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "Dry run: app bundle does not exist yet; command plan will still be printed for ${APP_PATH}"
    else
        fail "App bundle not found: ${APP_PATH}"
    fi
fi
[[ -f "${ENTITLEMENTS}" ]] || fail "Entitlements not found: ${ENTITLEMENTS}"

if [[ -z "${WORK_DIR}" ]]; then
    WORK_DIR="$(dirname "${APP_PATH}")/.notarization"
fi
ZIP_PATH="${WORK_DIR}/$(basename "${APP_PATH}" .app)-notarization.zip"

command -v codesign >/dev/null || fail "codesign not found"
command -v xcrun >/dev/null || fail "xcrun not found"
command -v ditto >/dev/null || fail "ditto not found"
command -v spctl >/dev/null || fail "spctl not found"

if [[ "${DRY_RUN}" -eq 0 ]]; then
    if ! security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
        echo "Available identities:" >&2
        security find-identity -v -p codesigning >&2 || true
        fail "signing identity not found in keychain: ${SIGNING_IDENTITY}"
    fi
    if [[ "${SKIP_SUBMIT}" -eq 0 ]]; then
        if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --no-progress >/dev/null 2>&1; then
            fail "notarytool keychain profile '${NOTARY_PROFILE}' is not configured or not valid. Run: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <apple-id> --team-id T5AFHQ4L9C --password <app-specific-password>"
        fi
    fi
fi

log "JARVISMacCockpit signing/notarization"
log "  App:              ${APP_PATH}"
log "  Entitlements:     ${ENTITLEMENTS}"
log "  Work dir:         ${WORK_DIR}"
log "  Signing identity: ${SIGNING_IDENTITY}"
log "  Notary profile:   ${NOTARY_PROFILE}"

# Sign embedded dylibs first. Do not use --deep for signing; it hides per-file failures.
while IFS= read -r dylib; do
    [[ -n "${dylib}" ]] || continue
    run codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp "${dylib}"
done < <(find "${APP_PATH}/Contents" -name '*.dylib' -print 2>/dev/null | sort)

# Sign other embedded code after dylibs, before the containing bundle.
while IFS= read -r nested; do
    [[ -n "${nested}" ]] || continue
    run codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp "${nested}"
done < <(find "${APP_PATH}/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \) -print 2>/dev/null | sort)

run codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" "${APP_PATH}"

# Verify every Mach-O in depth-first find order, not just top-level dylibs.
MACHO_COUNT=0
while IFS= read -r mach; do
    [[ -n "${mach}" ]] || continue
    MACHO_COUNT=$((MACHO_COUNT + 1))
    run codesign --verify --strict --verbose=2 "${mach}"
    run codesign --display --verbose=4 "${mach}"
done < <(find "${APP_PATH}" -type f -print0 | xargs -0 file -- 2>/dev/null | grep -E ':[[:space:]]*Mach-O' | cut -d: -f1)
log "Verified ${MACHO_COUNT} Mach-O file(s) under ${APP_PATH}."
run codesign --verify --strict --verbose=2 "${APP_PATH}"
run codesign --display --entitlements - "${APP_PATH}"

if [[ "${SKIP_SUBMIT}" -eq 1 ]]; then
    log "Skipping Apple notarization submit/staple because --skip-submit was provided."
    exit 0
fi

run mkdir -p "${WORK_DIR}"
run rm -f "${ZIP_PATH}"
run ditto -ck --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    run xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
    run xcrun stapler staple "${APP_PATH}"
    run xcrun stapler validate "${APP_PATH}"
    run spctl --assess --verbose --type execute "${APP_PATH}"
    log "Dry run complete: command sequence validated without signing or contacting Apple."
    exit 0
fi

SUBMIT_OUTPUT=""
set +e
SUBMIT_OUTPUT="$(xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait 2>&1)"
SUBMIT_STATUS=$?
set -e
printf '%s\n' "${SUBMIT_OUTPUT}"

SUBMISSION_ID="$(printf '%s\n' "${SUBMIT_OUTPUT}" | awk -F: '/^[[:space:]]*id:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')"
STATUS="$(printf '%s\n' "${SUBMIT_OUTPUT}" | awk -F: '/^[[:space:]]*status:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print tolower($2); exit}')"

if [[ ${SUBMIT_STATUS} -ne 0 || "${STATUS}" != "accepted" ]]; then
    echo "ERROR: notarization failed${SUBMISSION_ID:+ for submission ${SUBMISSION_ID}}" >&2
    if [[ -n "${SUBMISSION_ID}" ]]; then
        xcrun notarytool log "${SUBMISSION_ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
    fi
    exit 1
fi

run xcrun stapler staple "${APP_PATH}"
run xcrun stapler validate "${APP_PATH}"
run spctl --assess --verbose --type execute "${APP_PATH}"
log "Notarization complete: ${APP_PATH}"
