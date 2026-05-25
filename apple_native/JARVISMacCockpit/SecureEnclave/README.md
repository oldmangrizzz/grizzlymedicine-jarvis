# JARVIS Secure Enclave Soul Anchor

This package wires the Soul Anchor hot identity root to Apple's Secure Enclave on macOS.

- Cold root: operator-held libsodium Ed25519 keypair on USB/offline storage.
- Hot key: non-exportable Secure Enclave P-256 key created with `SecKeyCreateRandomKey` and `kSecAttrTokenIDSecureEnclave`.
- Binding: the cold root signs a deterministic certificate payload covering the hot public key, hardware fingerprint, timestamp, and Soul Anchor values hash.
- Runtime proof: JARVIS signs challenges with the hot key. Verifiers check the P-256 signature, then check the hot public key against the cold-root-signed certificate.

## Certificate envelope

`HotIdentityCertificate` JSON is the disk/audit envelope:

- `version`: `jarvis-se-hot-identity-1`
- `operatorID`: `Robert "Grizzly" Hanson, GMRI`
- `subjectID`: `JARVIS`
- `createdAtUnix`
- `mode`: `secure-enclave` or `libsodium-fallback`
- `hardwareBindingActive`
- `hotKeyAlgorithm`
- `hotPublicKeyBase64`
- `hotPublicKeySHA256Hex`
- `hardwareFingerprint.machineUUID`
- `hardwareFingerprint.secureEnclaveKeyID`
- `valuesHash`
- `coldRootPublicKeyHex`
- `warning`
- `signatureHex`: Ed25519 detached signature over the canonical payload

No custom crypto is implemented. SHA-256 uses CryptoKit, P-256 signing uses Security/Secure Enclave, and Ed25519 signing/verification uses libsodium.

## C ABI bridge

Include `include/JARVISSecureEnclaveBridge.h` from C++ and link the dynamic library product. Returned strings are malloc-owned and must be released with `jarvis_se_free`.

- `jarvis_se_hot_key_descriptor(...)`
- `jarvis_se_sign_challenge(...)`
- `jarvis_se_create_certificate(...)`
- `jarvis_se_verify_certificate(...)`

## Fallback policy

If Secure Enclave is unavailable, the module falls back to a libsodium software key. That fallback is never silent:

- returned descriptors/signatures/certificates set `hardwareBindingActive=false`
- `warning` is `hardware-binding NOT active: Secure Enclave unavailable; using libsodium software fallback`
- an audit JSONL event `hardware_binding_not_active` is appended
- the warning is also written to stderr

## Build and validation

```sh
cd <repo>/apple_native/JARVISMacCockpit/SecureEnclave
swift build
JARVIS_TEST_DATA_ROOT="${JARVIS_TEST_DATA_ROOT:-$PWD/.build/test_artifacts}" swift test
JARVIS_HOME="${JARVIS_HOME:-$PWD/.build/smoke-home}" swift run JARVISSecureEnclaveSmoke
```

On this machine the Command Line Tools Swift toolchain cannot import `XCTest` (`no such module 'XCTest'`). The XCTest sources are present under `Tests/JARVISSecureEnclaveTests`; run them under full Xcode or a toolchain with XCTest. `JARVISSecureEnclaveSmoke` exists to validate the same core paths without XCTest in this CLT environment.

## p5-soul-anchor-ceremony integration notes

1. Read the cold-root Ed25519 public/private key from the operator's USB during ceremony only.
2. Call `jarvis_se_create_certificate` with the canonical CharacterValues values hash.
3. Store the returned certificate JSON on disk and append it to the tamper-evident audit log.
4. Persist only the certificate and public cold-root key material. Do not copy the cold-root private key to local storage.
5. During runtime, call `jarvis_se_sign_challenge`; verify the signature against the certificate hot public key, then call `jarvis_se_verify_certificate` against the operator-backed cold-root public key.
