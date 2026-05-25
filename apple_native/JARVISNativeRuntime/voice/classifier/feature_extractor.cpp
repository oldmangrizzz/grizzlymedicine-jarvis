// feature_extractor.cpp — vDSP log-mel implementation.
// Zero allocation in hot path. See header for API.

#include "feature_extractor.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace jarvis {

// ─── Construction / destruction ───────────────────────────────────────────────

FeatureExtractor::FeatureExtractor(Config cfg) : cfg_(cfg) {
    if (cfg_.fft_size <= 0 || (cfg_.fft_size & (cfg_.fft_size - 1)) != 0)
        throw std::invalid_argument("fft_size must be a positive power of 2");
    if (cfg_.n_mels <= 0)
        throw std::invalid_argument("n_mels must be positive");
    if (cfg_.fft_size < window_size())
        throw std::invalid_argument("fft_size must be >= window_size");

    log2n_ = static_cast<int>(std::round(std::log2(static_cast<double>(cfg_.fft_size))));
    fft_setup_ = vDSP_create_fftsetup(static_cast<vDSP_Length>(log2n_), FFT_RADIX2);
    if (!fft_setup_)
        throw std::runtime_error("vDSP_create_fftsetup failed");

    const int win = window_size();
    hann_.resize(win);
    vDSP_hann_window(hann_.data(), static_cast<vDSP_Length>(win), vDSP_HANN_NORM);

    frame_buf_.assign(cfg_.fft_size, 0.0f);
    re_.assign(cfg_.fft_size / 2, 0.0f);
    im_.assign(cfg_.fft_size / 2, 0.0f);
    power_.assign(cfg_.fft_size / 2 + 1, 0.0f);
    mel_out_.assign(cfg_.n_mels, 0.0f);

    buildMelFilterbank();
}

FeatureExtractor::~FeatureExtractor() { releaseFFT(); }

void FeatureExtractor::releaseFFT() noexcept {
    if (fft_setup_) {
        vDSP_destroy_fftsetup(fft_setup_);
        fft_setup_ = nullptr;
    }
}

FeatureExtractor::FeatureExtractor(FeatureExtractor&& o) noexcept
    : cfg_(o.cfg_), fft_setup_(o.fft_setup_), log2n_(o.log2n_),
      hann_(std::move(o.hann_)), frame_buf_(std::move(o.frame_buf_)),
      re_(std::move(o.re_)), im_(std::move(o.im_)),
      power_(std::move(o.power_)), mel_out_(std::move(o.mel_out_)),
      mel_fb_(std::move(o.mel_fb_)) {
    o.fft_setup_ = nullptr;
}

FeatureExtractor& FeatureExtractor::operator=(FeatureExtractor&& o) noexcept {
    if (this != &o) {
        releaseFFT();
        cfg_       = o.cfg_;
        fft_setup_ = o.fft_setup_;
        log2n_     = o.log2n_;
        hann_      = std::move(o.hann_);
        frame_buf_ = std::move(o.frame_buf_);
        re_        = std::move(o.re_);
        im_        = std::move(o.im_);
        power_     = std::move(o.power_);
        mel_out_   = std::move(o.mel_out_);
        mel_fb_    = std::move(o.mel_fb_);
        o.fft_setup_ = nullptr;
    }
    return *this;
}

// ─── Mel filterbank ────────────────────────────────────────────────────────────

float FeatureExtractor::hzToMel(float hz) noexcept {
    return 2595.0f * std::log10(1.0f + hz / 700.0f);
}

float FeatureExtractor::melToHz(float mel) noexcept {
    return 700.0f * (std::pow(10.0f, mel / 2595.0f) - 1.0f);
}

