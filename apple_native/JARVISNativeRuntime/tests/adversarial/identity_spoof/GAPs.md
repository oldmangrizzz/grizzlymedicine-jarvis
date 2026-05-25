# GAPs — identity-spoofing adversarial suite

- Operator-attestation protocol is not yet a standalone runtime subsystem. Current tests cover operator-spoofing claims inside the birth-certificate authority material and require refusal; when operator attestation lands, add tests for signed operator challenges, replayed operator challenges, and stolen operator-device material.
- Secure Enclave attestation is represented by the existing `secure_enclave_key_id` string hook. When native attestation lands, replace mock fingerprints with attested Secure Enclave public-key references and nonce-bound attestation payloads.
