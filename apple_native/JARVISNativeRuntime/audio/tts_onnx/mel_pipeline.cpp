/**
 * mel_pipeline.cpp — STFT + log-mel spectrogram.
 *
 * Uses Accelerate/vDSP on Apple Silicon; falls back to KissFFT elsewhere.
 * Parameters are fixed to oracle spec: n_fft=2048, hop=256, n_mels=128, sr=24000.
 */

#include "mel_pipeline.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <numeric>
#include <stdexcept>
#include <vector>

#if defined(__APPLE__)
#  include <Accelerate/Accelerate.h>
#  define USE_VDSP 1
#else
#  include "kiss_fft.h"
#  define USE_KISSFFT 1
#endif

namespace jarvis {
namespace tts {
namespace onnx {

// ─── Hann window ─────────────────────────────────────────────────────────────

static std::vector<float> make_hann_window(int n) {
    std::vector<float> w(n);
    for (int i = 0; i < n; ++i) {
        w[i] = 0.5f * (1.0f - std::cos(2.0f * static_cast<float>(M_PI) * i / n));
    }
    return w;
}

// ─── Mel filterbank (matches librosa defaults) ───────────────────────────────

static float hz_to_mel(float hz) {
    // librosa default uses the Slaney mel scale (htk=False), not the HTK
    // 2595*log10 scale. The oracle .npy fixtures were generated with
    // librosa.feature.melspectrogram defaults, so this must stay Slaney.
    constexpr float f_sp = 200.0f / 3.0f;
    constexpr float min_log_hz = 1000.0f;
    constexpr float min_log_mel = min_log_hz / f_sp;
    constexpr float logstep = 1.8562979903656263f / 27.0f; // log(6.4)/27
    if (hz < min_log_hz) return hz / f_sp;
    return min_log_mel + std::log(hz / min_log_hz) / logstep;
}

static float mel_to_hz(float mel) {
    constexpr float f_sp = 200.0f / 3.0f;
    constexpr float min_log_hz = 1000.0f;
    constexpr float min_log_mel = min_log_hz / f_sp;
    constexpr float logstep = 1.8562979903656263f / 27.0f; // log(6.4)/27
    if (mel < min_log_mel) return mel * f_sp;
    return min_log_hz * std::exp(logstep * (mel - min_log_mel));
}

static std::vector<float> make_mel_filterbank(int n_fft, int n_mels, int sr, float fmin, float fmax) {
    int n_freqs = n_fft / 2 + 1;
    float mel_min = hz_to_mel(fmin);
    float mel_max = hz_to_mel(fmax);

    // n_mels + 2 evenly spaced mel points
    std::vector<float> mel_points(n_mels + 2);
    for (int i = 0; i < n_mels + 2; ++i) {
        mel_points[i] = mel_to_hz(mel_min + (mel_max - mel_min) * i / (n_mels + 1));
    }

    // Convert mel-centre frequencies to FFT bin indices
    std::vector<float> bin_freqs(n_freqs);
    for (int k = 0; k < n_freqs; ++k) {
        bin_freqs[k] = static_cast<float>(k) * sr / n_fft;
    }

    // Filterbank matrix [n_mels × n_freqs], row-major
    std::vector<float> fb(n_mels * n_freqs, 0.0f);
    for (int m = 0; m < n_mels; ++m) {
        float lower  = mel_points[m];
        float centre = mel_points[m + 1];
        float upper  = mel_points[m + 2];
        for (int k = 0; k < n_freqs; ++k) {
            float f = bin_freqs[k];
            float val = 0.0f;
            if (f >= lower && f <= centre) {
                val = (f - lower) / (centre - lower + 1e-10f);
            } else if (f > centre && f <= upper) {
                val = (upper - f) / (upper - centre + 1e-10f);
            }
            fb[m * n_freqs + k] = val;
        }
        // Slaney normalisation (matches librosa norm='slaney')
        float bw = upper - lower;
        if (bw > 0.0f) {
            for (int k = 0; k < n_freqs; ++k) {
                fb[m * n_freqs + k] *= 2.0f / bw;
            }
        }
    }
    return fb;
}

// ─── Single-frame STFT power using vDSP (Apple) ──────────────────────────────

#if defined(USE_VDSP)

struct VDSPContext {
    int n_fft;
    int log2n;
    FFTSetup setup;
    std::vector<float> window;
    std::vector<float> real_buf;
    std::vector<float> imag_buf;

    explicit VDSPContext(int n) : n_fft(n), window(make_hann_window(n)),
                                   real_buf(n / 2), imag_buf(n / 2)
    {
        log2n = static_cast<int>(std::round(std::log2(n)));
        setup = vDSP_create_fftsetup(log2n, FFT_RADIX2);
        if (!setup) throw std::runtime_error("vDSP_create_fftsetup failed");
    }

    ~VDSPContext() { vDSP_destroy_fftsetup(setup); }

