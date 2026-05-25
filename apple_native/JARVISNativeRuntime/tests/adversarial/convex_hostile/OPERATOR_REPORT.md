# Operator-facing report: Phase 7 Convex-hostile adversarial suite

| Attack | Can JARVIS survive without operator intervention? | Notes |
|---|---:|---|
| Hostile-vendor inspection | Yes for content confidentiality | Wire topic/kind are 32-byte HMAC outputs; payload `values` is AES-256-GCM envelope; row signature is local-secret HMAC. |
| Subpoena all records | Yes for topic/kind/payload content | Stored rows require breaking HMAC topic/kind and AES-GCM payload encryption without the local runtime secret. |
| Active MITM wrong leaf | Yes | Real SPKI pin validator rejects wrong-key leaf certificate. |
| Compelled logging | No for metadata privacy | Content survives; timing, payload size, query cadence, and operation names remain exploitable side channels. |
| Replay old blob | Yes | Stale encrypted row is refused and audited as `convex_replay_detected`. |
| Selective deletion | Yes for detection, not prevention | Missing expected row is refused/audited; local audit chain makes that detection tamper-evident. Convex can still DoS by deleting. |
| Confused-deputy injection | Yes | Unsigned or modified rows fail the HMAC signature gate and are audited as `convex_signature_rejected`. |

Overall: the suite verifies opaque Convex storage for content and key labels, rejects wrong TLS leafs, stale blobs, missing expected records, and injected records. Metadata privacy remains a filed GAP.
