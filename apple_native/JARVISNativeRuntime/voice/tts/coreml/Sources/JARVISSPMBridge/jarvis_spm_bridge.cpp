// jarvis_spm_bridge.cpp — SentencePiece C bridge implementation
//
// Links against sentencepiece library.
// Install: brew install sentencepiece
//
// Build note: If sentencepiece is not installed, the stub implementation
// (returns nullptr from jarvis_spm_load) is used, and the Swift tokenizer
// falls back to character-level encoding.

#include "jarvis_spm_bridge.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// Attempt to include sentencepiece. Guarded so the file compiles without it.
#if __has_include(<sentencepiece_processor.h>)
#  include <sentencepiece_processor.h>
#  define HAVE_SENTENCEPIECE 1
#elif __has_include("sentencepiece_processor.h")
#  include "sentencepiece_processor.h"
#  define HAVE_SENTENCEPIECE 1
#else
#  define HAVE_SENTENCEPIECE 0
#endif

#if HAVE_SENTENCEPIECE

struct JARVISSPMHandle {
    sentencepiece::SentencePieceProcessor processor;
    bool loaded = false;
};

JARVISSPMHandle* jarvis_spm_load(const char* model_path) {
    auto* h = new JARVISSPMHandle();
    const auto status = h->processor.Load(std::string(model_path));
    if (!status.ok()) {
        delete h;
        return nullptr;
    }
    h->loaded = true;
    return h;
}

void jarvis_spm_free(JARVISSPMHandle* h) {
    delete h;
}

int32_t* jarvis_spm_encode(JARVISSPMHandle* h, const char* text, int32_t* out_count) {
    if (!h || !h->loaded || !text || !out_count) return nullptr;
    std::vector<int> ids;
    const auto status = h->processor.Encode(std::string(text), &ids);
    if (!status.ok()) return nullptr;
    *out_count = static_cast<int32_t>(ids.size());
    auto* result = static_cast<int32_t*>(std::malloc(ids.size() * sizeof(int32_t)));
    for (size_t i = 0; i < ids.size(); ++i)
        result[i] = static_cast<int32_t>(ids[i]);
    return result;
}

void jarvis_spm_free_ids(int32_t* ids) {
    std::free(ids);
}

char* jarvis_spm_decode(JARVISSPMHandle* h, const int32_t* ids, int32_t count) {
    if (!h || !h->loaded || !ids || count <= 0) return nullptr;
    std::vector<int> id_vec(ids, ids + count);
    std::string text;
    const auto status = h->processor.Decode(id_vec, &text);
    if (!status.ok()) return nullptr;
    char* result = static_cast<char*>(std::malloc(text.size() + 1));
    std::memcpy(result, text.data(), text.size());
    result[text.size()] = '\0';
    return result;
}

void jarvis_spm_free_str(char* str) {
    std::free(str);
}

int32_t jarvis_spm_vocab_size(JARVISSPMHandle* h) {
    if (!h || !h->loaded) return 0;
    return static_cast<int32_t>(h->processor.GetPieceSize());
}

#else  // !HAVE_SENTENCEPIECE — stub implementation

JARVISSPMHandle* jarvis_spm_load(const char* /*model_path*/) {
    return nullptr;  // signals Swift to use fallback character tokenizer
}

void jarvis_spm_free(JARVISSPMHandle* h) { (void)h; }

int32_t* jarvis_spm_encode(JARVISSPMHandle* /*h*/, const char* /*text*/, int32_t* out_count) {
    if (out_count) *out_count = 0;
    return nullptr;
}

void jarvis_spm_free_ids(int32_t* ids) { (void)ids; }

char* jarvis_spm_decode(JARVISSPMHandle* /*h*/, const int32_t* /*ids*/, int32_t /*count*/) {
    return nullptr;
}

void jarvis_spm_free_str(char* str) { (void)str; }

int32_t jarvis_spm_vocab_size(JARVISSPMHandle* /*h*/) { return 0; }

#endif // HAVE_SENTENCEPIECE
