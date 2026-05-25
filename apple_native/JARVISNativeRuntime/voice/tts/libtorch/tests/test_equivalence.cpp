/**
 * test_equivalence.cpp
 *
 * Mel-spectrogram L2 equivalence test: for each of the 50 oracle prompts,
 * synthesise audio with the LibTorch pipeline and compare the log-mel
 * spectrogram against the oracle .npy file.
 *
 * Acceptance criterion: mel_L2 ≤ 1.0 dB on all 50 prompts.
 *
 * Run via CTest after building:
 *   cmake --build build && ctest --test-dir build -R equivalence --output-on-failure
 *
 * Environment variables (set these before running):
 *   JARVIS_LIBTORCH_MODELS_DIR  — dir containing text_encoder.pt, gpt_decoder.pt, hifigan.pt
 *   JARVIS_TOKENIZER_MODEL      — path to tokenizer.model
 *   JARVIS_VOICE_STATE          — path to jarvis_voice_state.safetensors
 *   JARVIS_ORACLE_MEL_DIR       — dir containing 00.npy … 49.npy
 *   JARVIS_ORACLE_PROMPTS_JSON  — path to prompts.json
 */

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "../xtts_pipeline.h"
#include "../mel_pipeline.h"

// ─── Minimal .npy loader ────────────────────────────────────────────────────

namespace {

/**
 * Load a float32 .npy file (1-D or 2-D, C-order, no pickle).
 * Returns flat data in row-major order and fills shape.
 */
std::vector<float> load_npy_f32(const std::string& path,
                                 std::vector<int>& shape) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("Cannot open .npy: " + path);

    // Magic + version
    char magic[7];
    f.read(magic, 6); magic[6] = '\0';
    if (std::string(magic) != "\x93NUMPY")
        throw std::runtime_error("Not a .npy file: " + path);
    uint8_t maj, min;
    f.read(reinterpret_cast<char*>(&maj), 1);
    f.read(reinterpret_cast<char*>(&min), 1);

    uint16_t header_len;
    f.read(reinterpret_cast<char*>(&header_len), 2);
    std::string header(header_len, '\0');
    f.read(header.data(), header_len);

    // Parse dtype
    const bool is_f32 = header.find("'<f4'") != std::string::npos ||
                        header.find("'f4'")  != std::string::npos ||
                        header.find("float32") != std::string::npos;
    if (!is_f32) throw std::runtime_error("Expected float32 .npy: " + path);

    // Parse shape: "(A, B)" or "(A,)"
    const auto s0 = header.find('(');
    const auto s1 = header.find(')');
    if (s0 == std::string::npos || s1 == std::string::npos)
        throw std::runtime_error("Cannot parse shape in .npy header");
    std::string shape_str = header.substr(s0 + 1, s1 - s0 - 1);
    shape.clear();
    std::istringstream ss(shape_str);
    std::string tok;
    while (std::getline(ss, tok, ',')) {
        // strip whitespace
        tok.erase(std::remove_if(tok.begin(), tok.end(), ::isspace), tok.end());
        if (!tok.empty()) shape.push_back(std::stoi(tok));
    }

    int total = 1;
    for (int d : shape) total *= d;

    std::vector<float> data(total);
    f.read(reinterpret_cast<char*>(data.data()), total * 4);
    if (!f) throw std::runtime_error("Short read in .npy: " + path);
    return data;
}

/** Parse a minimal JSON array of objects to extract idx + text fields. */
struct Prompt { int idx; std::string text; };
std::vector<Prompt> parse_prompts_json(const std::string& path) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error("Cannot open prompts.json: " + path);
    std::string content((std::istreambuf_iterator<char>(f)), {});

    // We do a very small hand-written parser sufficient for this fixed JSON.
    std::vector<Prompt> prompts;
    size_t pos = 0;
    while ((pos = content.find("\"idx\"", pos)) != std::string::npos) {
        // Find idx value
        pos = content.find(':', pos) + 1;
        while (pos < content.size() && std::isspace(content[pos])) ++pos;
        int idx = std::stoi(content.substr(pos));

        // Find text value
        auto tpos = content.find("\"text\"", pos);
        if (tpos == std::string::npos) break;
        tpos = content.find('"', content.find(':', tpos) + 1) + 1;
        auto tend = content.find('"', tpos);
        // Handle escaped quotes: walk forward
        while (tend != std::string::npos && content[tend - 1] == '\\') {
            tend = content.find('"', tend + 1);
        }
        std::string text = content.substr(tpos, tend - tpos);

        prompts.push_back({idx, text});
        pos = tend + 1;
    }
    return prompts;
}

