#pragma once
/**
 * voice_state_loader.h — KV-cache voice state from safetensors.
 *
 * Loaded once at startup from jarvis_voice_state.safetensors.
 * The loaded tensors are injected into the ONNX session as initial
 * KV-cache inputs for each autoregressive decode step.
 */

#include <cstdint>
#include <string>
#include <vector>
#include <unordered_map>

namespace jarvis {
namespace tts {
namespace onnx {

/** One per-layer KV-cache tensor from the voice state file. */
struct KVCacheTensor {
    std::vector<int64_t> shape;   // [2, B, T_cap, H, D]
    std::vector<float>   data;    // raw float32 values, length = product(shape)
};

/** Complete voice state: one KV cache + one offset per transformer layer. */
struct VoiceState {
    int num_layers = 0;
    std::vector<KVCacheTensor> kv_caches;   // size = num_layers
    std::vector<int64_t>       kv_offsets;  // size = num_layers, scalar per layer
};

/**
 * Load voice state from a safetensors file.
 * @param safetensors_path  Path to jarvis_voice_state.safetensors
 * @param expected_layers   Expected number of FlowLM transformer layers (e.g. 6)
 */
VoiceState load_voice_state(const std::string& safetensors_path, int expected_layers = 6);

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
