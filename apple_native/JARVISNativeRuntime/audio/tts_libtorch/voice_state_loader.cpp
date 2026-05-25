/**
 * voice_state_loader.cpp
 *
 * Loads a pocket-tts voice state from a .safetensors file and reconstructs
 * it as a std::vector of per-layer KV caches and offsets ready for use
 * with the FlowLM TorchScript decoder (gpt_decoder.pt).
 *
 * safetensors key format (as written by pocket_tts.models.tts_model.export_model_state):
 *   "transformer.layers.<N>.self_attn/cache"   → Tensor [2, 1, S, 16, 64]
 *   "transformer.layers.<N>.self_attn/offset"  → Tensor [1] int64
 *
 * The loader produces:
 *   kv_caches  : std::vector<torch::Tensor>  — ordered 0..N-1 by layer index
 *   offsets    : torch::Tensor               — [N] int64, one entry per layer
 *
 * Note: the safetensors loader used here is the header-only C++17 implementation
 * The current build uses the manual safetensors parser below plus nlohmann/json.
 * No Python is used at runtime and the canonical voice state is read-only.
 *
 * Zero Python at runtime: this file links only against LibTorch and the
 * safetensors C++ header.
 */

#include "voice_state_loader.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <torch/torch.h>
#include <nlohmann/json.hpp>

// Minimal safetensors C++ header-only parser (bundled under third_party/).
// The header provides: safetensors::load(path) → map<string, Tensor>
#if __has_include(<safetensors.hpp>)
#  include <safetensors.hpp>
#else
// Fallback: manual safetensors parser below.
#  ifndef JARVIS_SAFETENSORS_FALLBACK
#    define JARVIS_SAFETENSORS_FALLBACK
#  endif
#endif

