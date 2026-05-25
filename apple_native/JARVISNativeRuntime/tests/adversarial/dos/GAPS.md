# GAPs — Phase 7 DoS Resilience

1. **STT live slow-loris harness absent**
   - Current test uses unallowlisted-host fail-closed sessions to avoid real outbound calls.
   - Needed: local Deepgram-compatible WSS harness that accepts, holds, and minimally responds to sessions so handle-limit behavior can be tested without external egress.

2. **Integrated whole-runtime entry-point flood absent**
   - Current suite attacks landed native module entry points directly.
   - Needed: once the single native JARVIS runtime process entry point lands, replay these vectors through that top-level API.

3. **Convex live transport DoS not exercised**
   - Current suite uses `ConvexBackend` with a mock `ConvexTransport`, verifying encryption/hash/audit behavior without network.
   - Needed: local Convex-compatible transport harness for socket-level slow-loris and response-dribble tests.
