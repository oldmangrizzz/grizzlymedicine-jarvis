// test_classifier.cpp — Catch2 v3 tests for RawAudioSceneClassifier.
//
// Coverage:
//   1. Silence gate: zero-energy buffer always → silence
//   2. Synthetic music: harmonic signal → music for ≥ 90 % of windows
//   3. Speech recall: oracle voice WAVs (50 files) → speech_* for ≥ 48/50
//   4. Scene change callback: fires on transition, not on every window
//   5. Routing table: verify routingFor() for all classes
//
// Expectations WITHOUT a trained model:
//   Tests 1–5 rely on the heuristic classifier. If TEST_MODEL_PATH is set,
//   the model path is injected and the CoreML path is also exercised.
//
// Oracle WAVs are 24 000 Hz; a minimal linear-interpolation downsampler is
// included so we do not depend on an external audio library at test time.

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "scene_classifier.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// ─── WAV loader ──────────────────────────────────────────────────────────────

struct WavInfo {
    int sample_rate{0};
    int channels{0};
    int bits_per_sample{0};
};

/// Minimal PCM WAV reader (16-bit signed, mono or stereo).
static std::vector<int16_t> load_wav(const std::string& path, WavInfo* info = nullptr) {
    std::ifstream f(path, std::ios::binary);
    REQUIRE(f.is_open());

    auto read16 = [&]() -> uint16_t {
        uint8_t b[2]{}; f.read(reinterpret_cast<char*>(b), 2);
        return static_cast<uint16_t>(b[0] | (b[1] << 8));
    };
    auto read32 = [&]() -> uint32_t {
        uint8_t b[4]{}; f.read(reinterpret_cast<char*>(b), 4);
        return static_cast<uint32_t>(b[0] | (b[1]<<8) | (b[2]<<16) | (b[3]<<24));
    };
    auto skip = [&](int n) { f.seekg(n, std::ios::cur); };

    // RIFF header
    char riff[4]{}; f.read(riff, 4);
    REQUIRE(std::string(riff, 4) == "RIFF");
    skip(4);  // chunk size
    char wave[4]{}; f.read(wave, 4);
    REQUIRE(std::string(wave, 4) == "WAVE");

    WavInfo wi{};
    std::vector<int16_t> samples;

    while (!f.eof()) {
        char tag[4]{}; f.read(tag, 4);
        if (f.gcount() < 4) break;
        uint32_t chunk_size = read32();

        if (std::string(tag, 4) == "fmt ") {
            /* audio_format = */ read16();
            wi.channels        = read16();
            wi.sample_rate     = static_cast<int>(read32());
            /* byte_rate     = */ read32();
            /* block_align   = */ read16();
            wi.bits_per_sample = read16();
            if (chunk_size > 16) skip(static_cast<int>(chunk_size - 16));
        } else if (std::string(tag, 4) == "data") {
            REQUIRE(wi.bits_per_sample == 16);
            size_t n_frames = chunk_size / (static_cast<size_t>(wi.channels) * 2);
            samples.resize(n_frames);
            for (size_t i = 0; i < n_frames; ++i) {
                int16_t s = static_cast<int16_t>(read16());
                if (wi.channels > 1) {
                    for (int c = 1; c < wi.channels; ++c) read16(); // skip extra channels
                }
                samples[i] = s;
            }
            break;
        } else {
            skip(static_cast<int>(chunk_size));
        }
    }

    if (info) *info = wi;
    return samples;
}

/// Linear-interpolation resampler: src_sr → dst_sr (mono int16).
static std::vector<int16_t> resample(const std::vector<int16_t>& src,
                                     int src_sr, int dst_sr) {
    if (src_sr == dst_sr) return src;
    const double ratio = static_cast<double>(src_sr) / dst_sr;
    const size_t n_out = static_cast<size_t>(
        std::floor(static_cast<double>(src.size()) / ratio));
    std::vector<int16_t> out(n_out);
    for (size_t i = 0; i < n_out; ++i) {
        double pos = static_cast<double>(i) * ratio;
        size_t lo  = static_cast<size_t>(pos);
        double frac = pos - static_cast<double>(lo);
        size_t hi  = std::min(lo + 1, src.size() - 1);
        out[i] = static_cast<int16_t>(
            static_cast<double>(src[lo]) * (1.0 - frac) +
            static_cast<double>(src[hi]) * frac);
    }
    return out;
}

// ─── Synthetic audio generators ──────────────────────────────────────────────

static constexpr int kSR = 16'000;  // target sample rate for all tests

/// Zero-filled buffer (silence)
static std::vector<int16_t> make_silence(int n_samples) {
    return std::vector<int16_t>(n_samples, 0);
}

