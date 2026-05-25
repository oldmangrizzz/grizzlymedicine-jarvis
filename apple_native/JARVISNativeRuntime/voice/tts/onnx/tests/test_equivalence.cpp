/**
 * test_equivalence.cpp — 50-prompt mel-L2 vs oracle (acceptance: ≤ 1.0 dB).
 *
 * Reads oracle mel spectrograms from ORACLE_MEL_DIR (*.npy files),
 * runs ONNX synthesis for each prompt, computes log-mel, measures L2.
 *
 * Environment / CMake cache variables required:
 *   ORACLE_MEL_DIR      — path to oracle/voice/mel/
 *   ORACLE_PROMPTS_JSON — path to oracle/voice/prompts.json
 *   ONNX_MODELS_DIR     — directory with text_encoder.onnx, gpt_decoder.onnx, hifigan.onnx
 *   TOKENIZER_MODEL     — path to tokenizer.model
 *   VOICE_STATE_PATH    — path to jarvis_voice_state.safetensors
 */

#include <catch2/catch_test_macros.hpp>
#include <catch2/reporters/catch_reporters_all.hpp>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../mel_pipeline.h"
#include "../xtts_pipeline.h"

// ─── Compile-time paths injected by CMake ────────────────────────────────────
#ifndef ORACLE_MEL_DIR
#  define ORACLE_MEL_DIR "/Users/rbhanson/research/oracle/voice/mel"
#endif
#ifndef ORACLE_PROMPTS_JSON
#  define ORACLE_PROMPTS_JSON "/Users/rbhanson/research/oracle/voice/prompts.json"
#endif
#ifndef ONNX_MODELS_DIR
#  define ONNX_MODELS_DIR "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/voice/tts/onnx/onnx_models"
#endif
#ifndef TOKENIZER_MODEL
#  define TOKENIZER_MODEL "/Users/rbhanson/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots/d29db7978e464fb90cb3359ee0c69a273b9142cc/languages/english_2026-04/tokenizer.model"
#endif
#ifndef VOICE_STATE_PATH
#  define VOICE_STATE_PATH "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors"
#endif

// ─── Minimal .npy loader (float32, C-order) ──────────────────────────────────

struct NpyArray {
    std::vector<int64_t> shape;
    std::vector<float>   data;
};

static NpyArray load_npy_float32(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("Cannot open npy: " + path);

    // Magic + version
    char magic[7] = {};
    f.read(magic, 6);
    if (std::strncmp(magic, "\x93NUMPY", 6) != 0)
        throw std::runtime_error("Not a numpy file: " + path);

    uint8_t major, minor;
    f.read(reinterpret_cast<char*>(&major), 1);
    f.read(reinterpret_cast<char*>(&minor), 1);

    uint32_t header_len = 0;
    if (major == 1) {
        uint16_t hl;
        f.read(reinterpret_cast<char*>(&hl), 2);
        header_len = hl;
    } else {
        f.read(reinterpret_cast<char*>(&header_len), 4);
    }

    std::string header(header_len, '\0');
    f.read(header.data(), header_len);

    // Parse shape from header string: "... 'shape': (128, 1234), ..."
    NpyArray arr;
    auto pos = header.find("'shape': (");
    if (pos == std::string::npos) pos = header.find("'shape': (");
    if (pos == std::string::npos) throw std::runtime_error("Cannot find shape in npy header");
    auto start = header.find('(', pos);
    auto end   = header.find(')', start);
    std::string shape_str = header.substr(start + 1, end - start - 1);
    std::istringstream ss(shape_str);
    std::string token;
    while (std::getline(ss, token, ',')) {
        // trim whitespace
        token.erase(0, token.find_first_not_of(" \t"));
        token.erase(token.find_last_not_of(" \t") + 1);
        if (!token.empty()) arr.shape.push_back(std::stoll(token));
    }

    int64_t total = 1;
    for (auto s : arr.shape) total *= s;
    arr.data.resize(total);
    f.read(reinterpret_cast<char*>(arr.data.data()), total * sizeof(float));
    if (!f) throw std::runtime_error("Short read from npy: " + path);
    return arr;
}

