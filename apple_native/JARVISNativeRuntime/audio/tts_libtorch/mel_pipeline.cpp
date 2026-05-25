/**
 * mel_pipeline.cpp — STFT + log-mel spectrogram
 *
 * Implements the oracle mel parameters:
 *   n_fft=2048, hop=256, n_mels=128, sr=24000, fmin=0, fmax=12000
 *   librosa.power_to_db(mel, ref=np.max)
 *
 * Platform backends:
 *   Apple Silicon (ARM64): Accelerate.framework vDSP_DFT_Execute
 *   x86 / other:           KissFFT (third_party/kissfft)
 *
 * Mel filterbank is computed once at first call and cached.
 */

#include "mel_pipeline.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <vector>

// Platform detection
#if defined(__APPLE__) && (defined(__arm64__) || defined(__aarch64__))
#  define JARVIS_USE_ACCELERATE 1
#  include <Accelerate/Accelerate.h>
#else
#  define JARVIS_USE_KISSFFT 1
#  include <kiss_fftr.h>  // KissFFT real-to-complex FFT
#endif

namespace jarvis::tts {

namespace {

// ─── Mel filterbank ─────────────────────────────────────────────────────────

/** Hz → mel (HTK formula). */
static float hz_to_mel(float hz) {
    return 2595.0f * std::log10(1.0f + hz / 700.0f);
}
/** Mel → Hz (HTK). */
static float mel_to_hz(float mel) {
    return 700.0f * (std::pow(10.0f, mel / 2595.0f) - 1.0f);
}

/**
 * Build a mel filterbank matrix of shape (n_mels, n_fft/2+1).
 * Matches librosa.filters.mel exactly (HTK formula, linear amplitude).
 */
std::vector<float> build_mel_filterbank(const MelParams& p) {
    const int n_bins = p.n_fft / 2 + 1;
    const float f_min_mel = hz_to_mel(p.fmin);
    const float f_max_mel = hz_to_mel(p.fmax);

    // n_mels + 2 mel points (include fmin and fmax)
    std::vector<float> mel_pts(p.n_mels + 2);
    for (int i = 0; i < p.n_mels + 2; ++i) {
        mel_pts[i] = mel_to_hz(f_min_mel + (f_max_mel - f_min_mel) *
                                float(i) / float(p.n_mels + 1));
    }

    // FFT bin frequencies
    std::vector<float> f_fft(n_bins);
    for (int k = 0; k < n_bins; ++k) {
        f_fft[k] = float(k) * float(p.sr) / float(p.n_fft);
    }

    // Build filterbank matrix [n_mels × n_bins]
    std::vector<float> fb(p.n_mels * n_bins, 0.0f);
    for (int m = 0; m < p.n_mels; ++m) {
        const float fl = mel_pts[m];
        const float fc = mel_pts[m + 1];
        const float fh = mel_pts[m + 2];
        for (int k = 0; k < n_bins; ++k) {
            const float f = f_fft[k];
            float w = 0.0f;
            if (f >= fl && f <= fc && (fc - fl) > 0.0f)
                w = (f - fl) / (fc - fl);
            else if (f > fc && f <= fh && (fh - fc) > 0.0f)
                w = (fh - f) / (fh - fc);
            fb[m * n_bins + k] = w;
        }
    }
    return fb;
}

// ─── Hann window ────────────────────────────────────────────────────────────

std::vector<float> make_hann(int n) {
    std::vector<float> w(n);
    for (int i = 0; i < n; ++i)
        w[i] = 0.5f * (1.0f - std::cos(2.0f * M_PI * float(i) / float(n)));
    return w;
}

// ─── Platform-specific FFT ───────────────────────────────────────────────────

#ifdef JARVIS_USE_ACCELERATE

struct FFTState {
    int n_fft;
    FFTSetup setup;
    std::vector<float> window;
    int log2n;

