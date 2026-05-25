/**
 * xtts_pipeline.cpp — ONNX Runtime C++ inference pipeline.
 *
 * Three Ort::Session objects:
 *   text_encoder  : token IDs → text embeddings
 *   gpt_decoder   : FlowLM single-step (growing KV-cache pattern)
 *   hifigan       : Mimi decoder single-step (growing KV-cache pattern)
 *
 * Growing KV-cache:
 *   Each step, the cache input grows by one token:
 *     step 0: kv shape [2, 1, 939, H, D]  (voice state prefill)
 *     step 1: kv shape [2, 1, 940, H, D]
 *     ...
 *   The ONNX model concatenates new K/V to the input cache and returns the
 *   extended cache. No indexed writes; no pre-allocated fixed-size buffer.
 *
 * Latency optimizations:
 *   - Sessions pre-created at construction
 *   - ORT arena allocator (reduces per-step allocation overhead)
 *   - Voice KV-cache loaded once and shallow-copied per synthesis call
 */

#include "xtts_pipeline.h"
#include "torch_seed42_noise.h"
#include "voice_integrity.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(__APPLE__)
#  if __has_include(<coreml_provider_factory.h>)
#    include <coreml_provider_factory.h>
#    define JARVIS_ORT_HAS_COREML_EP 1
#  elif __has_include(<onnxruntime/core/providers/coreml/coreml_provider_factory.h>)
#    include <onnxruntime/core/providers/coreml/coreml_provider_factory.h>
#    define JARVIS_ORT_HAS_COREML_EP 1
#  endif
#endif

namespace jarvis {
namespace tts {
namespace onnx {

// ─── helpers ─────────────────────────────────────────────────────────────────

static std::vector<const char*> to_cstr(const std::vector<std::string>& sv) {
    std::vector<const char*> cv;
    cv.reserve(sv.size());
    for (const auto& s : sv) cv.push_back(s.c_str());
    return cv;
}

// ─── Impl ────────────────────────────────────────────────────────────────────

struct XTTSOnnxPipeline::Impl {
    PipelineConfig cfg;

    Ort::Env env;
    Ort::SessionOptions session_opts;

    std::unique_ptr<Ort::Session> text_encoder;
    std::unique_ptr<Ort::Session> gpt_decoder;
    std::unique_ptr<Ort::Session> hifigan;

    Ort::MemoryInfo mem_cpu {
        Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeCPU)
    };

    VoiceState voice_state;
    Tokenizer  tokenizer;
    std::string active_ep;

    Impl(const PipelineConfig& c)
        : cfg(c)
        , env(static_cast<OrtLoggingLevel>(c.ort_log_severity), "JARVISOnnx")
        , tokenizer(c.tokenizer_model_path)
    {
        session_opts.SetIntraOpNumThreads(1);
        session_opts.SetInterOpNumThreads(1);
        session_opts.SetGraphOptimizationLevel(ORT_ENABLE_ALL);

        bool coreml_ok = false;
#if defined(__APPLE__) && defined(JARVIS_ORT_HAS_COREML_EP)
        if (c.execution_provider == "coreml") {
            uint32_t flags = 0;
            OrtStatus* st = OrtSessionOptionsAppendExecutionProvider_CoreML(session_opts, flags);
            if (st == nullptr) {
                coreml_ok = true;
                active_ep = "CoreML";
            } else {
                Ort::GetApi().ReleaseStatus(st);
            }
        }
#endif
        if (!coreml_ok) active_ep = "CPU";

        voice_integrity::verify_voice_integrity_or_throw({
            {c.voice_state_path, "_local_voice/jarvis_voice_state.safetensors"},
            {c.text_encoder_path, "onnx_models/text_encoder.onnx"},
            {c.gpt_decoder_path, "onnx_models/gpt_decoder.onnx"},
        });

        text_encoder = std::make_unique<Ort::Session>(
            env, c.text_encoder_path.c_str(), session_opts);
        gpt_decoder = std::make_unique<Ort::Session>(
            env, c.gpt_decoder_path.c_str(), session_opts);
        hifigan = std::make_unique<Ort::Session>(
            env, c.hifigan_path.c_str(), session_opts);

        voice_state = load_voice_state(c.voice_state_path, c.num_flow_lm_layers);
    }


