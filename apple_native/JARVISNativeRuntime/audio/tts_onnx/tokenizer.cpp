/**
 * tokenizer.cpp — SentencePiece tokenizer wrapper.
 *
 * Links against sentencepiece (libsentencepiece).
 * No Python at runtime.
 */

#include "tokenizer.h"

#include <stdexcept>
#include <string>
#include <vector>

#include <sentencepiece_processor.h>

namespace jarvis {
namespace tts {
namespace onnx {

struct Tokenizer::Impl {
    sentencepiece::SentencePieceProcessor sp;
};

Tokenizer::Tokenizer(const std::string& model_path, int expected_vocab_size)
    : impl_(std::make_unique<Impl>())
{
    const auto status = impl_->sp.Load(model_path);
    if (!status.ok()) {
        throw std::runtime_error(
            "Tokenizer: failed to load model '" + model_path + "': " + status.ToString());
    }
    if (impl_->sp.GetPieceSize() != expected_vocab_size) {
        throw std::runtime_error(
            "Tokenizer: vocab size mismatch — expected " +
            std::to_string(expected_vocab_size) + ", got " +
            std::to_string(impl_->sp.GetPieceSize()));
    }
}

Tokenizer::~Tokenizer() = default;

Tokenizer::Tokenizer(Tokenizer&&) noexcept = default;
Tokenizer& Tokenizer::operator=(Tokenizer&&) noexcept = default;

std::vector<int32_t> Tokenizer::encode(const std::string& text) const {
    std::vector<int> ids;
    const auto status = impl_->sp.Encode(text, &ids);
    if (!status.ok()) {
        throw std::runtime_error("Tokenizer::encode failed: " + status.ToString());
    }
    // Convert int → int32_t (same width on every platform, but explicit cast for clarity)
    return std::vector<int32_t>(ids.begin(), ids.end());
}

std::string Tokenizer::decode(const std::vector<int32_t>& ids) const {
    std::vector<int> sp_ids(ids.begin(), ids.end());
    std::string text;
    const auto status = impl_->sp.Decode(sp_ids, &text);
    if (!status.ok()) {
        throw std::runtime_error("Tokenizer::decode failed: " + status.ToString());
    }
    return text;
}

int Tokenizer::vocab_size() const {
    return impl_->sp.GetPieceSize();
}

}  // namespace onnx
}  // namespace tts
}  // namespace jarvis