    FFTState(int nfft) : n_fft(nfft), window(make_hann(nfft)) {
        log2n = 0;
        int tmp = nfft;
        while (tmp >>= 1) ++log2n;
        setup = vDSP_create_fftsetup(log2n, FFT_RADIX2);
        if (!setup) throw std::runtime_error("vDSP_create_fftsetup failed");
    }
    ~FFTState() { if (setup) vDSP_destroy_fftsetup(setup); }

    /**
     * Compute magnitude spectrum (one-sided) of a windowed frame.
     * frame  : n_fft float32 samples
     * out    : n_fft/2+1 float32 power values (magnitude^2)
     */
    void fft_power(const float* frame, float* out) const {
        const int n_bins = n_fft / 2 + 1;
        // Apply Hann window
        std::vector<float> windowed(n_fft);
        vDSP_vmul(frame, 1, window.data(), 1, windowed.data(), 1, n_fft);

        // Split into even/odd (real FFT via vDSP)
        std::vector<float> re(n_fft / 2), im(n_fft / 2);
        DSPSplitComplex split{re.data(), im.data()};

        // Pack real input into split-complex format
        vDSP_ctoz(reinterpret_cast<const DSPComplex*>(windowed.data()), 2,
                  &split, 1, n_fft / 2);

        vDSP_fft_zrip(setup, &split, 1, log2n, FFT_FORWARD);

        // Unpack magnitudes
        // DC
        out[0] = (re[0] * re[0]) * 0.25f;
        // Nyquist
        out[n_fft / 2] = (im[0] * im[0]) * 0.25f;
        // 1..n/2-1
        for (int k = 1; k < n_fft / 2; ++k) {
            const float r = re[k] * 0.5f;
            const float i = im[k] * 0.5f;
            out[k] = r * r + i * i;
        }
    }
};

#else // JARVIS_USE_KISSFFT

struct FFTState {
    int n_fft;
    kiss_fftr_cfg cfg;
    std::vector<float> window;

    FFTState(int nfft) : n_fft(nfft), window(make_hann(nfft)) {
        cfg = kiss_fftr_alloc(nfft, 0, nullptr, nullptr);
        if (!cfg) throw std::runtime_error("kiss_fftr_alloc failed");
    }
    ~FFTState() { if (cfg) kiss_fftr_free(cfg); }

    void fft_power(const float* frame, float* out) const {
        const int n_bins = n_fft / 2 + 1;
        std::vector<float> windowed(n_fft);
        for (int i = 0; i < n_fft; ++i) windowed[i] = frame[i] * window[i];
        std::vector<kiss_fft_cpx> cpx(n_bins);
        kiss_fftr(cfg, windowed.data(), cpx.data());
        for (int k = 0; k < n_bins; ++k) {
            out[k] = cpx[k].r * cpx[k].r + cpx[k].i * cpx[k].i;
        }
    }
};

#endif

// ─── Cached per-params state ─────────────────────────────────────────────────

struct PipelineCache {
    MelParams params;
    std::vector<float> filterbank;  // [n_mels × (n_fft/2+1)]
    std::unique_ptr<FFTState> fft;

