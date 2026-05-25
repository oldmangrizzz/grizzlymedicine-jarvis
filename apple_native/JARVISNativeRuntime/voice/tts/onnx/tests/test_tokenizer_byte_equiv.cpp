/**
 * test_tokenizer_byte_equiv.cpp — Token ID roundtrip vs pocket-tts Python.
 *
 * Verifies that the C++ SentencePiece tokenizer produces bit-identical token IDs
 * to pocket_tts.conditioners.text.SentencePieceTokenizer on all 50 oracle prompts.
 *
 * Reference token IDs are pre-computed by tools/gen_token_ref.py and stored in
 * a JSON file at TEST_TOKEN_REF_JSON (generated at build time if Python+pocket-tts
 * is available; otherwise test is skipped).
 */

#include <catch2/catch_test_macros.hpp>

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <nlohmann/json.hpp>

#include "../tokenizer.h"

#ifndef ORACLE_PROMPTS_JSON
#  define ORACLE_PROMPTS_JSON "/Users/rbhanson/research/oracle/voice/prompts.json"
#endif
#ifndef TOKENIZER_MODEL
#  define TOKENIZER_MODEL "/Users/rbhanson/.cache/huggingface/hub/models--kyutai--pocket-tts-without-voice-cloning/snapshots/d29db7978e464fb90cb3359ee0c69a273b9142cc/languages/english_2026-04/tokenizer.model"
#endif
#ifndef TEST_TOKEN_REF_JSON
#  define TEST_TOKEN_REF_JSON "/Users/rbhanson/research/jarvis/apple_native/JARVISNativeRuntime/voice/tts/onnx/tests/token_ref.json"
#endif

TEST_CASE("tokenizer_vocab_size", "[tokenizer]") {
    jarvis::tts::onnx::Tokenizer tok(TOKENIZER_MODEL, 4000);
    REQUIRE(tok.vocab_size() == 4000);
}

TEST_CASE("tokenizer_basic_encode_decode", "[tokenizer]") {
    jarvis::tts::onnx::Tokenizer tok(TOKENIZER_MODEL);

    // Basic round-trip
    std::string text = "Ready.";
    auto ids = tok.encode(text);
    REQUIRE(!ids.empty());

    auto decoded = tok.decode(ids);
    // SentencePiece may add leading space; trim for comparison
    auto trim = [](std::string s) {
        while (!s.empty() && (s.front() == ' ' || s.front() == '\n')) s.erase(s.begin());
        while (!s.empty() && (s.back()  == ' ' || s.back()  == '\n')) s.pop_back();
        return s;
    };
    REQUIRE(trim(decoded) == trim(text));
}

TEST_CASE("tokenizer_byte_equiv_vs_python_ref", "[tokenizer]") {
    // Load reference token IDs (pre-computed by Python pocket-tts)
    std::ifstream ref_file(TEST_TOKEN_REF_JSON);
    if (!ref_file.is_open()) {
        WARN("token_ref.json not found at " << TEST_TOKEN_REF_JSON
             << " — skipping byte-equivalence test.\n"
             << "Generate with: python tools/gen_token_ref.py");
        return;   // Skip, not fail
    }
    auto j = nlohmann::json::parse(ref_file);

    jarvis::tts::onnx::Tokenizer tok(TOKENIZER_MODEL);

    int pass = 0, fail = 0;
    for (auto& entry : j) {
        std::string text = entry["text"].get<std::string>();
        auto ref_ids = entry["token_ids"].get<std::vector<int32_t>>();

        auto cpp_ids = tok.encode(text);

        bool match = (cpp_ids == ref_ids);
        if (!match) {
            ++fail;
            std::cout << "MISMATCH for: " << text.substr(0, 40) << "\n";
            std::cout << "  Python: [";
            for (size_t i = 0; i < std::min((size_t)8, ref_ids.size()); ++i)
                std::cout << ref_ids[i] << ",";
            std::cout << "...]\n";
            std::cout << "  C++:    [";
            for (size_t i = 0; i < std::min((size_t)8, cpp_ids.size()); ++i)
                std::cout << cpp_ids[i] << ",";
            std::cout << "...]\n";
        } else {
            ++pass;
        }
    }

    std::cout << "\nTokenizer byte-equiv: " << pass << " pass, " << fail << " fail\n";
    REQUIRE(fail == 0);
}
