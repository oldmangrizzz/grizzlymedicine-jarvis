#!/usr/bin/env bash
set -euo pipefail

PORT="${JARVIS_NATIVE_SERVICE_PORT:-18788}"
TOKEN="${JARVIS_RUNTIME_COMPANION_TOKEN:-receipt-token}"
NONCE="0123456789abcdef0123456789abcdef"
STAMP="$(date +%s)"
STORE="${JARVIS_HTTP_NONCE_STORE:-$(pwd)/.build/http-replay-curl-nonces.jsonl}"
BIN="${JARVIS_NATIVE_HTTP_RECEIPT_BIN:-$(pwd)/build/Build/Products/Debug/JARVISNativeHTTPServiceReceipt}"

if [[ ! -x "$BIN" ]]; then
  if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild -project JARVISCompanionApps.xcodeproj -target JARVISNativeHTTPServiceReceipt -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO >/dev/null
  fi
fi
[[ -x "$BIN" ]] || { echo "missing JARVISNativeHTTPServiceReceipt binary; set JARVIS_NATIVE_HTTP_RECEIPT_BIN" >&2; exit 1; }
mkdir -p "$(dirname "$STORE")"
rm -f "$STORE"

terminate_service() {
  [[ -n "${PID:-}" ]] || return 0
  /bin/kill -9 "$PID" 2>/dev/null || true
}

start_service() {
  JARVIS_HTTP_NONCE_STORE="$STORE" JARVIS_RUNTIME_COMPANION_TOKEN="$TOKEN" JARVIS_NATIVE_SERVICE_PORT="$PORT" "$BIN" >/dev/null 2>&1 &
  PID=$!
  for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  terminate_service
  echo "service did not become ready" >&2
  exit 1
}

request_code() {
  curl -sS -o .build/http-replay-response.json -w '%{http_code}' \
    -H "x-jarvis-companion-token: $TOKEN" \
    -H "x-jarvis-nonce: $NONCE" \
    -H "x-jarvis-timestamp: $STAMP" \
    "http://127.0.0.1:$PORT/companion/skills"
}

start_service
first="$(request_code)"
[[ "$first" == "200" ]] || { echo "first request expected 200, got $first" >&2; terminate_service; exit 1; }
terminate_service
sleep 0.2
start_service
second="$(request_code)"
terminate_service
[[ "$second" == "401" ]] || { echo "replay expected 401, got $second" >&2; cat .build/http-replay-response.json >&2; exit 1; }
grep -q 'nonce_reuse' .build/http-replay-response.json || { echo "401 did not report nonce_reuse" >&2; cat .build/http-replay-response.json >&2; exit 1; }
echo "curl restart replay refused with 401 nonce_reuse"
