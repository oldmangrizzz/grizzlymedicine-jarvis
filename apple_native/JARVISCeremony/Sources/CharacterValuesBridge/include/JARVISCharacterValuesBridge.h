#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void jarvis_cv_free(char *ptr);
bool jarvis_cv_canonical_json(char **json_out, char **error_out);
// Installs the Secure-Enclave-derived 32-byte audit HMAC key into the native runtime.
bool jarvis_cv_install_audit_bridge_key(const unsigned char *key, unsigned long key_len, char **error_out);
bool jarvis_cv_audit_append(const char *log_path, const unsigned char *key, unsigned long key_len, const char *step, const char *outcome, const char *metadata_json, char **error_out);

#ifdef __cplusplus
}
#endif
