#!/usr/bin/env bash
# notarize.sh — build, submit, and staple JARVIS Soul Anchor.
#
# Required notarytool profile:
#   xcrun notarytool store-credentials AC_PASSWORD \
#     --apple-id <apple-id> --team-id T5AFHQ4L9C --password <app-specific-password>

set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
APP=".build/JARVISCeremony.app"
ZIP=".build/JARVISCeremony-notarization.zip"

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v xcrun >/dev/null || fail "xcrun not found"
command -v ditto >/dev/null || fail "ditto not found"

if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" --no-progress >/dev/null 2>&1; then
    fail "notarytool keychain profile '${NOTARY_PROFILE}' is not configured or not valid. Run: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <apple-id> --team-id T5AFHQ4L9C --password <app-specific-password>"
fi

echo "==> building signed ceremony bundle" >&2
BUILD_OUTPUT="$(./tools/build_app.sh)"
printf '%s\n' "${BUILD_OUTPUT}"
APP_PATH="$(printf '%s\n' "${BUILD_OUTPUT}" | tail -n 1)"
[[ -d "${APP_PATH}" ]] || fail "build_app.sh did not produce an app bundle at: ${APP_PATH}"

rm -f "${ZIP}"
echo "==> creating notarization zip ${ZIP}" >&2
ditto -ck --keepParent "${APP}" "${ZIP}"

SUBMIT_OUTPUT=""
set +e
SUBMIT_OUTPUT="$(xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait 2>&1)"
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

echo "==> stapling ${APP}" >&2
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
spctl -a -vvv -t exec "${PWD}/${APP}"

echo "==> notarized bundle ready: ${PWD}/${APP}" >&2