// ─── Pipeline factory ─────────────────────────────────────────────────────────

static jarvis::tts::onnx::XTTSOnnxPipeline make_pipeline() {
    jarvis::tts::onnx::PipelineConfig cfg;
    cfg.text_encoder_path  = std::string(ONNX_MODELS_DIR) + "/text_encoder.onnx";
    cfg.gpt_decoder_path   = std::string(ONNX_MODELS_DIR) + "/gpt_decoder.onnx";
    cfg.hifigan_path       = std::string(ONNX_MODELS_DIR) + "/hifigan.onnx";
    cfg.tokenizer_model_path = TOKENIZER_MODEL;
    cfg.voice_state_path   = VOICE_STATE_PATH;
    return jarvis::tts::onnx::XTTSOnnxPipeline(cfg);
}

// ─── Test ─────────────────────────────────────────────────────────────────────

TEST_CASE("mel_L2_all_50_prompts", "[equivalence]") {
    // Load prompts
    std::ifstream pf(ORACLE_PROMPTS_JSON);
    REQUIRE(pf.is_open());
    auto j = nlohmann::json::parse(pf);
    auto prompts = j["prompts"];
    REQUIRE(prompts.size() == 50);

    auto pipeline = make_pipeline();

    float worst_l2 = 0.0f;
    int   fail_count = 0;

    struct PromptResult {
        int   idx;
        std::string cat;
        std::string text;
        float l2;
        bool  pass;
    };
    std::vector<PromptResult> results;

    for (auto& p : prompts) {
        int idx         = p["idx"].get<int>();
        std::string cat = p["cat"].get<std::string>();
        std::string text = p["text"].get<std::string>();

        // Load oracle mel
        char mel_path[512];
        std::snprintf(mel_path, sizeof(mel_path), "%s/%02d.npy", ORACLE_MEL_DIR, idx);
        NpyArray oracle_mel;
        try {
            oracle_mel = load_npy_float32(mel_path);
        } catch (const std::exception& e) {
            FAIL("Cannot load oracle mel " << mel_path << ": " << e.what());
        }

        // Oracle mel shape: [128, T_oracle]
        REQUIRE(oracle_mel.shape.size() == 2);
        REQUIRE(oracle_mel.shape[0] == 128);
        int T_oracle = static_cast<int>(oracle_mel.shape[1]);

        // Synthesize
        auto audio = pipeline.synthesize(text, 42);

        // Compute log-mel of synthesized audio
        jarvis::tts::onnx::MelConfig mel_cfg;
        auto synth_mel = jarvis::tts::onnx::compute_log_mel(
            audio.data(), audio.size(), mel_cfg);
        int T_synth = static_cast<int>(audio.size()) / mel_cfg.hop + 1;

        // L2 distance in dB
        float l2 = jarvis::tts::onnx::mel_l2_db(
            synth_mel, T_synth,
            oracle_mel.data, T_oracle);

        bool pass = (l2 <= 1.0f);
        if (!pass) ++fail_count;
        if (l2 > worst_l2) worst_l2 = l2;

        results.push_back({idx, cat, text, l2, pass});

        INFO("Prompt " << idx << " [" << cat << "] L2=" << l2 << " dB " << (pass ? "PASS" : "FAIL"));
    }

    // Print summary table (top 5 worst)
    std::sort(results.begin(), results.end(),
              [](const PromptResult& a, const PromptResult& b) { return a.l2 > b.l2; });

    std::cout << "\n=== Mel-L2 Results (worst 5) ===\n";
    std::cout << " idx  cat               L2(dB)  result\n";
    for (int i = 0; i < std::min(5, (int)results.size()); ++i) {
        auto& r = results[i];
        std::printf("  %02d  %-18s  %.4f  %s\n",
                    r.idx, r.cat.c_str(), r.l2, r.pass ? "PASS" : "FAIL");
    }
    std::cout << "Total failures: " << fail_count << " / 50\n";
    std::cout << "Worst L2: " << worst_l2 << " dB\n\n";

    REQUIRE(fail_count == 0);
}