std::string env_or(const char* name, const char* dflt) {
    const char* v = std::getenv(name);
    return v ? std::string(v) : std::string(dflt);
}

} // anonymous namespace

// ─── Test ───────────────────────────────────────────────────────────────────

TEST_CASE("mel_L2_equivalence_all_50_prompts", "[equivalence][libtorch]") {

    const std::string models_dir = env_or("JARVIS_LIBTORCH_MODELS_DIR",
        "../../../../../../oracle/voice");  // fallback for in-tree run
    const std::string tok_model  = env_or("JARVIS_TOKENIZER_MODEL", "models/tokenizer.model");
    const std::string vs_path    = env_or("JARVIS_VOICE_STATE",
        "../../../../../../jarvis/_local_voice/jarvis_voice_state.safetensors");
    const std::string mel_dir    = env_or("JARVIS_ORACLE_MEL_DIR",
        "../../../../../../oracle/voice/mel");
    const std::string prompts_p  = env_or("JARVIS_ORACLE_PROMPTS_JSON",
        "../../../../../../oracle/voice/prompts.json");

    // ── Build pipeline ─────────────────────────────────────────────────────
    jarvis::tts::PipelineConfig cfg;
    cfg.text_encoder_pt  = models_dir + "/text_encoder.pt";
    cfg.gpt_decoder_pt   = models_dir + "/gpt_decoder.pt";
    cfg.hifigan_pt       = models_dir + "/hifigan.pt";
    cfg.tokenizer_model  = tok_model;
    cfg.voice_state_path = vs_path;
    cfg.device           = "cpu";  // use CPU for reproducibility in CI

    jarvis::tts::XTTSPipeline pipeline;
    REQUIRE_NOTHROW(pipeline.load(cfg));
    REQUIRE(pipeline.is_loaded());
    pipeline.warmup();

    // ── Load prompts ───────────────────────────────────────────────────────
    auto prompts = parse_prompts_json(prompts_p);
    REQUIRE(prompts.size() == 50);

    // ── Per-prompt L2 ─────────────────────────────────────────────────────
    const float THRESHOLD_DB = 1.0f;
    jarvis::tts::MelParams mel_params;  // defaults match oracle

    struct Result { int idx; float l2; bool pass; };
    std::vector<Result> results;
    int failures = 0;

    for (auto& prompt : prompts) {
        // Synthesise
        auto audio = pipeline.synthesize(prompt.text, /*seed=*/42);
        REQUIRE(!audio.samples.empty());

        // Compute C++ mel
        const int n_frames = jarvis::tts::mel_frame_count(
            static_cast<int>(audio.samples.size()), mel_params);
        std::vector<float> cpp_mel(mel_params.n_mels * n_frames);
        jarvis::tts::compute_log_mel(audio.samples.data(),
                                     static_cast<int>(audio.samples.size()),
                                     mel_params, cpp_mel.data());

        // Load oracle mel
        std::ostringstream npy_path;
        npy_path << mel_dir << "/" << std::setfill('0') << std::setw(2)
                 << prompt.idx << ".npy";
        std::vector<int> oracle_shape;
        auto oracle_mel = load_npy_f32(npy_path.str(), oracle_shape);
        REQUIRE(oracle_shape.size() == 2);
        const int oracle_mels   = oracle_shape[0];  // 128
        const int oracle_frames = oracle_shape[1];

        REQUIRE(oracle_mels == mel_params.n_mels);

        // Compute L2
        const float l2 = jarvis::tts::mel_l2_db(
            cpp_mel.data(),    n_frames,
            oracle_mel.data(), oracle_frames,
            mel_params.n_mels);

        const bool pass = l2 <= THRESHOLD_DB;
        results.push_back({prompt.idx, l2, pass});
        if (!pass) ++failures;
    }

    // ── Report ────────────────────────────────────────────────────────────
    // Sort by L2 descending for the "top 5 worst" report
    std::sort(results.begin(), results.end(),
              [](const Result& a, const Result& b){ return a.l2 > b.l2; });

    std::cout << "\n=== mel-L2 equivalence results (worst 5) ===\n";
    for (int i = 0; i < std::min(5, static_cast<int>(results.size())); ++i) {
        const auto& r = results[i];
        std::cout << "  idx=" << std::setw(2) << r.idx
                  << "  L2=" << std::fixed << std::setprecision(4) << r.l2
                  << " dB  " << (r.pass ? "PASS" : "FAIL") << "\n";
    }
    std::cout << "Total failures: " << failures << " / 50\n";

    // All 50 must pass
    CHECK(failures == 0);
}
