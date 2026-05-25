// fuzz_wire_protocol.cpp — STUB: libFuzzer harness for Phase 4 wire protocol
//
// STATUS: STUB — activate when Phase 4 wire protocol is implemented
//
// TODO (wire-protocol agent): Wire this harness to the binary frame
//   parser / serializer when JARVISNativeRuntime/wire/ is implemented.
//
// Expected surface to fuzz:
//   - Framing layer: magic bytes, version, payload-length field, checksums
//   - Message type dispatch: unknown opcodes, reserved fields, future extensions
//   - Variable-length payload deserialization
//   - Fragmented / partial frame reassembly
//   - Stream-of-frames: multi-message boundaries
//
// Invariants to assert:
//   - Deserializer never crashes or traps on arbitrary byte input
//   - Parsed message length is never greater than available buffer
//   - Round-trip: serialize(deserialize(x)) == x for all valid x
//   - Unknown opcode returns an explicit error, not UB
//
// Seed corpus: corpus/wire_protocol/
//   Seed with captured inter-process frames from integration tests when available.
//
// Build and run: see README.md.

#include "fuzz_common.h"

extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    jarvis_fuzz_assert_environment();
    jarvis_fuzz_init_null_logger();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* /*data*/, std::size_t /*size*/) {
    // TODO(wire-protocol-agent): replace with actual frame parser call.
    //   #include "wire/frame_parser.h"
    //   auto result = jarvis::wire::FrameParser::parse(data, size);
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
