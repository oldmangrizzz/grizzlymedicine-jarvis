// fuzz_convex_message.cpp — STUB: libFuzzer harness for Convex message deserialization
//
// STATUS: STUB — activate when convex/ client C++ layer lands
//
// TODO (convex-agent): Wire this harness to the Convex message deserializer
//   when JARVISNativeRuntime/convex/ is implemented.
//
// Expected surface to fuzz:
//   - Convex JSON message envelope deserialization (type, requestId, body)
//   - QueryResult / MutationResult / ActionResult bodies
//   - Nested document values: strings, numbers, Uint8Arrays, IDs, arrays, objects
//   - Edge cases: deeply nested structures (stack overflow?), empty arrays/objects,
//     null values in unexpected positions, oversized strings
//   - Subscription update (patch) messages: add/remove/patch operations
//   - Error response messages: unknown error codes, missing required fields
//
// Invariants to assert:
//   - Deserializer never crashes on arbitrary JSON input
//   - Error messages do not contain operator-content in plaintext (redaction check)
//   - Round-trip fidelity for well-formed messages
//
// Seed corpus: corpus/convex_message/
//   Seed with captured Convex WebSocket frames from integration tests.
//
// Build and run: see README.md.

#include "fuzz_common.h"

extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    jarvis_fuzz_assert_environment();
    jarvis_fuzz_init_null_logger();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* /*data*/, std::size_t /*size*/) {
    // TODO(convex-agent): replace with:
    //   #include "convex/message.h"
    //   std::string_view json(reinterpret_cast<const char*>(data), size);
    //   auto result = jarvis::convex::Message::deserialize(json);
    //   // assert result is valid or explicit error
    return 0;
}

#ifdef JARVIS_FUZZ_AFL
__AFL_FUZZ_INIT();
int main() {
#ifdef __AFL_HAVE_MANUAL_CONTROL
    __AFL_INIT();
#endif
    unsigned char* buf = __AFL_FUZZ_TESTCASE_BUF;
    while (__AFL_LOOP(100000)) {
        int len = __AFL_FUZZ_TESTCASE_LEN;
        if (len > 0) LLVMFuzzerTestOneInput(buf, static_cast<std::size_t>(len));
    }
    return 0;
}
#endif
