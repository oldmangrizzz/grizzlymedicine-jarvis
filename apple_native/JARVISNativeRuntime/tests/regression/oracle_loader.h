/// oracle_loader.h — Generic CSV / JSONL loader for oracle traces.
///
/// Provides:
///   load_csv(path)              → vector<CsvRow>  (header-discovered schema)
///   load_jsonl(path)            → vector<JsonlRecord>  (flat string fields)
///   ndarray_from_record(r, key) → vector<float>  (decodes __ndarray__ blobs)
///
/// No external JSON library required; the loader uses a hand-rolled minimal
/// extractor sufficient for the known oracle schema (string, number, bool,
/// __ndarray__ objects).  Adding proper JSON support is a future hardening
/// concern; for now the oracle traces have a stable, predictable shape.
///
/// Thread safety: each call is independent; no shared state.
///
/// Usage:
///   #include "oracle_loader.h"
///   auto rows = jarvis::oracle::load_csv(ORACLE_DIR "/endocrine_trace.csv");
///   for (auto& r : rows) {
///       double t = r.get_double("t");
///       double cortisol = r.get_double("cortisol");
///   }
#pragma once

#include <cmath>
#include <cstdint>
#include <fstream>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <cstring>

namespace jarvis::oracle {

// ── CSV row ─────────────────────────────────────────────────────────────────

struct CsvRow {
    std::vector<std::string>       header;
    std::map<std::string, std::string> fields;

    bool has(const std::string& col) const {
        auto it = fields.find(col);
        return it != fields.end() && !it->second.empty();
    }

    std::string get(const std::string& col, const std::string& def = "") const {
        auto it = fields.find(col);
        return (it != fields.end()) ? it->second : def;
    }

    double get_double(const std::string& col,
                      double def = std::numeric_limits<double>::quiet_NaN()) const {
        auto it = fields.find(col);
        if (it == fields.end() || it->second.empty()) return def;
        try { return std::stod(it->second); }
        catch (...) { return def; }
    }

    float get_float(const std::string& col, float def = 0.f) const {
        return static_cast<float>(get_double(col, def));
    }

    long long get_int(const std::string& col, long long def = 0) const {
        auto it = fields.find(col);
        if (it == fields.end() || it->second.empty()) return def;
        try { return std::stoll(it->second); }
        catch (...) { return def; }
    }

    bool get_bool(const std::string& col, bool def = false) const {
        auto it = fields.find(col);
        if (it == fields.end() || it->second.empty()) return def;
        const auto& s = it->second;
        return s == "True" || s == "true" || s == "1";
    }
};

inline std::vector<std::string> split_csv_line(const std::string& line) {
    std::vector<std::string> out;
    std::stringstream ss(line);
    std::string tok;
    while (std::getline(ss, tok, ',')) out.push_back(tok);
    return out;
}

inline std::vector<CsvRow> load_csv(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open())
        throw std::runtime_error("oracle_loader: cannot open CSV: " + path);

    std::string line;
    if (!std::getline(f, line))
        throw std::runtime_error("oracle_loader: CSV empty: " + path);

    auto header = split_csv_line(line);
    std::vector<CsvRow> rows;

    while (std::getline(f, line)) {
        if (line.empty()) continue;
        auto vals = split_csv_line(line);
        while (vals.size() < header.size()) vals.push_back("");
        CsvRow row;
        row.header = header;
        for (size_t i = 0; i < header.size(); ++i)
            row.fields[header[i]] = vals[i];
        rows.push_back(std::move(row));
    }
    return rows;
}

// ── JSONL record ─────────────────────────────────────────────────────────────

/// Minimal flat-map representation of a JSONL record.  Scalar string/number
/// fields are stored as strings keyed by field name.  Nested objects and
/// arrays are stored verbatim under their key for downstream inspection.
struct JsonlRecord {
    std::map<std::string, std::string> fields;