    PipelineCache() = default;
    PipelineCache(const MelParams& p)
        : params(p),
          filterbank(build_mel_filterbank(p)),
          fft(std::make_unique<FFTState>(p.n_fft)) {}
};

static PipelineCache g_cache;
static std::mutex    g_cache_mutex;

const PipelineCache& get_cache(const MelParams& p) {
    std::lock_guard<std::mutex> lg(g_cache_mutex);
    if (g_cache.fft == nullptr ||
        g_cache.params.n_fft  != p.n_fft  ||
        g_cache.params.hop    != p.hop    ||
        g_cache.params.n_mels != p.n_mels ||
        g_cache.params.sr     != p.sr) {
        g_cache = PipelineCache(p);
    }
    return g_cache;
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

int mel_frame_count(int n_samples, const MelParams& params) {
    // librosa center=True: pads n_fft/2 on each side
    const int padded = n_samples + params.n_fft;
    return (padded - params.n_fft) / params.hop + 1;
}

void compute_log_mel(const float* audio,
                     int n_samples,
                     const MelParams& params,
                     float* out_mels) {
    if (!audio || n_samples <= 0) throw std::runtime_error("Invalid audio input");
    if (!out_mels) throw std::runtime_error("Null output buffer");

    const auto& cache = get_cache(params);
    const int n_fft   = params.n_fft;
    const int hop     = params.hop;
    const int n_mels  = params.n_mels;
    const int n_bins  = n_fft / 2 + 1;

    // Center-pad audio by n_fft/2 on each side (librosa default)
    const int pad     = n_fft / 2;
    const int padded  = n_samples + 2 * pad;
    std::vector<float> padded_audio(padded, 0.0f);
    std::memcpy(padded_audio.data() + pad, audio, n_samples * sizeof(float));

    const int n_frames = mel_frame_count(n_samples, params);
    std::vector<float> power(n_bins);
    std::vector<float> mel_power(n_mels);

    float global_max = -1e30f;

    // Temporary storage for all mel frames before dB conversion
    std::vector<float> all_mel(n_mels * n_frames);

    for (int t = 0; t < n_frames; ++t) {
        const int start = t * hop;
        const float* frame = padded_audio.data() + start;

        // Handle edge: if frame extends past padded_audio, zero-fill
        std::vector<float> safe_frame(n_fft, 0.0f);
        const int avail = std::min(n_fft, padded - start);
        if (avail > 0) std::memcpy(safe_frame.data(), frame, avail * sizeof(float));

        cache.fft->fft_power(safe_frame.data(), power.data());

        // Mel filterbank: mel_power = filterbank @ power
        const float* fb = cache.filterbank.data();
        for (int m = 0; m < n_mels; ++m) {
            float s = 0.0f;
            const float* row = fb + m * n_bins;
            for (int k = 0; k < n_bins; ++k) s += row[k] * power[k];
            // Clip to a small positive value (matches librosa behaviour)
            s = std::max(s, 1e-10f);
            mel_power[m] = s;
        }

        // Store and track max for dB normalisation (ref=np.max)
        for (int m = 0; m < n_mels; ++m) {
            const float v = mel_power[m];
            all_mel[t * n_mels + m] = v;
            if (v > global_max) global_max = v;
        }
    }

    // Convert to dB: 10 * log10(mel / max), then clip at -80 dB (librosa default)
    // librosa.power_to_db(S, ref=np.max) = 10*log10(S/ref)
    // Output shape: [n_mels × n_frames]  (column-major along time)
    const float log_max = (global_max > 1e-10f) ? 10.0f * std::log10(global_max) : 0.0f;
    for (int t = 0; t < n_frames; ++t) {
        for (int m = 0; m < n_mels; ++m) {
            const float v = all_mel[t * n_mels + m];
            float db = 10.0f * std::log10(std::max(v, 1e-10f)) - log_max;
            // librosa clips at amin=1e-10 (done above), no explicit top_db here
            out_mels[m * n_frames + t] = db;
        }
    }
}

float mel_l2_db(const float* mel_a, int frames_a,
                const float* mel_b, int frames_b,
                int n_mels) {
    const int T = std::max(frames_a, frames_b);
    double sum_sq = 0.0;
    for (int m = 0; m < n_mels; ++m) {
        for (int t = 0; t < T; ++t) {
            const float a = (t < frames_a) ? mel_a[m * frames_a + t] : 0.0f;
            const float b = (t < frames_b) ? mel_b[m * frames_b + t] : 0.0f;
            const float d = a - b;
            sum_sq += static_cast<double>(d) * static_cast<double>(d);
        }
    }
    // RMS across all mel*time bins
    const double rms = std::sqrt(sum_sq / double(n_mels * T));
    return static_cast<float>(rms);
}

} // namespace jarvis::tts
