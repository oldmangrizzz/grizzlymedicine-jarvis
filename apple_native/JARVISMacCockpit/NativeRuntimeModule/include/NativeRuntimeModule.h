#pragma once
#include <stdint.h>
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

void JARVISLog_configure(const char *config_json);
void JARVISLog_emit(int level, const char *subsystem, const char *event, const char *fields_json);
void JARVISLog_set_subsystem_optin(const char *subsystem, int enabled);
void JARVISLog_shutdown(void);
uint64_t JARVISLog_bytes_on_disk(void);

#ifdef __cplusplus
}
#endif
