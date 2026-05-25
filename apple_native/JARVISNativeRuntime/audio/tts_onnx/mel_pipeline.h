#pragma once
/**
 * mel_pipeline.h — STFT + log-mel spectrogram (validation / equivalence test).
 *
 * Parameters matching oracle manifest:
 *   n_fft   = 2048
 *   hop     = 256
 *   n_mels  = 128
 *   sr      = 24000
 *   fmin    = 0 Hz
 *   fmax    = sr/2
 *   power   = 2.0 (power spectrum)
 *   log     = 10 * log10 (dB, consistent with librosa.power_to_db default)
 *   ref     = max of the spectrogram
 *
 * On Apple Silicon: vDSP FFT (Accelerate.framework) is used.
 * Elsewhere       : KissFFT is used (bundled or found via find_package).
 *
 * This module is used ONLY by the equivalence tests; it is NOT in the hot TTS path.
 */

#include <cstddef>
#include <cstdint>
#include <vector>

namespace jarvis {
namespace tts {
namespace onnx {

struct MelConfig {
    int n_fft    = 2048;
    int hop      = 256;
    int n_mels   = 128;
    int sr       = 24000;
    float fmin   = 0.0f;
    float fmax   = 12000.0f;   // sr/2
};

/**
 * Compute the log-mel spectrogram of a mono PCM waveform.
 *
 * @param samples   Interleaved float32 audio samples (mono, normalised to [-1, 1]).
 * @param n_samples Number of samples.
 * @param cfg       Mel configuration (must match oracle parameters).
 * @return          Flat float32 buffer, shape [n_mels × n_frames], row-major.
 *                  n_frames = 1 + (n_samples / hop) (centre-padded like librosa).
 */
std::vector<float> compute_log_mel(
    const float* samples, size_t n_samples, const MelConfig& cfg = {});

/**
 * L2 distance in dB between two mel spectrograms of the same shape.
 * Pads/crops the shorter axis to match (consistent with oracle validation script).
 */
float mel_l2_db(
    const std::vector<float>& a, int a_frames,
    const std::vector<float>& b, int b_frames,
    int n_mels = 128);

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
