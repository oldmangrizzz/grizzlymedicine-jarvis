#pragma once
/**
 * mel_pipeline.h — STFT + log-mel spectrogram
 *
 * Parameters matching the oracle capture script (capture.py):
 *   n_fft    = 2048
 *   hop      = 256
 *   n_mels   = 128
 *   fmin     = 0 Hz
 *   fmax     = 12000 Hz
 *   sr       = 24000 Hz
 *
 * On Apple Silicon (TARGET_CPU_ARM64), the STFT is computed with
 * Accelerate.framework vDSP (FFT via vDSP_fft_zrip / vDSP_DFT_Execute).
 * On x86 / other platforms, KissFFT is used (bundled in third_party/).
 *
 * Output: float32 ndarray of shape (n_mels, T) in log-mel dB scale,
 *         ref = max (matching librosa.power_to_db with ref=np.max).
 *
 * Zero Python at runtime.
 */

#include <cstdint>
#include <memory>
#include <vector>

namespace jarvis::tts {

struct MelParams {
    int n_fft   = 2048;
    int hop     = 256;
    int n_mels  = 128;
    int sr      = 24000;
    float fmin  = 0.0f;
    float fmax  = 12000.0f;
};

/**
 * Compute log-mel spectrogram from float32 mono audio.
 *
 * @param audio   Pointer to float32 audio samples ([-1, 1] range).
 * @param n_samples Number of samples.
 * @param params  Mel spectrogram parameters.
 * @param out_mels Output buffer: shape [n_mels × n_frames].
 *                 n_frames = ceil((n_samples + n_fft/2) / hop)
 *                 The caller must allocate this; call mel_frame_count() first.
 *
 * Throws std::runtime_error if parameters are invalid.
 */
void compute_log_mel(const float* audio,
                     int n_samples,
                     const MelParams& params,
                     float* out_mels);

/**
 * Compute the number of mel frames that will be produced for a given
 * number of input samples using center-padding (librosa default).
 */
int mel_frame_count(int n_samples, const MelParams& params);

/**
 * Compute L2 distance (in dB) between two log-mel spectrograms.
 * Both must have shape [n_mels × n_frames].  If they differ in T,
 * the shorter is zero-padded on the right.
 *
 * @return RMS L2 distance in dB.
 */
float mel_l2_db(const float* mel_a, int frames_a,
                const float* mel_b, int frames_b,
                int n_mels);

} // namespace jarvis::tts
