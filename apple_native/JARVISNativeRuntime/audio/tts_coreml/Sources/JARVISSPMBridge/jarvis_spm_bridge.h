// jarvis_spm_bridge.h — C bridge for SentencePiece tokenizer
// Used by XTTSCoreMLPipeline.swift to tokenise text without Python.

#ifndef JARVIS_SPM_BRIDGE_H
#define JARVIS_SPM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JARVISSPMHandle JARVISSPMHandle;

JARVISSPMHandle* jarvis_spm_load(const char* model_path);
void jarvis_spm_free(JARVISSPMHandle* handle);
int32_t* jarvis_spm_encode(JARVISSPMHandle* handle, const char* text, int32_t* out_count);
void jarvis_spm_free_ids(int32_t* ids);
char* jarvis_spm_decode(JARVISSPMHandle* handle, const int32_t* ids, int32_t count);
void jarvis_spm_free_str(char* str);
int32_t jarvis_spm_vocab_size(JARVISSPMHandle* handle);

#ifdef __cplusplus
}
#endif

#endif // JARVIS_SPM_BRIDGE_H