    // Compute power spectrum [n/2+1] for a windowed frame.
    void power_spectrum(const float* frame, std::vector<float>& power) {
        int half = n_fft / 2;
        power.resize(half + 1);

        // Apply window
        std::vector<float> windowed(n_fft);
        vDSP_vmul(frame, 1, window.data(), 1, windowed.data(), 1, n_fft);

        // Pack real signal into split complex form
        DSPSplitComplex split { real_buf.data(), imag_buf.data() };
        vDSP_ctoz(reinterpret_cast<DSPComplex*>(windowed.data()), 2, &split, 1, half);

        // FFT
        vDSP_fft_zrip(setup, &split, 1, log2n, FFT_FORWARD);

        // Extract unnormalized power |X[k]|^2 to match librosa.stft.
        // Do not divide by n_fft: librosa.power_to_db applies an absolute
        // 1e-10 floor before ref=max, so extra scaling changes low-energy bins.
        const float scale = 1.0f;
        power[0]    = (real_buf[0] * real_buf[0]) * scale;
        power[half] = (imag_buf[0] * imag_buf[0]) * scale;
        for (int k = 1; k < half; ++k) {
            power[k] = (real_buf[k] * real_buf[k] + imag_buf[k] * imag_buf[k]) * scale;
        }
    }
};

#else  // KissFFT fallback

struct KissFFTContext {
    int n_fft;
    kiss_fftr_cfg cfg;
    std::vector<float> window;
    std::vector<kiss_fft_scalar> buf;
    std::vector<kiss_fft_cpx> out;

    explicit KissFFTContext(int n) : n_fft(n), window(make_hann_window(n)),
                                     buf(n), out(n / 2 + 1)
    {
        cfg = kiss_fftr_alloc(n, 0, nullptr, nullptr);
        if (!cfg) throw std::runtime_error("kiss_fftr_alloc failed");
    }

    ~KissFFTContext() { kiss_fftr_free(cfg); }

    void power_spectrum(const float* frame, std::vector<float>& power) {
        int half = n_fft / 2;
        power.resize(half + 1);
        for (int i = 0; i < n_fft; ++i) buf[i] = frame[i] * window[i];
        kiss_fftr(cfg, buf.data(), out.data());
        const float scale = 1.0f;
        for (int k = 0; k <= half; ++k) {
            power[k] = (out[k].r * out[k].r + out[k].i * out[k].i) * scale;
        }
    }
};

#endif  // USE_VDSP / USE_KISSFFT

// ─── Main mel computation ─────────────────────────────────────────────────────

std::vector<float> compute_log_mel(const float* samples, size_t n_samples, const MelConfig& cfg) {
    const int n_fft  = cfg.n_fft;
    const int hop    = cfg.hop;
    const int n_mels = cfg.n_mels;

    // Centre-pad like librosa: pad by n_fft/2 on each side
    int pad = n_fft / 2;
    std::vector<float> padded(n_samples + 2 * pad, 0.0f);
    std::copy(samples, samples + n_samples, padded.begin() + pad);

    int n_frames = 1 + static_cast<int>(n_samples) / hop;
    int n_freqs  = n_fft / 2 + 1;

    // Mel filterbank
    auto fb = make_mel_filterbank(n_fft, n_mels, cfg.sr, cfg.fmin, cfg.fmax);

    // STFT context
#if defined(USE_VDSP)
    VDSPContext fft(n_fft);
#else
    KissFFTContext fft(n_fft);
#endif

    std::vector<float> result(n_mels * n_frames, 0.0f);
    std::vector<float> power;
    std::vector<float> mel_frame(n_mels, 0.0f);

    for (int f = 0; f < n_frames; ++f) {
        int start = f * hop;
        int avail = static_cast<int>(padded.size()) - start;
        int to_copy = std::min(n_fft, avail);

        // Zero-pad if needed at end
        std::vector<float> frame(n_fft, 0.0f);
        std::copy(padded.data() + start, padded.data() + start + to_copy, frame.data());

        fft.power_spectrum(frame.data(), power);

        // Apply mel filterbank: mel_frame = fb @ power
        for (int m = 0; m < n_mels; ++m) {
            float s = 0.0f;
            const float* row = fb.data() + m * n_freqs;
            for (int k = 0; k < n_freqs; ++k) {
                s += row[k] * power[k];
            }
            mel_frame[m] = s;
        }

        // Store in column order [n_mels × n_frames]
        for (int m = 0; m < n_mels; ++m) {
            result[m * n_frames + f] = mel_frame[m];
        }
    }

    // Convert to dB: librosa.power_to_db(..., ref=np.max) defaults.
    // librosa also applies top_db=80; without that floor, long prompts accrue
    // large L2 in near-silent bins despite identical audio.
    float max_val = *std::max_element(result.begin(), result.end());
    if (max_val < 1e-10f) max_val = 1e-10f;
    for (float& v : result) {
        v = 10.0f * std::log10(std::max(v, 1e-10f) / max_val);
        if (v < -80.0f) v = -80.0f;
    }

    return result;
}

float mel_l2_db(
    const std::vector<float>& a, int a_frames,
    const std::vector<float>& b, int b_frames,
    int n_mels)
{
    // Align to shorter axis (same as oracle validation script)
    int frames = std::min(a_frames, b_frames);
    double sum = 0.0;
    int count = 0;
    for (int m = 0; m < n_mels; ++m) {
        for (int f = 0; f < frames; ++f) {
            float va = a[m * a_frames + f];
            float vb = b[m * b_frames + f];
            double diff = va - vb;
            sum += diff * diff;
            ++count;
        }
    }
    if (count == 0) return 0.0f;
    return static_cast<float>(std::sqrt(sum / count));
}

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
