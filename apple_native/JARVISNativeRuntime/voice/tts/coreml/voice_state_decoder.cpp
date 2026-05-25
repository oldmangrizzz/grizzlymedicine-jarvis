// voice_state_decoder.cpp — Load JARVIS voice state (safetensors or pre-baked .bin)
//
// Implements a minimal safetensors parser (header-only JSON + flat tensor data)
// and a .bin loader for the pre-baked voice state.

#include "voice_state_decoder.h"

#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>

// Minimal JSON integer/array extractor (no full JSON library dependency)
namespace {

// Extract integer value for "key": <int> from JSON string
int64_t json_int(const std::string& json, const std::string& key) {
    auto pos = json.find("\"" + key + "\"");
    if (pos == std::string::npos) throw std::runtime_error("key not found: " + key);
    pos = json.find(":", pos);
    if (pos == std::string::npos) throw std::runtime_error("no colon after: " + key);
    ++pos;
    while (pos < json.size() && std::isspace(json[pos])) ++pos;
    bool neg = json[pos] == '-';
    if (neg) ++pos;
    int64_t val = 0;
    while (pos < json.size() && std::isdigit(json[pos]))
        val = val * 10 + (json[pos++] - '0');
    return neg ? -val : val;
}

// Extract string value for "key": "val"
std::string json_str(const std::string& json, const std::string& key) {
    auto pos = json.find("\"" + key + "\"");
    if (pos == std::string::npos) throw std::runtime_error("key not found: " + key);
    pos = json.find("\"", json.find(":", pos) + 1);
    if (pos == std::string::npos) throw std::runtime_error("no string value for: " + key);
    ++pos;
    auto end = json.find("\"", pos);
    return json.substr(pos, end - pos);
}

// Extract array of ints for "key": [a, b, c, ...]
std::vector<int64_t> json_int_array(const std::string& json, const std::string& key) {
    auto pos = json.find("\"" + key + "\"");
    if (pos == std::string::npos) return {};
    pos = json.find("[", json.find(":", pos));
    if (pos == std::string::npos) return {};
    auto end = json.find("]", pos);
    std::string arr_str = json.substr(pos + 1, end - pos - 1);
    std::vector<int64_t> result;
    std::regex re(R"(-?\d+)");
    auto it = std::sregex_iterator(arr_str.begin(), arr_str.end(), re);
    for (; it != std::sregex_iterator(); ++it)
        result.push_back(std::stoll(it->str()));
    return result;
}

} // namespace

