# Operator Report — Phase 7 Side-Channel Audit

Operator: Robert "Grizzly" Hanson, GMRI  
Deliverable: `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/`

## Result

All requested targets were audited. Catch2 timing tests built and ran successfully.

Validation run:

```text
ctest --test-dir build --output-on-failure
1/1 Test #1: test_side_channel_timing ......... Passed 8.39 sec
100% tests passed, 0 tests failed out of 1
```

Direct Catch2 run: all 7 test cases passed, 22 assertions. Each timing test uses 10,000 samples per input class.

## Findings

- Identity Ed25519 path uses libsodium: `crypto_sign_keypair`, `crypto_sign_detached`, `crypto_sign_verify_detached`, `crypto_hash_sha256`, `sodium_memcmp`.
- Identity secret/sensitive field comparisons use `sodium_memcmp` through `safe_equal()` for equal-length values.
- Convex HMAC/AES-GCM uses OpenSSL EVP/HMAC; document signature compare uses `CRYPTO_memcmp` for same-size HMAC hex values.
- No plain `memcmp`/`strcmp` on target secret material found.
- Cert pin matching is input-dependent via early-exit `std::string::operator==`; SPKI pins are public, but the security-sensitive path is filed as `GAP-SC-001`.
- HDC similarity and BeliefStore thresholding are input-dependent by design; HV contents and abstention thresholds are not cryptographic secrets in this threat model.
- Apple Silicon Spectre/Meltdown-class behavior remains OS/platform trust-domain and out-of-scope for native runtime code audit.

## Timing observations from run

- Cert pin first-vs-second public pin: mean 4066.76 ns vs 16211.9 ns, Welch t = -2.68888; documented as GAP-SC-001.
- HDC active-vs-zero similarity: mean 17692.3 ns vs 13881.6 ns, Welch t = 0.924167; documented non-secret.

## Files written

- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/CMakeLists.txt`
- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/test_side_channel_timing.cpp`
- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/README.md`
- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/STATIC_AUDIT.md`
- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/GAPs.md`
- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/tests/adversarial/side_channel/OPERATOR_REPORT.md`
- `/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/CMakeLists.txt` integrated the side-channel subdirectory.
