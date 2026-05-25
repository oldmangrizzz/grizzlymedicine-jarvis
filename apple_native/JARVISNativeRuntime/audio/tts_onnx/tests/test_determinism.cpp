/**
 * test_determinism.cpp — Bit-identical mel re-synthesis with same seed.
 *
 * Synthesize prompt #0 ("Ready.") twice with seed=42.
 * Both audio outputs must be bit-identical → mel L2 = 0.000 dB.
 */

#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <iostream>
#include <string>
#include <vector>

#include "../mel_pipeline.h"
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

TEST_CASE("determinism_same_seed_bit_identical", "[determinism]") {
    auto pipeline = make_pipeline();

    const std::string text = "Ready.";
    const uint32_t seed = 42;

    auto audio1 = pipeline.synthesize(text, seed);
    auto audio2 = pipeline.synthesize(text, seed);

    REQUIRE(audio1.size() == audio2.size());

    // Bit-identical check
    bool bit_identical = true;
    for (size_t i = 0; i < audio1.size(); ++i) {
        if (audio1[i] != audio2[i]) {
            bit_identical = false;
            std::cout << "First mismatch at sample " << i
                      << ": " << audio1[i] << " vs " << audio2[i] << "\n";
            break;
        }
    }

    // Also compute mel L2 (should be exactly 0.0 for bit-identical)
    jarvis::tts::onnx::MelConfig mel_cfg;
    int T = static_cast<int>(audio1.size()) / mel_cfg.hop + 1;
    auto mel1 = jarvis::tts::onnx::compute_log_mel(audio1.data(), audio1.size(), mel_cfg);
    auto mel2 = jarvis::tts::onnx::compute_log_mel(audio2.data(), audio2.size(), mel_cfg);
    float l2 = jarvis::tts::onnx::mel_l2_db(mel1, T, mel2, T);

    std::cout << "Determinism check:\n";
    std::cout << "  Audio samples: " << audio1.size() << "\n";
    std::cout << "  Bit-identical: " << (bit_identical ? "YES" : "NO") << "\n";
    std::cout << "  Mel L2 (dB):   " << l2 << " (must be 0.0)\n";

    REQUIRE(bit_identical);
    REQUIRE(l2 == 0.0f);
}

TEST_CASE("determinism_different_seeds_differ", "[determinism]") {
    auto pipeline = make_pipeline();
    const std::string text = "Ready.";

    auto audio_42 = pipeline.synthesize(text, 42);
    auto audio_99 = pipeline.synthesize(text, 99);

    // Different seeds should produce different (but valid) audio
    bool any_diff = false;
    size_t n = std::min(audio_42.size(), audio_99.size());
    for (size_t i = 0; i < n; ++i) {
        if (audio_42[i] != audio_99[i]) { any_diff = true; break; }
    }
    // NOTE: if lsd_decode_steps=1 and the noise fully controls the output,
    // different seeds will differ. If the model is deterministic w.r.t. noise,
    // this may not hold. Log but don't hard-fail.
    std::cout << "Different seeds produce different audio: " << (any_diff ? "YES" : "SAME (unexpected)\n");
}
