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
#include "voice_integrity.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(__APPLE__)
#  include <coreml_provider_factory.h>
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
#if defined(__APPLE__)
        if (c.execution_provider == "auto" || c.execution_provider == "coreml") {
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

    FlowStepResult flow_lm_step(
        const std::vector<float>& backbone_latent,  // [ldim]
        const std::vector<float>& text_embeddings,  // [T_cond * d_model]
        int64_t T_cond,
        const std::vector<KVState>& kv,
        std::mt19937& rng) const
    {
        const int NL    = cfg.num_flow_lm_layers;
        const int ldim  = cfg.ldim;
        const int dm    = cfg.d_model;

        // Build input names
        std::vector<std::string> in_str = {"backbone_latent", "text_embeddings", "noise"};
        for (int i = 0; i < NL; ++i) in_str.push_back("kv_" + std::to_string(i));
        auto in_cstr = to_cstr(in_str);

        std::vector<std::string> out_str = {"next_latent", "is_eos"};
        for (int i = 0; i < NL; ++i) out_str.push_back("kv_" + std::to_string(i) + "_out");
        auto out_cstr = to_cstr(out_str);

        // Build ORT input tensors
        std::vector<Ort::Value> inputs;
        inputs.reserve(3 + NL);

        // backbone_latent [1, 1, ldim] — NaN = BOS
        {
            auto buf = const_cast<float*>(backbone_latent.data());
            std::vector<int64_t> sh = {1, 1, ldim};
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu, buf, ldim, sh.data(), sh.size()));
        }
        // text_embeddings [1, T_cond, d_model]
        {
            auto buf = const_cast<float*>(text_embeddings.data());
            std::vector<int64_t> sh = {1, T_cond, dm};
            size_t n = (T_cond > 0) ? static_cast<size_t>(T_cond * dm) : 0;
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu, buf, n, sh.data(), sh.size()));
        }
        // noise [1, ldim] — sampled by caller
        {
            std::normal_distribution<float> dist(0.f, std::sqrt(cfg.temperature));
            std::vector<float> noise_buf(ldim);
            for (auto& v : noise_buf) v = dist(rng);
            std::vector<int64_t> sh = {1, ldim};
            // We need to keep noise_buf alive for the duration of the Run call.
            // Use a thread-local buffer or copy into a persistent vector.
            // For simplicity, use a local and rely on CreateTensor pointing into it.
            // (ORT copies data when building the actual run inputs)
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu,
                const_cast<float*>(noise_buf.data()),
                noise_buf.size(), sh.data(), sh.size()));

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

    // ── Mimi decode step ─────────────────────────────────────────────────────

    struct MimiStepResult {
        std::vector<float> audio;        // mono float32 samples
        std::vector<KVState> new_kv;
    };

    MimiStepResult mimi_decode_step(
        const std::vector<float>& normalized_latent,  // [ldim]
        const std::vector<KVState>& mkv) const
    {
        const int NDL  = cfg.num_mimi_dec_layers;
        const int ldim = cfg.ldim;

        std::vector<std::string> in_str = {"normalized_latent"};
        for (int i = 0; i < NDL; ++i) in_str.push_back("mimi_kv_" + std::to_string(i));
        auto in_cstr = to_cstr(in_str);

        std::vector<std::string> out_str = {"audio_frame"};
        for (int i = 0; i < NDL; ++i) out_str.push_back("mimi_kv_" + std::to_string(i) + "_out");
        auto out_cstr = to_cstr(out_str);

        std::vector<Ort::Value> inputs;
        inputs.reserve(1 + NDL);

        // normalized_latent [1, 1, ldim]
        {
            auto buf = const_cast<float*>(normalized_latent.data());
            std::vector<int64_t> sh = {1, 1, ldim};
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu, buf, ldim, sh.data(), sh.size()));
        }
        for (int i = 0; i < NDL; ++i) {
            auto sh = const_cast<KVState&>(mkv[i]).shape();
            auto buf = const_cast<float*>(mkv[i].data.data());
            inputs.push_back(Ort::Value::CreateTensor<float>(
                mem_cpu, buf, mkv[i].data.size(), sh.data(), sh.size()));
        }

        auto outs = hifigan->Run(
            Ort::RunOptions{nullptr},
            in_cstr.data(), inputs.data(), inputs.size(),
            out_cstr.data(), out_str.size());

        MimiStepResult res;

        // audio_frame [1, 1, S]
        {
            auto* d = outs[0].GetTensorData<float>();
            auto  n = outs[0].GetTensorTypeAndShapeInfo().GetElementCount();
            res.audio.assign(d, d + n);
        }
        // Updated Mimi KV caches
        res.new_kv.resize(NDL);
        for (int i = 0; i < NDL; ++i) {
            auto info  = outs[1 + i].GetTensorTypeAndShapeInfo();
            auto shape = info.GetShape();
            int64_t new_T = shape[2];
            res.new_kv[i] = KVState(new_T, mkv[i].H, mkv[i].D);
            auto* src = outs[1 + i].GetTensorData<float>();
            std::copy(src, src + res.new_kv[i].data.size(), res.new_kv[i].data.begin());
        }
        return res;
    }

    // ── Full synthesis ───────────────────────────────────────────────────────

    size_t run_synthesis(
        const std::string& text,
        uint32_t seed,
        AudioChunkCallback& callback,
        std::vector<float>* full_out) const
    {
        std::mt19937 rng(seed);

        // Tokenize + encode text
        int64_t T_text = 0;
        auto text_embed = encode_text(text, T_text);

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

        // Initialize Mimi KV caches (empty — start fresh each synthesis)
        const int NDL   = cfg.num_mimi_dec_layers;
        const int H_mim = cfg.mimi_dec_heads;
        const int D_mim = cfg.mimi_dec_head_dim;
        std::vector<KVState> mkv(NDL);
        for (int i = 0; i < NDL; ++i) {
            mkv[i] = KVState(0, H_mim, D_mim);
        }

        // Autoregressive generation
        size_t frames = 0;
        int eos_count = 0;
        int max_eos   = 3;
        bool eos_seen = false;

        // BOS latent: all NaN [ldim]
        std::vector<float> latent(cfg.ldim, std::numeric_limits<float>::quiet_NaN());

        // First step: inject text embeddings as conditioning prefix
        // Subsequent steps: empty conditioning (voice KV cache prefix covers speaker)
        bool first = true;

        for (int step = 0; step < cfg.max_tokens; ++step) {
            const auto& te_input  = first ? text_embed : std::vector<float>{};
            int64_t     T_cond    = first ? T_text : 0LL;
            first = false;

            auto sr = flow_lm_step(latent, te_input, T_cond, kv, rng);

            if (sr.is_eos && !eos_seen) {
                eos_seen = true;
                // Heuristic: 1–3 frames after EOS based on text length
                max_eos = std::clamp(static_cast<int>(T_text) / 10 + 1, 1, 3);
            }

            // Decode latent → audio
            auto mr = mimi_decode_step(sr.next_latent, mkv);
            ++frames;

            if (callback) callback(mr.audio.data(), mr.audio.size());
            if (full_out) full_out->insert(full_out->end(), mr.audio.begin(), mr.audio.end());

            // Update states
            latent = sr.next_latent;
            kv     = std::move(sr.new_kv);
            mkv    = std::move(mr.new_kv);

            if (eos_seen) {
                ++eos_count;
                if (eos_count >= max_eos) break;
            }
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
