# Memory-extraction coverage report

| Allocation class | mlock/no-swap | zeroize-on-free | Status |
|---|---:|---:|---|
| Audit HMAC key (`TamperEvidentAuditLog::key_`) | yes | yes | covered |
| Convex runtime secret (`RuntimeSecretStore::secret_`) | yes | yes | covered |
| Convex AES-GCM derived key locals | stack only | yes | covered |
| Convex document-HMAC derived key locals | stack only | yes | covered |
| CharacterValues Ed25519 mock private key | yes | yes | covered |
| Wire-protocol ephemeral keys | not present in current tree | not present | not applicable |
| BeliefStore / H-MEM content | no | no | GAP-MEM-001 |
| Conversation transcripts | no central allocation found | no central allocation found | GAP-MEM-002 |
| Voice anchor sample | no central allocation found | no central allocation found | GAP-MEM-003 |

Secret allocation coverage: 5/8 current-or-expected sensitive classes covered = 62.5%.
Implemented current key-material coverage: 5/5 = 100%.