namespace jarvis {

// ---------------------------------------------------------------------------
// Load from pre-baked .bin + .json
// ---------------------------------------------------------------------------
VoiceState load_voice_state_bin(const std::string& bin_path, const std::string& json_path) {
    // Read JSON metadata
    std::ifstream jf(json_path);
    if (!jf) throw std::runtime_error("Cannot open voice_state.json: " + json_path);
    std::string json_str_val((std::istreambuf_iterator<char>(jf)),
                             std::istreambuf_iterator<char>());

    int num_layers = static_cast<int>(json_int(json_str_val, "num_layers"));

    // Read binary data
    std::ifstream bf(bin_path, std::ios::binary);
    if (!bf) throw std::runtime_error("Cannot open voice_state.bin: " + bin_path);
    bf.seekg(0, std::ios::end);
    size_t file_bytes = static_cast<size_t>(bf.tellg());
    bf.seekg(0, std::ios::beg);
    std::vector<float> data(file_bytes / sizeof(float));
    bf.read(reinterpret_cast<char*>(data.data()), file_bytes);

    VoiceState vs;
    vs.num_layers = num_layers;

    // Parse layer shapes from the "layers" array in JSON
    // Pattern: "cache_shape": [2, 1, 939, 16, 64]
    size_t offset_float = 0;
    for (int l = 0; l < num_layers; ++l) {
        // Find the l-th "layer": N object
        // Simple approach: find "\"layer\": <l>" context
        std::string layer_search = "\"layer\": " + std::to_string(l);
        auto pos = json_str_val.find(layer_search);
        if (pos == std::string::npos)
            throw std::runtime_error("layer " + std::to_string(l) + " not found in JSON");

        // Find cache_shape after this position
        auto cs_pos = json_str_val.find("\"cache_shape\"", pos);
        auto cs_end = json_str_val.find("]", cs_pos);
        std::string cs_str = json_str_val.substr(cs_pos, cs_end - cs_pos + 1);
        auto shape = json_int_array(cs_str, "cache_shape");

        if (shape.size() != 5)
            throw std::runtime_error("Expected 5-D cache shape for layer " + std::to_string(l));

        VoiceStateLayer layer;
        layer.layer_idx = l;
        layer.kv_dim    = static_cast<int>(shape[0]);  // 2
        layer.batch_dim = static_cast<int>(shape[1]);  // 1
        layer.seq_len   = static_cast<int>(shape[2]);  // 939
        layer.num_heads = static_cast<int>(shape[3]);  // 16
        layer.head_dim  = static_cast<int>(shape[4]);  // 64
        layer.offset    = layer.seq_len;               // all tokens valid

        size_t n_floats = layer.floats();
        if (offset_float + n_floats > data.size())
            throw std::runtime_error("Binary file too short at layer " + std::to_string(l));

        layer.cache.assign(
            data.data() + offset_float,
            data.data() + offset_float + n_floats
        );
        offset_float += n_floats;
        vs.layers.push_back(std::move(layer));
    }

    return vs;
}

// ---------------------------------------------------------------------------
// Minimal safetensors parser
//
// safetensors format (https://github.com/huggingface/safetensors):
//   [8 bytes LE: header_len]
//   [header_len bytes: JSON header]
//   [tensor data ...]
//
// JSON header maps tensor name -> {"dtype": "F32", "shape": [...], "data_offsets": [start, end]}
// ---------------------------------------------------------------------------
VoiceState load_voice_state_safetensors(const std::string& st_path) {
    std::ifstream f(st_path, std::ios::binary);
    if (!f) throw std::runtime_error("Cannot open safetensors: " + st_path);

    // Read header length (8-byte LE uint64)
    uint64_t header_len = 0;
    f.read(reinterpret_cast<char*>(&header_len), 8);

    // Read header JSON
    std::string header_json(header_len, '\0');
    f.read(header_json.data(), header_len);

    // Data starts at offset 8 + header_len
    size_t data_start = 8 + header_len;

    VoiceState vs;

    // Parse each layer
    // Keys: "transformer.layers.N.self_attn/cache" and ".../offset"
    for (int l = 0; ; ++l) {
        std::string cache_key = "transformer.layers." + std::to_string(l) + ".self_attn/cache";
        if (header_json.find("\"" + cache_key + "\"") == std::string::npos)
            break;

        // Find the entry object for this key
        auto key_pos = header_json.find("\"" + cache_key + "\"");
        auto obj_start = header_json.find("{", key_pos);
        auto obj_end   = header_json.find("}", obj_start);
        std::string obj = header_json.substr(obj_start, obj_end - obj_start + 1);

        // Parse shape
        auto shape = json_int_array(obj, "shape");
        if (shape.size() != 5)
            throw std::runtime_error("Expected 5-D cache shape at layer " + std::to_string(l));

        // Parse data_offsets
        auto do_pos = obj.find("\"data_offsets\"");
        auto do_arr = obj.substr(do_pos);
        auto offsets_vec = json_int_array(do_arr, "data_offsets");
        if (offsets_vec.size() < 2)
            throw std::runtime_error("data_offsets missing for layer " + std::to_string(l));

        size_t byte_start = data_start + static_cast<size_t>(offsets_vec[0]);
        size_t byte_end   = data_start + static_cast<size_t>(offsets_vec[1]);
        size_t n_bytes    = byte_end - byte_start;
        size_t n_floats   = n_bytes / sizeof(float);

        VoiceStateLayer layer;
        layer.layer_idx = l;
        layer.kv_dim    = static_cast<int>(shape[0]);
        layer.batch_dim = static_cast<int>(shape[1]);
        layer.seq_len   = static_cast<int>(shape[2]);
        layer.num_heads = static_cast<int>(shape[3]);
        layer.head_dim  = static_cast<int>(shape[4]);
        layer.offset    = layer.seq_len;

        layer.cache.resize(n_floats);
        f.seekg(byte_start, std::ios::beg);
        f.read(reinterpret_cast<char*>(layer.cache.data()), n_bytes);

        vs.layers.push_back(std::move(layer));
    }

    vs.num_layers = static_cast<int>(vs.layers.size());
    return vs;
}

} // namespace jarvis
