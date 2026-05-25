#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// All returned char* buffers are malloc-owned by the bridge. Release with jarvis_se_free.
void jarvis_se_free(void *ptr);

// Creates or loads the hardware-bound hot key and returns a JSON descriptor.
// If Secure Enclave is unavailable, returns a libsodium fallback descriptor with
// hardwareBindingActive=false and a non-empty warning. Fallback is never silent.
bool jarvis_se_hot_key_descriptor(const char *key_tag,
                                  const char *audit_log_path,
                                  char **descriptor_json_out,
                                  char **error_out);

// Signs challenge bytes with the Secure Enclave hot key, or with explicit logged
// libsodium fallback if Secure Enclave cannot be used. Signature JSON includes
// algorithm, key id, signature, public key, mode, and warning fields.
bool jarvis_se_sign_challenge(const char *key_tag,
                              const uint8_t *challenge,
                              size_t challenge_len,
                              const char *audit_log_path,
                              char **signature_json_out,
                              char **error_out);

// Generates a cold-root-signed hot identity certificate. root_public_key must be
// 32 bytes and root_private_key must be 64 bytes, both libsodium Ed25519 format.
bool jarvis_se_create_certificate(const char *key_tag,
                                  const char *values_hash,
                                  const uint8_t *root_public_key,
                                  size_t root_public_key_len,
                                  const uint8_t *root_private_key,
                                  size_t root_private_key_len,
                                  const char *audit_log_path,
                                  char **certificate_json_out,
                                  char **error_out);

// Verifies the certificate signature and material against the cold root public key.
bool jarvis_se_verify_certificate(const char *certificate_json,
                                  const uint8_t *root_public_key,
                                  size_t root_public_key_len,
                                  char **verification_json_out,
                                  char **error_out);

#ifdef __cplusplus
}
#endif
