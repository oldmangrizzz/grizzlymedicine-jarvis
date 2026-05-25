# Side-Channel GAPs

## GAP-SC-001 — Cert pin matching uses early-exit string equality

- Status: filed / low-risk.
- Path: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/security/cert_pinning.cpp:144-146`, `:208-212`.
- Behavior: `validate_leaf_cert()` and chain backup pin checks use `std::string::operator==` and return on first matching SPKI pin.
- Impact: timing can reveal whether a public peer SPKI hash matched the first or a later embedded public pin. No JARVIS secret, private key, identity secret, HMAC key, or AES key is compared here.
- Recommendation: replace with fixed-length constant-time compare over 44-byte base64 pin strings, scan all pins, and aggregate match result before returning. This removes an observable branch from a security-sensitive path even though current exposure is public material only.
- Test coverage: `Certificate pin matching is measured and documented as non-secret but input-dependent` in `test_side_channel_timing.cpp`.

No high-risk timing leak or non-constant-time comparison of secret material was found in this audit.
