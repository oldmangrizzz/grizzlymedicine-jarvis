# JARVIS native Convex backend

C++20 replacement for `_baseline/convex_backend.py`.

## API

`ConvexBackend` exposes the Python bridge surface:

- `put({kind, topic}, Signal)` → `stigmergy:put`
- `get({kind, topic}) -> optional<Signal>` → `stigmergy:get`
- `all() -> vector<Signal>` → `stigmergy:all`
- `delete_key({kind, topic})` → `stigmergy:del`
- `gc_keys(vector<{kind, topic}>)` → `stigmergy:gcKeys`

Live transport uses libcurl against Convex `/api/query` and `/api/mutation`. Unit tests use an in-process mocked Convex server and never contact Convex.

## Privacy contract

Before any Convex transmission, every `topic` and `kind` value is replaced with `HMAC-SHA256(runtime_secret, "topic:" + topic)` or `HMAC-SHA256(runtime_secret, "kind:" + kind)` as 64-character lowercase hex.

- Secret: `~/.jarvis/runtime_secret.key`, 32 raw bytes, mode `0600`.
- Local lookup index: `~/.jarvis/topic_index.json`, mode `0600`.
- The index maps hash to plaintext for operator-local lookup only; it is never sent to Convex.
- `assert_no_cleartext_topic_kind()` fails loud if a `topic` or `kind` field is not a 64-character hex digest.

## Defense wiring

- SPKI pinning: `security/pins_embedded.h` contains `fleet-goose-114.convex.cloud` and `convex.cloud` pins. Operator-attested note: pins were present before this worker and remain the source of truth.
- Egress allowlist: `security/egress` derives allowed hosts from the pin table; the live transport enforces host `:443` before curl setup.
- Audit: every query and mutation appends a tamper-evident audit event with a SHA-256 subject of redacted args.
- Logging: runtime events use `logging/redacting_logger`; no plaintext topic/kind is logged.

## Pin rotation calendar

Convex pin entry currently notes leaf expiry `2026-07-10`. Rotate by `2026-06-26` (14 days before expiry), then re-run mocked tests. Regenerate pins with `apple_native/tools/extract_spki_pin.sh fleet-goose-114.convex.cloud 443 --chain` and update `security/PIN_ROTATION.md` if the chain changes.
