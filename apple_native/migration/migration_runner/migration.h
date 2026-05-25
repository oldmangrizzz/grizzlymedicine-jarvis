#pragma once

#include <filesystem>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace jarvis::migration {

enum class Mode { DryRun, Migrate, Verify };

struct Options {
    Mode mode{Mode::DryRun};
    std::filesystem::path source_dir;
    std::filesystem::path destination_dir;
    std::filesystem::path manifest_path;
    std::filesystem::path attestation_token_path;
    std::string sqlcipher_key_hex;
    std::optional<std::string> voice_baseline_hash;
    std::optional<std::string> voice_current_hash;
    bool inject_failure_after_backup_for_test{false};
};

struct Result {
    bool ok{false};
    std::string code;
    std::string message;
    std::filesystem::path manifest_path;
    std::map<std::string, std::uint64_t> row_counts;
};

Result run(const Options& options);
Result rollback(const std::filesystem::path& manifest_path, const std::filesystem::path& attestation_token_path);
Options parse_args(int argc, char** argv, bool rollback_binary = false);
std::string sha256_file(const std::filesystem::path& path);
std::string sha256_text(const std::string& text);
bool path_contains_voice_root(const std::filesystem::path& path);

} // namespace jarvis::migration