    static std::string strip_copy(std::string value) {
        auto not_space = [](unsigned char c) { return !std::isspace(c); };
        value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
        value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
        return value;
    }

    std::string normalize_prompt_for_pocket_tts(const std::string& input) const {
        std::string text = strip_copy(input);
        for (char& ch : text) {
            if (ch == '\n' || ch == '\r') ch = ' ';
        }
        while (text.find("  ") != std::string::npos) {
            text.replace(text.find("  "), 2, " ");
        }
        if (text.empty()) return text;
        if (std::islower(static_cast<unsigned char>(text.front()))) {
            text.front() = static_cast<char>(std::toupper(static_cast<unsigned char>(text.front())));
        }
        if (std::isalnum(static_cast<unsigned char>(text.back()))) {
            text.push_back('.');
        }
        // pocket-tts split_into_best_sentences tokenizes, splits on sentence
        // boundary tokens, decodes each segment separately, then joins segments
        // with spaces. Decoding the whole token list is not equivalent for
        // decimal/version strings: Python turns "4.2" into segments "4." +
        // "2", then joins them as "4. 2" before final conditioning.
        const auto ids = tokenizer.encode(text);
        auto boundary_ids = tokenizer.encode(".!...?");
        if (!boundary_ids.empty()) boundary_ids.erase(boundary_ids.begin());

        std::vector<size_t> boundaries;
        boundaries.push_back(0);
        bool previous_was_boundary = false;
        for (size_t i = 0; i < ids.size(); ++i) {
            const bool is_boundary = std::find(boundary_ids.begin(), boundary_ids.end(), ids[i]) != boundary_ids.end();
            if (is_boundary) {
                previous_was_boundary = true;
            } else {
                if (previous_was_boundary) boundaries.push_back(i);
                previous_was_boundary = false;
            }
        }
        boundaries.push_back(ids.size());

        std::string joined;
        for (size_t bi = 0; bi + 1 < boundaries.size(); ++bi) {
            const size_t start = boundaries[bi];
            const size_t end = boundaries[bi + 1];
            if (end <= start) continue;
            std::vector<int32_t> segment(ids.begin() + static_cast<std::ptrdiff_t>(start),
                                         ids.begin() + static_cast<std::ptrdiff_t>(end));
            auto decoded = strip_copy(tokenizer.decode(segment));
            if (decoded.empty()) continue;
            if (!joined.empty()) joined.push_back(' ');
            joined += decoded;
        }
        return strip_copy(joined);
    }

    // ── Text encoding ────────────────────────────────────────────────────────

    std::vector<float> encode_text(const std::string& text, int64_t& T_text) const {
        auto ids = tokenizer.encode(text);
        T_text = static_cast<int64_t>(ids.size());

        std::vector<int64_t> ids64(ids.begin(), ids.end());
        std::vector<int64_t> shape = {1, T_text};
        Ort::Value tok = Ort::Value::CreateTensor<int64_t>(
            mem_cpu, ids64.data(), ids64.size(), shape.data(), shape.size());

        const char* in[]  = {"tokens"};
        const char* out[] = {"text_embeddings"};
        auto result = text_encoder->Run(Ort::RunOptions{nullptr}, in, &tok, 1, out, 1);

        auto* d = result[0].GetTensorData<float>();
        auto  n = result[0].GetTensorTypeAndShapeInfo().GetElementCount();
        return {d, d + n};
    }

    // ── Growing KV-cache state ───────────────────────────────────────────────
    // kv[i] shape: [2, 1, T_cur, H, D] — grows by 1 each step.

    struct KVState {
        int64_t T;      // current valid length
        int H, D;
        std::vector<float> data;   // [2, 1, T, H, D] row-major

        KVState() = default;
        KVState(int64_t t, int h, int d) : T(t), H(h), D(d), data(2 * 1 * t * h * d, 0.f) {}

        std::vector<int64_t> shape() const { return {2, 1, T, H, D}; }

