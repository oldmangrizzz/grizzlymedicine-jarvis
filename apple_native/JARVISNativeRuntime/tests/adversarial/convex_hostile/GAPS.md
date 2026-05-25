# Convex-hostile residual GAPs

| GAP | Status | Mitigation TODO |
|---|---|---|
| Timing side channel | Open | Add batching or delayed dispatch after operator chooses acceptable latency. |
| Query cadence side channel | Open | Add fixed-rate cover traffic or queue coalescing if Convex remains in the path. |
| Payload size side channel | Open | Add encrypted-envelope padding buckets; choose max overhead budget. |
| Operation-name side channel | Open | Collapse vendor-visible operations where possible or tunnel through a uniform RPC envelope. |
| Selective deletion denial-of-service | Open but detected | Local expected-record manifest detects omission; Convex can still deny service by dropping rows. |
