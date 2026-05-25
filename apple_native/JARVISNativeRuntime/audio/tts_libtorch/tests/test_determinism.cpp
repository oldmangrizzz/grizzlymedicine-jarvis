/**
 * test_determinism.cpp
 *
 * Verify that XTTSPipeline::synthesize() produces bit-identical audio when
 * called twice with the same text and the same seed.
 *
 * Acceptance criterion: identical PCM samples (memcmp == 0).
 *
 * Also checks that two different seeds produce different outputs (sanity check
 * that the PRNG is actually being used).
 */

#include <catch2/catch_test_macros.hpp>

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../xtts_pipeline.h"

namespace {

std::string env_or(const char* name, const char* dflt) {
    const char* v = std::getenv(name);
    return v ? v : dflt;
}

jarvis::tts::XTTSPipeline make_pipeline() {
    const std::string models_dir = env_or("JARVIS_LIBTORCH_MODELS_DIR", "models");
    jarvis::tts::PipelineConfig cfg;
    cfg.text_encoder_pt  = models_dir + "/text_encoder.pt";
    cfg.gpt_decoder_pt   = models_dir + "/gpt_decoder.pt";
    cfg.hifigan_pt       = models_dir + "/hifigan.pt";
    cfg.tokenizer_model  = env_or("JARVIS_TOKENIZER_MODEL", "models/tokenizer.model");
    cfg.voice_state_path = env_or("JARVIS_VOICE_STATE",
        "../../../../../../jarvis/_local_voice/jarvis_voice_state.safetensors");
    cfg.device           = "cpu";
    jarvis::tts::XTTSPipeline p;
    p.load(cfg);
    return p;
}

} // anonymous namespace

TEST_CASE("determinism_same_seed_bit_identical", "[determinism][libtorch]") {
    auto pipeline = make_pipeline();
    REQUIRE(pipeline.is_loaded());

    const std::string text = "JARVIS online.";
    const uint64_t seed = 42;

    auto run1 = pipeline.synthesize(text, seed);
    auto run2 = pipeline.synthesize(text, seed);

    REQUIRE(run1.samples.size() == run2.samples.size());
    const bool identical = std::memcmp(
        run1.samples.data(), run2.samples.data(),
        run1.samples.size() * sizeof(float)) == 0;
    CHECK(identical);
}

TEST_CASE("determinism_different_seed_different_output", "[determinism][libtorch]") {
    auto pipeline = make_pipeline();
    REQUIRE(pipeline.is_loaded());

    const std::string text = "Ready.";
    auto run_a = pipeline.synthesize(text, /*seed=*/42);
    auto run_b = pipeline.synthesize(text, /*seed=*/99);

    // Different seeds must produce different audio
    const bool same = (run_a.samples.size() == run_b.samples.size()) &&
                      std::memcmp(run_a.samples.data(), run_b.samples.data(),
                                  run_a.samples.size() * sizeof(float)) == 0;
    CHECK(!same);
}

TEST_CASE("determinism_all_oracle_prompts_stable", "[determinism][libtorch]") {
    // Re-synthesise the first 5 oracle prompts twice; compare
    const std::vector<std::string> texts = {
        "Ready.",
        "JARVIS online.",
        "Understood, sir.",
        "Confirmed.",
        "Yes, sir.",
    };
    auto pipeline = make_pipeline();
    REQUIRE(pipeline.is_loaded());

    for (const auto& text : texts) {
        auto r1 = pipeline.synthesize(text, 42);
        auto r2 = pipeline.synthesize(text, 42);
        REQUIRE(r1.samples.size() == r2.samples.size());
        const bool bit_equal = std::memcmp(
            r1.samples.data(), r2.samples.data(),
            r1.samples.size() * sizeof(float)) == 0;
        INFO("Text: " << text);
        CHECK(bit_equal);
    }
}
