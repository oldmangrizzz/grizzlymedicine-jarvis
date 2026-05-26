// manifest_hash_harness.cpp — standalone test harness for hash parity verification.
//
// Implements the canonical recursive manifest hash algorithm (v4r-r6-hash-algo-reconcile)
// in isolation (no audit machinery, no runtime deps beyond libsodium + libc++).
//
// This is the AUTHORITATIVE reference implementation used by JARVISManifestHashHarness
// to cross-check against the Swift recursiveDirectoryManifestHex output.
//
// Algorithm specification (both sides must match exactly):
//   1. Enumerate all regular files under directory recursively (no depth limit).
//   2. Skip symlinks (reject — do not follow).
//   3. Skip files whose basename is in kAllowlist (currently: ".DS_Store").
//   4. Sort by relative POSIX path (generic_string) using byte-order std::string comparison.
//   5. For each file, in order:
//        SHA256(relative_path_utf8 + NUL + sha256_hex_of_file_contents_lowercase + NUL)
//      where sha256_hex is lowercase 64-char hex.
//   6. The outer SHA256 finalizes as a lowercase 64-char hex string.
//
// Usage: manifest_hash_harness <directory_path>
// Output: 64-char lowercase hex SHA-256 to stdout, trailing newline.
// Exit: 0 on success, 1 on error (error message to stderr).

#include <sodium.h>

#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Must be kept identical to kHashManifestIgnoreList in XTTSCoreMLPipeline.swift
// and kAllowlist in isHashManifestAllowlisted in JARVISNativeRuntime.cpp.
static bool isAllowlisted(const std::string &filename) {
    static const std::array<const char *, 1> kAllowlist = {{".DS_Store"}};
    for (const char *name : kAllowlist) {
        if (filename == name) { return true; }
    }
    return false;
}

static std::string hexEncode(const std::array<unsigned char, crypto_hash_sha256_BYTES> &digest) {
    constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(digest.size() * 2);
    for (unsigned char byte : digest) {
        out.push_back(hex[(byte >> 4) & 0x0f]);
        out.push_back(hex[byte & 0x0f]);
    }
    return out;
}

static std::string sha256FileHex(const std::filesystem::path &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) { throw std::runtime_error("Cannot open file: " + path.string()); }
    crypto_hash_sha256_state state;
    if (crypto_hash_sha256_init(&state) != 0) { throw std::runtime_error("sha256_init failed"); }
    std::array<unsigned char, 65536> buf{};
    while (in) {
        in.read(reinterpret_cast<char *>(buf.data()), static_cast<std::streamsize>(buf.size()));
        const auto n = in.gcount();
        if (n > 0 && crypto_hash_sha256_update(&state, buf.data(), static_cast<unsigned long long>(n)) != 0) {
            throw std::runtime_error("sha256_update failed");
        }
    }
    if (in.bad()) { throw std::runtime_error("Read error: " + path.string()); }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    if (crypto_hash_sha256_final(&state, digest.data()) != 0) { throw std::runtime_error("sha256_final failed"); }
    return hexEncode(digest);
}

static std::string computeManifestHash(const std::filesystem::path &dirPath) {
    std::error_code ec;
    const auto rootStatus = std::filesystem::symlink_status(dirPath, ec);
    if (ec || !std::filesystem::is_directory(rootStatus)) {
        throw std::runtime_error("Not a directory: " + dirPath.string());
    }
    if (std::filesystem::is_symlink(rootStatus)) {
        throw std::runtime_error("Root symlink rejected: " + dirPath.string());
    }

    std::vector<std::filesystem::path> files;
    for (std::filesystem::recursive_directory_iterator it(dirPath, std::filesystem::directory_options::none, ec), end;
         it != end; it.increment(ec)) {
        if (ec) { throw std::runtime_error("Enumeration error: " + ec.message()); }
        const auto st = it->symlink_status(ec);
        if (ec) { throw std::runtime_error("lstat error: " + ec.message()); }
        if (std::filesystem::is_symlink(st)) {
            throw std::runtime_error("Symlink in tree rejected: " + it->path().string());
        }
        if (std::filesystem::is_regular_file(st)) {
            if (!isAllowlisted(it->path().filename().string())) {
                files.push_back(it->path());
            }
        }
    }

    std::sort(files.begin(), files.end(), [&](const auto &lhs, const auto &rhs) {
        return std::filesystem::relative(lhs, dirPath, ec).generic_string() <
               std::filesystem::relative(rhs, dirPath, ec).generic_string();
    });

    crypto_hash_sha256_state state;
    if (crypto_hash_sha256_init(&state) != 0) { throw std::runtime_error("outer sha256_init failed"); }
    const unsigned char nul = 0;
    for (const auto &file : files) {
        const std::string relative = std::filesystem::relative(file, dirPath, ec).generic_string();
        if (ec) { throw std::runtime_error("relative path error: " + ec.message()); }
        const std::string fileHex = sha256FileHex(file);
        if (crypto_hash_sha256_update(&state, reinterpret_cast<const unsigned char *>(relative.data()), relative.size()) != 0 ||
            crypto_hash_sha256_update(&state, &nul, 1) != 0 ||
            crypto_hash_sha256_update(&state, reinterpret_cast<const unsigned char *>(fileHex.data()), fileHex.size()) != 0 ||
            crypto_hash_sha256_update(&state, &nul, 1) != 0) {
            throw std::runtime_error("outer sha256_update failed");
        }
    }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    if (crypto_hash_sha256_final(&state, digest.data()) != 0) { throw std::runtime_error("outer sha256_final failed"); }
    return hexEncode(digest);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        std::cerr << "Usage: ManifestHashHarness <directory_path>" << std::endl;
        return 1;
    }
    if (sodium_init() < 0) {
        std::cerr << "libsodium init failed" << std::endl;
        return 1;
    }
    try {
        std::cout << computeManifestHash(std::filesystem::path(argv[1])) << std::endl;
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
}
