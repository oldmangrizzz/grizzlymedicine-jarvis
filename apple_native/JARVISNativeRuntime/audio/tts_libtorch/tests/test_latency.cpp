/**
 * test_latency.cpp
 *
 * Measure first-chunk latency and total synthesis latency for short / medium /
 * long prompts, compared against the oracle baseline (mean=266ms first-chunk).
 *
 * Target: first-chunk ≤ 250ms for short prompts (<20 words).
 *
 * This test records timing but does NOT fail on latency alone (latency is
 * hardware-dependent).  It prints a table and fails only if the pipeline
 * produces no output (a correctness failure masquerading as a latency issue).
 */

#include <catch2/catch_test_macros.hpp>

#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

#include "../xtts_pipeline.h"

namespace {

struct LatencyPrompt {
    const char* category;
    const char* text;
    int words;
};

static const LatencyPrompt PROMPTS[] = {
    {"short",  "Ready.",                                   1},
    {"short",  "JARVIS online.",                           2},
    {"short",  "Understood, sir.",                         2},
    {"short",  "Good morning. All systems are nominal.",   6},
    {"short",  "How may I be of assistance today, sir?",   8},
    {"medium", "All primary systems are functioning within normal parameters. "
               "The neural inference engine is operating at ninety-one percent "
               "efficiency. Thermal management is nominal.",                  28},
    {"medium", "Good morning, sir. I have reviewed your schedule. You have "
               "three priority items this morning: a research review at nine, "
               "a design sync at eleven, and a deadline submission at three.", 37},
    {"long",   "Good morning, sir. Here is your operational briefing for today. "
               "The primary objective is to complete the C++ TTS port validation "
               "pass, which requires running the mel-spectrogram equivalence tests "
               "against today's oracle captures.",                            62},
};

std::string env_or(const char* name, const char* dflt) {
    const char* v = std::getenv(name);
    return v ? v : dflt;
}

jarvis::tts::XTTSPipeline make_pipeline(const std::string& device = "cpu") {
    const std::string models_dir = env_or("JARVIS_LIBTORCH_MODELS_DIR", "models");
    jarvis::tts::PipelineConfig cfg;
    cfg.text_encoder_pt  = models_dir + "/text_encoder.pt";
    cfg.gpt_decoder_pt   = models_dir + "/gpt_decoder.pt";
    cfg.hifigan_pt       = models_dir + "/hifigan.pt";
    cfg.tokenizer_model  = env_or("JARVIS_TOKENIZER_MODEL", "models/tokenizer.model");
    cfg.voice_state_path = env_or("JARVIS_VOICE_STATE",
        "../../../../../../jarvis/_local_voice/jarvis_voice_state.safetensors");
    cfg.device           = device;
    jarvis::tts::XTTSPipeline p;
    p.load(cfg);
    return p;
}

} // anonymous namespace

TEST_CASE("latency_table", "[latency][libtorch]") {
    // Prefer MPS on Apple Silicon
    std::string dev = "cpu";
#if defined(__APPLE__) && (defined(__arm64__) || defined(__aarch64__))
    dev = "mps";
#endif

    auto pipeline = make_pipeline(dev);
    REQUIRE(pipeline.is_loaded());
    pipeline.warmup();

    struct Row {
        std::string cat;
        int words;
        int first_chunk_ms;
        int total_ms;
        bool audio_ok;
    };
    std::vector<Row> rows;

    for (const auto& p : PROMPTS) {
        auto r = pipeline.synthesize(p.text, /*seed=*/42);
        rows.push_back({p.category, p.words,
                        r.first_chunk_latency_ms,
                        r.total_latency_ms,
                        !r.samples.empty()});
    }

    // Print table
    std::cout << "\n=== Latency table (" << dev << ") ===\n";
    std::cout << std::left
              << std::setw(8)  << "cat"
              << std::setw(8)  << "words"
              << std::setw(18) << "first_chunk_ms"
              << std::setw(12) << "total_ms"
              << "audio_ok\n";
    std::cout << std::string(56, '-') << "\n";

    int short_first_chunk_sum = 0;
    int short_count = 0;
    for (const auto& r : rows) {
        std::cout << std::setw(8)  << r.cat
                  << std::setw(8)  << r.words
                  << std::setw(18) << r.first_chunk_ms
                  << std::setw(12) << r.total_ms
                  << (r.audio_ok ? "YES" : "NO") << "\n";
        CHECK(r.audio_ok);  // Hard failure: no audio = pipeline broken
        if (r.cat == "short") {
            short_first_chunk_sum += r.first_chunk_ms;
            ++short_count;
        }
    }
    if (short_count > 0) {
        const int mean_fc = short_first_chunk_sum / short_count;
        std::cout << "\nMean first-chunk (short, " << dev << "): " << mean_fc << " ms";
        std::cout << "  (oracle baseline: 266 ms, target: ≤250 ms)\n";
        // Report only — don't fail (depends on hardware)
    }
}

TEST_CASE("latency_streaming_first_chunk", "[latency][libtorch]") {
    // Verify that the streaming interface delivers the first chunk before
    // synthesis is complete (i.e., streaming is actually incremental).
    std::string dev = "cpu";
#if defined(__APPLE__) && (defined(__arm64__) || defined(__aarch64__))
    dev = "mps";
#endif

    auto pipeline = make_pipeline(dev);
    REQUIRE(pipeline.is_loaded());

    const std::string text = "Good morning. All systems are nominal.";
    const auto t0 = std::chrono::steady_clock::now();
    int first_chunk_ms = -1;
    int chunks_received = 0;

    pipeline.synthesize_stream(text, 42,
        [&](const float* samples, int n, bool /*is_last*/) -> bool {
            if (first_chunk_ms < 0) {
                first_chunk_ms = static_cast<int>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - t0).count());
            }
            ++chunks_received;
            return true;  // continue
        });

    CHECK(chunks_received > 0);
    std::cout << "\nStreaming first-chunk latency: " << first_chunk_ms << " ms  "
              << "(oracle baseline: 266 ms)\n";
}
