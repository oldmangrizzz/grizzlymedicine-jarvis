#pragma once
/**
 * xtts_pipeline.h — JARVIS native TTS pipeline (LibTorch backend)
 *
 * Uses three TorchScript archives produced by trace_xtts_to_torchscript.py:
 *   text_encoder.pt   — SentencePiece token → dense embeddings
 *   gpt_decoder.pt    — FlowLM autoregressive step (pocket-tts architecture)
 *   hifigan.pt        — Mimi codec decoder step
 *
 * Zero Python at runtime.  Only LibTorch (torch::jit::load) + sentencepiece C++.
 *
 * Usage:
 *   XTTSPipeline pipeline;
 *   pipeline.load(config);
 *   pipeline.warmup();
 *
 *   // Full synthesis (blocking)
 *   auto audio = pipeline.synthesize("Hello, sir.", seed);
 *
 *   // Streaming (non-blocking, callback per audio chunk)
 *   pipeline.synthesize_stream("Hello, sir.", seed,
 *       [](const float* samples, int n, bool is_last) { ... });
 */

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace jarvis::tts {

struct PipelineConfig {
    // Paths
    std::string text_encoder_pt;   // text_encoder.pt
    std::string gpt_decoder_pt;    // gpt_decoder.pt
    std::string hifigan_pt;        // hifigan.pt
    std::string tokenizer_model;   // tokenizer.model (SentencePiece)
    std::string voice_state_path;  // jarvis_voice_state.safetensors

    // Device: "mps" (Apple Silicon), "cuda", or "cpu"
    std::string device = "mps";

    // Generation parameters (must match the oracle capture)
    float temperature    = 0.75f;
    float eos_threshold  = 0.5f;  // pocket-tts default
    int   lsd_steps      = 1;     // pocket-tts default
    int   max_gen_steps  = 300;   // safety cap (~24s at 12.5fps)

    // Mimi frame parameters
    int ldim             = 32;    // latent dimension
    int d_model          = 1024;  // FlowLM transformer width
    int num_fl_layers    = 6;     // FlowLM transformer layers
    int num_mimi_layers  = 2;     // Mimi decoder transformer layers
    int frame_samples    = 1920;  // 24000/12.5 per latent frame
    int sample_rate      = 24000;
};

/**
 * Synthesised audio result.
 */
struct AudioResult {
    std::vector<float> samples;    // float32 PCM [-1, 1]
    int sample_rate = 24000;
    int first_chunk_latency_ms = 0;
    int total_latency_ms = 0;
};

/**
 * Streaming callback: called for each decoded audio chunk.
 *   samples   — pointer to float32 PCM samples
 *   n_samples — sample count
 *   is_last   — true on the final chunk
 * Return false to abort early.
 */
using StreamCallback = std::function<bool(const float* samples, int n_samples, bool is_last)>;

class XTTSPipeline {
public:
    XTTSPipeline();
    ~XTTSPipeline();

    // Non-copyable
    XTTSPipeline(const XTTSPipeline&) = delete;
    XTTSPipeline& operator=(const XTTSPipeline&) = delete;
    XTTSPipeline(XTTSPipeline&&) noexcept;
    XTTSPipeline& operator=(XTTSPipeline&&) noexcept;

    /**
     * Load models and voice state from disk.
     * Throws std::runtime_error on failure.
     */
    void load(const PipelineConfig& config);

    /**
     * Warm-up: run one short synthesis to pre-JIT all kernels.
     * Call after load() before the first real synthesis.
     */
    void warmup();

    /**
     * Synthesise text fully and return all audio.
     * Thread-safe for concurrent calls on the same loaded pipeline.
     *
     * @param text   Raw text string (will be preprocessed by the tokenizer).
     * @param seed   RNG seed for determinism (0 = random).
     * @return       AudioResult with float32 PCM + timing info.
     */
    AudioResult synthesize(const std::string& text, uint64_t seed = 42) const;

    /**
     * Streaming synthesis.  The callback is called for each Mimi audio frame
     * as it is decoded.  First chunk arrives in ~200ms for short texts.
     *
     * @param text      Raw text.
     * @param seed      RNG seed.
     * @param callback  Called per chunk; returning false aborts generation.
     * @return          Total latency (ms).
     */
    int synthesize_stream(const std::string& text,
                          uint64_t seed,
                          StreamCallback callback) const;

    bool is_loaded() const;
    const PipelineConfig& config() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace jarvis::tts
