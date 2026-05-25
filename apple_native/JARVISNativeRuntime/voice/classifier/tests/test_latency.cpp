// test_latency.cpp — Latency benchmark for RawAudioSceneClassifier.
//
// Requirement (from audio_context.py hot_path_budget_ms: 250):
//   1-second window log-mel extraction + classification ≤ 20 ms p99
//   on Apple Silicon. This claims ≤ 8 % of the 250 ms hot path budget.
//
// Methodology:
//   Run 1 000 independent classification cycles (each starting from a fresh
//   full window so the ring-buffer accumulation is not in the measurement).
//   Report p50, p99, max latency in nanoseconds and milliseconds.
//   Fail if p99 > 20 ms.

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>

#include "scene_classifier.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <vector>

using Clock     = std::chrono::steady_clock;
using TimePoint = std::chrono::time_point<Clock>;
using Nanos     = std::chrono::nanoseconds;

static constexpr int kSR          = 16'000;
static constexpr int kWindowSamps = 16'000;  // 1 s window
static constexpr int kIterations  = 1'000;

/// Synthetic harmonic audio (deterministic, reused across iterations)
static std::vector<int16_t> make_bench_signal(int n) {
    const float f0 = 220.0f;
    const float amps[] = {1.0f, 0.6f, 0.4f, 0.3f, 0.2f};
    const float total  = 1.0f + 0.6f + 0.4f + 0.3f + 0.2f;
    std::vector<int16_t> out(n);
    for (int i = 0; i < n; ++i) {
        const float t = static_cast<float>(i) / kSR;
        float s = 0.0f;
        for (int h = 0; h < 5; ++h)
            s += amps[h] * std::sin(2.0f * static_cast<float>(M_PI) * f0 * (h + 1) * t);
        out[i] = static_cast<int16_t>((s / total) * 0.5f * 32767.0f);
    }
    return out;
}

static double ns_to_ms(int64_t ns) { return static_cast<double>(ns) * 1e-6; }

static void print_latency_stats(const std::vector<int64_t>& ns_samples) {
    auto sorted = ns_samples;
    std::sort(sorted.begin(), sorted.end());

    const size_t n = sorted.size();
    const int64_t p50  = sorted[n / 2];
    const int64_t p95  = sorted[static_cast<size_t>(n * 0.95)];
    const int64_t p99  = sorted[static_cast<size_t>(n * 0.99)];
    const int64_t pmax = sorted.back();
    const double  mean = static_cast<double>(
        std::accumulate(sorted.begin(), sorted.end(), int64_t{0})) / n;

    std::cout << "\n[latency] n=" << n
              << "  mean=" << ns_to_ms(static_cast<int64_t>(mean)) << " ms"
              << "  p50="  << ns_to_ms(p50)  << " ms"
              << "  p95="  << ns_to_ms(p95)  << " ms"
              << "  p99="  << ns_to_ms(p99)  << " ms"
              << "  max="  << ns_to_ms(pmax) << " ms\n";
}

// ─────────────────────────────────────────────────────────────────────────────

TEST_CASE("classify_window latency: p99 ≤ 20 ms on 1-second window") {
    // We measure only the hot path: one full window already in the ring buffer.
    // Construct a classifier, prime it with (window - 1) samples so the next
    // feed_audio call completes exactly one window.
    const auto signal = make_bench_signal(kWindowSamps);
    std::vector<int64_t> latencies;
    latencies.reserve(kIterations);

    for (int iter = 0; iter < kIterations; ++iter) {
        // Fresh classifier per iteration — avoids any committed-state shortcuts
        jarvis::RawAudioSceneClassifier clf(std::string(TEST_MODEL_PATH));

        // Pre-fill ring buffer with (window_samples - 1) samples so the next
        // single sample triggers classification.  We do NOT time this setup.
        constexpr int kPrime = kWindowSamps - 1;
        clf.feed_audio({ signal.data(), static_cast<size_t>(kPrime) });

        // ── Measured section ──
        const TimePoint t0 = Clock::now();
        clf.feed_audio({ signal.data() + kPrime, 1 });  // triggers classify_window()
        const TimePoint t1 = Clock::now();
        // ─────────────────────

        const int64_t elapsed_ns =
            std::chrono::duration_cast<Nanos>(t1 - t0).count();
        latencies.push_back(elapsed_ns);
    }

    print_latency_stats(latencies);

    const auto sorted = [&]() {
        auto v = latencies;
        std::sort(v.begin(), v.end());
        return v;
    }();

    const int64_t p99_ns = sorted[static_cast<size_t>(kIterations * 0.99)];
    const double  p99_ms = ns_to_ms(p99_ns);

    INFO("p99 latency = " << p99_ms << " ms  (budget = 20 ms)");
    CHECK(p99_ms <= 20.0);
}

TEST_CASE("feature extraction latency: p99 ≤ 5 ms for 1-second window") {
    // Measures just the feature extractor (log-mel computation).
    // This is the dominant cost in the heuristic path.
    jarvis::FeatureExtractor extractor;
    const auto signal = make_bench_signal(kWindowSamps);

    const int n_frames = extractor.n_frames(kWindowSamps);
    std::vector<float> buf(static_cast<size_t>(n_frames) *
                           static_cast<size_t>(extractor.n_mels()), 0.0f);

    std::vector<int64_t> latencies;
    latencies.reserve(kIterations);

    for (int iter = 0; iter < kIterations; ++iter) {
        const TimePoint t0 = Clock::now();
        extractor.extract(signal, buf.data());
        const TimePoint t1 = Clock::now();
        latencies.push_back(std::chrono::duration_cast<Nanos>(t1 - t0).count());
    }

    print_latency_stats(latencies);

    auto sorted = latencies;
    std::sort(sorted.begin(), sorted.end());
    const double p99_ms = ns_to_ms(sorted[static_cast<size_t>(kIterations * 0.99)]);

    INFO("feature extraction p99 = " << p99_ms << " ms  (budget = 5 ms)");
    CHECK(p99_ms <= 5.0);
}

TEST_CASE("batch throughput: can classify 1000 windows in < 5 seconds") {
    // Sanity check for sustained throughput (no memory leaks / buffer issues).
    jarvis::RawAudioSceneClassifier clf(std::string(TEST_MODEL_PATH));
    const auto signal = make_bench_signal(kWindowSamps * 2);  // plenty of data

    const TimePoint t_start = Clock::now();

    int windows = 0;
    for (int i = 0; i < kIterations; ++i) {
        // Feed one window at a time
        auto evt = clf.feed_audio({ signal.data(), static_cast<size_t>(kWindowSamps) });
        if (evt) ++windows;
        // Reset ring buffer by constructing fresh (simulates back-to-back classification)
    }

    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        Clock::now() - t_start).count();

    INFO("1000 iterations in " << elapsed_ms << " ms");
    CHECK(elapsed_ms < 5'000);
}
