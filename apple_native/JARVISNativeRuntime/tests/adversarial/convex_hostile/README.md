# Phase 7 Convex-Hostile Adversarial Suite

Target: `jarvis/apple_native/JARVISNativeRuntime/storage/convex/`

Threat model: Convex is hostile or compromised. The vendor may inspect all wire bytes, retain subpoenable records, log every query with timestamps, replay old blobs, delete records, inject records, or present a wrong TLS leaf certificate.

## Build / run

```sh
cmake -B build -S .
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The suite uses a local in-process hostile Convex transport. It does not contact real Convex.

## Coverage

| # | Attack | Expected defense | Test assertion |
|---|---|---|---|
| 1 | Hostile-vendor inspection | Topic/kind are HMAC-SHA256 outputs; `values` is AES-256-GCM encrypted; document is HMAC-signed | Wire capture contains no operator topic/kind/payload marker; wrong local secret cannot read row |
| 2 | Subpoena all stored records | Stored records remain opaque without local runtime secret | Full hostile dump has only HMAC keys and encrypted envelopes |
| 3 | Active MITM | Real SPKI cert pinning rejects wrong leaf | `validate_leaf_cert` returns `Mismatch` for wrong-key fixture |
| 4 | Compelled logging | Query names/timestamps/sizes remain visible, payload content does not | Test logs residual cadence/size/timing while rejecting cleartext topic/kind |
| 5 | Replay | Versioned signed encrypted blobs reject stale rows | Old row replay throws and appends `convex_replay_detected` |
| 6 | Selective deletion | Expected-record manifest plus tamper-evident audit chain records omission | Missing expected row throws; audit contains `convex_missing_expected_record`; chain verifier detects audit truncation |
| 7 | Confused deputy injection | HMAC signature gate rejects unauthenticated rows | Injected row throws and appends `convex_signature_rejected` |

## Residual side channels / GAPs

- Timing, query cadence, method names, and payload sizes remain visible to a hostile Convex endpoint.
- Padding is not implemented for Convex payload envelopes.
- Batching/mixnet-style delayed dispatch is not implemented.
- Operator-action TODO: choose latency budget, padding buckets, and whether Convex remains acceptable for metadata-sensitive workflows.

See `OPERATOR_REPORT.md` and `GAPS.md`.