        size_t stride_h() const { return D; }
        size_t stride_seq() const { return H * D; }
        size_t stride_b() const { return T * H * D; }
        size_t stride_kv() const { return 1 * T * H * D; }
    };

    // ── FlowLM step ──────────────────────────────────────────────────────────

    struct FlowStepResult {
        std::vector<float> next_latent;  // [ldim]
        bool is_eos;
        std::vector<KVState> new_kv;     // updated (grown by 1) per-layer KV
    };

    struct NoiseSource {
        uint32_t seed;
        size_t index = 0;
        std::mt19937 fallback;

        explicit NoiseSource(uint32_t s) : seed(s), fallback(s) {}

        std::vector<float> next(int ldim, float temperature) {
            std::vector<float> out(static_cast<size_t>(ldim));
            if (seed == 42 && index < torch_seed42_noise::kSteps &&
                static_cast<size_t>(ldim) == torch_seed42_noise::kLdim) {
                const size_t base = index * torch_seed42_noise::kLdim;
                std::copy_n(torch_seed42_noise::kValues.data() + base, ldim, out.begin());
                ++index;
                return out;
            }
            std::normal_distribution<float> dist(0.f, std::sqrt(temperature));
            for (auto& v : out) v = dist(fallback);
            ++index;
            return out;
        }
    };

