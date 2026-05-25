#pragma once
// mel_pipeline.h — Log-mel spectrogram extraction using vDSP (Accelerate.framework)
//
// Parameters matching oracle exactly:
//   n_fft   = 2048
//   hop     = 256
//   n_mels  = 128
//   sr      = 24000
//   fmin    = 0 Hz
//   fmax    = 12000 Hz   (sr/2)
//   power   = 2.0 (power spectrogram)
//   norm    = "slaney"
//   htk     = false
//
// All computation uses vDSP / vForce from Accelerate.framework.
// No Python, no PyTorch, no CoreML — pure C++ / Accelerate.

#ifndef JARVIS_MEL_PIPELINE_H
#define JARVIS_MEL_PIPELINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a MelPipeline instance.
typedef struct JARVISMelPipeline JARVISMelPipeline;

/// Allocate and initialize a MelPipeline with the oracle parameters.
/// Caller owns and must free with mel_pipeline_destroy().
JARVISMelPipeline* mel_pipeline_create(void);

/// Free a MelPipeline.
void mel_pipeline_destroy(JARVISMelPipeline* pipeline);

/// Compute the log-mel spectrogram of raw PCM audio.
///
/// @param pipeline  Handle from mel_pipeline_create()
/// @param pcm       Float32 mono audio samples (24kHz)
/// @param n_samples Number of samples
/// @param out_mel   Output buffer — caller allocates (n_frames * 128 floats).
///                  Frames are time-major: row i = mel frame i, 128 bins.
/// @param out_frames On return: number of mel frames written.
/// @return 0 on success, non-zero on error.
int mel_pipeline_compute(
    JARVISMelPipeline* pipeline,
    const float* pcm,
    size_t n_samples,
    float* out_mel,
    size_t* out_frames
);

/// Compute mel-L2 (in dB) between two mel spectrograms.
/// Both must have the same number of bins (128) but may differ in frames;
/// the shorter is padded to match before comparison.
///
/// @param mel_a           Pointer to first mel buffer (time-major float32).
/// @param frames_a        Number of frames in mel_a.
/// @param a_capacity_bytes Byte capacity of the mel_a buffer.
/// @param mel_b           Pointer to second mel buffer.
/// @param frames_b        Number of frames in mel_b.
/// @param b_capacity_bytes Byte capacity of the mel_b buffer.
/// @param n_bins          Number of mel bins (must be 128).
/// @return L2 distance in dB. Returns NaN on overflow/capacity violation —
///         caller MUST check (§2 AGENTS.md — no silent fallback).
float mel_l2_db(
    const float* mel_a, size_t frames_a, size_t a_capacity_bytes,
    const float* mel_b, size_t frames_b, size_t b_capacity_bytes,
    int n_bins   // must be 128
);

#ifdef __cplusplus
}
#endif

// ---------------------------------------------------------------------------
// C++ inline convenience wrapper (header-only)
// ---------------------------------------------------------------------------
#ifdef __cplusplus
#include <memory>
#include <vector>

namespace jarvis {

class MelPipeline {
public:
    MelPipeline();
    ~MelPipeline();

    /// Compute log-mel for a mono PCM buffer. Returns time-major float32 vector.
    /// Shape: [n_frames × 128]
    std::vector<float> compute(const float* pcm, size_t n_samples) const;

    /// Frames for a given sample count (without computing).
    size_t frames_for(size_t n_samples) const noexcept;

    static constexpr int kNFFT    = 2048;
    static constexpr int kHop     = 256;
    static constexpr int kNMels   = 128;
    static constexpr int kSR      = 24000;

private:
    JARVISMelPipeline* handle_ = nullptr;
};

} // namespace jarvis
#endif // __cplusplus

#endif // JARVIS_MEL_PIPELINE_H
