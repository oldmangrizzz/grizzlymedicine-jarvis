/**
 * test_tokenizer_byte_equiv.cpp
 *
 * Validates that the C++ SentencePiece tokenizer produces byte-for-byte
 * identical token ID sequences as the Python pocket-tts tokenizer on all
 * 50 oracle prompts.
 *
 * The oracle token sequences are pre-computed by the build-time tool:
 *   tools/trace_xtts_to_torchscript.py --dump_tokens oracle_tokens.json
 *
 * oracle_tokens.json format:
 *   [{"idx": 0, "text": "Ready.", "tokens": [123, 456, ...]}, ...]
 *
 * Run via CTest:
 *   ctest --test-dir build -R tokenizer --output-on-failure
 *
 * Environment:
 *   JARVIS_TOKENIZER_MODEL       — path to tokenizer.model
 *   JARVIS_ORACLE_TOKENS_JSON    — path to oracle_tokens.json (default: models/oracle_tokens.json)
 *   JARVIS_ORACLE_PROMPTS_JSON   — path to prompts.json
 */

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "../tokenizer.h"

namespace {

std::string env_or(const char* name, const char* dflt) {
    const char* v = std::getenv(name);
    return v ? v : dflt;
}

// Very minimal JSON parser for the oracle token file.
struct TokenEntry {
    int idx;
    std::string text;
    std::vector<int32_t> tokens;
};

std::vector<TokenEntry> load_oracle_tokens(const std::string& path) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error("Cannot open oracle tokens JSON: " + path);
    std::string content((std::istreambuf_iterator<char>(f)), {});

    std::vector<TokenEntry> entries;
    size_t pos = 0;

    while ((pos = content.find("\"idx\"", pos)) != std::string::npos) {
        TokenEntry e;

        // idx
        pos = content.find(':', pos) + 1;
        while (std::isspace(content[pos])) ++pos;
        e.idx = std::stoi(content.substr(pos));

        // text
        auto tp = content.find("\"text\"", pos);
        if (tp == std::string::npos) break;
        tp = content.find('"', content.find(':', tp) + 1) + 1;
        auto te = content.find('"', tp);
        while (te != std::string::npos && content[te - 1] == '\\') te = content.find('"', te + 1);
        e.text = content.substr(tp, te - tp);

        // tokens array
        auto ap = content.find("\"tokens\"", pos);
        if (ap == std::string::npos) break;
        ap = content.find('[', ap) + 1;
        auto ae = content.find(']', ap);
        std::string arr = content.substr(ap, ae - ap);
        std::istringstream ss(arr);
        std::string tok;
        while (std::getline(ss, tok, ',')) {
            tok.erase(std::remove_if(tok.begin(), tok.end(), ::isspace), tok.end());
            if (!tok.empty()) e.tokens.push_back(std::stoi(tok));
        }

        entries.push_back(std::move(e));
        pos = ae + 1;
    }
    return entries;
}

} // anonymous namespace

// ─── Tests ──────────────────────────────────────────────────────────────────

TEST_CASE("tokenizer_loads_and_vocab_size", "[tokenizer][libtorch]") {
    const std::string model_path = env_or("JARVIS_TOKENIZER_MODEL", "models/tokenizer.model");
    jarvis::tts::Tokenizer tok;
    REQUIRE_NOTHROW(tok.load(model_path));
    REQUIRE(tok.is_loaded());
    CHECK(tok.vocab_size() == 4000);  // pocket-tts English SentencePiece
}

TEST_CASE("tokenizer_text_preprocessing", "[tokenizer][libtorch]") {
    const std::string model_path = env_or("JARVIS_TOKENIZER_MODEL", "models/tokenizer.model");
    jarvis::tts::Tokenizer tok;
    tok.load(model_path);

    // lowercase first char → should be uppercased
    auto ids1 = tok.encode("hello world");
    auto ids2 = tok.encode("Hello world.");
    // Both should produce the same tokens (preprocessing capitalises + adds period)
    CHECK(ids1 == ids2);

    // Multi-space collapsing
    auto ids3 = tok.encode("ready  now");
    auto ids4 = tok.encode("ready now.");
    CHECK(ids3 == ids4);
}

TEST_CASE("tokenizer_byte_equiv_oracle_prompts", "[tokenizer][libtorch]") {
    const std::string model_path   = env_or("JARVIS_TOKENIZER_MODEL",    "models/tokenizer.model");
    const std::string tokens_path  = env_or("JARVIS_ORACLE_TOKENS_JSON", "models/oracle_tokens.json");

    jarvis::tts::Tokenizer tok;
    REQUIRE_NOTHROW(tok.load(model_path));

    std::vector<TokenEntry> oracle;
    try {
        oracle = load_oracle_tokens(tokens_path);
    } catch (const std::exception& e) {
        // If oracle_tokens.json has not been generated yet, skip this test.
        SKIP("oracle_tokens.json not found (" + std::string(e.what()) +
             "). Run trace_xtts_to_torchscript.py --dump_tokens first.");
    }
    REQUIRE(oracle.size() == 50);

    int failures = 0;
    for (const auto& entry : oracle) {
        const auto cpp_ids = tok.encode(entry.text);
        const bool match = (cpp_ids.size() == entry.tokens.size()) &&
                           std::equal(cpp_ids.begin(), cpp_ids.end(), entry.tokens.begin());
        if (!match) {
            ++failures;
            std::cout << "  MISMATCH idx=" << entry.idx
                      << " text=\"" << entry.text.substr(0, 40) << "\"\n";
            std::cout << "  Python tokens: [";
            for (int i = 0; i < std::min(10, (int)entry.tokens.size()); ++i)
                std::cout << entry.tokens[i] << ",";
            std::cout << "...]\n";
            std::cout << "  C++ tokens:    [";
            for (int i = 0; i < std::min(10, (int)cpp_ids.size()); ++i)
                std::cout << cpp_ids[i] << ",";
            std::cout << "...]\n";
        }
    }

    std::cout << "\nTokenizer byte-equiv: " << (50 - failures) << "/50 match\n";
    CHECK(failures == 0);
}

TEST_CASE("tokenizer_empty_and_edge_cases", "[tokenizer][libtorch]") {
    const std::string model_path = env_or("JARVIS_TOKENIZER_MODEL", "models/tokenizer.model");
    jarvis::tts::Tokenizer tok;
    tok.load(model_path);

    // Empty input should throw
    CHECK_THROWS(tok.encode(""));
    CHECK_THROWS(tok.encode("   "));

    // Single word
    REQUIRE_NOTHROW(tok.encode("Ready"));

    // Long text
    std::string long_text(200, 'a');
    long_text = "The " + long_text + " end.";
    REQUIRE_NOTHROW(tok.encode(long_text));
}
