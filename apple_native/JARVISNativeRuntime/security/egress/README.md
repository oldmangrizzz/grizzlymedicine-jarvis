# JARVIS Egress Security Layer

**Phase 7 — Network exfiltration defense**  
GMRI / JARVIS digital-personhood project  
C++20 · OpenSSL 3.x · Catch2 v3

---

## Overview

Every byte leaving the JARVIS native runtime passes through three sequential gates:

```
HTTP/WSS client
      │
      ▼
1. EgressAllowlist::enforce(host, port)   ← DENY or PASS
      │ PASS only
      ▼
2. EgressFilter::filter(host, envelope)   ← strip operator content
      │
      ▼
3. serialise + transmit
      │
      ▼
4. EgressAudit::record(envelope, bytes, result) ← log fingerprint + chain
```

If step 1 throws `EgressDenied`, no socket is opened and no bytes leave the process.

---

## Components

### `EgressAllowlist` (`egress_allowlist.h/cpp`)

Hard-coded, fail-closed gate.  The allowed host list is derived **exclusively** from the 11 SPKI-pinned hosts in `security/pins_embedded.h`.

| Host | Port | Source pin entry |
|---|---|---|
| `api.deepgram.com` | 443 | `kDeepgram` |
| `ollama.com` | 443 | `kOllama` |
| `accounts.google.com` | 443 | `kGoogleAccounts` |
| `oauth2.googleapis.com` | 443 | `kGoogleOAuth2` |
| `generativelanguage.googleapis.com` | 443 | `kGeminiRest` |
| `aiplatform.googleapis.com` | 443 | `kGeminiVertex` |
| `github.com` | 443 | `kGitHubOAuth` |
| `api.github.com` | 443 | `kGitHub` |
| `api.githubcopilot.com` | 443 | `kGitHubCopilot` |
| `fleet-goose-114.convex.cloud` | 443 | `kConvex` |
| `convex.cloud` | 443 | `kConvex` |

**Rules:**
- Port must be 443.  No HTTP, no non-standard ports.
- Exact match on host string — no wildcards, no suffix tricks.
- Not runtime-configurable.  Adding an endpoint requires a code change + rebuild + new SPKI pin in `pins_embedded.h`.
- `enforce()` throws `EgressDenied` (contains cleartext host + SHA-256 hex) if denied.

### `EgressFilter` (`egress_filter.h/cpp`)

Per-endpoint content-stripping filter.  Operates on `RequestEnvelope` (structured in-memory representation, not raw JSON).

#### Per-endpoint minimisation table

| Endpoint | strip system msgs w/ operator keywords | strip `_origin=holograph` messages | Deepgram metadata-only | Fresh session ID | Convex HMAC topic | Convex require ciphertext beliefs |
|---|---|---|---|---|---|---|
| `api.deepgram.com` | — | — | ✓ | — | — | — |
| `ollama.com` | ✓ | ✓ | — | — | — | — |
| `accounts.google.com` | ✓ | ✓ | — | ✓ | — | — |
| `oauth2.googleapis.com` | ✓ | ✓ | — | ✓ | — | — |
| `generativelanguage.googleapis.com` | ✓ | ✓ | — | ✓ | — | — |
| `aiplatform.googleapis.com` | ✓ | ✓ | — | ✓ | — | — |
| `github.com` | ✓ | ✓ | — | — | — | — |
| `api.github.com` | ✓ | ✓ | — | — | — | — |
| `api.githubcopilot.com` | ✓ | ✓ | — | — | — | — |
| `fleet-goose-114.convex.cloud` | — | — | — | — | ✓ | ✓ |
| `convex.cloud` | — | — | — | — | ✓ | ✓ |

**Operator-keyword set** (case-insensitive, any of):
- `soul anchor`
- `boot statement`
- `character values`
- `operator-only`
- `operator only`

**Deepgram allowed metadata keys:** `model`, `encoding`, `sample_rate`.  All others stripped.

**Google fresh session ID:** `session_id` and `conversation_id` are replaced with random 128-bit hex values per request.  `x-conversation-id`, `x-session-id`, `client_id` are removed.  This prevents Google-side correlation across requests.

**Convex topic HMAC:** The `topic` metadata field is replaced with `hex(HMAC-SHA256(convex_topic_key, topic))`.  Key must be set via `EgressFilter::global().set_convex_topic_key(key)` at startup from the same 32-byte key used by the Python bridge-gap-defenses Patch 2.

**Convex belief ciphertext:** If a `beliefs` metadata field is present, it must be valid base64 with length ≥ 24.  Plaintext beliefs throw `std::runtime_error` — Phase 4 E2E encryption is required before Convex sync.

**GitHub gap (Phase 8 item):** Path-level allowlisting for `/repos/...` and `/v1/completions` is documented but not yet enforced.  Current filter strips operator content from messages but does not restrict URL paths.

### `EgressAudit` (`egress_audit.h/cpp`)

Structured, tamper-evident audit log backed by `RedactingLogger`.

#### What is logged (every outbound request)