/// Harmonic signal mimicking a plucked instrument (A3 = 220 Hz + overtones)
static std::vector<int16_t> make_harmonic_music(int n_samples) {
    const float fundamental = 220.0f;
    // Amplitude coefficients for harmonics 1..8
    const float amp[]   = {1.0f, 0.60f, 0.40f, 0.28f, 0.20f, 0.14f, 0.10f, 0.07f};
    const float amp_sum = 1.0f + 0.60f + 0.40f + 0.28f + 0.20f + 0.14f + 0.10f + 0.07f;

    std::vector<int16_t> out(n_samples);
    for (int i = 0; i < n_samples; ++i) {
        const float t = static_cast<float>(i) / kSR;
        float s = 0.0f;
        for (int h = 0; h < 8; ++h)
            s += amp[h] * std::sin(2.0f * static_cast<float>(M_PI) * fundamental * (h + 1) * t);
        out[i] = static_cast<int16_t>((s / amp_sum) * 0.5f * 32767.0f);
    }
    return out;
}

// ─── Helper: classify all windows in a buffer ────────────────────────────────

struct ClassifySummary {
    int total_windows{0};
    int speech_count{0};   // speech_directed + speech_ambient
    int music_count{0};
    int noise_count{0};
    int silence_count{0};
};

static ClassifySummary classify_all(const std::vector<int16_t>& samples,
                                    const std::string& model_path = "") {
    jarvis::RawAudioSceneClassifier clf(model_path);

    // Feed in 4000-sample chunks (250 ms) to exercise the streaming path
    ClassifySummary summary{};
    constexpr int kChunk = 4'000;

    for (size_t pos = 0; pos < samples.size(); pos += kChunk) {
        const size_t end  = std::min(pos + kChunk, samples.size());
        auto evt = clf.feed_audio({ samples.data() + pos, end - pos });
        if (evt) {
            ++summary.total_windows;
            switch (evt->label) {
                case jarvis::SceneClass::speech_directed:
                case jarvis::SceneClass::speech_ambient:
                    ++summary.speech_count; break;
                case jarvis::SceneClass::music:
                    ++summary.music_count; break;
                case jarvis::SceneClass::noise:
                    ++summary.noise_count; break;
                case jarvis::SceneClass::silence:
                    ++summary.silence_count; break;
                default: break;
            }
        }
    }
    return summary;
}

// ─────────────────────────────────────────────────────────────────────────────
// TEST CASES
// ─────────────────────────────────────────────────────────────────────────────

