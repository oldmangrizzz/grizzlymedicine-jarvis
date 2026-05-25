/**
 * tokenizer.cpp — pocket-tts SentencePiece tokenizer (C++, zero Python)
 *
 * Replicates the exact tokenisation path of pocket-tts 2.1.0:
 *   pocket_tts.conditioners.text.SentencePieceTokenizer.__call__
 *   pocket_tts.models.tts_model.prepare_text_prompt
 *
 * All behaviour validated by test_tokenizer_byte_equiv.cpp against the
 * oracle output.
 */

#include "tokenizer.h"

#include <algorithm>
#include <cctype>
#include <stdexcept>
#include <string>
#include <vector>

// sentencepiece C++ header
#include <sentencepiece_processor.h>

namespace jarvis::tts {

Tokenizer::Tokenizer() = default;
Tokenizer::~Tokenizer() = default;
Tokenizer::Tokenizer(Tokenizer&&) noexcept = default;
Tokenizer& Tokenizer::operator=(Tokenizer&&) noexcept = default;

void Tokenizer::load(const std::string& model_path) {
    auto sp = std::make_unique<sentencepiece::SentencePieceProcessor>();
    const auto status = sp->Load(model_path);
    if (!status.ok()) {
        throw std::runtime_error(
            "Failed to load SentencePiece model from '" + model_path + "': " +
            std::string(status.message()));
    }
    sp_ = std::move(sp);
}

std::vector<int32_t> Tokenizer::encode(const std::string& text) const {
    if (!sp_) throw std::runtime_error("Tokenizer not loaded");
    return encode_raw(prepare_text(text));
}

std::vector<int32_t> Tokenizer::encode_raw(const std::string& text) const {
    if (!sp_) throw std::runtime_error("Tokenizer not loaded");
    std::vector<int32_t> ids;
    const auto status = sp_->Encode(text, &ids);
    if (!status.ok()) {
        throw std::runtime_error("SentencePiece encode failed: " +
                                 std::string(status.message()));
    }
    return ids;
}

int32_t Tokenizer::vocab_size() const {
    if (!sp_) return 0;
    return static_cast<int32_t>(sp_->GetPieceSize());
}

// ---------------------------------------------------------------------------
// prepare_text — must exactly match pocket-tts prepare_text_prompt()
//
// Python reference (pocket_tts/models/tts_model.py):
//
//   def prepare_text_prompt(text, pad_with_spaces_for_short_inputs, remove_semicolons):
//       text = text.strip()
//       if text == "": raise ValueError(...)
//       text = text.replace("\n", " ").replace("\r", " ").replace("  ", " ")
//       if remove_semicolons: text = text.replace(";", ",")
//       # Capitalize first letter
//       if not text[0].isupper(): text = text[0].upper() + text[1:]
//       # Append period if ends with alnum
//       if text[-1].isalnum(): text = text + "."
//       return text, frames_after_eos_guess
//
// Notes:
//  • pad_with_spaces_for_short_inputs is False for the oracle (default English model)
//  • remove_semicolons is False for the oracle (default)
//  • The Python replace("  ", " ") is applied once; we collapse all runs to be safe.
// ---------------------------------------------------------------------------
std::string Tokenizer::prepare_text(const std::string& raw) {
    if (raw.empty()) throw std::runtime_error("Empty text input");

    std::string s = raw;

    // Strip leading whitespace
    {
        const auto first = s.find_first_not_of(" \t\n\r\f\v");
        s = (first == std::string::npos) ? "" : s.substr(first);
    }
    // Strip trailing whitespace
    {
        const auto last = s.find_last_not_of(" \t\n\r\f\v");
        s = (last == std::string::npos) ? "" : s.substr(0, last + 1);
    }
    if (s.empty()) throw std::runtime_error("Text became empty after stripping");

    // Replace \n and \r with space, then collapse multiple spaces
    {
        std::string out;
        out.reserve(s.size());
        bool prev_space = false;
        for (char c : s) {
            if (c == '\n' || c == '\r') c = ' ';
            if (c == ' ') {
                if (!prev_space) out += c;
                prev_space = true;
            } else {
                out += c;
                prev_space = false;
            }
        }
        s = std::move(out);
    }

    // Uppercase first character
    if (!s.empty() && std::islower(static_cast<unsigned char>(s[0]))) {
        s[0] = static_cast<char>(std::toupper(static_cast<unsigned char>(s[0])));
    }

    // Append period if last char is alphanumeric
    if (!s.empty() && std::isalnum(static_cast<unsigned char>(s.back()))) {
        s += '.';
    }

    return s;
}

} // namespace jarvis::tts