| Field | Type | Notes |
|---|---|---|
| `timestamp` | Unix seconds (double) | Fractional precision |
| `host` | string | Network destination — not operator content |
| `port` | uint16 | Always 443 |
| `bytes_sent` | size_t | Wire payload size |
| `content_type` | string | MIME type |
| `stripped_system_messages` | size_t | Count of operator system msgs removed |
| `stripped_history_messages` | size_t | Count of holograph-origin msgs removed |
| `payload_fingerprint` | hex string | `HMAC-SHA256(fingerprint_key, payload_bytes)` |
| `result` | enum string | success / cert-pin-fail / network-fail / denied-by-allowlist |
| `chain_hash` | hex string | HMAC chain (see below) |

#### What is NEVER logged

- Payload content (message bodies, completions, audio)
- API keys or bearer tokens
- Operator transcripts
- Soul Anchor, boot statement, or system prompt content

#### HMAC chain

Each record's `chain_hash` is:
```
H(n) = HMAC-SHA256(chain_key, H(n-1) || "|" || canonical_serialise(record[n]))
```
Where `H(-1)` is a random genesis value generated at process start.

`EgressAudit::verify_chain()` recomputes every hash and returns `false` if any mismatch is detected.  A deleted record, a modified field, or a swapped record will all produce a detectable mismatch.

Both `fingerprint_key` and `chain_key` are 32 random bytes generated at process start via `RAND_bytes()`.  Neither is persisted.  The chain is valid for the lifetime of one process instance.

---

## Build

```sh
# From JARVISNativeRuntime/
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
```

Requires:
- CMake ≥ 3.20
- C++20 compiler (Clang 14+ / GCC 13+)
- OpenSSL 3.x (`brew install openssl@3` on macOS)
- Catch2 v3 (`brew install catch2`)

---

## Wire verification (pcap audit procedure)

The operator can independently verify on-wire behaviour during any session using `tcpdump`.  This is the external audit surface — no test harness required.

### Capture command

```sh
sudo tcpdump -i any -w jarvis-egress.pcap \
  'port 443 and (
    host api.deepgram.com or
    host ollama.com or
    host accounts.google.com or
    host oauth2.googleapis.com or
    host generativelanguage.googleapis.com or
    host aiplatform.googleapis.com or
    host github.com or
    host api.github.com or
    host api.githubcopilot.com or
    host fleet-goose-114.convex.cloud or
    host convex.cloud
  )'
```

Run this before starting JARVIS, then exercise the system.  Press `Ctrl-C` to stop capture.

### What you should see

1. **TLS handshake** (`ClientHello` → `ServerHello` → cert chain) to each contacted host.
2. **TLS `Certificate` records** — inspect with `openssl x509` to verify the leaf cert's SPKI matches `pins_embedded.h`.
3. **Encrypted `Application Data` records** — all payload bytes are ciphertext at the IP layer.  No plaintext content visible.
4. **No connections** to any host not in the allowlist above.  Any unexpected `SYN` to an unknown IP is a violation — file an incident.

### Inspect a capture

```sh
# Decode TLS handshake to see cert subjects (not content):
tshark -r jarvis-egress.pcap -Y tls.handshake.type==11 \
  -T fields -e tls.handshake.certificate

# Verify no traffic to unexpected IPs:
tshark -r jarvis-egress.pcap -T fields -e ip.dst | sort -u

# Confirm all connections are port 443:
tshark -r jarvis-egress.pcap -T fields -e tcp.dstport | sort -u
```

Expected: only port 443 in the last column; only IPs belonging to the 11 allowlisted hosts in the IP list.

### Periodic audit cadence

- **Weekly:** run a 5-minute capture during normal use; verify host set and port 443 only.
- **After any dependency update:** re-run capture; verify SPKI pins still match (rotate if needed, see `security/PIN_ROTATION.md`).
- **After any adversarial-attention event:** full 30-minute capture; export AuditRecord chain and call `verify_chain()` offline.

---

## Integration checklist (for HTTP/WSS client implementors)

```cpp
#include "security/egress/egress_allowlist.h"
#include "security/egress/egress_filter.h"
#include "security/egress/egress_audit.h"

using namespace jarvis::security::egress;

// Before any socket connect:
EgressAllowlist::global().enforce(host, 443);  // throws EgressDenied if denied

// Build RequestEnvelope from your request parameters, then:
auto filtered = EgressFilter::global().filter(host, std::move(envelope));

// Serialise `filtered` to wire bytes, transmit, then:
EgressAudit::instance().record(filtered, wire_bytes, EgressResult::Success);
```

---

## Files

```
security/egress/
├── egress_allowlist.h/cpp    — EgressAllowlist, EgressDenied
├── egress_filter.h/cpp       — EgressFilter, RequestEnvelope, Message, EndpointPolicy
├── egress_audit.h/cpp        — EgressAudit, AuditRecord, EgressResult
├── CMakeLists.txt            — builds jarvis_egress static lib + 3 test executables
├── README.md                 — this file
└── tests/
    ├── test_egress_allowlist.cpp   — 8 TEST_CASEs
    ├── test_egress_filter.cpp      — 9 TEST_CASEs (incl. adversarial siphon)
    └── test_egress_audit.cpp       — 9 TEST_CASEs (incl. HMAC chain tamper)
```