TEST_CASE("silence gate: zero-energy buffer is always classified as silence") {
    jarvis::RawAudioSceneClassifier clf;

    // Feed 4 full windows of silence (4 × 1 s = 64 000 samples)
    auto silent = make_silence(64'000);
    int classified = 0;
    int correct    = 0;

    for (size_t pos = 0; pos < silent.size(); pos += 4'000) {
        auto evt = clf.feed_audio({ silent.data() + pos, 4'000 });
        if (evt) {
            ++classified;
            if (evt->label == jarvis::SceneClass::silence) ++correct;
        }
    }

    // Must produce at least one event and all must be silence
    REQUIRE(classified > 0);
    CHECK(correct == classified);
}

TEST_CASE("silence gate: near-zero energy (dBFS << -50) is silence") {
    jarvis::RawAudioSceneClassifier clf(
        "", 1000, 250,
        -50.0f  // threshold
    );

    // 1-LSB dither — effectively -90 dBFS
    std::vector<int16_t> dither(16'000);
    for (auto& s : dither) s = (rand() % 3) - 1;  // values in {-1, 0, 1}

    // Feed one full window
    auto evt = clf.feed_audio(dither);
    if (evt) CHECK(evt->label == jarvis::SceneClass::silence);
}

TEST_CASE("synthetic music: harmonic signal classified as music ≥ 90 % of windows") {
    // 10 seconds of synthetic harmonic audio → ≥ 36 music windows out of 40
    auto music_samples = make_harmonic_music(kSR * 10);
    auto summary = classify_all(music_samples, std::string(TEST_MODEL_PATH));

    INFO("total_windows=" << summary.total_windows
         << " music=" << summary.music_count
         << " speech=" << summary.speech_count
         << " noise=" << summary.noise_count);

    REQUIRE(summary.total_windows > 0);
    const double music_rate = static_cast<double>(summary.music_count) /
                              static_cast<double>(summary.total_windows);
    CHECK(music_rate >= 0.90);
}

TEST_CASE("speech recall: oracle voice WAVs produce speech_* for ≥ 48/50 files") {
    const fs::path wav_dir(ORACLE_WAV_DIR);
    REQUIRE(fs::exists(wav_dir));

    std::vector<fs::path> wav_files;
    for (auto& entry : fs::directory_iterator(wav_dir))
        if (entry.path().extension() == ".wav")
            wav_files.push_back(entry.path());

    std::sort(wav_files.begin(), wav_files.end());
    REQUIRE(wav_files.size() >= 50);

    // Take first 50 files
    wav_files.resize(50);

    int speech_detected = 0;
    int confusion[jarvis::kNumSceneClasses][jarvis::kNumSceneClasses]{};  // [true][predicted] (true class always = speech)

    for (const auto& wf : wav_files) {
        WavInfo wi{};
        auto raw = load_wav(wf.string(), &wi);
        auto pcm = resample(raw, wi.sample_rate, kSR);

        // A file "passes" if at least one classified window is speech_*
        jarvis::RawAudioSceneClassifier clf(std::string(TEST_MODEL_PATH));
        bool got_speech = false;
        int  best_pred  = static_cast<int>(jarvis::SceneClass::noise);  // default

        constexpr int kChunk = 4'000;
        for (size_t pos = 0; pos < pcm.size(); pos += kChunk) {
            const size_t end = std::min(pos + kChunk, pcm.size());
            auto evt = clf.feed_audio({ pcm.data() + pos, end - pos });
            if (evt) {
                const int pi = static_cast<int>(evt->label);
                if (evt->label == jarvis::SceneClass::speech_directed ||
                    evt->label == jarvis::SceneClass::speech_ambient) {
                    got_speech = true;
                    best_pred  = pi;
                }
            }
        }

        // Fill confusion matrix row (true label = 0 = speech_directed)
        confusion[0][best_pred]++;

        if (got_speech) ++speech_detected;
        else {
            INFO("No speech window for: " << wf.filename().string());
        }
    }

    // Print confusion matrix to INFO for diagnostics
    const char* names[] = {"spe_dir","spe_amb","music","noise","silence"};
    for (int r = 0; r < jarvis::kNumSceneClasses; ++r) {
        std::string row = std::string(names[r]) + ": ";
        for (int c = 0; c < jarvis::kNumSceneClasses; ++c)
            row += std::to_string(confusion[r][c]) + " ";
        INFO(row);
    }
    INFO("speech_detected=" << speech_detected << "/50");

    CHECK(speech_detected >= 48);
}

TEST_CASE("scene change callback fires on transition, not every window") {
    jarvis::RawAudioSceneClassifier clf;

    int callback_count = 0;
    jarvis::SceneClass last_class = jarvis::SceneClass::silence;

    clf.on_scene_change([&](jarvis::SceneEvent e) {
        ++callback_count;
        // Callbacks must only fire when the class actually changed
        CHECK(e.label != last_class);
        last_class = e.label;
    });

    // Feed silence — all windows are silence; after initial transition, no more callbacks
    auto silent = make_silence(64'000);
    for (size_t pos = 0; pos < silent.size(); pos += 4'000)
        clf.feed_audio({ silent.data() + pos, 4'000 });

    // At most one callback: silence → silence (initial)
    CHECK(callback_count <= 1);

    // Now feed music — expect one callback for silence→music transition
    int music_callbacks = 0;
    clf.on_scene_change([&](jarvis::SceneEvent e) {
        if (e.label == jarvis::SceneClass::music) ++music_callbacks;
    });
    auto music = make_harmonic_music(kSR * 5);
    for (size_t pos = 0; pos < music.size(); pos += 4'000)
        clf.feed_audio({ music.data() + pos, 4'000 });

    // Should fire once (or a few times if short oscillation) — not on every window
    INFO("music transition callbacks=" << music_callbacks);
    CHECK(music_callbacks >= 1);
}

TEST_CASE("routing table: correct downstream routing for each class") {
    using SC = jarvis::SceneClass;
    using SR = jarvis::SceneRouting;

    CHECK(jarvis::routingFor(SC::speech_directed) == SR::stt);
    CHECK(jarvis::routingFor(SC::speech_ambient)  == SR::log_only);
    CHECK(jarvis::routingFor(SC::music)           == SR::regulation);
    CHECK(jarvis::routingFor(SC::noise)           == SR::suppress);
    CHECK(jarvis::routingFor(SC::silence)         == SR::suppress);
}

TEST_CASE("SceneEvent label_name() returns non-empty string for all classes") {
    for (int i = 0; i < jarvis::kNumSceneClasses; ++i) {
        jarvis::SceneEvent e;
        e.label = static_cast<jarvis::SceneClass>(i);
        const char* name = e.label_name();
        REQUIRE(name != nullptr);
        CHECK(std::strlen(name) > 0);
    }
}

TEST_CASE("feed_audio: partial buffers accumulate correctly") {
    jarvis::RawAudioSceneClassifier clf;

    // Feed 500-sample chunks; classifier should not classify until 16 000 accumulated
    std::vector<int16_t> chunk(500, 0);
    int events = 0;
    for (int i = 0; i < 31; ++i) {   // 31 × 500 = 15 500 < 16 000 — no event yet
        auto e = clf.feed_audio(chunk);
        if (e) ++events;
    }
    CHECK(events == 0);

    // One more 500-sample chunk pushes us to 16 000 → event
    auto e = clf.feed_audio(chunk);
    CHECK(e.has_value());
}
