// mel_pipeline.cpp — Log-mel spectrogram using vDSP (Accelerate.framework)
//
// Matches oracle parameters exactly:
//   n_fft=2048, hop=256, n_mels=128, sr=24000
//   Slaney-normalized triangular mel filterbank, power=2

#include "mel_pipeline.h"

#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

static constexpr int kNFFT      = 2048;
static constexpr int kHop       = 256;
static constexpr int kNMels     = 128;
static constexpr int kSR        = 24000;
static constexpr float kFMin    = 0.0f;
static constexpr float kFMax    = 12000.0f;
static constexpr float kLogEps  = 1e-6f;  // avoid log(0)

// ---------------------------------------------------------------------------
// Mel filterbank (Slaney norm, HTK=false)
// ---------------------------------------------------------------------------
static float hz_to_mel(float hz) {
    // O'Shaughnessy (linear below 1000 Hz, log above)
    constexpr float f_min = 0.0f;
    constexpr float f_sp  = 200.0f / 3.0f;
    constexpr float min_log_hz = 1000.0f;
    constexpr float logstep    = 0.06875f;  // log(6.4) / 27.0
    if (hz < min_log_hz)
        return (hz - f_min) / f_sp;
    return 15.0f + (std::log(hz / min_log_hz) / logstep);
}

static float mel_to_hz(float mel) {
    constexpr float f_min = 0.0f;
    constexpr float f_sp  = 200.0f / 3.0f;
    constexpr float min_log_hz = 1000.0f;
    constexpr float logstep    = 0.06875f;
    if (mel < 15.0f)
        return f_min + f_sp * mel;
    return min_log_hz * std::exp(logstep * (mel - 15.0f));
}

/// Build the Slaney-normalized mel filterbank matrix.
/// Result: n_mels × (n_fft/2+1) flat row-major float32
static std::vector<float> build_mel_filterbank() {
    const int n_fft_bins = kNFFT / 2 + 1;  // 1025
    const int n_mels     = kNMels;

    // n_mels + 2 mel center points
    std::vector<float> mel_pts(n_mels + 2);
    float mel_lo = hz_to_mel(kFMin);
    float mel_hi = hz_to_mel(kFMax);
    for (int i = 0; i < n_mels + 2; ++i)
        mel_pts[i] = mel_lo + (mel_hi - mel_lo) * i / (n_mels + 1);

    // Convert back to Hz
    std::vector<float> hz_pts(n_mels + 2);
    for (int i = 0; i < n_mels + 2; ++i)
        hz_pts[i] = mel_to_hz(mel_pts[i]);

    // Map Hz to FFT bin indices (float)
    std::vector<float> bin_pts(n_mels + 2);
    for (int i = 0; i < n_mels + 2; ++i)
        bin_pts[i] = (kNFFT + 1) * hz_pts[i] / kSR;

    // Build filter matrix (row = mel channel, col = fft bin)
    std::vector<float> fb(n_mels * n_fft_bins, 0.0f);

    for (int m = 0; m < n_mels; ++m) {
        float lower = bin_pts[m];
        float center= bin_pts[m + 1];
        float upper = bin_pts[m + 2];

        for (int k = 0; k < n_fft_bins; ++k) {
            float fk = static_cast<float>(k);
            float val = 0.0f;
            if (fk >= lower && fk <= center)
                val = (center != lower) ? (fk - lower) / (center - lower) : 1.0f;
            else if (fk > center && fk <= upper)
                val = (upper != center) ? (upper - fk) / (upper - center) : 0.0f;
            fb[m * n_fft_bins + k] = val;
        }

        // Slaney normalization: divide each filter by its area in Hz
        // area = (hz_pts[m+2] - hz_pts[m]) / 2
        float enorm = 2.0f / (hz_pts[m + 2] - hz_pts[m]);
        for (int k = 0; k < n_fft_bins; ++k)
            fb[m * n_fft_bins + k] *= enorm;
    }

    return fb;
}

// ---------------------------------------------------------------------------
// Hann window
// ---------------------------------------------------------------------------
static std::vector<float> build_hann_window(int n) {
    std::vector<float> w(n);
    for (int i = 0; i < n; ++i)
        w[i] = 0.5f * (1.0f - std::cos(2.0f * M_PI * i / n));
    return w;
}

