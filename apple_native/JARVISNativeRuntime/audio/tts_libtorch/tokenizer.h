#pragma once
/**
 * tokenizer.h — C++ SentencePiece tokenizer wrapper for pocket-tts
 *
 * Runtime is zero-Python: uses the SentencePiece C++ library directly.
 * The tokenizer model file (tokenizer.model, ~800 KB) must be present at
 * the path supplied to Tokenizer::load().
 *
 * Implements the exact pre-processing that pocket-tts applies before tokenisation:
 *  • strip + collapse whitespace
 *  • upper-case first character
 *  • append '.' if the last char is alphanumeric
 * This must match prepare_text_prompt() in pocket_tts/models/tts_model.py exactly.
 *
 * Thread safety: the SentencePiece processor is const after load(); multiple
 * threads may call encode() concurrently.
 */

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

// Forward-declare SentencePieceProcessor to avoid exposing the SP header
// in downstream translation units that only include this header.
namespace sentencepiece { class SentencePieceProcessor; }

namespace jarvis::tts {

class Tokenizer {
public:
    Tokenizer();
    ~Tokenizer();

    // Non-copyable, moveable.
    Tokenizer(const Tokenizer&) = delete;
    Tokenizer& operator=(const Tokenizer&) = delete;
    Tokenizer(Tokenizer&&) noexcept;
    Tokenizer& operator=(Tokenizer&&) noexcept;

    /**
     * Load the SentencePiece model from disk.
     * Throws std::runtime_error on failure.
     */
    void load(const std::string& model_path);

    /**
     * Encode raw text exactly as pocket-tts does:
     *  1. prepare_text_prompt preprocessing (capitalize, add period)
     *  2. SentencePiece encode → integer IDs
     * Returns a vector of token IDs (int32_t).
     * Throws std::runtime_error if the tokenizer is not loaded.
     */
    std::vector<int32_t> encode(const std::string& text) const;

    /**
     * Raw SentencePiece encode without preprocessing — for byte-equivalence testing.
     */
    std::vector<int32_t> encode_raw(const std::string& text) const;

    /** Vocabulary size (should be 4000 for pocket-tts English). */
    int32_t vocab_size() const;

    /** True if the model has been successfully loaded. */
    bool is_loaded() const { return sp_ != nullptr; }

private:
    std::unique_ptr<sentencepiece::SentencePieceProcessor> sp_;

    /**
     * Apply the exact same text normalisation as pocket-tts prepare_text_prompt():
     *  - strip leading/trailing whitespace
     *  - collapse internal whitespace to single spaces
     *  - uppercase first character
     *  - append '.' if last char is alphanumeric
     */
    static std::string prepare_text(const std::string& raw);
};

} // namespace jarvis::tts
