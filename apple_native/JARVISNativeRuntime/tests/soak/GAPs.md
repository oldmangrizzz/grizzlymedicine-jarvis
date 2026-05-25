# JARVIS Phase 7 Soak GAPs

- SAGE exposes no cancellation/interruption API; harness runs consolidation in an isolated worker and verifies post-cycle health instead of fabricating interrupt control.
- Audit log has no disk-full fault hook; harness uses an invalid append path to verify IO failure is non-silent while preserving the main audit chain.
- Convex live WebSocket transport is not invoked by the soak harness without external credentials; fault is recorded as an audited deferred mutation, not a fabricated network API call.
- Deepgram STT transport requires external service state; harness uses a local state-machine session to verify drop-to-error-to-closed recovery without sending audio off-machine.
- Native Secure Enclave availability is not abstracted behind an injectable interface; harness uses the identity verifier's explicit unavailable flag and audits refuse-not-disable behavior.