namespace jarvis::tts {

// ---------------------------------------------------------------------------
// safetensors parsing helpers (header-only implementation)
// ---------------------------------------------------------------------------

namespace {

#ifndef JARVIS_SAFETENSORS_FALLBACK

/**
 * Parse a safetensors file using the bundled header-only implementation.
 * Returns a flat map from tensor name to torch::Tensor.
 */
std::map<std::string, torch::Tensor> load_safetensors(const std::string& path) {
    auto tensors = safetensors::load(path);
    std::map<std::string, torch::Tensor> result;
    for (auto& [name, st] : tensors) {
        // Convert safetensors::Tensor to torch::Tensor
        // The header provides .dtype, .shape, .data_ptr()
        torch::ScalarType dtype;
        switch (st.dtype) {
            case safetensors::kF32:  dtype = torch::kFloat32; break;
            case safetensors::kF16:  dtype = torch::kFloat16; break;
            case safetensors::kBF16: dtype = torch::kBFloat16; break;
            case safetensors::kI64:  dtype = torch::kInt64; break;
            case safetensors::kI32:  dtype = torch::kInt32; break;
            default: throw std::runtime_error("Unsupported dtype in safetensors: " + name);
        }
        std::vector<int64_t> shape(st.shape.begin(), st.shape.end());
        auto opts = torch::TensorOptions().dtype(dtype);
        auto t = torch::from_blob(const_cast<void*>(st.data_ptr()), shape, opts).clone();
        result[name] = t;
    }
    return result;
}

#else // JARVIS_SAFETENSORS_FALLBACK

/**
 * Fallback: parse safetensors manually using the documented binary format.
 *
 * safetensors binary layout:
 *   bytes 0–7   : uint64_le  header_size
 *   bytes 8..   : UTF-8 JSON header (header_size bytes)
 *   after header: raw tensor data
 */
#include <cstring>

std::map<std::string, torch::Tensor> load_safetensors(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("Cannot open safetensors file: " + path);

    uint64_t header_size = 0;
    f.read(reinterpret_cast<char*>(&header_size), 8);
    if (!f) throw std::runtime_error("Failed to read safetensors header size");

    std::string header_json(header_size, '\0');
    f.read(header_json.data(), static_cast<std::streamsize>(header_size));
    if (!f) throw std::runtime_error("Failed to read safetensors header JSON");

    auto header = nlohmann::json::parse(header_json);

    // Read remaining data into a buffer
    const std::streampos data_start = f.tellg();
    f.seekg(0, std::ios::end);
    const std::streampos file_end = f.tellg();
    const size_t data_size = static_cast<size_t>(file_end - data_start);
    std::vector<char> data(data_size);
    f.seekg(data_start);
    f.read(data.data(), static_cast<std::streamsize>(data_size));

    static const std::map<std::string, torch::ScalarType> dtype_map = {
        {"F32",  torch::kFloat32},
        {"F16",  torch::kFloat16},
        {"BF16", torch::kBFloat16},
        {"I64",  torch::kInt64},
        {"I32",  torch::kInt32},
    };

    std::map<std::string, torch::Tensor> result;
    for (auto& [name, meta] : header.items()) {
        if (name == "__metadata__") continue;
        const std::string dtype_str = meta["dtype"].get<std::string>();
        const auto dt_it = dtype_map.find(dtype_str);
        if (dt_it == dtype_map.end())
            throw std::runtime_error("Unknown dtype '" + dtype_str + "' for tensor " + name);

        std::vector<int64_t> shape = meta["shape"].get<std::vector<int64_t>>();
        const auto& offsets = meta["data_offsets"];
        const size_t begin = offsets[0].get<size_t>();
        const size_t end   = offsets[1].get<size_t>();
        if (end < begin || end > data.size()) {
            throw std::runtime_error("Invalid data_offsets for tensor " + name);
        }

        auto opts = torch::TensorOptions().dtype(dt_it->second);
        auto t = torch::from_blob(data.data() + begin,
                                  shape,
                                  opts).clone();
        result[name] = t;
    }
    return result;
}

#endif // JARVIS_SAFETENSORS_FALLBACK

/** Parse "module.path/property" → (module_path, property_name). */
std::pair<std::string, std::string> split_key(const std::string& key) {
    const auto slash = key.rfind('/');
    if (slash == std::string::npos) return {key, "value"};
    return {key.substr(0, slash), key.substr(slash + 1)};
}

/**
 * Extract the layer index from a module path like
 * "transformer.layers.3.self_attn" → 3.
 * Returns -1 if not found.
 */
int extract_layer_index(const std::string& mod_path) {
    static const std::regex re(R"(transformer\.layers\.(\d+)\.)");
    std::smatch m;
    if (std::regex_search(mod_path, m, re)) {
        return std::stoi(m[1].str());
    }
    return -1;
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// VoiceState::load
// ---------------------------------------------------------------------------

VoiceState VoiceState::load(const std::string& safetensors_path, torch::Device device) {
    const auto flat = load_safetensors(safetensors_path);

    // Collect per-layer data
    // key → (layer_index, property_name, tensor)
    std::map<int, std::map<std::string, torch::Tensor>> per_layer;

    for (auto& [key, tensor] : flat) {
        auto [mod, prop] = split_key(key);
        int idx = extract_layer_index(mod);
        if (idx < 0) {
            // Not a transformer layer KV cache — skip or warn
            continue;
        }
        per_layer[idx][prop] = tensor.to(device);
    }

    if (per_layer.empty()) {
        throw std::runtime_error(
            "No transformer layer KV cache found in safetensors file: " + safetensors_path);
    }

    // Build ordered kv_caches and offsets
    const int num_layers = static_cast<int>(per_layer.size());
    VoiceState vs;
    vs.kv_caches.reserve(num_layers);
    std::vector<int64_t> off_vals(num_layers, 0);

    for (auto& [idx, props] : per_layer) {
        auto cache_it = props.find("cache");
        auto offset_it = props.find("offset");
        if (cache_it == props.end())
            throw std::runtime_error("Missing 'cache' for layer " + std::to_string(idx));

        vs.kv_caches.push_back(cache_it->second);  // [2, 1, S, H, Dh]
        if (offset_it != props.end()) {
            off_vals[idx] = offset_it->second.view(-1)[0].item<int64_t>();
        }
    }

    vs.offsets = torch::tensor(off_vals, torch::TensorOptions()
                                              .dtype(torch::kInt64)
                                              .device(device));
    vs.num_layers = num_layers;

    // Cache sequence length = total positions used by voice prompt
    if (!vs.kv_caches.empty()) {
        // Shape: [2, B, S_max, H, Dh] — S_max is the allocated capacity
        vs.voice_prompt_len = static_cast<int>(vs.offsets[0].item<int64_t>());
    }

    return vs;
}

VoiceState VoiceState::expand_for_generation(int extra_capacity) const {
    VoiceState expanded;
    expanded.num_layers = num_layers;
    expanded.voice_prompt_len = voice_prompt_len;

    // Build new offsets
    expanded.offsets = offsets.clone();

    for (const auto& cache : kv_caches) {
        // cache: [2, B, current_S, H, Dh]
        const int64_t current_S = cache.size(2);
        const int64_t new_S = current_S + static_cast<int64_t>(extra_capacity);

        auto new_cache = torch::full(
            {cache.size(0), cache.size(1), new_S, cache.size(3), cache.size(4)},
            std::numeric_limits<float>::quiet_NaN(),
            cache.options());
        // Copy existing data
        new_cache.slice(2, 0, current_S) = cache;
        expanded.kv_caches.push_back(std::move(new_cache));
    }
    return expanded;
}

} // namespace jarvis::tts
