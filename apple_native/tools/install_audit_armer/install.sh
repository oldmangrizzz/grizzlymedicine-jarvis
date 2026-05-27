#!/usr/bin/env bash
# install.sh — V4R R11l α.3.1 (F-KE03 in-threat-model coverage).
#
# Operator-side install of the JARVISAuditArmer LaunchDaemon. Run AFTER
# build.sh produces ./build/jarvis-audit-armer. Requires sudo.
#
# Side effects:
#   1. Copies binary  -> /usr/local/libexec/jarvis-audit-armer (root:wheel 0755)
#   2. Copies plist   -> /Library/LaunchDaemons/ai.realjarvis.audit.armer.plist (root:wheel 0644)
#   3. Creates helper audit dir ~$OPERATOR/.jarvis/audit/helper/ (0700, owned by OPERATOR)
#   4. Touches & SF_APPEND's the helper sub-chain file armer.jsonl
#   5. bootstrap-loads the LaunchDaemon under system-domain
#
# Uninstall:
#   sudo launchctl bootout system/ai.realjarvis.audit.armer
#   sudo rm /Library/LaunchDaemons/ai.realjarvis.audit.armer.plist
#   sudo chflags noschg,nosappnd ~$OPERATOR/.jarvis/audit/helper/armer.jsonl
#   sudo rm /usr/local/libexec/jarvis-audit-armer

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "install.sh: must be run with sudo" >&2
    exit 2
fi

cd "$(dirname "$0")"

BUILD_BIN="$(pwd)/build/jarvis-audit-armer"
SRC_PLIST="$(pwd)/ai.realjarvis.audit.armer.plist"

INSTALL_BIN="/usr/local/libexec/jarvis-audit-armer"
INSTALL_PLIST="/Library/LaunchDaemons/ai.realjarvis.audit.armer.plist"
LAUNCHD_LABEL="ai.realjarvis.audit.armer"

OPERATOR="${SUDO_USER:-}"
if [[ -z "${OPERATOR}" || "${OPERATOR}" == "root" ]]; then
    echo "install.sh: SUDO_USER not set or root; refusing to install for unknown operator" >&2
    exit 3
fi
OPERATOR_HOME="$(eval echo "~${OPERATOR}")"
HELPER_AUDIT_DIR="${OPERATOR_HOME}/.jarvis/audit/helper"
HELPER_AUDIT_FILE="${HELPER_AUDIT_DIR}/armer.jsonl"

if [[ ! -x "${BUILD_BIN}" ]]; then
    echo "install.sh: ${BUILD_BIN} not found; run ./build.sh first" >&2
    exit 4
fi

echo "==> Installing binary to ${INSTALL_BIN}"
install -d -m 0755 "$(dirname "${INSTALL_BIN}")"
install -m 0755 -o root -g wheel "${BUILD_BIN}" "${INSTALL_BIN}"

echo "==> Installing LaunchDaemon plist to ${INSTALL_PLIST}"
install -m 0644 -o root -g wheel "${SRC_PLIST}" "${INSTALL_PLIST}"

echo "==> Creating helper audit dir + SF_APPEND'ing helper sub-chain"
mkdir -p "${HELPER_AUDIT_DIR}"
chown "${OPERATOR}":staff "${HELPER_AUDIT_DIR}"
chmod 0700 "${HELPER_AUDIT_DIR}"
if [[ ! -f "${HELPER_AUDIT_FILE}" ]]; then
    : > "${HELPER_AUDIT_FILE}"
    chown "${OPERATOR}":staff "${HELPER_AUDIT_FILE}"
    chmod 0600 "${HELPER_AUDIT_FILE}"
fi
# UF_APPEND first (defense-in-depth from α.3); then SF_APPEND (root-only).
chflags uappnd "${HELPER_AUDIT_FILE}"
chflags sappnd "${HELPER_AUDIT_FILE}"

echo "==> Loading LaunchDaemon under system-domain"
if launchctl print "system/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
    launchctl bootout "system/${LAUNCHD_LABEL}" || true
fi
launchctl bootstrap system "${INSTALL_PLIST}"
launchctl enable "system/${LAUNCHD_LABEL}"

echo "==> Verifying"
launchctl print "system/${LAUNCHD_LABEL}" | head -20
echo "==> Install complete"
echo "    binary:        ${INSTALL_BIN}"
echo "    plist:         ${INSTALL_PLIST}"
echo "    helper chain:  ${HELPER_AUDIT_FILE} (UF_APPEND + SF_APPEND)"