// ---------------------------------------------------------------------------
// Internal pipeline struct
// ---------------------------------------------------------------------------
struct JARVISMelPipeline {
    // vDSP FFT setup
    FFTSetup fft_setup = nullptr;
    int log2n = 0;

    // Filterbank (n_mels × n_fft_bins)
    std::vector<float> filterbank;  // kNMels × 1025

    // Hann window
    std::vector<float> hann;

    // Work buffers
    std::vector<float> windowed;    // kNFFT
    std::vector<float> mag_sq;      // kNFFT/2+1
    DSPSplitComplex split;

    std::vector<float> real_buf;
    std::vector<float> imag_buf;

    JARVISMelPipeline() {
        log2n    = static_cast<int>(std::log2(kNFFT));
        fft_setup = vDSP_create_fftsetup(log2n, FFT_RADIX2);
        filterbank = build_mel_filterbank();
        hann       = build_hann_window(kNFFT);
        windowed.resize(kNFFT);
        mag_sq.resize(kNFFT / 2 + 1);
        real_buf.resize(kNFFT / 2 + 1);
        imag_buf.resize(kNFFT / 2 + 1);
        split.realp = real_buf.data();
        split.imagp = imag_buf.data();
    }

    ~JARVISMelPipeline() {
        if (fft_setup) vDSP_destroy_fftsetup(fft_setup);
    }
};

// ---------------------------------------------------------------------------
// Public C API
// ---------------------------------------------------------------------------
JARVISMelPipeline* mel_pipeline_create(void) {
    return new JARVISMelPipeline();
}

void mel_pipeline_destroy(JARVISMelPipeline* p) {
    delete p;
}

int mel_pipeline_compute(
    JARVISMelPipeline* p,
    const float* pcm,
    size_t n_samples,
    float* out_mel,
    size_t* out_frames)
{
    if (!p || !pcm || !out_mel || !out_frames) return -1;

    const int n_fft    = kNFFT;
    const int hop      = kHop;
    const int n_bins   = n_fft / 2 + 1;  // 1025
    const int n_mels   = kNMels;

    // Number of frames
    size_t n_frames = 0;
    if (n_samples >= (size_t)n_fft)
        n_frames = 1 + (n_samples - n_fft) / hop;
    else
        n_frames = 0;

    *out_frames = n_frames;
    if (n_frames == 0) return 0;

    const float* fb   = p->filterbank.data();
    const float* hann = p->hann.data();

    for (size_t frame = 0; frame < n_frames; ++frame) {
        size_t start = frame * hop;

        // Apply Hann window
        vDSP_vmul(pcm + start, 1, hann, 1, p->windowed.data(), 1, n_fft);

        // Pack into split complex (real FFT)
        vDSP_ctoz(
            reinterpret_cast<const DSPComplex*>(p->windowed.data()),
            2, &p->split, 1, n_fft / 2
        );

        // Real FFT
        vDSP_fft_zrip(p->fft_setup, &p->split, 1, p->log2n, FFT_FORWARD);

        // Power spectrum
        // The DC and Nyquist are packed specially by vDSP_fft_zrip:
        //   real[0] = DC, imag[0] = Nyquist
        float scale = 1.0f / (n_fft * n_fft);

        // DC bin
        p->mag_sq[0] = p->split.realp[0] * p->split.realp[0] * scale;
        // Nyquist bin
        p->mag_sq[n_bins - 1] = p->split.imagp[0] * p->split.imagp[0] * scale;
        // Middle bins
        for (int k = 1; k < n_fft / 2; ++k) {
            float re = p->split.realp[k];
            float im = p->split.imagp[k];
            p->mag_sq[k] = (re * re + im * im) * scale;
        }

        // Apply mel filterbank: out_mel[frame * n_mels : (frame+1)*n_mels]
        // = fb (n_mels × n_bins) @ mag_sq (n_bins)
        float* mel_row = out_mel + frame * n_mels;
        vDSP_mmul(fb, 1, p->mag_sq.data(), 1, mel_row, 1,
                  n_mels, 1, n_bins);

        // Convert to log scale
        for (int m = 0; m < n_mels; ++m) {
            mel_row[m] = std::log(mel_row[m] + kLogEps);
        }
    }

    return 0;
}

