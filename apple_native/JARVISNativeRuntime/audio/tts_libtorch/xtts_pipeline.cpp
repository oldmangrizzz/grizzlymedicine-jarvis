/**
 * xtts_pipeline.cpp — JARVIS native TTS pipeline (LibTorch backend)
 *
 * Architecture: pocket-tts 2.1.0 (Kyutai FlowLM + Mimi codec)
 *
 * Inference flow for one utterance:
 *   1. Tokenise: Tokenizer::encode(text) → int32 IDs via SentencePiece
 *   2. Embed:    text_encoder.forward(tokens) → [1, T, d_model]
 *   3. State:    load voice_state KV caches (pre-loaded at startup)
 *   4. Autoregressive loop (FlowLM):
 *        while !eos && step < max_gen_steps:
 *          noise = randn(1, ldim) * sqrt(temp)     // PRNG controlled by seed
 *          latent, is_eos = gpt_decoder.forward(prev_latent, text_cond,
 *                                                kv_caches, offsets, noise)
 *          offsets += 1
 *          latent_denorm = gpt_decoder.denormalize_latent(latent)
 *          audio_frame = hifigan.forward(latent_denorm, mimi_kv, mimi_offsets)
 *          mimi_offsets += 4   // upsample factor
 *          stream audio_frame
 *   5. Concatenate audio frames → return
 *
 * Zero Python at runtime.
 */

#include "xtts_pipeline.h"
#include "tokenizer.h"
#include "voice_state_loader.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>

#include <torch/script.h>
#include <torch/torch.h>

namespace jarvis::tts {

// ---------------------------------------------------------------------------
// Impl
// ---------------------------------------------------------------------------

struct XTTSPipeline::Impl {
    PipelineConfig cfg;

    mutable torch::jit::Module text_encoder;
    mutable torch::jit::Module gpt_decoder;
    mutable torch::jit::Module hifigan;

    Tokenizer tokenizer;
    VoiceState base_voice_state;  // original (read-only)

    torch::Device torch_device{torch::kCPU};
    bool loaded = false;

    // Pre-allocated warm-up state
    void do_warmup();

