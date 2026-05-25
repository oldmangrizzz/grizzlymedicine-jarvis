# Wire-protocol adversarial residual GAPs

| GAP | Status | Mitigation TODO |
|---|---|---|
| Admission-controller persistence | Open | Persist consumed pairing nonces across process restarts so a crash cannot reopen a still-unexpired offer. |
| Distributed resource limits | Open | Coordinate per-source caps across multiple listener processes/interfaces if the transport becomes multi-process. |
| Transport-level distress suppression | Open but bounded | Cryptography preserves integrity; a network adversary can still drop all packets. Add redundant transports / local alert paths if operator requires delivery guarantees. |
| Metadata side channels | Open | Local adversary can observe timing, sizes, and connection attempts. Add padding and batching if metadata resistance becomes a requirement. |
