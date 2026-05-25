#pragma once
// feature_extractor.h — Log-Mel spectrogram extractor using Accelerate.framework vDSP.
//
// Zero allocation in hot path — all buffers pre-allocated at construction.
// C++20, Apple Silicon, Accelerate.framework.

#include <cstdint>
#include <span>
#include <vector>

#include <Accelerate/Accelerate.h>

namespace jarvis {

// ── FeatureExtractor configuration ──────────────────────────────────────────
// Defined at namespace scope to avoid a clang limitation with nested-struct
// default member initializers used as default function arguments.
struct FeatureExtractorConfig {
    int   sample_rate = 16000;   ///< Hz
    int   window_ms   = 25;      ///< Frame window  (25 ms = 400 samps @ 16 kHz)
    int   hop_ms      = 10;      ///< Frame hop     (10 ms = 160 samps @ 16 kHz)
    int   fft_size    = 512;     ///< FFT size (power-of-2, must be ≥ window_samples)
    int   n_mels      = 64;      ///< Mel filterbank bins
    float fmin        = 80.0f;   ///< Lower mel bound (Hz)
    float fmax        = 8000.0f; ///< Upper mel bound (Hz, ≤ Nyquist)
    float log_floor   = 1e-6f;   ///< Clamp before log to avoid -inf
};

/// Computes log-mel spectrograms from mono PCM int16 audio using vDSP.
///
/// Default configuration (1-second window at 16 kHz):
///   Input:  16 000 int16 samples
///   Output: 98 frames × 64 mel bins — row-major float32
///   Budget: < 2 ms on Apple Silicon (M-series)
class FeatureExtractor {
public:
    using Config = FeatureExtractorConfig;

    explicit FeatureExtractor(Config cfg = {});
    ~FeatureExtractor();

    FeatureExtractor(const FeatureExtractor&)            = delete;
    FeatureExtractor& operator=(const FeatureExtractor&) = delete;
    FeatureExtractor(FeatureExtractor&&) noexcept;
    FeatureExtractor& operator=(FeatureExtractor&&) noexcept;

    /// Extract log-mel features into a pre-allocated output buffer.
    ///
    /// @param samples    Mono int16 PCM at sample_rate Hz.
    /// @param out_logmel Caller-allocated buffer: n_frames(n_samples) * n_mels() floats.
    ///                   Row-major: row = time frame, column = mel bin.
    /// @returns          Number of frames written.
    int extract(std::span<const int16_t> samples, float* out_logmel) const;

    /// Number of time frames produced for a given sample count.
    int n_frames(int n_samples) const noexcept;

    int n_mels()      const noexcept { return cfg_.n_mels; }
    int fft_size()    const noexcept { return cfg_.fft_size; }
    int window_size() const noexcept { return (cfg_.window_ms * cfg_.sample_rate) / 1000; }
    int hop_size()    const noexcept { return (cfg_.hop_ms   * cfg_.sample_rate) / 1000; }

    const Config& config() const noexcept { return cfg_; }

private:
    Config  cfg_;
    FFTSetup fft_setup_{nullptr};
    int      log2n_{0};

    // Pre-allocated working buffers — mutable so extract() can be const.
    mutable std::vector<float> hann_;       ///< [window_size]   Hann window
    mutable std::vector<float> frame_buf_;  ///< [fft_size]      zero-padded windowed frame
    mutable std::vector<float> re_;         ///< [fft_size/2]    split-complex real
    mutable std::vector<float> im_;         ///< [fft_size/2]    split-complex imag
    mutable std::vector<float> power_;      ///< [fft_size/2+1]  power spectrum
    mutable std::vector<float> mel_out_;    ///< [n_mels]        one frame output

    std::vector<float> mel_fb_;             ///< [n_mels × (fft_size/2+1)] — read-only after init

    void buildMelFilterbank();
    void releaseFFT() noexcept;

    static float hzToMel(float hz) noexcept;
    static float melToHz(float mel) noexcept;
};

} // namespace jarvis