    bool has(const std::string& k) const { return fields.count(k) > 0; }
    std::string get(const std::string& k, const std::string& def = "") const {
        auto it = fields.find(k);
        return (it != fields.end()) ? it->second : def;
    }
    double get_double(const std::string& k, double def = 0.0) const {
        auto it = fields.find(k);
        if (it == fields.end() || it->second.empty()) return def;
        try { return std::stod(it->second); } catch (...) { return def; }
    }
    long long get_int(const std::string& k, long long def = 0) const {
        auto it = fields.find(k);
        if (it == fields.end() || it->second.empty()) return def;
        try { return std::stoll(it->second); } catch (...) { return def; }
    }
    bool get_bool(const std::string& k, bool def = false) const {
        auto it = fields.find(k);
        if (it == fields.end()) return def;
        const auto& s = it->second;
        return s == "true" || s == "True" || s == "1";
    }
    /// Returns the raw JSON text stored under this key (useful for retval blobs).
    std::string raw(const std::string& k) const { return get(k); }
};

// ── Minimal JSON extractor ────────────────────────────────────────────────

namespace detail {

/// Skip whitespace in s starting at pos.
inline size_t skip_ws(const std::string& s, size_t pos) {
    while (pos < s.size() && (s[pos]==' '||s[pos]=='\t'||s[pos]=='\n'||s[pos]=='\r'))
        ++pos;
    return pos;
}

/// Read a JSON string value starting at pos (must point to opening '"').
/// Returns the unescaped string and the position AFTER the closing '"'.
inline std::pair<std::string, size_t> read_json_string(const std::string& s, size_t pos) {
    if (pos >= s.size() || s[pos] != '"')
        throw std::runtime_error("expected '\"' at pos " + std::to_string(pos));
    ++pos; // skip opening quote
    std::string out;
    while (pos < s.size() && s[pos] != '"') {
        if (s[pos] == '\\') {
            ++pos;
            if (pos < s.size()) {
                switch (s[pos]) {
                    case '"': out += '"'; break;
                    case '\\': out += '\\'; break;
                    case '/': out += '/'; break;
                    case 'n': out += '\n'; break;
                    case 't': out += '\t'; break;
                    case 'r': out += '\r'; break;
                    default: out += '\\'; out += s[pos]; break;
                }
                ++pos;
            }
        } else {
            out += s[pos++];
        }
    }
    if (pos < s.size() && s[pos] == '"') ++pos;
    return {out, pos};
}

/// Read a JSON value (string, number, bool, null, or nested object/array).
/// Returns the raw text and position after the value.
inline std::pair<std::string, size_t> read_json_value(const std::string& s, size_t pos) {
    pos = skip_ws(s, pos);
    if (pos >= s.size()) return {"", pos};

    if (s[pos] == '"') {
        auto [str, end] = read_json_string(s, pos);
        return {str, end};
    }
    if (s[pos] == '{' || s[pos] == '[') {
        // Return verbatim nested object / array.
        char open = s[pos], close = (open == '{') ? '}' : ']';
        int depth = 0;
        size_t start = pos;
        bool in_str = false;
        while (pos < s.size()) {
            char c = s[pos];
            if (!in_str) {
                if (c == open) ++depth;
                else if (c == close) { --depth; if (depth == 0) { ++pos; break; } }
                else if (c == '"') in_str = true;
            } else {
                if (c == '\\') { ++pos; } // skip escaped
                else if (c == '"') in_str = false;
            }
            ++pos;
        }
        return {s.substr(start, pos - start), pos};
    }
    // Number / bool / null
    size_t start = pos;
    while (pos < s.size() && s[pos] != ',' && s[pos] != '}' && s[pos] != ']'
           && s[pos] != '\n' && s[pos] != ' ')
        ++pos;
    std::string raw = s.substr(start, pos - start);
    // Strip trailing whitespace
    while (!raw.empty() && (raw.back()==' '||raw.back()=='\n'||raw.back()=='\r'))
        raw.pop_back();
    return {raw, pos};
}

/// Parse a flat JSON object (one level deep) into key→raw-value pairs.
inline std::map<std::string, std::string> parse_flat_object(const std::string& s) {
    std::map<std::string, std::string> out;
    size_t pos = skip_ws(s, 0);
    if (pos >= s.size() || s[pos] != '{') return out;
    ++pos; // skip '{'

    while (true) {
        pos = skip_ws(s, pos);
        if (pos >= s.size() || s[pos] == '}') break;
        if (s[pos] != '"') { ++pos; continue; } // skip malformed

        auto [key, kend] = read_json_string(s, pos);
        pos = skip_ws(s, kend);
        if (pos >= s.size() || s[pos] != ':') continue;
        ++pos; // skip ':'
        pos = skip_ws(s, pos);
        auto [val, vend] = read_json_value(s, pos);
        out[key] = val;
        pos = skip_ws(s, vend);
        if (pos < s.size() && s[pos] == ',') ++pos;
    }
    return out;
}

} // namespace detail

