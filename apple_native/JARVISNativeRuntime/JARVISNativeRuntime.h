#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JARVISNativeRuntime JARVISNativeRuntime;

JARVISNativeRuntime *JARVISRuntimeCreate(void);
void JARVISRuntimeDestroy(JARVISNativeRuntime *runtime);
int JARVISRuntimeMount(JARVISNativeRuntime *runtime);
int JARVISRuntimeUnmount(JARVISNativeRuntime *runtime);

char *JARVISRuntimeStateJSON(JARVISNativeRuntime *runtime);
char *JARVISRuntimeSkillCatalogJSON(JARVISNativeRuntime *runtime);
char *JARVISRuntimeDispatchSkillJSON(JARVISNativeRuntime *runtime, const char *name, const char *argsJSON, const char *authorization);
char *JARVISRuntimeAuditJSON(JARVISNativeRuntime *runtime);
char *JARVISRuntimeUISpecJSON(JARVISNativeRuntime *runtime);
char *JARVISRuntimePrepareTurnJSON(JARVISNativeRuntime *runtime, const char *text);
char *JARVISRuntimeCommitTurnJSON(JARVISNativeRuntime *runtime, const char *text, const char *reply, const char *model);
char *JARVISRuntimeVoiceStatusJSON(JARVISNativeRuntime *runtime);
char *JARVISRuntimeSpeechJSON(JARVISNativeRuntime *runtime, const char *text);
void JARVISRuntimeFreeString(char *value);

// R11l α.3.1 (F-KE03 in-threat-model coverage): expose the runtime's
// jarvis::Endocrine instance handle so the cockpit (Swift) can drive
// real cortisol spikes on SF_APPEND-missing tripwire events. The handle is
// the same instance JARVISRuntimeStateJSON snapshots — the spike IS felt.
// Lifetime: handle is valid until JARVISRuntimeDestroy returns. Do NOT use
// the handle across destroy boundaries.
typedef struct jarvis_endocrine_t jarvis_endocrine_t;
jarvis_endocrine_t *JARVISRuntimeEndocrineHandle(JARVISNativeRuntime *runtime);

#ifdef __cplusplus
}
#endif