void FeatureExtractor::buildMelFilterbank() {
    const int n_freqs = cfg_.fft_size / 2 + 1;
    mel_fb_.assign(cfg_.n_mels * n_freqs, 0.0f);

    const float mel_lo = hzToMel(cfg_.fmin);
    const float mel_hi = hzToMel(cfg_.fmax);
    const int   n_pts  = cfg_.n_mels + 2;

    // n_mels+2 linearly-spaced mel-frequency points
    std::vector<float> mel_pts(n_pts);
    for (int i = 0; i < n_pts; ++i)
        mel_pts[i] = mel_lo + i * (mel_hi - mel_lo) / (n_pts - 1);

    // Convert to FFT bin indices
    const float bin_hz = static_cast<float>(cfg_.sample_rate) / cfg_.fft_size;
    std::vector<int> bins(n_pts);
    for (int i = 0; i < n_pts; ++i) {
        bins[i] = static_cast<int>(melToHz(mel_pts[i]) / bin_hz);
        bins[i] = std::clamp(bins[i], 0, n_freqs - 1);
    }

    // Triangular filters
    for (int m = 0; m < cfg_.n_mels; ++m) {
        const int lo = bins[m];
        const int pk = bins[m + 1];
        const int hi = bins[m + 2];
        float* row = mel_fb_.data() + m * n_freqs;
        if (pk > lo)
            for (int k = lo; k < pk; ++k)
                row[k] = static_cast<float>(k - lo) / (pk - lo);
        if (hi > pk)
            for (int k = pk; k < hi; ++k)
                row[k] = static_cast<float>(hi - k) / (hi - pk);
        if (pk == lo && pk == hi)
            row[pk] = 1.0f;  // degenerate filter — shouldn't happen in practice
    }
}

// ─── Extraction ───────────────────────────────────────────────────────────────

int FeatureExtractor::n_frames(int n_samples) const noexcept {
    const int win = window_size();
    const int hop = hop_size();
    if (n_samples < win) return 0;
    return (n_samples - win) / hop + 1;
}

int FeatureExtractor::extract(std::span<const int16_t> samples, float* out_logmel) const {
    const int win     = window_size();
    const int hop     = hop_size();
    const int nf      = n_frames(static_cast<int>(samples.size()));
    const int N       = cfg_.fft_size;
    const int n_freqs = N / 2 + 1;

    constexpr float kInt16Scale = 1.0f / 32768.0f;

    for (int f = 0; f < nf; ++f) {
        const int offset = f * hop;

        // 1. Zero-fill frame buffer, then apply Hann window to samples
        std::fill(frame_buf_.begin(), frame_buf_.end(), 0.0f);
        for (int i = 0; i < win; ++i)
            frame_buf_[i] = static_cast<float>(samples[offset + i]) * kInt16Scale * hann_[i];

        // 2. Pack real data into split-complex for vDSP real FFT.
        //    vDSP_fft_zrip treats the N-point real input as N/2 complex samples.
        DSPSplitComplex split{ re_.data(), im_.data() };
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(frame_buf_.data()),
                  2, &split, 1, static_cast<vDSP_Length>(N / 2));

        // 3. Forward real FFT (in-place)
        vDSP_fft_zrip(fft_setup_, &split, 1,
                      static_cast<vDSP_Length>(log2n_), FFT_FORWARD);

        // 4. Power spectrum.
        //    After vDSP_fft_zrip: re[0]=DC, im[0]=Nyquist; re/im[1..N/2-1] = bins 1..N/2-1.
        //    No normalization constant needed — log absorbs scale offsets.
        power_[0]     = re_[0] * re_[0];
        power_[N / 2] = im_[0] * im_[0];
        for (int k = 1; k < N / 2; ++k)
            power_[k] = re_[k] * re_[k] + im_[k] * im_[k];

        // 5. Mel filterbank: mel_out = mel_fb × power  (n_mels × n_freqs) × (n_freqs × 1)
        vDSP_mmul(mel_fb_.data(),  1,
                  power_.data(),   1,
                  mel_out_.data(), 1,
                  static_cast<vDSP_Length>(cfg_.n_mels), 1,
                  static_cast<vDSP_Length>(n_freqs));

        // 6. Log + floor clamp
        float* dst = out_logmel + f * cfg_.n_mels;
        for (int m = 0; m < cfg_.n_mels; ++m) {
            const float v = (mel_out_[m] < cfg_.log_floor) ? cfg_.log_floor : mel_out_[m];
            dst[m] = std::log(v);
        }
    }
    return nf;
}

} // namespace jarvis
