# Static Audit — Side-Channel and Secret Comparison Paths

## identity/character_values

Call sites using libsodium:

- `character_values.cpp:27` — `sodium_init()`.
- `character_values.cpp:85` — `crypto_hash_sha256()` for deterministic HDC seed material.
- `character_values.cpp:150` — `sodium_memcmp()` in `safe_equal()`.
- `character_values.cpp:163` — `crypto_hash_sha256()` for SHA-256 hex helpers.
- `character_values.cpp:281` — `crypto_sign_keypair()` for Ed25519 key generation.
- `character_values.cpp:306` — `crypto_sign_detached()` in `SoulAnchor::anchor_birth_certificate()`.
- `character_values.cpp:341` — `crypto_sign_verify_detached()` in `SoulAnchor::verify_birth_certificate()`.

Secret/sensitive comparisons:

- `character_values.cpp:148-151` — `safe_equal(a,b)` checks length then `sodium_memcmp()`. Constant-time for equal-length material. Length leaks are not treated as secret because compared fields have protocol-fixed or public structural length.
- `character_values.cpp:320` — plain `!=` for certificate `version` and `subject_id`; not secret.
- `character_values.cpp:323-331` — boot identity, value hashes, origin hash, identity hash, HV hash, hardware fingerprint, machine UUID, and Secure Enclave key ID all route through `safe_equal()`.

Finding: no plain `memcmp`/`strcmp` on identity secrets found.

## security/cert_pinning

Crypto call sites:

- `cert_pinning.cpp:86` — OpenSSL `SHA256()` over SPKI DER.
- `cert_pinning.cpp:144-146` — stored SPKI pin comparison with `std::string::operator==`.
- `cert_pinning.cpp:208-212` — chain backup pin comparison with `std::string::operator==`.

Assessment: SPKI pins and peer certificates are public, not secret. The loop exits on first match and is input-dependent. Filed as `GAP-SC-001` because the path is security-sensitive and observable, even though it does not expose secret material.

## storage/convex

Crypto call sites:

- `convex_backend.cpp:186` — OpenSSL `HMAC(EVP_sha256)` for topic/kind hashing.
- `convex_backend.cpp:197` — OpenSSL `HMAC(EVP_sha256)` for key derivation.
- `convex_backend.cpp:220-232` — OpenSSL EVP AES-256-GCM encryption.
- `convex_backend.cpp:257-267` — OpenSSL EVP AES-256-GCM decryption/authentication.
- `convex_backend.cpp:279` — OpenSSL `HMAC(EVP_sha256)` for document signature.
- `convex_backend.cpp:290` — `CRYPTO_memcmp()` for same-length document signature compare.

Secret/sensitive comparisons:

- `convex_backend.cpp:290` — `actual.size() == expected.size() && CRYPTO_memcmp(...) == 0`; constant-time for same-size HMACs. Length leak is non-secret because HMAC hex signatures are fixed length.
- `convex_backend.cpp:149-151` — `is_hmac_hex()` validates public 64-byte hex envelope fields; not secret.
- `convex_backend.cpp:244, 248` — AES-GCM envelope algorithm/size checks; not secret.

Finding: no plain `memcmp`/`strcmp` on Convex secrets found.

## holograph/hdc

Input-dependent non-secret paths:

- `hdc_real.cpp:245-270` — `RealKernel::similarity()` branches on non-finite vectors and zero norms.
- `hdc_ternary.cpp:316-317` — `TernaryKernel::similarity()` branches on zero active trits.
- `hdc_ternary.cpp:41-46` and `331-353` — ternary sign/pack/unpack are value-dependent.

Assessment: hypervector contents in this target are not secret identity keys or cryptographic material. Similarity is intentionally not constant-time and is documented as acceptable.

## holograph/beliefstore

Input-dependent non-secret paths:

- `beliefstore.cpp:159-171` — retrieval floor, quarantine, provenance, confidence filters, and best-score selection.
- `beliefstore.cpp:238-305` — revision hysteresis/abstention branch behavior.
- `beliefstore.cpp:413-416` — confidence clamp thresholding.

Assessment: threshold behavior may reveal whether a belief cleared retrieval floor if an attacker can repeatedly time local calls. The values are not cryptographic secrets; risk is low and documented.

## Explicit compare-function grep

Command run from runtime root:

```sh
grep -RInE 'memcmp|CRYPTO_memcmp|sodium_memcmp|std::equal|strcmp|strncmp' identity/character_values security storage/convex holograph/hdc holograph/beliefstore --include='*.cpp' --include='*.h' | grep -v '/build/'
```

Results:

- `identity/character_values/character_values.cpp:150` — `sodium_memcmp()`.
- `storage/convex/convex_backend.cpp:290` — `CRYPTO_memcmp()`.

No plain `memcmp`, `strcmp`, `strncmp`, or `std::equal` on target source paths outside build artifacts.
