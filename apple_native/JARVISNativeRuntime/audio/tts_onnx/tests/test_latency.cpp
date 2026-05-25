/**
 * test_latency.cpp — First-chunk latency measurement.
 *
 * Target: first-chunk latency ≤ 250 ms on short prompts.
 * Oracle baseline: 266 ms mean (from timings.csv).
 *
 * Categories: short (5–20 words), medium (20–60 words), long (60–200 words).
 */

#include <catch2/catch_test_macros.hpp>

#include <chrono>
#include <cstdio>
#include <iostream>
#include <string>
#include <vector>

#include "../xtts_pipeline.h"

#ifndef ONNX_MODELS_DIR
#  define ONNX_MODELS_DIR "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models"
#endif
#ifndef TOKENIZER_MODEL
#  define TOKENIZER_MODEL "/Users/rbhanson/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots/d29db7978e464fb90cb3359ee0c69a273b9142cc/languages/english_2026-04/tokenizer.model"
#endif
#ifndef VOICE_STATE_PATH
#  define VOICE_STATE_PATH "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors"
#endif

static jarvis::tts::onnx::XTTSOnnxPipeline make_pipeline() {
    jarvis::tts::onnx::PipelineConfig cfg;
    cfg.text_encoder_path    = std::string(ONNX_MODELS_DIR) + "/text_encoder.onnx";
    cfg.gpt_decoder_path     = std::string(ONNX_MODELS_DIR) + "/gpt_decoder.onnx";
    cfg.hifigan_path         = std::string(ONNX_MODELS_DIR) + "/hifigan.onnx";
    cfg.tokenizer_model_path = TOKENIZER_MODEL;
    cfg.voice_state_path     = VOICE_STATE_PATH;
    return jarvis::tts::onnx::XTTSOnnxPipeline(cfg);
}

struct LatencyResult {
    std::string category;
    std::string text;
    double      first_chunk_ms;
    double      total_ms;
};

static LatencyResult measure_latency(
    jarvis::tts::onnx::XTTSOnnxPipeline& pipeline,
    const std::string& category,
    const std::string& text)
{
    using clock = std::chrono::high_resolution_clock;
    using ms    = std::chrono::duration<double, std::milli>;

    auto t_start = clock::now();
    double first_chunk_ms = -1.0;

    size_t frames = pipeline.synthesize_streaming(
        text,
        [&](const float*, size_t) {
            if (first_chunk_ms < 0.0) {
                first_chunk_ms = std::chrono::duration_cast<ms>(clock::now() - t_start).count();
            }
        },
        42);

    double total_ms = std::chrono::duration_cast<ms>(clock::now() - t_start).count();

    return {category, text, first_chunk_ms, total_ms};
}

TEST_CASE("latency_short_prompts", "[latency]") {
    auto pipeline = make_pipeline();

    std::vector<std::pair<std::string, std::string>> prompts = {
        {"very_short", "Ready."},
        {"very_short", "JARVIS online."},
        {"short",      "Good morning. All systems are nominal."},
        {"short",      "How may I be of assistance today, sir?"},
        {"short",      "Initiating standby protocol. Please hold."},
    };

    std::vector<LatencyResult> results;
    for (auto& [cat, text] : prompts) {
        results.push_back(measure_latency(pipeline, cat, text));
    }

    std::cout << "\n=== First-Chunk Latency (short prompts) ===\n";
    std::cout << "  category       first_ms   total_ms  text\n";
    for (auto& r : results) {
        std::printf("  %-14s  %7.1f    %7.1f   %.40s\n",
                    r.category.c_str(), r.first_chunk_ms, r.total_ms, r.text.c_str());
    }

    // Hard gate: first-chunk ≤ 250ms.
    for (auto& r : results) {
        REQUIRE(r.first_chunk_ms > 0.0);
        REQUIRE(r.first_chunk_ms <= 250.0);
        REQUIRE(r.first_chunk_ms < 5000.0);
    }
}

TEST_CASE("latency_medium_prompts", "[latency]") {
    auto pipeline = make_pipeline();

    std::vector<std::pair<std::string, std::string>> prompts = {
        {"medium", "All primary systems are functioning within normal parameters. "
                   "The neural inference engine is online and ready."},
        {"medium", "Good morning, sir. I have reviewed your schedule. "
                   "You have three priority items that require your attention."},
    };

    std::vector<LatencyResult> results;
    for (auto& [cat, text] : prompts) {
        results.push_back(measure_latency(pipeline, cat, text));
    }

    std::cout << "\n=== First-Chunk Latency (medium prompts) ===\n";
    for (auto& r : results) {
        std::printf("  %-10s  first=%.1fms  total=%.1fms\n",
                    r.category.c_str(), r.first_chunk_ms, r.total_ms);
    }

    for (auto& r : results) {
        REQUIRE(r.first_chunk_ms > 0.0);
        REQUIRE(r.first_chunk_ms <= 250.0);
        REQUIRE(r.first_chunk_ms < 10000.0);
    }
}

TEST_CASE("latency_long_prompt", "[latency]") {
    auto pipeline = make_pipeline();

    std::string text =
        "Good morning, sir. Here is your operational briefing for today. "
        "The primary objective is to complete the C plus plus TTS port validation. "
        "All three branches — CoreML, libtorch, and ONNX — must pass the "
        "equivalence test before the Python runtime can be retired.";

    auto r = measure_latency(pipeline, "long", text);

    std::cout << "\n=== First-Chunk Latency (long prompt) ===\n";
    std::printf("  first=%.1fms  total=%.1fms\n", r.first_chunk_ms, r.total_ms);

    REQUIRE(r.first_chunk_ms > 0.0);
    REQUIRE(r.first_chunk_ms <= 250.0);
    REQUIRE(r.first_chunk_ms < 10000.0);
}