    AudioResult run_synthesis(const std::string& text,
                              uint64_t seed,
                              StreamCallback* cb) const;
};

// ---------------------------------------------------------------------------
// XTTSPipeline public API
// ---------------------------------------------------------------------------

XTTSPipeline::XTTSPipeline() : impl_(std::make_unique<Impl>()) {}
XTTSPipeline::~XTTSPipeline() = default;
XTTSPipeline::XTTSPipeline(XTTSPipeline&&) noexcept = default;
XTTSPipeline& XTTSPipeline::operator=(XTTSPipeline&&) noexcept = default;

void XTTSPipeline::load(const PipelineConfig& config) {
    auto& im = *impl_;
    im.cfg = config;

    // Resolve device
    if (config.device == "mps") {
#if defined(__APPLE__)
        if (torch::mps::is_available()) {
            im.torch_device = torch::Device(torch::kMPS);
        } else {
            im.torch_device = torch::Device(torch::kCPU);
        }
#else
        im.torch_device = torch::Device(torch::kCPU);
#endif
    } else if (config.device == "cuda") {
        im.torch_device = torch::Device(torch::kCUDA);
    } else {
        im.torch_device = torch::Device(torch::kCPU);
    }

    // Load TorchScript modules
    try {
        im.text_encoder = torch::jit::load(config.text_encoder_pt, im.torch_device);
        im.text_encoder.eval();
        im.gpt_decoder  = torch::jit::load(config.gpt_decoder_pt,  im.torch_device);
        im.gpt_decoder.eval();
        im.hifigan      = torch::jit::load(config.hifigan_pt,      im.torch_device);
        im.hifigan.eval();
    } catch (const c10::Error& e) {
        throw std::runtime_error(
            std::string("Failed to load TorchScript models: ") + e.what());
    }

    // Load tokenizer
    im.tokenizer.load(config.tokenizer_model);

    // Load voice state
    im.base_voice_state = VoiceState::load(config.voice_state_path, im.torch_device);

    im.loaded = true;
}

void XTTSPipeline::warmup() {
    if (!impl_->loaded) throw std::runtime_error("Pipeline not loaded");
    impl_->do_warmup();
}

bool XTTSPipeline::is_loaded() const { return impl_->loaded; }
const PipelineConfig& XTTSPipeline::config() const { return impl_->cfg; }

AudioResult XTTSPipeline::synthesize(const std::string& text, uint64_t seed) const {
    if (!impl_->loaded) throw std::runtime_error("Pipeline not loaded");
    return impl_->run_synthesis(text, seed, nullptr);
}

int XTTSPipeline::synthesize_stream(const std::string& text,
                                     uint64_t seed,
                                     StreamCallback callback) const {
    if (!impl_->loaded) throw std::runtime_error("Pipeline not loaded");
    auto result = impl_->run_synthesis(text, seed, &callback);
    return result.total_latency_ms;
}

// ---------------------------------------------------------------------------
// Warm-up
// ---------------------------------------------------------------------------

void XTTSPipeline::Impl::do_warmup() {
    // Synthesise a very short text to pre-compile all CUDA/MPS kernels.
    const std::string warmup_text = "Ready.";
    const uint64_t seed = 0;
    run_synthesis(warmup_text, seed, nullptr);
}

// ---------------------------------------------------------------------------
// Core synthesis
// ---------------------------------------------------------------------------

namespace {

/** Deterministic noise generator seeded per-step for PRNG reproducibility. */
torch::Tensor generate_step_noise(int ldim, float temp,
                                   uint64_t base_seed, int step,
                                   torch::Device dev) {
    // Use a per-step seed: seed + step * 1000003 (large prime to avoid correlation)
    const uint64_t step_seed = base_seed + static_cast<uint64_t>(step) * 1000003ULL;
    torch::manual_seed(static_cast<int64_t>(step_seed & 0x7FFFFFFFFFFFFFFF));
    return torch::randn({1, ldim}, torch::TensorOptions().dtype(torch::kFloat32).device(dev))
           * std::sqrt(temp);
}

} // anonymous namespace

AudioResult XTTSPipeline::Impl::run_synthesis(const std::string& text,
                                               uint64_t seed,
                                               StreamCallback* cb) const {
    torch::NoGradGuard no_grad;

    const auto t_start = std::chrono::steady_clock::now();
    auto elapsed_ms = [&]() {
        return static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t_start).count());
    };

    // ── 1. Tokenise ──────────────────────────────────────────────────────────
    const auto token_ids = tokenizer.encode(text);
    if (token_ids.empty()) throw std::runtime_error("Tokeniser returned empty sequence");

    const int T = static_cast<int>(token_ids.size());

    // Token tensor [1, T] int64
    auto tokens_i64 = torch::from_blob(
        const_cast<int32_t*>(token_ids.data()),
        {1, T},
        torch::TensorOptions().dtype(torch::kInt32))
        .to(torch::kInt64).to(torch_device);

    // ── 2. Text embedding ────────────────────────────────────────────────────
    torch::Tensor text_cond;
    {
        std::vector<torch::jit::IValue> inp = {tokens_i64};
        text_cond = text_encoder.forward(inp).toTensor();  // [1, T, d_model]
    }

    // ── 3. Clone voice state and expand for generation ───────────────────────
    const int extra = T + cfg.max_gen_steps + 10;
    VoiceState vs = base_voice_state.expand_for_generation(extra);

    // Build kv_cache list for TorchScript
    std::vector<torch::IValue> kv_list;
    kv_list.reserve(vs.num_layers);
    for (auto& cache : vs.kv_caches) kv_list.emplace_back(cache);
    auto kv_caches_ts = torch::ivalue::Tuple::create(kv_list);  // but we use list
    // Actually pass as c10::List<Tensor>
    c10::List<torch::Tensor> kv_list_c10;
    for (auto& cache : vs.kv_caches) kv_list_c10.push_back(cache);

    // Offsets for FlowLM
    torch::Tensor fl_offsets = vs.offsets.clone();

    // Mimi KV caches (fresh per utterance)
    const int MIMI_S_MAX = 2000;
    c10::List<torch::Tensor> mimi_kv_list;
    for (int i = 0; i < cfg.num_mimi_layers; ++i) {
        mimi_kv_list.push_back(
            torch::full({2, 1, MIMI_S_MAX, 8, 64},
                        std::numeric_limits<float>::quiet_NaN(),
                        torch::TensorOptions().dtype(torch::kFloat32).device(torch_device)));
    }
    torch::Tensor mimi_offsets = torch::zeros(
        {cfg.num_mimi_layers},
        torch::TensorOptions().dtype(torch::kInt64).device(torch_device));

    // ── 4. Text conditioning prompt (run text tokens through FlowLM KV cache) ─
    // Run one forward pass with the text tokens so the KV cache ingests them.
    // backbone_input = empty [1, 0, ldim]
    {
        auto bi_text = torch::empty(
            {1, 0, cfg.ldim},
            torch::TensorOptions().dtype(torch::kFloat32).device(torch_device));
        auto noise_dummy = torch::zeros(
            {1, cfg.ldim},
            torch::TensorOptions().dtype(torch::kFloat32).device(torch_device));

        std::vector<torch::IValue> args = {
            bi_text,
            text_cond,
            kv_list_c10,
            fl_offsets,
            noise_dummy
        };
        // This populates the KV cache with text tokens and returns a dummy latent
        auto result = gpt_decoder.forward(args);
        // Increment offsets by T (number of text tokens processed)
        fl_offsets.add_(static_cast<int64_t>(T));
    }

    // ── 5. Autoregressive generation loop ───────────────────────────────────
    AudioResult audio_result;
    audio_result.sample_rate = cfg.sample_rate;

    // First backbone input: NaN → BOS embedding
    auto backbone_input = torch::full(
        {1, 1, cfg.ldim},
        std::numeric_limits<float>::quiet_NaN(),
        torch::TensorOptions().dtype(torch::kFloat32).device(torch_device));

    bool first_chunk = true;

    for (int step = 0; step < cfg.max_gen_steps; ++step) {
        const auto noise = generate_step_noise(cfg.ldim, cfg.temperature,
                                               seed, step, torch_device);

        std::vector<torch::IValue> gpt_args = {
            backbone_input,
            text_cond,      // reused every step (condition doesn't change)
            kv_list_c10,
            fl_offsets,
            noise
        };

        auto gpt_out = gpt_decoder.forward(gpt_args).toTuple();
        torch::Tensor latent = gpt_out->elements()[0].toTensor();   // [1, 1, ldim]
        torch::Tensor is_eos = gpt_out->elements()[1].toTensor();   // [1] bool

        // Increment FlowLM offset by 1
        fl_offsets.add_(1LL);

        // Denormalise latent
        {
            std::vector<torch::IValue> dn_args = {latent};
            latent = gpt_decoder.run_method("denormalize_latent", latent).toTensor();
        }

        // Decode audio frame with Mimi
        std::vector<torch::IValue> mimi_args = {
            latent.squeeze(1),   // [1, ldim] → actually need [1, 1, ldim] check
            mimi_kv_list,
            mimi_offsets
        };
        // Mimi expects [1, 1, ldim]:
        mimi_args[0] = latent;   // [1, 1, ldim]
        auto audio_frame = hifigan.forward(mimi_args).toTensor();  // [1, 1, samples]

        // Increment Mimi offsets (upsample_stride=4 for frame_rate 12.5→50 fps)
        mimi_offsets.add_(4LL);

        // Collect audio
        const auto flat = audio_frame.squeeze(0).squeeze(0).to(torch::kCPU).contiguous();
        const float* data = flat.data_ptr<float>();
        const int n = static_cast<int>(flat.size(0));

        if (first_chunk) {
            audio_result.first_chunk_latency_ms = elapsed_ms();
            first_chunk = false;
        }

        audio_result.samples.insert(audio_result.samples.end(), data, data + n);

        // Streaming callback
        if (cb) {
            const bool last = is_eos.item<bool>() || (step == cfg.max_gen_steps - 1);
            if (!(*cb)(data, n, last)) break;  // caller aborted
        }

        if (is_eos.item<bool>()) break;

        // Next step: use generated latent (before denormalisation) as backbone input
        // pocket-tts uses the raw latent (normalised) as next backbone_input
        backbone_input = gpt_out->elements()[0].toTensor();  // [1, 1, ldim]
    }

    audio_result.total_latency_ms = elapsed_ms();
    return audio_result;
}

} // namespace jarvis::tts
