#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace jarvis::tts::onnx::voice_integrity {

struct VoiceIntegrityFile {
    std::filesystem::path path;
    std::string baseline_suffix;
};

struct VoiceIntegrityOptions {
    std::filesystem::path audit_log_path;
    std::filesystem::path audit_key_path;
    bool emit_distress_beacon{true};
};

[[nodiscard]] std::string sha256_file_hex(const std::filesystem::path& path);
[[nodiscard]] bool constant_time_hash_equal(std::string_view actual_hex, std::string_view expected_hex);
[[nodiscard]] std::string expected_hash_for_suffix(std::string_view suffix);

void verify_voice_integrity_or_throw(const std::vector<VoiceIntegrityFile>& files,
                                     const VoiceIntegrityOptions& options = {});

} // namespace jarvis::tts::onnx::voice_integrity
