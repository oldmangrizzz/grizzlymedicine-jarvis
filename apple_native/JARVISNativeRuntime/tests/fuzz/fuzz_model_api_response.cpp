// fuzz_model_api_response.cpp — STUB: libFuzzer harness for model API JSON/SSE parser
//
// STATUS: STUB — activate when model_client/ lands (Ollama / Gemini / Copilot)
//
// TODO (model-client-agent): Wire this harness to the JSON/SSE response parser
//   when JARVISNativeRuntime/model_client/ is implemented.
//
// Target surfaces (all three backends share this harness via a common parser interface):
//
//   Ollama (/api/generate, /api/chat):
//     - Streaming NDJSON: {"model":"...","response":"...","done":false}
//     - Termination sentinel: {"done":true,"total_duration":...}
//     - Error envelope: {"error":"..."}
//     - Malformed: truncated JSON, BOM, trailing garbage, \0 in string values
//
//   Gemini (generateContent SSE):
//     - data: {...}\n\n chunks; event: ping; event: error
//     - Nested candidates[].content.parts[].text
//     - safetyRatings arrays; finishReason enum values
//
//   GitHub Copilot / OpenAI Chat Completions SSE:
//     - data: {"id":"...","choices":[{"delta":{"content":"..."}}]}\n\n
//     - data: [DONE] sentinel
//     - Streaming tool_calls delta fragments
//
// Invariants to assert:
//   - Parser never crashes or traps on arbitrary byte input
//   - Content fields never bypass redaction layer (if plumbed through logger)
//   - Partial chunks do not produce partially-initialised output structs
//   - "done" / "[DONE]" sentinel correctly terminates accumulation
//   - Unknown fields are silently ignored (forward-compatibility)
//
// Seed corpus: corpus/model_api_response/
//   Seed with captured API responses from Ollama/Gemini/Copilot integration tests.
//
// Build and run: see README.md.

#include "fuzz_common.h"

extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    jarvis_fuzz_assert_environment();
    jarvis_fuzz_init_null_logger();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* /*data*/, std::size_t /*size*/) {
    // TODO(model-client-agent): replace with:
    //
    //   // Option A — Ollama streaming NDJSON
    //   #include "model_client/ollama_stream_parser.h"
    //   jarvis::model::OllamaStreamParser parser;
    //   std::string_view chunk(reinterpret_cast<const char*>(data), size);
    //   parser.ingest(chunk);
    //   // assert: parser.error() is set cleanly, not UB
    //
    //   // Option B — OpenAI SSE
    //   #include "model_client/sse_parser.h"
    //   jarvis::model::SSEParser sse;
    //   sse.feed(data, size);
    //   // assert: every emitted event has a valid type field
    //
    //   // Option C — Gemini JSON body
    //   #include "model_client/gemini_response_parser.h"
    //   auto result = jarvis::model::GeminiResponseParser::parse(data, size);
    //   // assert: result.content or result.error is set, never both
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
