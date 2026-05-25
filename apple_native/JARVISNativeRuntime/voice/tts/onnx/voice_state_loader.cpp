/**
 * voice_state_loader.cpp — Load pocket-tts voice state from safetensors.
 *
 * The voice state file (jarvis_voice_state.safetensors, ~46 MB) contains
 * pre-computed KV-cache tensors for the speaker conditioning:
 *
 *   Key format: "transformer.layers.N.self_attn/cache"  shape [2,1,939,16,64] float32
 *               "transformer.layers.N.self_attn/offset" shape [1]              int64
 *
 * This loader parses the safetensors format (header + raw data), validates
 * tensor shapes and dtypes, and returns them as flat float32/int64 buffers
 * ready to feed into the ORT session.
 *
 * Safetensors format (https://huggingface.co/docs/safetensors):
 *   [8 bytes: uint64 header_len LE]
 *   [header_len bytes: UTF-8 JSON]
 *   [tensor data]
 */

#include "voice_state_loader.h"

#include <cassert>
#include <cstring>
#include <fstream>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <string>
#include <vector>

namespace jarvis {
namespace tts {
namespace onnx {

// ─── Safetensors parser ──────────────────────────────────────────────────────

struct SafetensorEntry {
    std::string dtype;              // "F32", "I64", etc.
    std::vector<int64_t> shape;
    size_t data_offset_begin;
    size_t data_offset_end;
};

static std::unordered_map<std::string, SafetensorEntry>
parse_safetensors_header(const std::string& path, std::vector<uint8_t>& raw_data)
{
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        throw std::runtime_error("VoiceStateLoader: cannot open '" + path + "'");
    }

    // Read 8-byte header length
    uint64_t header_len = 0;
    f.read(reinterpret_cast<char*>(&header_len), 8);
    if (!f || header_len == 0 || header_len > 100 * 1024 * 1024) {
        throw std::runtime_error("VoiceStateLoader: invalid safetensors header length");
    }

    // Read JSON header
    std::string header_json(header_len, '\0');
    f.read(header_json.data(), header_len);
    if (!f) {
        throw std::runtime_error("VoiceStateLoader: failed to read JSON header");
    }

    // Read remaining data
    size_t data_start = 8 + header_len;
    f.seekg(0, std::ios::end);
    size_t file_size = f.tellg();
    size_t data_size = file_size - data_start;
    raw_data.resize(data_size);
    f.seekg(data_start, std::ios::beg);
    f.read(reinterpret_cast<char*>(raw_data.data()), data_size);
    if (!f) {
        throw std::runtime_error("VoiceStateLoader: failed to read tensor data");
    }

    // Parse JSON
    auto j = nlohmann::json::parse(header_json);

    std::unordered_map<std::string, SafetensorEntry> entries;
    for (auto& [key, val] : j.items()) {
        if (key == "__metadata__") continue;
        SafetensorEntry e;
        e.dtype = val["dtype"].get<std::string>();
        e.shape = val["shape"].get<std::vector<int64_t>>();
        auto offsets = val["data_offsets"].get<std::vector<size_t>>();
        e.data_offset_begin = offsets[0];
        e.data_offset_end   = offsets[1];
        entries[key] = std::move(e);
    }
    return entries;
}

// ─── Public API ──────────────────────────────────────────────────────────────

VoiceState load_voice_state(const std::string& safetensors_path, int expected_layers) {
    std::vector<uint8_t> raw;
    auto entries = parse_safetensors_header(safetensors_path, raw);

    VoiceState state;
    state.num_layers = expected_layers;
    state.kv_caches.resize(expected_layers);
    state.kv_offsets.resize(expected_layers);

    for (int layer = 0; layer < expected_layers; ++layer) {
        // Cache key
        std::string cache_key = "transformer.layers." + std::to_string(layer) + ".self_attn/cache";
        std::string offset_key = "transformer.layers." + std::to_string(layer) + ".self_attn/offset";

        auto cache_it = entries.find(cache_key);
        auto offset_it = entries.find(offset_key);

        if (cache_it == entries.end()) {
            throw std::runtime_error(
                "VoiceStateLoader: missing key '" + cache_key + "' in " + safetensors_path);
        }
        if (offset_it == entries.end()) {
            throw std::runtime_error(
                "VoiceStateLoader: missing key '" + offset_key + "' in " + safetensors_path);
        }

        // Validate dtype
        if (cache_it->second.dtype != "F32") {
            throw std::runtime_error(
                "VoiceStateLoader: cache dtype is '" + cache_it->second.dtype + "', expected F32");
        }
        if (offset_it->second.dtype != "I64") {
            throw std::runtime_error(
                "VoiceStateLoader: offset dtype is '" + offset_it->second.dtype + "', expected I64");
        }

        // Cache shape: [2, 1, T_cap, num_heads, head_dim]
        const auto& shape = cache_it->second.shape;
        if (shape.size() != 5) {
            throw std::runtime_error("VoiceStateLoader: cache shape rank != 5");
        }

        KVCacheTensor kv;
        kv.shape = {shape[0], shape[1], shape[2], shape[3], shape[4]};
        size_t n_elements = 1;
        for (auto s : shape) n_elements *= s;
        kv.data.resize(n_elements);

        const uint8_t* src = raw.data() + cache_it->second.data_offset_begin;
        std::memcpy(kv.data.data(), src, n_elements * sizeof(float));

        state.kv_caches[layer] = std::move(kv);

        // Offset scalar [1] int64
        int64_t offset_val = 0;
        std::memcpy(&offset_val,
                    raw.data() + offset_it->second.data_offset_begin,
                    sizeof(int64_t));
        state.kv_offsets[layer] = offset_val;
    }

    return state;
}

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
