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

// R11l α.3.1 (F-KE03): cockpit-visible endocrine instance handle. Mirrors
// the declaration in JARVISNativeRuntime.h. See that file for lifetime
// and binding terms.
typedef struct jarvis_endocrine_t jarvis_endocrine_t;
jarvis_endocrine_t *JARVISRuntimeEndocrineHandle(JARVISNativeRuntime *runtime);

// R11l α.3.1: endocrine CABI write surface re-declared here so the SwiftPM
// module's Clang importer sees both the handle getter and the shims in the
// same translation unit. Definitions live in endocrine/endocrine.cpp.
void   jarvis_cabi_endocrine_on_threat(jarvis_endocrine_t *endocrine, double severity);
void   jarvis_cabi_endocrine_stimulus (jarvis_endocrine_t *endocrine,
                                       double cortisol,
                                       double dopamine,
                                       double adrenaline);
double jarvis_cabi_endocrine_level    (jarvis_endocrine_t *endocrine, const char *hormone);

void JARVISLog_configure(const char *config_json);
void JARVISLog_emit(int level, const char *subsystem, const char *event, const char *fields_json);
void JARVISLog_set_subsystem_optin(const char *subsystem, int enabled);
void JARVISLog_shutdown(void);
uint64_t JARVISLog_bytes_on_disk(void);

#ifdef __cplusplus
}
#endif
