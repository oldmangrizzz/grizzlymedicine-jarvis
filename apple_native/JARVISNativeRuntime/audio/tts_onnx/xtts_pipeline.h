#pragma once
/**
 * xtts_pipeline.h — ONNX Runtime C++ pipeline for pocket-tts 2.1.0 voice synthesis.
 *
 * Architecture (Kyutai pocket-tts 2.1.0 — NOT vanilla XTTS-v2):
 *   - text_encoder.onnx  : token IDs → text embeddings (LUTConditioner)
 *   - gpt_decoder.onnx   : FlowLM single-step decode with explicit KV-cache I/O
 *   - hifigan.onnx       : Mimi decoder step — latent frame → audio samples
 *
 * Voice conditioning is injected via the pre-loaded KV-cache from the voice
 * state safetensors file (jarvis_voice_state.safetensors).
 *
 * Streaming: latent frames are decoded by the Mimi decoder immediately after
 * each FlowLM step, enabling first-chunk delivery before full synthesis ends.
 *
 * Execution providers (Apple Silicon):
 *   - CoreML EP (OrtSessionOptionsAppendExecutionProvider_CoreML) — ANE/GPU
 *   - CPU EP fallback with NEON optimizations
 *
 * Thread safety: XTTSOnnxPipeline is NOT thread-safe. Use separate instances
 * for concurrent synthesis (same ONNX sessions can be shared if ORT is built
 * with thread-safe session inference — check ORT version).
 */

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include <onnxruntime_cxx_api.h>

#include "tokenizer.h"
#include "voice_state_loader.h"

namespace jarvis {
namespace tts {
namespace onnx {

/** Configuration for XTTSOnnxPipeline. */
struct PipelineConfig {
    // Paths to ONNX model files (produced by tools/export_xtts_to_onnx.py)
    std::string text_encoder_path;
    std::string gpt_decoder_path;
    std::string hifigan_path;

    // Paths to runtime assets
    std::string tokenizer_model_path;       // SentencePiece tokenizer.model
    std::string voice_state_path;           // jarvis_voice_state.safetensors

    // FlowLM hyperparameters (pocket-tts 2.1.0, english config)
    int    num_flow_lm_layers    = 6;
    int    ldim                  = 32;      // latent dimension (quantizer.dimension)
    int    d_model               = 1024;    // transformer hidden dim
    int    num_heads             = 16;
    int    head_dim              = 64;      // d_model / num_heads
    int    num_mimi_dec_layers   = 2;       // Mimi decoder transformer layers
    int    mimi_dec_heads        = 8;       // Mimi decoder num_heads
    int    mimi_dec_head_dim     = 64;      // Mimi decoder head_dim (512/8)
    float  temperature           = 0.75f;   // oracle synth_config value
    float  eos_threshold         = -4.0f;   // default TTSModel.load_model() value
    int    lsd_decode_steps      = 1;
    int    max_tokens            = 5000;
    int    sample_rate           = 24000;
    int    voice_state_seq_len   = 939;     // KV cache prefix length from voice state

    // Execution provider: "coreml", "cpu" (default auto-selects best available)
    std::string execution_provider = "auto";

    // ORT log severity: 0=verbose, 1=info, 2=warning, 3=error, 4=fatal
    int ort_log_severity = 3;
};

/** Audio chunk callback. Called with float32 mono samples at 24 kHz. */
using AudioChunkCallback = std::function<void(const float* samples, size_t n_samples)>;

/**
 * Main TTS inference pipeline.
 *
 * Lifecycle:
 *   1. Construct with PipelineConfig.
 *   2. Call synthesize() or synthesize_streaming().
 *   3. Optionally copy and reuse (state is reset between calls).
 */
class XTTSOnnxPipeline {
public:
    explicit XTTSOnnxPipeline(const PipelineConfig& config);
    ~XTTSOnnxPipeline();

    // Non-copyable (ORT sessions own GPU/ANE handles)
    XTTSOnnxPipeline(const XTTSOnnxPipeline&) = delete;
    XTTSOnnxPipeline& operator=(const XTTSOnnxPipeline&) = delete;
    XTTSOnnxPipeline(XTTSOnnxPipeline&&) noexcept;
    XTTSOnnxPipeline& operator=(XTTSOnnxPipeline&&) noexcept;

    /**
     * Synthesize text to audio (blocking, full output).
     * @param text   Input text to speak.
     * @param seed   RNG seed for noise sampling (42 = oracle baseline).
     * @return       Float32 mono PCM at sample_rate Hz.
     */
    std::vector<float> synthesize(const std::string& text, uint32_t seed = 42) const;

    /**
     * Streaming synthesis — calls callback for each decoded audio chunk.
     * First chunk arrives after the first Mimi decode step (~1 FlowLM step).
     * @param text        Input text.
     * @param callback    Called with each audio chunk as it is decoded.
     * @param seed        RNG seed.
     * @return            Total number of audio frames generated.
     */
    size_t synthesize_streaming(
        const std::string& text,
        AudioChunkCallback callback,
        uint32_t seed = 42) const;

    /** Sample rate of synthesized audio (24000 Hz). */
    int sample_rate() const;

    /** Name of active execution provider (e.g. "CoreML", "CPU"). */
    std::string active_execution_provider() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
