#!/bin/sh
# extract_spki_pin.sh — JARVIS cert-pinning bootstrap tool
#
# Usage: ./extract_spki_pin.sh <hostname> [port]
#        ./extract_spki_pin.sh <hostname> [port] --chain
#
# Prints the base64 SHA-256 of the Subject Public Key Info (SPKI) for
# the leaf certificate (default) or every cert in the chain (--chain).
# SPKI pins survive certificate renewal as long as the key pair is unchanged.
#
# Requires: openssl (LibreSSL or OpenSSL ≥1.1), awk, mktemp (POSIX)
#
# Legal notice: JARVIS security infrastructure, GMRI project.

set -eu

HOST="${1:-}"
PORT="443"
CHAIN_MODE=0

if [ -z "${HOST}" ]; then
    echo "Usage: $0 <hostname> [port] [--chain]" >&2
    exit 1
fi

# Parse remaining args
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --chain) CHAIN_MODE=1 ;;
        [0-9]*) PORT="$1" ;;
    esac
    shift
done

# ── helper: SPKI pin from a PEM file ─────────────────────────────────────────
spki_pin_from_file() {
    openssl x509 -pubkey -noout -in "$1" 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | openssl enc -base64
}

# ── fetch full chain ──────────────────────────────────────────────────────────
RAWFILE=$(mktemp)
trap 'rm -f "${RAWFILE}" "${TMPDIR:-/tmp}"/jarvis_cert_*.pem 2>/dev/null' EXIT

echo "" \
    | openssl s_client \
        -connect "${HOST}:${PORT}" \
        -servername "${HOST}" \
        -showcerts \
        2>/dev/null > "${RAWFILE}"

if [ ! -s "${RAWFILE}" ]; then
    echo "ERROR: Could not connect to ${HOST}:${PORT}" >&2
    exit 2
fi

# ── split PEM blocks into individual files ────────────────────────────────────
# Uses awk to detect cert boundaries; no mapfile needed (sh-compatible).
CERT_COUNT=$(grep -c 'BEGIN CERTIFICATE' "${RAWFILE}" || true)
if [ "${CERT_COUNT}" -eq 0 ]; then
    echo "ERROR: No certificates found in server response from ${HOST}:${PORT}" >&2
    exit 3
fi

awk '
    /-----BEGIN CERTIFICATE-----/ { idx++; out=ENVIRON["TMPDIR"] "/jarvis_cert_" idx ".pem"; printing=1 }
    printing { print > out }
    /-----END CERTIFICATE-----/  { printing=0 }
' "${RAWFILE}"

# ── output ────────────────────────────────────────────────────────────────────
GENERATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

if [ "${CHAIN_MODE}" -eq 1 ]; then
    echo "# Certificate chain for ${HOST}:${PORT}"
    echo "# Generated: ${GENERATED}"
    echo ""
    i=1
    while [ "${i}" -le "${CERT_COUNT}" ]; do
        PEMFILE="${TMPDIR}/jarvis_cert_${i}.pem"
        [ -f "${PEMFILE}" ] || break
        if [ "${i}" -eq 1 ]; then label="leaf"
        elif [ "${i}" -eq "${CERT_COUNT}" ]; then label="root"
        else label="intermediate-$((i-1))"
        fi
        subject=$(openssl x509 -subject -noout -in "${PEMFILE}" 2>/dev/null | sed 's/subject=//')
        notafter=$(openssl x509 -enddate -noout -in "${PEMFILE}" 2>/dev/null | sed 's/notAfter=//')
        pin=$(spki_pin_from_file "${PEMFILE}")
        echo "[${i}] ${label}"
        echo "    subject:     ${subject}"
        echo "    expires:     ${notafter}"
        echo "    spki-sha256: ${pin}"
        echo ""
        i=$((i+1))
    done
else
    # Leaf only
    PEMFILE="${TMPDIR}/jarvis_cert_1.pem"
    [ -f "${PEMFILE}" ] || { echo "ERROR: leaf cert not extracted" >&2; exit 4; }
    subject=$(openssl x509 -subject -noout -in "${PEMFILE}" 2>/dev/null | sed 's/subject=//')
    notafter=$(openssl x509 -enddate -noout -in "${PEMFILE}" 2>/dev/null | sed 's/notAfter=//')
    pin=$(spki_pin_from_file "${PEMFILE}")
    echo "# ${HOST}:${PORT}"
    echo "# subject:   ${subject}"
    echo "# expires:   ${notafter}"
    echo "# generated: ${GENERATED}"
    echo "${pin}"
fi
