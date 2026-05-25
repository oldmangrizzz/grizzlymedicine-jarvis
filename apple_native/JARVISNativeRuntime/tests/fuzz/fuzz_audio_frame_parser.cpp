// fuzz_audio_frame_parser.cpp — STUB: libFuzzer harness for voice/stt/ audio frame parser
//
// STATUS: STUB — activate when voice/stt/ lands (Phase 5 / p5-voice-stt)
//
// TODO (voice agent): Wire this harness to the audio frame parser when
//   JARVISNativeRuntime/voice/stt/ is implemented.
//
// Expected surface to fuzz:
//   - Raw audio frame ingestion (PCM / WAV byte streams)
//   - Frame boundary detection and demuxing
//   - VAD (voice activity detection) edge cases: all-silence, all-noise,
//     boundary-straddling speech, zero-length frames
//   - Malformed WAV headers (truncated RIFF, bad sample rate, impossible chunk sizes)
//   - Integer overflow in sample-count arithmetic
//
// Invariants to assert:
//   - Parser never reads out of bounds (ASan catches this automatically)
//   - Output frame list is non-null even for empty/malformed input
//   - Sample count is consistent with byte count and bit-depth
//   - No uninitialized reads (MSan)
//
// Seed corpus: corpus/audio_frame/
//   Seed from corpus/audio_frame/*.wav (oracle/voice/wav/ when populated).
//   libFuzzer's -dict flag should include a WAV header dictionary.
//
// Build: same cmake flags as active targets (see README).
// Run:
//   ./fuzz_audio_frame_parser -max_total_time=3600 -max_len=65536 \
//       corpus/audio_frame

#include "fuzz_common.h"

// ── Placeholder entry point ───────────────────────────────────────────────────

extern "C" int LLVMFuzzerInitialize(int* /*argc*/, char*** /*argv*/) {
    jarvis_fuzz_assert_environment();
    jarvis_fuzz_init_null_logger();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* /*data*/, std::size_t /*size*/) {
    // TODO(voice-agent): replace with:
    //   #include "voice/stt/audio_frame_parser.h"
    //   jarvis::voice::AudioFrameParser parser;
    //   auto frames = parser.ingest(data, size);
    //   assert(frames has valid structure);
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