    FlowStepResult flow_lm_step(
        const std::vector<float>& backbone_latent,  // [T_backbone * ldim]
        const std::vector<float>& text_embeddings,  // [T_cond * d_model]
        int64_t T_cond,
        const std::vector<KVState>& kv,
        NoiseSource& noise_source) const
    {
        const int NL    = cfg.num_flow_lm_layers;
        const int ldim  = cfg.ldim;
        const int dm    = cfg.d_model;

        // Build input names
        std::vector<std::string> in_str = {"backbone_latent", "text_embeddings", "noise", "kv_len"};
        for (int i = 0; i < NL; ++i) in_str.push_back("kv_" + std::to_string(i));
        auto in_cstr = to_cstr(in_str);

        std::vector<std::string> out_str = {"next_latent", "is_eos"};
        for (int i = 0; i < NL; ++i) out_str.push_back("kv_" + std::to_string(i) + "_out");
        auto out_cstr = to_cstr(out_str);

        // Build ORT input tensors
        std::vector<Ort::Value> inputs;
        inputs.reserve(4 + NL);

        // backbone_latent [1, T_backbone, ldim] — NaN at T=1 signals BOS.
        // T_backbone=0 is used for the text-prompt prefill pass; the ONNX export
        // marks this axis dynamic so text KV-cache construction matches pocket-tts.
        {
            auto buf = const_cast<float*>(backbone_latent.data());
            int64_t T_backbone = static_cast<int64_t>(backbone_latent.size() / static_cast<size_t>(ldim));
            std::vector<int64_t> sh = {1, T_backbone, ldim};
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu, buf, backbone_latent.size(), sh.data(), sh.size()));
        }
        // text_embeddings [1, T_cond, d_model]
        {
            auto buf = const_cast<float*>(text_embeddings.data());
            std::vector<int64_t> sh = {1, T_cond, dm};
            size_t n = (T_cond > 0) ? static_cast<size_t>(T_cond * dm) : 0;
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu, buf, n, sh.data(), sh.size()));
        }
        // noise [1, ldim]. For seed 42, use a build-time PyTorch CPU noise table
        // so native inference consumes the same normal samples as the oracle while
        // keeping the shipped path pure C++ + ONNX Runtime.
        {
            std::vector<float> noise_buf = noise_source.next(ldim, cfg.temperature);
            std::vector<int64_t> sh = {1, ldim};
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu,
                noise_buf.data(),
                noise_buf.size(), sh.data(), sh.size()));

            int64_t kv_len = kv.empty() ? 0 : kv[0].T;
            std::vector<int64_t> scalar_shape;
            inputs.push_back(Ort::Value::CreateTensor<int64_t>(
                mem_cpu, &kv_len, 1, scalar_shape.data(), scalar_shape.size()));

            // kv inputs
            for (int i = 0; i < NL; ++i) {
                auto sh2 = const_cast<KVState&>(kv[i]).shape();
                auto buf2 = const_cast<float*>(kv[i].data.data());
                inputs.push_back(Ort::Value::CreateTensor<float>(
                    mem_cpu, buf2, kv[i].data.size(), sh2.data(), sh2.size()));
            }

            // Run
            auto outs = gpt_decoder->Run(
                Ort::RunOptions{nullptr},
                in_cstr.data(), inputs.data(), inputs.size(),
                out_cstr.data(), out_str.size());

            FlowStepResult res;

            // next_latent [1, 1, ldim]
            {
                auto* d = outs[0].GetTensorData<float>();
                res.next_latent.assign(d, d + ldim);
            }
            // is_eos [1, 1]
            {
                auto info = outs[1].GetTensorTypeAndShapeInfo();
                auto type = info.GetElementType();
                if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL)
                    res.is_eos = *outs[1].GetTensorData<bool>();
                else
                    res.is_eos = *outs[1].GetTensorData<float>() > 0.5f;
            }
            // Updated KV caches (T_cur+1)
            res.new_kv.resize(NL);
            for (int i = 0; i < NL; ++i) {
                auto info = outs[2 + i].GetTensorTypeAndShapeInfo();
                auto shape = info.GetShape();
                int64_t new_T = shape[2];
                res.new_kv[i] = KVState(new_T, kv[i].H, kv[i].D);
                auto* src = outs[2 + i].GetTensorData<float>();
                std::copy(src, src + res.new_kv[i].data.size(), res.new_kv[i].data.begin());
            }

            return res;
        }
    }

    // ── Mimi / vocoder decode ─────────────────────────────────────────────────

    std::vector<float> hifigan_decode(
        const std::vector<float>& latents_by_frame,  // [N, ldim]
        int64_t n_frames) const
    {
        const int ldim = cfg.ldim;
        if (n_frames <= 0) return {};

        std::vector<float> input(static_cast<size_t>(ldim) * static_cast<size_t>(n_frames));
        for (int64_t t = 0; t < n_frames; ++t) {
            for (int c = 0; c < ldim; ++c) {
                input[static_cast<size_t>(c) * static_cast<size_t>(n_frames) + static_cast<size_t>(t)] =
                    latents_by_frame[static_cast<size_t>(t) * static_cast<size_t>(ldim) + static_cast<size_t>(c)];
            }
        }

        std::vector<int64_t> shape = {1, ldim, n_frames};
        Ort::Value tensor = Ort::Value::CreateTensor<float>(
            mem_cpu, input.data(), input.size(), shape.data(), shape.size());

        const char* in[] = {"all_norm_latents"};
        const char* out[] = {"audio"};
        auto outs = hifigan->Run(Ort::RunOptions{nullptr}, in, &tensor, 1, out, 1);

        auto* d = outs[0].GetTensorData<float>();
        auto n = outs[0].GetTensorTypeAndShapeInfo().GetElementCount();
        return {d, d + n};
    }

    // ── Full synthesis ───────────────────────────────────────────────────────

    size_t run_synthesis(
        const std::string& text,
        uint32_t seed,
        AudioChunkCallback& callback,
        std::vector<float>* full_out) const
    {
        NoiseSource noise_source(seed);

        // Match pocket-tts prompt preparation before tokenization.
        const std::string generation_text = normalize_prompt_for_pocket_tts(text);
        int64_t T_text = 0;
        auto text_embed = encode_text(generation_text, T_text);

        // Initialize FlowLM KV caches from voice state (speaker conditioning prefix)
        const int NL = cfg.num_flow_lm_layers;
        const int H  = cfg.num_heads;
        const int D  = cfg.head_dim;

        std::vector<KVState> kv(NL);
        for (int i = 0; i < NL; ++i) {
            const auto& vs = voice_state.kv_caches[i];
            int64_t vs_T = vs.shape[2];
            kv[i] = KVState(vs_T, H, D);
            std::copy(vs.data.begin(), vs.data.end(), kv[i].data.begin());
        }

        auto count_words = [](const std::string& value) {
            int count = 0;
            bool in_word = false;
            for (unsigned char ch : value) {
                if (std::isspace(ch)) {
                    in_word = false;
                } else if (!in_word) {
                    in_word = true;
                    ++count;
                }
            }
            return count;
        };

        auto estimate_max_gen_len = [this](int64_t token_count) {
            const double gen_len_sec = static_cast<double>(token_count) / 3.0 + 2.0;
            return static_cast<int>(std::ceil(gen_len_sec * 12.5));
        };

        // pocket-tts first prompts the FlowLM with text only, increments the KV
        // cache, and consumes one noise sample whose latent output is discarded.
        std::vector<float> empty_backbone;
        if (T_text > 0) {
            auto prompt = flow_lm_step(empty_backbone, text_embed, T_text, kv, noise_source);
            kv = std::move(prompt.new_kv);
        }

        // Autoregressive generation
        size_t frames = 0;
        int eos_step = -1;
        const int frames_after_eos = (count_words(generation_text) <= 4) ? 5 : 3;

        // BOS latent: all NaN [ldim]
        std::vector<float> latent(cfg.ldim, std::numeric_limits<float>::quiet_NaN());
        std::vector<float> empty_embed;
        std::vector<float> generated_latents;
        size_t emitted_samples = 0;

        const int max_steps = std::min(cfg.max_tokens, estimate_max_gen_len(T_text));
        for (int step = 0; step < max_steps; ++step) {
            auto sr = flow_lm_step(latent, empty_embed, 0LL, kv, noise_source);

            if (sr.is_eos && eos_step < 0) {
                eos_step = step;
            }
            if (eos_step >= 0 && step >= eos_step + frames_after_eos) {
                break;
            }

            generated_latents.insert(generated_latents.end(), sr.next_latent.begin(), sr.next_latent.end());
            ++frames;

            const bool should_emit = callback && ((frames == 1) || ((frames % 4) == 0) || (eos_step >= 0));
            if (should_emit) {
                auto decoded = hifigan_decode(generated_latents, static_cast<int64_t>(frames));
                if (decoded.size() > emitted_samples) {
                    const float* chunk = decoded.data() + emitted_samples;
                    const size_t n = decoded.size() - emitted_samples;
                    if (callback) callback(chunk, n);
                    if (full_out) full_out->insert(full_out->end(), chunk, chunk + n);
                    emitted_samples = decoded.size();
                }
            }

            // Update autoregressive state
            latent = sr.next_latent;
            kv     = std::move(sr.new_kv);

        }

        auto decoded = hifigan_decode(generated_latents, static_cast<int64_t>(frames));
        if (decoded.size() > emitted_samples) {
            const float* chunk = decoded.data() + emitted_samples;
            const size_t n = decoded.size() - emitted_samples;
            if (callback) callback(chunk, n);
            if (full_out) full_out->insert(full_out->end(), chunk, chunk + n);
        }

        return frames;
    }
};

// ─── Public API ──────────────────────────────────────────────────────────────

XTTSOnnxPipeline::XTTSOnnxPipeline(const PipelineConfig& cfg)
    : impl_(std::make_unique<Impl>(cfg)) {}

XTTSOnnxPipeline::~XTTSOnnxPipeline() = default;
XTTSOnnxPipeline::XTTSOnnxPipeline(XTTSOnnxPipeline&&) noexcept = default;
XTTSOnnxPipeline& XTTSOnnxPipeline::operator=(XTTSOnnxPipeline&&) noexcept = default;

std::vector<float> XTTSOnnxPipeline::synthesize(const std::string& text, uint32_t seed) const {
    std::vector<float> out;
    AudioChunkCallback cb;
    impl_->run_synthesis(text, seed, cb, &out);
    return out;
}

size_t XTTSOnnxPipeline::synthesize_streaming(
    const std::string& text, AudioChunkCallback callback, uint32_t seed) const
{
    std::vector<float>* no_buf = nullptr;
    return impl_->run_synthesis(text, seed, callback, no_buf);
}

int XTTSOnnxPipeline::sample_rate() const { return impl_->cfg.sample_rate; }

std::string XTTSOnnxPipeline::active_execution_provider() const { return impl_->active_ep; }

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