inline JsonlRecord parse_jsonl_line(const std::string& line) {
    JsonlRecord rec;
    rec.fields = detail::parse_flat_object(line);
    return rec;
}

inline std::vector<JsonlRecord> load_jsonl(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open())
        throw std::runtime_error("oracle_loader: cannot open JSONL: " + path);
    std::vector<JsonlRecord> records;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line.front() == '#') continue;
        records.push_back(parse_jsonl_line(line));
    }
    return records;
}

// ── Base64 decode ─────────────────────────────────────────────────────────

namespace detail {
inline int b64val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}
} // namespace detail

/// Decode a base64 string into raw bytes.
inline std::vector<uint8_t> base64_decode(const std::string& encoded) {
    std::vector<uint8_t> out;
    out.reserve(encoded.size() * 3 / 4);
    int buf = 0, bits = 0;
    for (char c : encoded) {
        if (c == '=') break;
        int v = detail::b64val(c);
        if (v < 0) continue;
        buf = (buf << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out.push_back(static_cast<uint8_t>((buf >> bits) & 0xFF));
        }
    }
    return out;
}

/// Decode an __ndarray__ JSON object string into a vector<float>.
/// The object has fields: dtype, shape, data_b64.
/// Only float32 arrays are currently supported.
inline std::vector<float> ndarray_to_float32(const std::string& ndarray_json) {
    auto fields = detail::parse_flat_object(ndarray_json);
    auto it_b64  = fields.find("data_b64");
    auto it_dtype = fields.find("dtype");
    if (it_b64 == fields.end())
        throw std::runtime_error("ndarray_to_float32: missing data_b64 field");
    if (it_dtype != fields.end() && it_dtype->second != "float32")
        throw std::runtime_error("ndarray_to_float32: unsupported dtype " + it_dtype->second);

    auto bytes = base64_decode(it_b64->second);
    if (bytes.size() % 4 != 0)
        throw std::runtime_error("ndarray_to_float32: byte count not divisible by 4");

    std::vector<float> out(bytes.size() / 4);
    for (size_t i = 0; i < out.size(); ++i) {
        uint32_t bits = static_cast<uint32_t>(bytes[4*i])
                      | (static_cast<uint32_t>(bytes[4*i+1]) << 8)
                      | (static_cast<uint32_t>(bytes[4*i+2]) << 16)
                      | (static_cast<uint32_t>(bytes[4*i+3]) << 24);
        std::memcpy(&out[i], &bits, 4);
    }
    return out;
}

/// Convenience: decode __ndarray__ from a JsonlRecord's "retval" field.
/// The retval field looks like: {"__ndarray__": true, "dtype": "float32",
///                               "shape": [...], "data_b64": "..."}
inline std::vector<float> ndarray_from_retval(const JsonlRecord& rec) {
    const std::string& retval = rec.get("retval");
    if (retval.find("__ndarray__") == std::string::npos)
        throw std::runtime_error("ndarray_from_retval: retval is not an __ndarray__");
    return ndarray_to_float32(retval);
}

/// Filter records by section name.
inline std::vector<JsonlRecord>
filter_section(const std::vector<JsonlRecord>& records, const std::string& section) {
    std::vector<JsonlRecord> out;
    for (const auto& r : records)
        if (r.get("section") == section) out.push_back(r);
    return out;
}

/// Filter records by function name.
inline std::vector<JsonlRecord>
filter_fn(const std::vector<JsonlRecord>& records, const std::string& fn) {
    std::vector<JsonlRecord> out;
    for (const auto& r : records)
        if (r.get("function") == fn) out.push_back(r);
    return out;
}

} // namespace jarvis::oracle
