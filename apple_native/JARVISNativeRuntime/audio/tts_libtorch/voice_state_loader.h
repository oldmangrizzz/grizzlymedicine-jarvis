#pragma once
/**
 * voice_state_loader.h
 *
 * VoiceState: holds the per-layer KV caches and offsets from a loaded
 * pocket-tts voice state .safetensors file.
 */

#include <string>
#include <vector>
#include <torch/torch.h>

namespace jarvis::tts {

struct VoiceState {
    // kv_caches[i] has shape [2, 1, S_max, H, Dh]
    // Index 0 = keys, index 1 = values.
    std::vector<torch::Tensor> kv_caches;

    // offsets[i] is the number of valid positions in kv_caches[i].
    // Shape: [num_layers] int64.
    torch::Tensor offsets;

    // Convenience metadata
    int num_layers = 0;
    int voice_prompt_len = 0;

    /**
     * Load voice state from a pocket-tts .safetensors file.
     * The file must have been exported via pocket_tts.models.tts_model.export_model_state().
     */
    static VoiceState load(const std::string& safetensors_path,
                           torch::Device device = torch::kCPU);

    /**
     * Return a copy of this VoiceState with KV caches extended by extra_capacity
     * NaN-padded frames.  Use this before generation to preallocate space for
     * the text tokens + generated latents.
     */
    VoiceState expand_for_generation(int extra_capacity) const;

    bool is_valid() const { return !kv_caches.empty() && offsets.defined(); }
};

} // namespace jarvis::tts
