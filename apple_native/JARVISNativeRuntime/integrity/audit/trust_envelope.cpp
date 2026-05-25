#include "trust_envelope.h"

#include <array>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

#include <sodium.h>

namespace jarvis::audit {
namespace {

void ensure_sodium() {
    if (sodium_init() < 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: libsodium initialization failed");
}

int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::vector<std::uint8_t> hex_decode_vec(std::string_view hex) {
    if (hex.size() % 2 != 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: odd-length hex");
    std::vector<std::uint8_t> out(hex.size() / 2);
    for (std::size_t i = 0; i < out.size(); ++i) {
        const int hi = hex_nibble(hex[2 * i]);
        const int lo = hex_nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: non-hex field");
        out[i] = static_cast<std::uint8_t>((hi << 4) | lo);
    }
    return out;
}

std::string json_string_field(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\":\"";
    const auto pos = json.find(needle);
    if (pos == std::string_view::npos) return {};
    const auto start = pos + needle.size();
    const auto end = json.find('"', start);
    if (end == std::string_view::npos) return {};
    return std::string(json.substr(start, end - start));
}

void check_component_policy(const std::filesystem::path& path) {
    std::filesystem::path current = path.is_absolute() ? std::filesystem::path("/") : std::filesystem::current_path();
    for (const auto& part : path.lexically_normal()) {
        if (part == "/" || part == ".") continue;
        current /= part;
        struct stat st{};
        if (::lstat(current.c_str(), &st) != 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy lstat failed: " + current.string());
        if ((st.st_mode & S_IFMT) == S_IFLNK) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy symlink refused: " + current.string());
        if (st.st_uid != ::geteuid() && st.st_uid != 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy owner mismatch: " + current.string());
        if ((st.st_mode & 0022) != 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy writable by group/other: " + current.string());
    }
}

} // namespace

int path_policy_open_read(const std::filesystem::path& path) {
    check_component_policy(path);
    int fd = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (fd < 0) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy open failed: " + path.string() + " errno=" + std::to_string(errno));
    struct stat st{};
    if (::fstat(fd, &st) != 0) {
        const int e = errno;
        ::close(fd);
        throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy fstat failed errno=" + std::to_string(e));
    }
    if (st.st_uid != ::geteuid() || (st.st_mode & 0022) != 0) {
        ::close(fd);
        throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: PathPolicy final file permissions refused: " + path.string());
    }
    return fd;
}

std::vector<std::uint8_t> read_file_path_policy(const std::filesystem::path& path) {
    int fd = path_policy_open_read(path);
    std::vector<std::uint8_t> out;
    std::array<std::uint8_t, 4096> buf{};
    while (true) {
        const ssize_t n = ::read(fd, buf.data(), buf.size());
        if (n < 0) {
            if (errno == EINTR) continue;
            const int e = errno;
            ::close(fd);
            throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: read failed errno=" + std::to_string(e));
        }
        if (n == 0) break;
        out.insert(out.end(), buf.begin(), buf.begin() + n);
    }
    ::close(fd);
    return out;
}

std::string sha256_hex_bytes(std::span<const std::uint8_t> bytes) {
    ensure_sodium();
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256(digest.data(), bytes.data(), static_cast<unsigned long long>(bytes.size()));
    std::array<char, crypto_hash_sha256_BYTES * 2 + 1> out{};
    sodium_bin2hex(out.data(), out.size(), digest.data(), digest.size());
    return std::string(out.data(), crypto_hash_sha256_BYTES * 2);
}

std::vector<std::uint8_t> verify_trust_envelope_bytes(std::string_view json, std::string_view trusted_root_public_key_hex) {
    ensure_sodium();
    const auto payload_b64 = json_string_field(json, "payload");
    const auto payload_sha = json_string_field(json, "payload_sha256");
    const auto sig_hex = json_string_field(json, "signature_over_payload_sha256");
    const auto fp_hex = json_string_field(json, "key_fingerprint_hex");
    if (payload_b64.empty() || payload_sha.empty() || sig_hex.empty() || fp_hex.empty()) {
        throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: missing envelope fields");
    }
    const auto pub = hex_decode_vec(trusted_root_public_key_hex);
    const auto sig = hex_decode_vec(sig_hex);
    if (pub.size() != crypto_sign_PUBLICKEYBYTES || sig.size() != crypto_sign_BYTES) {
        throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: invalid public key or signature size");
    }
    const std::string actual_fp = sha256_hex_bytes(std::span<const std::uint8_t>(pub.data(), pub.size()));
    if (actual_fp != fp_hex) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: key fingerprint mismatch");
    std::vector<std::uint8_t> payload(payload_b64.size());
    std::size_t payload_len = 0;
    if (sodium_base642bin(payload.data(), payload.size(), payload_b64.c_str(), payload_b64.size(), nullptr, &payload_len, nullptr, sodium_base64_VARIANT_ORIGINAL) != 0) {
        throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: payload base64 invalid");
    }
    payload.resize(payload_len);
    const auto actual_sha = sha256_hex_bytes(std::span<const std::uint8_t>(payload.data(), payload.size()));
    if (actual_sha != payload_sha) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: payload_sha256 mismatch");
    const auto digest = hex_decode_vec(payload_sha);
    if (digest.size() != crypto_hash_sha256_BYTES) throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: digest size invalid");
    if (crypto_sign_verify_detached(sig.data(), digest.data(), digest.size(), pub.data()) != 0) {
        throw TrustEnvelopeInvalid("TrustEnvelopeInvalid: envelope signature invalid");
    }
    return payload;
}

std::vector<std::uint8_t> verify_trust_envelope_file(const std::filesystem::path& path, std::string_view trusted_root_public_key_hex) {
    const auto bytes = read_file_path_policy(path);
    return verify_trust_envelope_bytes(std::string_view(reinterpret_cast<const char*>(bytes.data()), bytes.size()), trusted_root_public_key_hex);
}

} // namespace jarvis::audit
