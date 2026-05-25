#pragma once
/**
 * tokenizer.h — Pure C++ SentencePiece BPE tokenizer.
 *
 * Wraps the sentencepiece C library (no Python). Byte-equivalent to the
 * pocket-tts Python SentencePieceTokenizer on the 50 oracle prompts.
 *
 * Vocab size: 4000 (matches pocket-tts config n_bins).
 */

#include <cstdint>
#include <string>
#include <vector>
#include <memory>

// Forward-declare sentencepiece processor to avoid including heavy headers
// in every TU that only needs the interface.
namespace sentencepiece { class SentencePieceProcessor; }

namespace jarvis {
namespace tts {
namespace onnx {

class Tokenizer {
public:
    /**
     * Load the SentencePiece model file.
     * @param model_path  Absolute path to tokenizer.model
     * @param expected_vocab_size  Must match; throws if mismatch (4000 for pocket-tts).
     */
    explicit Tokenizer(const std::string& model_path, int expected_vocab_size = 4000);
    ~Tokenizer();

    // Non-copyable, movable.
    Tokenizer(const Tokenizer&) = delete;
    Tokenizer& operator=(const Tokenizer&) = delete;
    Tokenizer(Tokenizer&&) noexcept;
    Tokenizer& operator=(Tokenizer&&) noexcept;

    /**
     * Encode text to token IDs.
     * Returns the same IDs as pocket_tts.conditioners.text.SentencePieceTokenizer.
     */
    std::vector<int32_t> encode(const std::string& text) const;

    /** Decode token IDs back to text (for round-trip validation). */
    std::string decode(const std::vector<int32_t>& ids) const;

    int vocab_size() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