float mel_l2_db(
    const float* mel_a, size_t frames_a, size_t a_capacity_bytes,
    const float* mel_b, size_t frames_b, size_t b_capacity_bytes,
    int n_bins)
{
    // §2 AGENTS.md / operator law: guard the memcpy before touching bytes.
    // §3 voice math sacrosanct: formulas/filterbank/windowing UNCHANGED.
    if (n_bins <= 0) return std::numeric_limits<float>::quiet_NaN();

    const size_t n_bins_sz = static_cast<size_t>(static_cast<unsigned>(n_bins));

    size_t bytes_a_per_frame, bytes_a;
    if (__builtin_mul_overflow(n_bins_sz, sizeof(float), &bytes_a_per_frame) ||
        __builtin_mul_overflow(frames_a, bytes_a_per_frame, &bytes_a) ||
        bytes_a > a_capacity_bytes) {
        std::fprintf(stderr,
            "[mel_l2_db] SECURITY: a-buffer overflow guard triggered "
            "(frames_a=%zu n_bins=%d bytes_a=%zu a_capacity=%zu)\n",
            frames_a, n_bins, bytes_a, a_capacity_bytes);
        return std::numeric_limits<float>::quiet_NaN();
    }

    size_t bytes_b_per_frame, bytes_b;
    if (__builtin_mul_overflow(n_bins_sz, sizeof(float), &bytes_b_per_frame) ||
        __builtin_mul_overflow(frames_b, bytes_b_per_frame, &bytes_b) ||
        bytes_b > b_capacity_bytes) {
        std::fprintf(stderr,
            "[mel_l2_db] SECURITY: b-buffer overflow guard triggered "
            "(frames_b=%zu n_bins=%d bytes_b=%zu b_capacity=%zu)\n",
            frames_b, n_bins, bytes_b, b_capacity_bytes);
        return std::numeric_limits<float>::quiet_NaN();
    }

    size_t min_frames = std::min(frames_a, frames_b);
    size_t max_frames = std::max(frames_a, frames_b);

    size_t total;
    if (__builtin_mul_overflow(max_frames, n_bins_sz, &total)) {
        std::fprintf(stderr,
            "[mel_l2_db] SECURITY: total overflow guard triggered "
            "(max_frames=%zu n_bins=%d)\n", max_frames, n_bins);
        return std::numeric_limits<float>::quiet_NaN();
    }

    // Pad the shorter mel with zeros
    std::vector<float> a_pad(total, 0.0f);
    std::vector<float> b_pad(total, 0.0f);

    std::memcpy(a_pad.data(), mel_a, frames_a * n_bins * sizeof(float));
    std::memcpy(b_pad.data(), mel_b, frames_b * n_bins * sizeof(float));

    // Compute L2 distance: sqrt(sum((a-b)^2) / total)
    std::vector<float> diff(total);
    vDSP_vsub(b_pad.data(), 1, a_pad.data(), 1, diff.data(), 1, total);

    float sum_sq = 0.0f;
    vDSP_svesq(diff.data(), 1, &sum_sq, total);

    float rmse = std::sqrt(sum_sq / static_cast<float>(total));

    // Convert to dB: 20 * log10(rmse + eps)
    constexpr float eps = 1e-9f;
    float db = 20.0f * std::log10(rmse + eps);
    (void)min_frames;
    return db;
}

// ---------------------------------------------------------------------------
// C++ wrapper
// ---------------------------------------------------------------------------
namespace jarvis {

MelPipeline::MelPipeline() : handle_(mel_pipeline_create()) {}

MelPipeline::~MelPipeline() {
    if (handle_) mel_pipeline_destroy(handle_);
}

std::vector<float> MelPipeline::compute(const float* pcm, size_t n_samples) const {
    if (n_samples < static_cast<size_t>(kNFFT))
        return {};

    size_t n_frames = frames_for(n_samples);
    std::vector<float> mel(n_frames * kNMels, 0.0f);
    size_t actual = 0;
    mel_pipeline_compute(handle_, pcm, n_samples, mel.data(), &actual);
    mel.resize(actual * kNMels);
    return mel;
}

size_t MelPipeline::frames_for(size_t n_samples) const noexcept {
    if (n_samples < static_cast<size_t>(kNFFT)) return 0;
    return 1 + (n_samples - kNFFT) / kHop;
}

} // namespace jarvis
