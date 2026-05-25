#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace jarvis::audit {

class TrustEnvelopeInvalid final : public std::runtime_error {
public:
    explicit TrustEnvelopeInvalid(const std::string& reason) : std::runtime_error(reason) {}
};

int path_policy_open_read(const std::filesystem::path& path);
std::vector<std::uint8_t> read_file_path_policy(const std::filesystem::path& path);
std::vector<std::uint8_t> verify_trust_envelope_file(const std::filesystem::path& path, std::string_view trusted_root_public_key_hex);
std::vector<std::uint8_t> verify_trust_envelope_bytes(std::string_view json, std::string_view trusted_root_public_key_hex);
std::string sha256_hex_bytes(std::span<const std::uint8_t> bytes);

} // namespace jarvis::audit
