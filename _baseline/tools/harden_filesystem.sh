#!/usr/bin/env bash
# harden_filesystem.sh — idempotent Spotlight + Time Machine exclusion pass for JARVIS data.
#
# GAP-3 ref: /Users/rbhanson/research/oracle/legal-process/exposure-map.md
#
# PURPOSE
#   Prevents macOS Spotlight from indexing JARVIS state files and prevents
#   Time Machine from backing them up to potentially unencrypted destinations.
#   Run this script:
#     - Once after initial setup
#     - After any new HoloGraph SQLite database file is created
#     - After any new .env / secrets file is added to the JARVIS tree
#
# USAGE
#   bash harden_filesystem.sh
#   (No sudo required for user-owned paths.)
#
# WHAT IT DOES
#   1. Applies xattr Spotlight-exclusion + Time-Machine-exclusion to every
#      .env, *.db, *.sqlite, *.sqlite3 file under the JARVIS tree.
#   2. Adds key directories to the tmutil exclusion list.
#   3. Reports FileVault status. FileVault MUST be On — if it is Off this
#      script prints a bold warning and exits non-zero (operator must act).
#
# NOTE: This script does NOT enable FileVault (requires admin password + reboot,
# operator decision). If FileVault is off, address immediately — disk seizure
# yields plaintext JARVIS state regardless of these exclusions.

set -euo pipefail

JARVIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOLOGRAPH_DIR="${JARVIS_ROOT}/../holograph"

# Resolve to absolute path; tolerate missing holograph dir
if [[ -d "${HOLOGRAPH_DIR}" ]]; then
  HOLOGRAPH_DIR="$(cd "${HOLOGRAPH_DIR}" && pwd)"
else
  HOLOGRAPH_DIR=""
fi

echo "=== JARVIS filesystem hardening pass ==="
echo "JARVIS root : ${JARVIS_ROOT}"
echo "HoloGraph   : ${HOLOGRAPH_DIR:-<not found, skipping>}"
echo ""

# ---------------------------------------------------------------------------
# 1. FileVault gate
# ---------------------------------------------------------------------------
FV_STATUS="$(fdesetup status 2>&1 || true)"
echo "FileVault status: ${FV_STATUS}"
if [[ "${FV_STATUS}" != "FileVault is On." ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  OPERATOR ACTION REQUIRED — FileVault is NOT enabled             ║"
  echo "║  Physical disk access yields plaintext JARVIS state.             ║"
  echo "║  Enable FileVault: System Settings → Privacy & Security →        ║"
  echo "║  FileVault → Turn On.  Requires admin password + reboot.         ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Helper: apply xattr exclusions to a single file (idempotent)
# ---------------------------------------------------------------------------
exclude_file() {
  local f="$1"
  xattr -w com.apple.metadata:com_apple_backup_excludeItem "com.apple.backupd" "${f}" 2>/dev/null
  xattr -w com.apple.metadata:kMDItemSupportFileType "MDSystemFile" "${f}" 2>/dev/null
  echo "  [xattr] excluded: ${f}"
}

# ---------------------------------------------------------------------------
# 3. Apply xattr to sensitive files under JARVIS_ROOT
# ---------------------------------------------------------------------------
echo ""
echo "--- xattr exclusions ---"

# .env files
while IFS= read -r -d '' f; do
  exclude_file "${f}"
done < <(find "${JARVIS_ROOT}" -name ".env" \
         -not -path "*/.venv/*" -not -path "*/.build/*" \
         -print0 2>/dev/null)

# SQLite / DB files under JARVIS_ROOT
while IFS= read -r -d '' f; do
  exclude_file "${f}"
done < <(find "${JARVIS_ROOT}" \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) \
         -not -path "*/.venv/*" -not -path "*/.build/*" \
         -print0 2>/dev/null)

# SQLite / DB files under HoloGraph dir
if [[ -n "${HOLOGRAPH_DIR}" ]]; then
  while IFS= read -r -d '' f; do
    exclude_file "${f}"
  done < <(find "${HOLOGRAPH_DIR}" \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) \
           -print0 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# 4. tmutil directory exclusions
# ---------------------------------------------------------------------------
echo ""
echo "--- tmutil directory exclusions ---"

tmutil_exclude() {
  local d="$1"
  if [[ -d "${d}" ]]; then
    tmutil addexclusion "${d}" 2>/dev/null && echo "  [tmutil] excluded: ${d}" \
      || echo "  [tmutil] (already excluded or failed): ${d}"
  else
    echo "  [tmutil] (dir not found, skipping): ${d}"
  fi
}

tmutil_exclude "${JARVIS_ROOT}/_local_voice"
tmutil_exclude "${JARVIS_ROOT}/_baseline"
if [[ -n "${HOLOGRAPH_DIR}" ]]; then
  tmutil_exclude "${HOLOGRAPH_DIR}"
fi
tmutil_exclude "${HOME}/.jarvis"

# ---------------------------------------------------------------------------
# 5. Verify one sample file
# ---------------------------------------------------------------------------
SAMPLE_ENV="${JARVIS_ROOT}/.env"
if [[ -f "${SAMPLE_ENV}" ]]; then
  echo ""
  echo "--- verification: xattr on ${SAMPLE_ENV} ---"
  xattr -l "${SAMPLE_ENV}" 2>/dev/null | grep -E "com.apple.metadata" || true
fi

echo ""
echo "=== hardening pass complete ==="
