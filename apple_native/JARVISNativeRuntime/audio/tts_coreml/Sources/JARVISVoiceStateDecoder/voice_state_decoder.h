#pragma once
// voice_state_decoder.h — Load jarvis_voice_state.safetensors (or pre-baked .bin)
// for the FlowLM KV-cache speaker conditioning.
//
// The .bin produced by tools/embed_voice_state.py is a flat layer-major float32
// binary. This header + .cpp provides a pure C++ loader (no Python at runtime).
//
// Format:
//   For each layer l in 0..(num_layers-1):
//     float32[2 * 1 * seq_len * num_heads * head_dim]
//   i.e. shape [2, 1, seq_len, num_heads, head_dim] = [2, 1, 939, 16, 64]
//
// The loader returns a VoiceState struct with per-layer slices.

#ifndef JARVIS_VOICE_STATE_DECODER_H
#define JARVIS_VOICE_STATE_DECODER_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace jarvis {

struct VoiceStateLayer {
    int layer_idx = 0;
    // KV cache: [2 (k/v), 1 (batch), seq_len, num_heads, head_dim]
    std::vector<float> cache;  // flat float32
    int kv_dim     = 2;
    int batch_dim  = 1;
    int seq_len    = 0;
    int num_heads  = 0;
    int head_dim   = 0;
    int offset     = 0;  // number of valid tokens (= seq_len for a full voice prompt)

    size_t floats() const noexcept {
        return (size_t)kv_dim * batch_dim * seq_len * num_heads * head_dim;
    }
};

struct VoiceState {
    int num_layers = 0;
    std::vector<VoiceStateLayer> layers;
    bool valid() const noexcept { return num_layers > 0 && !layers.empty(); }
};

/// Load a pre-baked voice state .bin + .json pair produced by embed_voice_state.py.
/// @param bin_path   Path to voice_state.bin
/// @param json_path  Path to voice_state.json (shape metadata)
/// @return VoiceState (valid() == true on success)
VoiceState load_voice_state_bin(const std::string& bin_path, const std::string& json_path);

/// Load directly from a safetensors file (no Python required — hand-parsed).
/// Supports only the simple no-encryption safetensors format (pocket-tts output).
/// @param st_path   Path to jarvis_voice_state.safetensors
/// @return VoiceState (valid() == true on success)
VoiceState load_voice_state_safetensors(const std::string& st_path);

} // namespace jarvis

#endif // JARVIS_VOICE_STATE_DECODER_H
