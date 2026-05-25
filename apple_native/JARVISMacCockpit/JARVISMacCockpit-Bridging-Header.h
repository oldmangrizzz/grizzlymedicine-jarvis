#import "JARVISNativeRuntime.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
void JARVISLog_configure(const char *config_json);
void JARVISLog_emit(int level, const char *subsystem, const char *event, const char *fields_json);
void JARVISLog_set_subsystem_optin(const char *subsystem, int enabled);
void JARVISLog_shutdown(void);
uint64_t JARVISLog_bytes_on_disk(void);
#ifdef __cplusplus
}
#endif
