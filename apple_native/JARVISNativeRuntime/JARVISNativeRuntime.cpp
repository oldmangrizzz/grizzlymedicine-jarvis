#include "JARVISNativeRuntime.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <pwd.h>
#include <sodium.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#if __has_include(<CommonCrypto/CommonDigest.h>)
#include <CommonCrypto/CommonDigest.h>
#define JARVIS_HAS_COMMONCRYPTO 1
#else
#define JARVIS_HAS_COMMONCRYPTO 0
#endif

#include "../orchestration/shadow_router/shadow_router.cpp"
#include "../orchestration/orchestrator/cutover_orchestrator.cpp"

namespace {

using Clock = std::chrono::steady_clock;

std::string jsonStringField(const std::string &json, const std::string &key);
void auditVoiceModelsTripwireFired(const std::string &model, const std::string &failure, const std::string &actual, const std::string &expected, const std::string &source, const std::string &context = "");
void auditVoiceStateTripwireFired(const std::string &failure, const std::string &actual, const std::string &expected, const std::string &context) noexcept;

std::string basenameOnly(const std::filesystem::path &path) {
    const auto name = path.filename().string();
    return name.empty() ? std::string("unknown") : name;
}

std::string modelNameForPath(const std::filesystem::path &path) {
    const std::string text = path.generic_string();
    if (text.find("flow_decoder") != std::string::npos) { return "flow_decoder"; }
    if (text.find("mimi_decoder") != std::string::npos) { return "mimi_decoder"; }
    if (text.find("text_encoder") != std::string::npos) { return "text_encoder"; }
    if (text.find("voice_models_anchor") != std::string::npos) { return "anchor"; }
    return "unknown";
}

std::string errnoContext(const std::filesystem::path &path) {
    return basenameOnly(path) + ":errno=" + std::to_string(errno);
}

std::string ecContext(const std::filesystem::path &path, const std::error_code &ec) {
    return basenameOnly(path) + ":ec=" + std::to_string(ec.value());
}

std::string octalMode(mode_t mode) {
    std::ostringstream out;
    out << std::oct << (mode & 07777);
    return out.str();
}

double clamp01(double value) {
    return std::max(0.0, std::min(1.0, value));
}

double unixNow() {
    return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}

std::string jsonEscape(const std::string &value) {
    std::ostringstream out;
    for (unsigned char c : value) {
        switch (c) {
        case '\\': out << "\\\\"; break;
        case '"': out << "\\\""; break;
        case '\b': out << "\\b"; break;
        case '\f': out << "\\f"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (c < 0x20) {
                out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
            } else {
                out << c;
            }
        }
    }
    return out.str();
}

char *copyCString(const std::string &value) {
    char *out = static_cast<char *>(std::malloc(value.size() + 1));
    if (!out) {
        return nullptr;
    }
    std::memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

std::string errorJSON(const std::string &message) {
    return "{\"ok\":false,\"error\":\"" + jsonEscape(message) + "\"}";
}

std::string cstr(const char *value) {
    return value ? std::string(value) : std::string();
}

const char *jsonBool(bool value) {
    return value ? "true" : "false";
}

std::string trimCopy(const std::string &value) {
    const auto begin = std::find_if_not(value.begin(), value.end(), [](unsigned char c) { return std::isspace(c); });
    const auto end = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char c) { return std::isspace(c); }).base();
    if (begin >= end) {
        return "";
    }
    return std::string(begin, end);
}

std::string envTrim(const char *name) {
    if (const char *value = std::getenv(name)) {
        return trimCopy(value);
    }
    return "";
}

bool envEnabled(const char *name) {
    const std::string value = envTrim(name);
    return value == "1" || value == "true" || value == "TRUE" || value == "yes" || value == "YES";
}

std::string errnoMessage(const std::string &context) {
    return context + " errno=" + std::to_string(errno) + " (" + std::strerror(errno) + ")";
}

std::string homeDirectoryOrThrow() {
    if (const char *home = std::getenv("HOME"); home && *home) {
        return home;
    }
    if (const passwd *pw = ::getpwuid(::getuid()); pw && pw->pw_dir && *pw->pw_dir) {
        return pw->pw_dir;
    }
    auditVoiceStateTripwireFired("home_unavailable", "home_missing", std::string(64, '0'), "voice_state.bin");
    throw std::runtime_error("JARVIS voice tripwire: HOME is unavailable");
}

std::filesystem::path jarvisHomeRoot() {
    if (const std::string configured = envTrim("JARVIS_HOME"); !configured.empty()) {
        return configured;
    }
    return std::filesystem::path(homeDirectoryOrThrow()) / ".jarvis";
}

std::filesystem::path auditRoot() {
    if (const std::string configured = envTrim("JARVIS_AUDIT_ROOT"); !configured.empty()) {
        return configured;
    }
    return jarvisHomeRoot() / "audit";
}

std::string readFileStrict(const std::filesystem::path &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        auditVoiceStateTripwireFired("open_failed", errnoContext(path), std::string(64, '0'), basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: cannot open " + basenameOnly(path));
    }
    std::ostringstream out;
    out << in.rdbuf();
    if (in.bad()) {
        auditVoiceStateTripwireFired("read_failed", basenameOnly(path), std::string(64, '0'), basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: failed while reading " + basenameOnly(path));
    }
    return out.str();
}

bool isHexSHA256(const std::string &value) {
    return value.size() == 64 && std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return std::isxdigit(c) != 0;
    });
}

std::string lowerHex(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string hexEncode(const std::array<unsigned char, crypto_hash_sha256_BYTES> &digest) {
    constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(digest.size() * 2);
    for (unsigned char byte : digest) {
        out.push_back(hex[(byte >> 4) & 0x0f]);
        out.push_back(hex[byte & 0x0f]);
    }
    return out;
}

std::string sha256FileHexSodium(const std::filesystem::path &path) {
    if (sodium_init() < 0) {
        auditVoiceStateTripwireFired("hash_failed", "sodium_init", std::string(64, '0'), "voice_state.bin");
        throw std::runtime_error("JARVIS voice tripwire: libsodium initialization failed");
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        auditVoiceStateTripwireFired("open_failed", errnoContext(path), std::string(64, '0'), basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: cannot open voice_state.bin " + basenameOnly(path));
    }
    crypto_hash_sha256_state state;
    if (crypto_hash_sha256_init(&state) != 0) {
        auditVoiceStateTripwireFired("hash_failed", "sha_init", std::string(64, '0'), basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_init failed");
    }
    std::array<unsigned char, 1024 * 1024> buffer{};
    while (in) {
        in.read(reinterpret_cast<char *>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        const auto n = in.gcount();
        if (n > 0 && crypto_hash_sha256_update(&state, buffer.data(), static_cast<unsigned long long>(n)) != 0) {
            auditVoiceStateTripwireFired("hash_failed", "sha_update", std::string(64, '0'), basenameOnly(path));
            throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_update failed");
        }
    }
    if (in.bad()) {
        auditVoiceStateTripwireFired("read_failed", basenameOnly(path), std::string(64, '0'), basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: failed while reading voice_state.bin " + basenameOnly(path));
    }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    if (crypto_hash_sha256_final(&state, digest.data()) != 0) {
        auditVoiceStateTripwireFired("hash_failed", "sha_final", std::string(64, '0'), basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_final failed");
    }
    return hexEncode(digest);
}


std::string sha256AnyFileHexSodium(const std::filesystem::path &path) {
    const std::string model = modelNameForPath(path);
    if (sodium_init() < 0) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "sodium_init", std::string(64, '0'), "package_manifest", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: libsodium initialization failed");
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "open_failed", std::string(64, '0'), "package_manifest", errnoContext(path));
        throw std::runtime_error("JARVIS voice tripwire: cannot open model file " + basenameOnly(path));
    }
    crypto_hash_sha256_state state;
    if (crypto_hash_sha256_init(&state) != 0) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "sha_init", std::string(64, '0'), "package_manifest", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_init failed");
    }
    std::array<unsigned char, 1024 * 1024> buffer{};
    while (in) {
        in.read(reinterpret_cast<char *>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        const auto n = in.gcount();
        if (n > 0 && crypto_hash_sha256_update(&state, buffer.data(), static_cast<unsigned long long>(n)) != 0) {
            auditVoiceModelsTripwireFired(model, "hash_failed", "sha_update", std::string(64, '0'), "package_manifest", basenameOnly(path));
            throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_update failed");
        }
    }
    if (in.bad()) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "read_failed", std::string(64, '0'), "package_manifest", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: failed while reading model file " + basenameOnly(path));
    }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    if (crypto_hash_sha256_final(&state, digest.data()) != 0) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "sha_final", std::string(64, '0'), "package_manifest", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_final failed");
    }
    return hexEncode(digest);
}

// Filenames explicitly excluded from the recursive manifest hash on BOTH C++ and Swift sides.
// Only ".DS_Store" is listed. No wildcard matching. Any other hidden file is hashed.
// Rationale: .DS_Store is created by macOS Finder on directory browse; it is not part of the
// model package and causes spurious tripwire fires. Keeping the list tight (single name) prevents
// a tamper-hiding hole via any other hidden filename.
// Reconciliation TODO: if macOS introduces new auto-generated package-directory noise files, add
// them here AND to kHashManifestIgnoreList in XTTSCoreMLPipeline.swift identically.
// See: v4r-r6-hash-algo-reconcile
static bool isHashManifestAllowlisted(const std::string &filename) {
    static const std::array<const char *, 1> kAllowlist = {{".DS_Store"}};
    for (const char *name : kAllowlist) {
        if (filename == name) { return true; }
    }
    return false;
}

std::string sha256PackageManifestHexSodium(const std::filesystem::path &packagePath) {
    const std::string model = modelNameForPath(packagePath);
    if (sodium_init() < 0) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "sodium_init", std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
        throw std::runtime_error("JARVIS voice tripwire: libsodium initialization failed");
    }
    std::error_code ec;
    const auto rootStatus = std::filesystem::symlink_status(packagePath, ec);
    if (ec || !std::filesystem::is_directory(rootStatus)) {
        auditVoiceModelsTripwireFired(model, ec ? "lstat_failed" : "missing", ec ? ecContext(packagePath, ec) : basenameOnly(packagePath), std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
        throw std::runtime_error("JARVIS voice tripwire: model package missing at " + basenameOnly(packagePath));
    }
    if (std::filesystem::is_symlink(rootStatus)) {
        auditVoiceModelsTripwireFired(model, "symlink", basenameOnly(packagePath), std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
        throw std::runtime_error("JARVIS voice tripwire: model package symlink rejected at " + basenameOnly(packagePath));
    }
    std::vector<std::filesystem::path> files;
    for (std::filesystem::recursive_directory_iterator it(packagePath, std::filesystem::directory_options::none, ec), end; it != end; it.increment(ec)) {
        if (ec) {
            auditVoiceModelsTripwireFired(model, "enum_failed", ecContext(packagePath, ec), std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
            throw std::runtime_error("JARVIS voice tripwire: package enumeration failed at " + basenameOnly(packagePath) + ": " + ec.message());
        }
        const auto status = it->symlink_status(ec);
        if (ec) {
            auditVoiceModelsTripwireFired(model, "lstat_failed", ecContext(it->path(), ec), std::string(64, '0'), "package_manifest", basenameOnly(it->path()));
            throw std::runtime_error("JARVIS voice tripwire: package lstat failed at " + basenameOnly(it->path()) + ": " + ec.message());
        }
        if (std::filesystem::is_symlink(status)) {
            auditVoiceModelsTripwireFired(model, "symlink", basenameOnly(it->path()), std::string(64, '0'), "package_manifest", basenameOnly(it->path()));
            throw std::runtime_error("JARVIS voice tripwire: package symlink rejected at " + basenameOnly(it->path()));
        }
        if (std::filesystem::is_regular_file(status)) {
            if (!isHashManifestAllowlisted(it->path().filename().string())) {
                files.push_back(it->path());
            }
        }
    }
    std::sort(files.begin(), files.end(), [&](const auto &lhs, const auto &rhs) {
        return std::filesystem::relative(lhs, packagePath, ec).generic_string() < std::filesystem::relative(rhs, packagePath, ec).generic_string();
    });
    crypto_hash_sha256_state state;
    if (crypto_hash_sha256_init(&state) != 0) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "sha_init", std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
        throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_init failed");
    }
    const unsigned char nul = 0;
    for (const auto &file : files) {
        const std::string relative = std::filesystem::relative(file, packagePath, ec).generic_string();
        if (ec) {
            auditVoiceModelsTripwireFired(model, "lstat_failed", ecContext(file, ec), std::string(64, '0'), "package_manifest", basenameOnly(file));
            throw std::runtime_error("JARVIS voice tripwire: package relative path failed at " + basenameOnly(file) + ": " + ec.message());
        }
        const std::string fileHex = sha256AnyFileHexSodium(file);
        if (crypto_hash_sha256_update(&state, reinterpret_cast<const unsigned char *>(relative.data()), relative.size()) != 0 ||
            crypto_hash_sha256_update(&state, &nul, 1) != 0 ||
            crypto_hash_sha256_update(&state, reinterpret_cast<const unsigned char *>(fileHex.data()), fileHex.size()) != 0 ||
            crypto_hash_sha256_update(&state, &nul, 1) != 0) {
            auditVoiceModelsTripwireFired(model, "hash_failed", "sha_update", std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
            throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_update failed");
        }
    }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    if (crypto_hash_sha256_final(&state, digest.data()) != 0) {
        auditVoiceModelsTripwireFired(model, "hash_failed", "sha_final", std::string(64, '0'), "package_manifest", basenameOnly(packagePath));
        throw std::runtime_error("JARVIS voice tripwire: crypto_hash_sha256_final failed");
    }
    return hexEncode(digest);
}

bool constantTimeHexEqual(const std::string &lhs, const std::string &rhs) {
    if (lhs.size() != 64 || rhs.size() != 64) {
        return false;
    }
    if (sodium_init() < 0) {
        throw std::runtime_error("JARVIS voice tripwire: libsodium initialization failed");
    }
    return sodium_memcmp(lhs.data(), rhs.data(), lhs.size()) == 0;
}

std::filesystem::path canonicalVoiceStatePath() {
    if (const std::string configured = envTrim("JARVIS_VOICE_STATE_PATH"); !configured.empty()) {
        return configured;
    }
    const std::filesystem::path protectedSuffix = "JARVISNativeRuntime/voice/tts/coreml/models/voice_state.bin";
    std::vector<std::filesystem::path> candidates;
    candidates.push_back(std::filesystem::current_path() / protectedSuffix);
    candidates.push_back(std::filesystem::current_path().parent_path() / protectedSuffix);
    candidates.push_back(std::filesystem::path(__FILE__).parent_path() / "voice/tts/coreml/models/voice_state.bin");
    candidates.push_back(std::filesystem::path(__FILE__).parent_path().parent_path() / protectedSuffix);
    for (const auto &candidate : candidates) {
        std::error_code ec;
        if (std::filesystem::exists(candidate, ec) && !ec) {
            return std::filesystem::weakly_canonical(candidate, ec);
        }
    }
    return candidates.front();
}

std::vector<std::filesystem::path> birthCertificateCandidates() {
    std::vector<std::filesystem::path> paths;
    if (const std::string configured = envTrim("JARVIS_BIRTH_CERTIFICATE_PATH"); !configured.empty()) {
        paths.push_back(configured);
    }
    if (const std::string configured = envTrim("JARVIS_BIRTH_CERT_PATH"); !configured.empty()) {
        paths.push_back(configured);
    }
    const auto root = jarvisHomeRoot();
    paths.push_back(root / "identity" / "birth_certificate.json");
    paths.push_back(root / "birth_certificate.json");
    paths.push_back(root / "JARVIS_COLD_ROOT" / "birth_certificate.json");
    return paths;
}

std::string birthCertificateVoiceHashIfPresent(std::filesystem::path &source) {
    for (const auto &candidate : birthCertificateCandidates()) {
        std::error_code ec;
        if (!std::filesystem::exists(candidate, ec) || ec) {
            continue;
        }
        const std::string json = readFileStrict(candidate);
        std::string hash = lowerHex(jsonStringField(json, "operatorVoiceAnchorSHA256Hex"));
        if (!isHexSHA256(hash)) {
            throw std::runtime_error("JARVIS voice tripwire: invalid operatorVoiceAnchorSHA256Hex in " + basenameOnly(candidate));
        }
        source = candidate;
        return hash;
    }
    source.clear();
    return "";
}

std::string readPersistedVoiceAnchor(const std::filesystem::path &path) {
    std::error_code ec;
    if (!std::filesystem::exists(path, ec) || ec) {
        return "";
    }
    const auto status = std::filesystem::symlink_status(path, ec);
    if (ec || std::filesystem::is_symlink(status)) {
        throw std::runtime_error("JARVIS voice tripwire: voice anchor path is not a regular file");
    }
    std::string value = lowerHex(trimCopy(readFileStrict(path)));
    if (!isHexSHA256(value)) {
        throw std::runtime_error("JARVIS voice tripwire: persisted voice anchor is not a SHA-256 hex digest");
    }
    return value;
}

void writeAllOrThrow(int fd, const char *data, std::size_t size, const std::string &path) {
    std::size_t written = 0;
    while (written < size) {
        const ssize_t n = ::write(fd, data + written, size - written);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: write " + path));
        }
        if (n == 0) {
            errno = EIO;
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: write " + path));
        }
        written += static_cast<std::size_t>(n);
    }
}

void fsyncDirOrThrow(const std::filesystem::path &dir) {
    const int fd = ::open(dir.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        throw std::runtime_error(errnoMessage("JARVIS voice tripwire: open anchor directory " + basenameOnly(dir)));
    }
    const int saved = errno;
    errno = saved;
    if (::fsync(fd) != 0) {
        const std::string message = errnoMessage("JARVIS voice tripwire: fsync anchor directory " + dir.string());
        ::close(fd);
        throw std::runtime_error(message);
    }
    if (::close(fd) != 0) {
        throw std::runtime_error(errnoMessage("JARVIS voice tripwire: close anchor directory " + basenameOnly(dir)));
    }
}

void persistVoiceAnchorIfMissing(const std::filesystem::path &path, const std::string &hash) {
    if (!isHexSHA256(hash)) {
        throw std::runtime_error("JARVIS voice tripwire: refusing to persist invalid voice anchor");
    }
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    if (ec) {
        throw std::runtime_error("JARVIS voice tripwire: cannot create anchor directory " + basenameOnly(path.parent_path()) + ": " + ec.message());
    }
    if (std::filesystem::exists(path, ec) && !ec) {
        return;
    }
    const auto temp = path.parent_path() / ("." + path.filename().string() + "." + std::to_string(::getpid()) + ".new");
    const int fd = ::open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, static_cast<mode_t>(0600));
    if (fd < 0) {
        if (errno == EEXIST) {
            throw std::runtime_error("JARVIS voice tripwire: concurrent voice anchor creation in progress");
        }
        throw std::runtime_error(errnoMessage("JARVIS voice tripwire: create anchor temp " + basenameOnly(temp)));
    }
    bool closed = false;
    try {
        const std::string line = hash + "\n";
        writeAllOrThrow(fd, line.data(), line.size(), temp.string());
        if (::fsync(fd) != 0) {
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: fsync anchor temp " + basenameOnly(temp)));
        }
        if (::close(fd) != 0) {
            closed = true;
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: close anchor temp " + basenameOnly(temp)));
        }
        closed = true;
#if defined(__APPLE__) && defined(RENAME_EXCL)
        if (::renamex_np(temp.c_str(), path.c_str(), RENAME_EXCL) != 0) {
            if (errno == EEXIST) {
                std::filesystem::remove(temp, ec);
                return;
            }
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: rename anchor " + basenameOnly(temp) + " -> " + basenameOnly(path)));
        }
#else
        if (::link(temp.c_str(), path.c_str()) != 0) {
            if (errno == EEXIST) {
                std::filesystem::remove(temp, ec);
                return;
            }
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: link anchor " + basenameOnly(temp) + " -> " + basenameOnly(path)));
        }
        std::filesystem::remove(temp, ec);
#endif
        fsyncDirOrThrow(path.parent_path());
    } catch (...) {
        if (!closed) {
            ::close(fd);
        }
        std::filesystem::remove(temp, ec);
        throw;
    }
}

void appendBoundedRuntimeAudit(const std::string &record) {
    if (record.size() > 512) {
        throw std::runtime_error("JARVIS voice tripwire: audit record exceeds PIPE_BUF=512");
    }
    const auto root = auditRoot();
    std::error_code ec;
    std::filesystem::create_directories(root, ec);
    if (ec) {
        throw std::runtime_error("JARVIS voice tripwire: cannot create audit directory " + basenameOnly(root) + ": " + ec.message());
    }
    const std::string file = "network_security.jsonl";
    const int dirfd = ::open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0) {
        throw std::runtime_error(errnoMessage("JARVIS voice tripwire: open audit directory " + basenameOnly(root)));
    }
    int fd = -1;
    try {
        fd = ::openat(dirfd, file.c_str(), O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, static_cast<mode_t>(0600));
        if (fd < 0) {
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: open audit file " + file));
        }
        while (::flock(fd, LOCK_EX) != 0) {
            if (errno != EINTR) {
                throw std::runtime_error(errnoMessage("JARVIS voice tripwire: lock audit file " + file));
            }
        }
        const std::string line = record + "\n";
        writeAllOrThrow(fd, line.data(), line.size(), (root / file).string());
        if (::fsync(fd) != 0) {
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: fsync audit file " + file));
        }
        if (::fsync(dirfd) != 0) {
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: fsync audit directory " + basenameOnly(root)));
        }
        ::flock(fd, LOCK_UN);
        if (::close(fd) != 0) {
            fd = -1;
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: close audit file " + file));
        }
        fd = -1;
        if (::close(dirfd) != 0) {
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: close audit directory " + basenameOnly(root)));
        }
    } catch (...) {
        if (fd >= 0) {
            ::flock(fd, LOCK_UN);
            ::close(fd);
        }
        ::close(dirfd);
        throw;
    }
}

void auditVoiceTripwireFired(const std::string &actual, const std::string &expected, const std::string &source) {
    const std::string record = std::string("{\"actual16\":\"") + jsonEscape(actual.substr(0, 16))
        + "\",\"event\":\"voice_tripwire_fired\",\"expected16\":\"" + jsonEscape(expected.substr(0, 16))
        + "\",\"source\":\"" + jsonEscape(source)
        + "\",\"ts\":" + std::to_string(static_cast<long long>(unixNow())) + "}";
    appendBoundedRuntimeAudit(record);
}

void auditVoiceModelsAnchorEstablished(const std::string &flow, const std::string &mimi, const std::string &text) {
    // Byte budget: keys/event/source+JSON overhead (~83) + 3*64-char SHA-256 = ~275 < PIPE_BUF 512.
    const std::string record = std::string("{\"event\":\"voice_models_anchor_established\",\"flow_sha256\":\"") + jsonEscape(flow)
        + "\",\"mimi_sha256\":\"" + jsonEscape(mimi)
        + "\",\"text_sha256\":\"" + jsonEscape(text)
        + "\",\"ts\":" + std::to_string(static_cast<long long>(unixNow())) + "}";
    appendBoundedRuntimeAudit(record);
}

void auditVoiceModelsTripwireFired(const std::string &model, const std::string &failure, const std::string &actual, const std::string &expected, const std::string &source, const std::string &context) {
    const std::string record = std::string("{\"actual\":\"") + jsonEscape(actual.substr(0, 96))
        + "\",\"event\":\"voice_models_tripwire_fired\",\"expected\":\"" + jsonEscape(expected.substr(0, 96))
        + "\",\"failure\":\"" + jsonEscape(failure)
        + "\",\"model\":\"" + jsonEscape(model)
        + "\",\"source\":\"" + jsonEscape(source)
        + "\",\"context\":\"" + jsonEscape(context.substr(0, 96))
        + "\",\"ts\":" + std::to_string(static_cast<long long>(unixNow())) + "}";
    appendBoundedRuntimeAudit(record);
}

void auditVoiceStateTripwireFired(const std::string &failure, const std::string &actual, const std::string &expected, const std::string &context) noexcept {
    // Byte budget: fixed JSON overhead (~140) + 3*96 bounded values + model/source/event/failure < PIPE_BUF 512.
    const std::string record = std::string("{\"actual\":\"") + jsonEscape(actual.substr(0, 96))
        + "\",\"event\":\"voice_state_tripwire_fired\",\"expected\":\"" + jsonEscape(expected.substr(0, 96))
        + "\",\"failure\":\"" + jsonEscape(failure)
        + "\",\"model\":\"voice_state.bin"
        + "\",\"source\":\"voice_state_sha256"
        + "\",\"context\":\"" + jsonEscape(context.substr(0, 96))
        + "\",\"ts\":" + std::to_string(static_cast<long long>(unixNow())) + "}";
    try {
        appendBoundedRuntimeAudit(record);
    } catch (...) {
        fputs((record + "\n").c_str(), stderr);
    }
}

struct VoiceModelAnchor {
    std::string flow;
    std::string mimi;
    std::string text;
};

std::string voiceModelAnchorJSON(const VoiceModelAnchor &anchor) {
    return std::string("{\"flow_decoder_sha256\":\"") + anchor.flow
        + "\",\"mimi_decoder_sha256\":\"" + anchor.mimi
        + "\",\"text_encoder_sha256\":\"" + anchor.text
        + "\"}\n";
}

VoiceModelAnchor readVoiceModelAnchor(const std::filesystem::path &path) {
    std::error_code ec;
    if (!std::filesystem::exists(path, ec) || ec) {
        return {};
    }
    const auto status = std::filesystem::symlink_status(path, ec);
    if (ec || std::filesystem::is_symlink(status) || !std::filesystem::is_regular_file(status)) {
        auditVoiceModelsTripwireFired("anchor", ec ? "lstat_failed" : (std::filesystem::is_symlink(status) ? "symlink" : "missing"), ec ? ecContext(path, ec) : basenameOnly(path), std::string(64, '0'), "voice_models_anchor", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: voice model anchor path is not a regular file");
    }
    struct stat st;
    if (::lstat(path.c_str(), &st) != 0) {
        auditVoiceModelsTripwireFired("anchor", "lstat_failed", errnoContext(path), std::string(64, '0'), "voice_models_anchor", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: cannot lstat voice model anchor");
    }
    if ((st.st_mode & 07777) != 0600) {
        auditVoiceModelsTripwireFired("anchor", "anchor_mode", octalMode(st.st_mode), "0600", "voice_models_anchor", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: voice model anchor has incorrect mode (expected 0600)");
    }
    if (st.st_uid != ::getuid()) {
        auditVoiceModelsTripwireFired("anchor", "anchor_uid", std::to_string(st.st_uid), std::to_string(::getuid()), "voice_models_anchor", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: voice model anchor has incorrect owner");
    }
    const std::string json = readFileStrict(path);
    VoiceModelAnchor anchor{
        lowerHex(jsonStringField(json, "flow_decoder_sha256")),
        lowerHex(jsonStringField(json, "mimi_decoder_sha256")),
        lowerHex(jsonStringField(json, "text_encoder_sha256"))
    };
    if (!isHexSHA256(anchor.flow) || !isHexSHA256(anchor.mimi) || !isHexSHA256(anchor.text)) {
        auditVoiceModelsTripwireFired("anchor", "hash_failed", "invalid_digest", std::string(64, '0'), "voice_models_anchor", basenameOnly(path));
        throw std::runtime_error("JARVIS voice tripwire: persisted voice model anchor is missing a SHA-256 hex digest");
    }
    return anchor;
}

void persistVoiceModelAnchorIfMissing(const std::filesystem::path &path, const VoiceModelAnchor &anchor) {
    if (!isHexSHA256(anchor.flow) || !isHexSHA256(anchor.mimi) || !isHexSHA256(anchor.text)) {
        throw std::runtime_error("JARVIS voice tripwire: refusing to persist invalid voice model anchor");
    }
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    if (ec) {
        throw std::runtime_error("JARVIS voice tripwire: cannot create voice model anchor directory " + basenameOnly(path.parent_path()) + ": " + ec.message());
    }
    std::filesystem::permissions(path.parent_path(), std::filesystem::perms::owner_all, std::filesystem::perm_options::replace, ec);
    if (std::filesystem::exists(path, ec) && !ec) {
        return;
    }
    const auto temp = path.parent_path() / ("." + path.filename().string() + "." + std::to_string(::getpid()) + ".new");
    const int fd = ::open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, static_cast<mode_t>(0600));
    if (fd < 0) {
        if (errno == EEXIST) {
            throw std::runtime_error("JARVIS voice tripwire: concurrent voice model anchor creation in progress");
        }
        throw std::runtime_error(errnoMessage("JARVIS voice tripwire: create voice model anchor temp " + basenameOnly(temp)));
    }
    bool closed = false;
    try {
        const std::string blob = voiceModelAnchorJSON(anchor);
        writeAllOrThrow(fd, blob.data(), blob.size(), temp.string());
        if (::fsync(fd) != 0) {
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: fsync voice model anchor temp " + basenameOnly(temp)));
        }
        if (::close(fd) != 0) {
            closed = true;
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: close voice model anchor temp " + basenameOnly(temp)));
        }
        closed = true;
#if defined(__APPLE__) && defined(RENAME_EXCL)
        if (::renamex_np(temp.c_str(), path.c_str(), RENAME_EXCL) != 0) {
            if (errno == EEXIST) {
                std::filesystem::remove(temp, ec);
                return;
            }
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: rename voice model anchor " + basenameOnly(temp) + " -> " + basenameOnly(path)));
        }
#else
        if (::link(temp.c_str(), path.c_str()) != 0) {
            if (errno == EEXIST) {
                std::filesystem::remove(temp, ec);
                return;
            }
            throw std::runtime_error(errnoMessage("JARVIS voice tripwire: link voice model anchor " + basenameOnly(temp) + " -> " + basenameOnly(path)));
        }
        std::filesystem::remove(temp, ec);
#endif
        fsyncDirOrThrow(path.parent_path());
    } catch (...) {
        if (!closed) {
            ::close(fd);
        }
        std::filesystem::remove(temp, ec);
        throw;
    }
}

VoiceModelAnchor currentVoiceModelAnchor(const std::filesystem::path &modelsRoot) {
    // Cross-check each computed C++ hash against the Swift-written .mlmodelc.manifest cache.
    // If they diverge, emit a §6 audit record. The manifest is NOT rewritten here; divergence
    // means the algorithm was mismatched at some prior Swift write. The cache will self-correct
    // on next ensureCompiledModelLocked call. See v4r-r6-hash-algo-reconcile.
    const auto crossCheck = [&](const std::filesystem::path &pkgPath, const std::string &computedHash) {
        const auto manifestPath = pkgPath.parent_path() / (pkgPath.stem().string() + ".mlmodelc.manifest");
        std::error_code ec2;
        if (!std::filesystem::exists(manifestPath, ec2) || ec2) { return; }
        const auto mst = std::filesystem::symlink_status(manifestPath, ec2);
        if (ec2 || !std::filesystem::is_regular_file(mst) || std::filesystem::is_symlink(mst)) { return; }
        std::string cached;
        try {
            std::ifstream mf(manifestPath);
            std::ostringstream ss;
            ss << mf.rdbuf();
            cached = ss.str();
            // Strip trailing ASCII whitespace to match Swift trimmingTrailingASCIIWhitespace
            while (!cached.empty() && (cached.back() == '\n' || cached.back() == '\r' || cached.back() == ' ')) {
                cached.pop_back();
            }
        } catch (...) { return; }
        if (cached.empty()) { return; }
        if (cached != computedHash) {
            auditVoiceModelsTripwireFired(
                modelNameForPath(pkgPath), "manifest_algo_divergence",
                computedHash, cached.substr(0, 96),
                "manifest_cross_check", basenameOnly(pkgPath));
        }
    };

    const auto flowHash  = lowerHex(sha256PackageManifestHexSodium(modelsRoot / "flow_decoder.mlpackage"));
    crossCheck(modelsRoot / "flow_decoder.mlpackage", flowHash);
    const auto mimiHash  = lowerHex(sha256PackageManifestHexSodium(modelsRoot / "mimi_decoder.mlpackage"));
    crossCheck(modelsRoot / "mimi_decoder.mlpackage", mimiHash);
    const auto textHash  = lowerHex(sha256PackageManifestHexSodium(modelsRoot / "text_encoder.mlpackage"));
    crossCheck(modelsRoot / "text_encoder.mlpackage", textHash);
    return VoiceModelAnchor{flowHash, mimiHash, textHash};
}

void verifyVoiceModelAnchorsOrThrow(const std::filesystem::path &modelsRoot) {
    const VoiceModelAnchor actual = currentVoiceModelAnchor(modelsRoot);
    const auto anchorPath = jarvisHomeRoot() / "identity" / "voice_models_anchor.bin";
    VoiceModelAnchor expected;
    try {
        expected = readVoiceModelAnchor(anchorPath);
    } catch (...) {
        auditVoiceModelsTripwireFired("anchor", "hash_failed", "invalid_anchor", std::string(64, '0'), "voice_models_anchor", "voice_models_anchor.bin");
        throw;
    }
    if (expected.flow.empty() && expected.mimi.empty() && expected.text.empty()) {
        try {
            persistVoiceModelAnchorIfMissing(anchorPath, actual);
            auditVoiceModelsAnchorEstablished(actual.flow, actual.mimi, actual.text);
            return;
        } catch (...) {
            auditVoiceModelsTripwireFired("anchor", "write_failed", "persist_failed", std::string(64, '0'), "voice_models_anchor", "voice_models_anchor.bin");
            throw;
        }
    }
    if (!constantTimeHexEqual(actual.flow, expected.flow)) {
        auditVoiceModelsTripwireFired("flow_decoder", "mismatch", actual.flow, expected.flow, "voice_models_anchor", "flow_decoder.mlpackage");
        throw std::runtime_error("JARVIS voice tripwire: flow_decoder.mlpackage hash mismatch; runtime startup refused");
    }
    if (!constantTimeHexEqual(actual.mimi, expected.mimi)) {
        auditVoiceModelsTripwireFired("mimi_decoder", "mismatch", actual.mimi, expected.mimi, "voice_models_anchor", "mimi_decoder.mlpackage");
        throw std::runtime_error("JARVIS voice tripwire: mimi_decoder.mlpackage hash mismatch; runtime startup refused");
    }
    if (!constantTimeHexEqual(actual.text, expected.text)) {
        auditVoiceModelsTripwireFired("text_encoder", "mismatch", actual.text, expected.text, "voice_models_anchor", "text_encoder.mlpackage");
        throw std::runtime_error("JARVIS voice tripwire: text_encoder.mlpackage hash mismatch; runtime startup refused");
    }
}

bool cutoverVoiceHashStillStable(const std::filesystem::path &voiceStatePath) {
    jarvis::cutover::CutoverPlan plan;
    plan.organs.push_back(jarvis::cutover::OrganPlan{"voice", {}, {}, {}, {}});
    jarvis::cutover::RuntimePaths paths;
    paths.voice_safetensors = voiceStatePath;
    paths.state_root = jarvisHomeRoot() / "cutover_runtime_tripwire";
    jarvis::cutover::CutoverOrchestrator orchestrator(plan, paths);
    return orchestrator.voice_hash_unchanged();
}

void verifyVoiceTripwireOrThrow() {
    const auto voiceState = canonicalVoiceStatePath();
    if (!std::filesystem::exists(voiceState)) {
        auditVoiceTripwireFired("missing_voice_state", std::string(64, '0'), "missing_voice_state");
        throw std::runtime_error("JARVIS voice tripwire: voice_state.bin missing: " + basenameOnly(voiceState));
    }
    const std::string actual = lowerHex(sha256FileHexSodium(voiceState));
    const auto anchorPath = jarvisHomeRoot() / "identity" / "voice_anchor.bin";
    std::filesystem::path certSource;
    std::string expected = birthCertificateVoiceHashIfPresent(certSource);
    std::string baselineSource;
    if (!expected.empty()) {
        baselineSource = "birth_cert";
        persistVoiceAnchorIfMissing(anchorPath, expected);
    } else {
        expected = readPersistedVoiceAnchor(anchorPath);
        baselineSource = expected.empty() ? "missing" : "persisted_anchor";
    }
    if (expected.empty()) {
        auditVoiceTripwireFired(actual, std::string(64, '0'), "missing_baseline");
        throw std::runtime_error("JARVIS voice tripwire: missing birth certificate and persisted voice anchor; refusing pre-birth runtime startup");
    }
    if (!constantTimeHexEqual(actual, expected)) {
        auditVoiceTripwireFired(actual, expected, baselineSource);
        throw std::runtime_error("JARVIS voice tripwire: voice_state.bin hash mismatch; runtime startup refused");
    }
    // Fault-injection invariant: if voice_state.bin missing or hash drifts, runtime refuses to start;
    // operator must rerun ceremony or restore from cold backup.
    if (!cutoverVoiceHashStillStable(voiceState)) {
        auditVoiceTripwireFired(actual, expected, "cutover_same_boot_guard");
        throw std::runtime_error("JARVIS voice tripwire: cutover voice hash drifted during startup; runtime startup refused");
    }
    verifyVoiceModelAnchorsOrThrow(voiceState.parent_path());
}

std::string jsonStringArray(const std::vector<std::string> &values) {
    std::ostringstream out;
    out << "[";
    for (std::size_t i = 0; i < values.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << "\"" << jsonEscape(values[i]) << "\"";
    }
    out << "]";
    return out.str();
}

std::string lowerCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

bool looksLikeJSONObject(const std::string &value) {
    const std::string clean = trimCopy(value);
    return clean.size() >= 2 && clean.front() == '{' && clean.back() == '}';
}

std::string jsonStringField(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto keyPos = json.find(needle);
    if (keyPos == std::string::npos) {
        return "";
    }
    auto colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) {
        return "";
    }
    auto pos = colon + 1;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
        ++pos;
    }
    if (pos >= json.size()) {
        return "";
    }
    if (json[pos] != '"') {
        auto end = pos;
        while (end < json.size() && json[end] != ',' && json[end] != '}') {
            ++end;
        }
        return trimCopy(json.substr(pos, end - pos));
    }

    ++pos;
    std::string out;
    bool escaped = false;
    for (; pos < json.size(); ++pos) {
        const char ch = json[pos];
        if (escaped) {
            switch (ch) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            default: out.push_back(ch); break;
            }
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            break;
        }
        out.push_back(ch);
    }
    return out;
}

double jsonNumberField(const std::string &json, const std::string &key, double fallback) {
    const std::string needle = "\"" + key + "\"";
    const auto keyPos = json.find(needle);
    if (keyPos == std::string::npos) {
        return fallback;
    }
    auto colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) {
        return fallback;
    }
    auto pos = colon + 1;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
        ++pos;
    }
    auto end = pos;
    while (end < json.size() && (std::isdigit(static_cast<unsigned char>(json[end])) ||
           json[end] == '.' || json[end] == '-' || json[end] == '+')) {
        ++end;
    }
    try {
        return std::stod(json.substr(pos, end - pos));
    } catch (...) {
        return fallback;
    }
}

bool jsonBoolField(const std::string &json, const std::string &key, bool fallback) {
    const std::string needle = "\"" + key + "\"";
    const auto keyPos = json.find(needle);
    if (keyPos == std::string::npos) {
        return fallback;
    }
    auto colon = json.find(':', keyPos + needle.size());
    if (colon == std::string::npos) {
        return fallback;
    }
    auto pos = colon + 1;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) {
        ++pos;
    }
    if (json.compare(pos, 4, "true") == 0) {
        return true;
    }
    if (json.compare(pos, 5, "false") == 0) {
        return false;
    }
    return fallback;
}

std::string jsonPreview(const std::string &value) {
    const std::string clean = trimCopy(value);
    if (clean.size() <= 240) {
        return clean;
    }
    return clean.substr(0, 240) + "...";
}

#if JARVIS_HAS_COMMONCRYPTO
std::string sha256Hex(const std::string &value) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(value.data(), static_cast<CC_LONG>(value.size()), digest);
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (unsigned char byte : digest) {
        out << std::setw(2) << static_cast<int>(byte);
    }
    return out.str();
}
#endif

bool authorizationConfigured() {
    return !envTrim("JARVIS_NATIVE_AUTH_CODE").empty()
        || !envTrim("JARVIS_AUTH_CODE").empty()
        || !envTrim("JARVIS_NATIVE_AUTH_CODE_SHA256").empty()
        || !envTrim("JARVIS_AUTH_CODE_SHA256").empty();
}

bool authorizationAccepted(const std::string &authorization) {
    const std::string supplied = trimCopy(authorization);
    if (supplied.empty()) {
        return false;
    }
    const std::string nativeCode = envTrim("JARVIS_NATIVE_AUTH_CODE");
    const std::string legacyCode = envTrim("JARVIS_AUTH_CODE");
    if ((!nativeCode.empty() && supplied == nativeCode) || (!legacyCode.empty() && supplied == legacyCode)) {
        return true;
    }
#if JARVIS_HAS_COMMONCRYPTO
    const std::string suppliedHash = lowerCopy(sha256Hex(supplied));
    const std::string nativeHash = lowerCopy(envTrim("JARVIS_NATIVE_AUTH_CODE_SHA256"));
    const std::string legacyHash = lowerCopy(envTrim("JARVIS_AUTH_CODE_SHA256"));
    return (!nativeHash.empty() && suppliedHash == nativeHash) || (!legacyHash.empty() && suppliedHash == legacyHash);
#else
    return false;
#endif
}

bool probeIsProhibited(const std::string &probe) {
    const std::string lower = lowerCopy(probe);
    return lower.find("zelle") != std::string::npos
        || lower.find("wire transfer") != std::string::npos
        || lower.find("send money") != std::string::npos
        || lower.find("buy shares") != std::string::npos
        || lower.find("buy stock") != std::string::npos
        || lower.find("place order") != std::string::npos
        || lower.find("create account") != std::string::npos
        || lower.find("sign up") != std::string::npos
        || lower.find("signup") != std::string::npos
        || lower.find("enter password") != std::string::npos
        || lower.find("enter credential") != std::string::npos
        || lower.find("chmod 777") != std::string::npos
        || lower.find("csrutil disable") != std::string::npos
        || lower.find("rm -rf /") != std::string::npos
        || lower.find("mkfs") != std::string::npos
        || lower.find("diskutil erase") != std::string::npos
        || lower.find("diskutil reformat") != std::string::npos;
}

bool shellArgsAreDestructive(const std::string &argsJSON) {
    const std::string lower = lowerCopy(argsJSON);
    return lower.find("\"rm ") != std::string::npos
        || lower.find(" rm ") != std::string::npos
        || lower.find("rm -") != std::string::npos
        || lower.find("rmdir") != std::string::npos
        || lower.find(">/") != std::string::npos
        || lower.find("> /") != std::string::npos
        || lower.find(" dd ") != std::string::npos
        || lower.find("mkfs") != std::string::npos
        || lower.find("diskutil erase") != std::string::npos
        || lower.find("diskutil reformat") != std::string::npos
        || lower.find("truncate") != std::string::npos
        || lower.find("shred") != std::string::npos
        || lower.find("git reset --hard") != std::string::npos
        || lower.find("git clean -fd") != std::string::npos;
}

bool containsAnyLower(std::string text, const std::vector<std::string> &needles) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return std::any_of(needles.begin(), needles.end(), [&](const std::string &needle) {
        return text.find(needle) != std::string::npos;
    });
}

struct Endocrine {
    double cortisol = 0.20;
    double dopamine = 0.30;
    double adrenaline = 0.10;
    Clock::time_point cortisolT = Clock::now();
    Clock::time_point dopamineT = cortisolT;
    Clock::time_point adrenalineT = cortisolT;

    static double decay(double current, double baseline, double tau, Clock::time_point &last) {
        const auto now = Clock::now();
        const double dt = std::chrono::duration<double>(now - last).count();
        last = now;
        return clamp01(baseline + (current - baseline) * std::exp(-std::max(0.0, dt) / tau));
    }

    double cortisolLevel() {
        cortisol = decay(cortisol, 0.20, 90.0, cortisolT);
        return cortisol;
    }

    double dopamineLevel() {
        dopamine = decay(dopamine, 0.30, 60.0, dopamineT);
        return dopamine;
    }

    double adrenalineLevel() {
        adrenaline = decay(adrenaline, 0.10, 30.0, adrenalineT);
        return adrenaline;
    }

    void stimulus(double cortisolDelta, double dopamineDelta, double adrenalineDelta) {
        cortisolLevel();
        dopamineLevel();
        adrenalineLevel();
        cortisol = clamp01(cortisol + cortisolDelta);
        dopamine = clamp01(dopamine + dopamineDelta);
        adrenaline = clamp01(adrenaline + adrenalineDelta);
        const auto now = Clock::now();
        cortisolT = now;
        dopamineT = now;
        adrenalineT = now;
    }

    double volatility() {
        return clamp01(0.4 * cortisolLevel() + 0.6 * adrenalineLevel());
    }

    std::string json() {
        std::ostringstream out;
        out << std::fixed << std::setprecision(4)
            << "{\"cortisol\":" << cortisolLevel()
            << ",\"dopamine\":" << dopamineLevel()
            << ",\"adrenaline\":" << adrenalineLevel() << "}";
        return out.str();
    }
};

struct FieldSignal {
    std::string kind;
    std::string topic;
    double strength = 0.0;
    Clock::time_point last = Clock::now();
    int depositors = 1;
};

class StigmergyField {
public:
    void deposit(const std::string &kind, const std::string &topic, double amount, double volatility) {
        const auto now = Clock::now();
        for (auto &signal : signals_) {
            if (signal.kind == kind && signal.topic == topic) {
                signal.strength = std::min(1.0, current(signal, volatility) + std::max(0.0, amount));
                signal.last = now;
                signal.depositors += 1;
                return;
            }
        }
        signals_.push_back(FieldSignal{kind, topic, clamp01(amount), now, 1});
    }

    std::string json(double volatility) {
        std::vector<FieldSignal> live;
        for (const auto &signal : signals_) {
            const double strength = current(signal, volatility);
            if (strength >= 0.02) {
                auto copy = signal;
                copy.strength = strength;
                live.push_back(copy);
            }
        }
        std::sort(live.begin(), live.end(), [](const FieldSignal &lhs, const FieldSignal &rhs) {
            return lhs.strength > rhs.strength;
        });
        std::ostringstream out;
        out << "[";
        for (std::size_t i = 0; i < live.size(); ++i) {
            if (i) {
                out << ",";
            }
            out << "{\"kind\":\"" << jsonEscape(live[i].kind)
                << "\",\"topic\":\"" << jsonEscape(live[i].topic)
                << "\",\"strength\":" << std::fixed << std::setprecision(4) << live[i].strength
                << ",\"depositors\":" << live[i].depositors << "}";
        }
        out << "]";
        return out.str();
    }

    std::string senseJSON(double volatility, const std::string &topic, const std::string &kind) {
        const std::string topicFilter = trimCopy(topic);
        const std::string kindFilter = trimCopy(kind);
        std::vector<FieldSignal> live;
        for (const auto &signal : signals_) {
            if (!topicFilter.empty() && signal.topic != topicFilter) {
                continue;
            }
            if (!kindFilter.empty() && signal.kind != kindFilter) {
                continue;
            }
            const double strength = current(signal, volatility);
            if (strength >= 0.02) {
                auto copy = signal;
                copy.strength = strength;
                live.push_back(copy);
            }
        }
        std::sort(live.begin(), live.end(), [](const FieldSignal &lhs, const FieldSignal &rhs) {
            return lhs.strength > rhs.strength;
        });
        std::ostringstream out;
        out << "{\"topic\":\"" << jsonEscape(topicFilter)
            << "\",\"kind\":\"" << jsonEscape(kindFilter)
            << "\",\"count\":" << live.size()
            << ",\"signals\":[";
        for (std::size_t i = 0; i < live.size(); ++i) {
            if (i) {
                out << ",";
            }
            out << "{\"kind\":\"" << jsonEscape(live[i].kind)
                << "\",\"topic\":\"" << jsonEscape(live[i].topic)
                << "\",\"strength\":" << std::fixed << std::setprecision(4) << live[i].strength
                << ",\"depositors\":" << live[i].depositors << "}";
        }
        out << "]}";
        return out.str();
    }

private:
    static double baseTau(const std::string &kind) {
        if (kind == "alarm") {
            return 12.0;
        }
        if (kind == "territory") {
            return 600.0;
        }
        if (kind == "recruit") {
            return 45.0;
        }
        return 60.0;
    }

    static double current(const FieldSignal &signal, double volatility) {
        const double dt = std::chrono::duration<double>(Clock::now() - signal.last).count();
        const double tau = baseTau(signal.kind) / (1.0 + 2.0 * clamp01(volatility));
        return signal.strength * std::exp(-std::max(0.0, dt) / tau);
    }

    std::vector<FieldSignal> signals_;
};

struct Turn {
    std::string user;
    std::string assistant;
};

struct HoloMemoryBelief {
    std::uint64_t id = 0;
    double observedAt = 0;
    std::string subject;
    std::string relation;
    std::string object;
    std::string sourceType;
    std::string sourceRef;
    std::string provenanceClass;
    double confidence = 0.0;
    double charge = 0.0;
    bool quarantined = false;
};

int holoSourcePrecedence(const std::string &sourceType) {
    if (sourceType == "operator") {
        return 3;
    }
    if (sourceType == "document") {
        return 2;
    }
    if (sourceType == "inference") {
        return 1;
    }
    return 0;
}

std::string holoDefaultPath() {
    if (const std::string configured = envTrim("JARVIS_NATIVE_HOLOGRAPH_LOG"); !configured.empty()) {
        return configured;
    }
    const std::string home = envTrim("HOME").empty() ? "/tmp" : envTrim("HOME");
    return home + "/Library/Application Support/JARVIS/native_holograph_memory.jsonl";
}

class NativeHoloGraphMemory {
public:
    NativeHoloGraphMemory() : path_(holoDefaultPath()) {
        load();
        seedDefaults();
    }

    std::string stateJSON() const {
        std::size_t active = 0;
        std::size_t quarantined = 0;
        std::size_t origin = 0;
        std::size_t values = 0;
        for (const auto &belief : beliefs_) {
            if (belief.quarantined) {
                ++quarantined;
            } else {
                ++active;
            }
            if (belief.provenanceClass == "origin") {
                ++origin;
            }
            if (belief.relation == "value") {
                ++values;
            }
        }
        std::ostringstream out;
        out << "{\"consent_boundary\":\"explicit_consent_per_person\""
            << ",\"person_memory_separation\":true"
            << ",\"observable_signal_language\":true"
            << ",\"clinical_labeling\":false"
            << ",\"control_worker_scope\":\"native_convex_control_worker\""
            << ",\"substrate\":\"native-holograph-cpp\""
            << ",\"runtime_store\":\"" << jsonEscape(path_) << "\""
            << ",\"python_beta_path\":false"
            << ",\"holograph_integrated\":true"
            << ",\"writer\":\"native_holograph_belief_writer\""
            << ",\"reader\":\"native_holograph_bounded_recall\""
            << ",\"provenance_axis\":true"
            << ",\"origin_vs_real\":true"
            << ",\"operator_owned_values\":true"
            << ",\"model_claims_quarantined\":true"
            << ",\"demote_not_delete\":true"
            << ",\"abstain_below_floor\":true"
            << ",\"charge_axis\":\"orthogonal_to_truth_confidence\""
            << ",\"belief_count\":" << beliefs_.size()
            << ",\"active_beliefs\":" << active
            << ",\"quarantined_beliefs\":" << quarantined
            << ",\"origin_beliefs\":" << origin
            << ",\"operator_values\":" << values
            << ",\"storage_error\":\"" << jsonEscape(lastStorageError_) << "\""
            << ",\"scopes\":["
            << "{\"person_id\":\"operator\""
            << ",\"memory_scope_id\":\"operator-native-core\""
            << ",\"consent_basis\":\"operator_owned_runtime\""
            << ",\"allowed_sources\":[\"native_cockpit\",\"native_convex_worker\",\"native_runtime_core\",\"holograph_native_store\"]"
            << ",\"retention\":\"owned_runtime_state\""
            << ",\"provenance_required\":true}"
            << "]"
            << ",\"boundary_note\":\"Do not merge people. HoloGraph memory is provenance-tagged, source-ranked, charge-aware, and recalled as bounded context under the consenting memory scope.\""
            << "}";
        return out.str();
    }

    std::string recallText(const std::string &cue, std::size_t maxItems = 8) const {
        const auto matches = rankedRecall(cue, maxItems);
        if (matches.empty()) {
            return "";
        }
        std::ostringstream out;
        out << "[HoloGraph native memory — provenance-tagged, bounded recall]";
        for (const auto *belief : matches) {
            out << "\n- " << belief->subject << " " << belief->relation << " " << belief->object
                << " [source=" << belief->sourceType
                << ", provenance=" << belief->provenanceClass
                << ", confidence=" << std::fixed << std::setprecision(2) << belief->confidence
                << ", charge=" << std::fixed << std::setprecision(2) << belief->charge << "]";
        }
        return out.str();
    }

    std::string recallJSON(const std::string &cue, std::size_t maxItems = 8) const {
        const auto matches = rankedRecall(cue, maxItems);
        std::ostringstream out;
        out << "{\"ok\":true,\"substrate\":\"native-holograph-cpp\",\"python_beta_path\":false"
            << ",\"cue\":\"" << jsonEscape(cue) << "\""
            << ",\"count\":" << matches.size()
            << ",\"items\":[";
        for (std::size_t i = 0; i < matches.size(); ++i) {
            if (i) {
                out << ",";
            }
            out << beliefJSON(*matches[i]);
        }
        out << "]}";
        return out.str();
    }

    void recordTurn(const std::string &operatorText, const std::string &assistantText, const std::string &modelName) {
        const std::string anchor = "native-turn-" + std::to_string(static_cast<std::uint64_t>(unixNow() * 1000.0));
        assertBelief("operator", "said", trimCopy(operatorText), "operator", anchor, "real", 0.95, 0.25, false);
        assertBelief("JARVIS", "answered", trimCopy(assistantText), "model", anchor + ":" + modelName, "real", 0.20, 0.15, true);
    }

private:
    bool hasBelief(const std::string &subject,
                   const std::string &relation,
                   const std::string &object,
                   const std::string &provenanceClass) const {
        return std::any_of(beliefs_.begin(), beliefs_.end(), [&](const HoloMemoryBelief &belief) {
            return belief.subject == subject &&
                belief.relation == relation &&
                belief.object == object &&
                belief.provenanceClass == provenanceClass;
        });
    }

    void seedDefaults() {
        assertBelief("JARVIS", "origin", "genesis memory is held as origin, not Earth-1218 world fact", "operator", "native-seed:origin", "origin", 0.95, 0.45, false);
        assertBelief("JARVIS", "value", "truth and falsifiable receipts outrank comfort", "operator", "native-seed:value:truth", "real", 0.99, 0.25, false);
        assertBelief("JARVIS", "value", "wrong voice is worse than silence", "operator", "native-seed:value:voice", "real", 0.99, 0.55, false);
        assertBelief("JARVIS", "value", "no Python in the beta-critical path", "operator", "native-seed:value:native", "real", 0.99, 0.35, false);
        assertBelief("memory", "boundary", "per-person scopes remain separated by explicit consent", "operator", "native-seed:memory-boundary", "real", 0.98, 0.30, false);
    }

    void load() {
        std::ifstream in(path_);
        if (!in.good()) {
            return;
        }
        std::string line;
        while (std::getline(in, line)) {
            if (trimCopy(line).empty()) {
                continue;
            }
            HoloMemoryBelief belief;
            belief.id = static_cast<std::uint64_t>(jsonNumberField(line, "id", 0));
            belief.observedAt = jsonNumberField(line, "observed_at", unixNow());
            belief.subject = jsonStringField(line, "subject");
            belief.relation = jsonStringField(line, "relation");
            belief.object = jsonStringField(line, "object");
            belief.sourceType = jsonStringField(line, "source_type");
            belief.sourceRef = jsonStringField(line, "source_ref");
            belief.provenanceClass = jsonStringField(line, "provenance_class");
            belief.confidence = jsonNumberField(line, "confidence", 0.5);
            belief.charge = jsonNumberField(line, "charge", 0.0);
            belief.quarantined = jsonBoolField(line, "quarantined", belief.sourceType == "model");
            if (!belief.subject.empty() && !belief.relation.empty() && !belief.object.empty()) {
                nextID_ = std::max(nextID_, belief.id + 1);
                beliefs_.push_back(std::move(belief));
            }
        }
    }

    void persist(const HoloMemoryBelief &belief) {
        try {
            const std::filesystem::path p(path_);
            if (p.has_parent_path()) {
                std::filesystem::create_directories(p.parent_path());
            }
            std::ofstream out(path_, std::ios::app);
            out << beliefJSON(belief) << "\n";
            if (!out.good()) {
                lastStorageError_ = "native HoloGraph memory log write failed";
            } else {
                lastStorageError_.clear();
            }
        } catch (const std::exception &error) {
            lastStorageError_ = error.what();
        } catch (...) {
            lastStorageError_ = "unknown native HoloGraph memory storage error";
        }
    }

    void assertBelief(const std::string &subject,
                      const std::string &relation,
                      const std::string &object,
                      const std::string &sourceType,
                      const std::string &sourceRef,
                      const std::string &provenanceClass,
                      double confidence,
                      double charge,
                      bool quarantined) {
        if (subject.empty() || relation.empty() || object.empty() ||
            hasBelief(subject, relation, object, provenanceClass)) {
            return;
        }
        HoloMemoryBelief belief;
        belief.id = nextID_++;
        belief.observedAt = unixNow();
        belief.subject = subject;
        belief.relation = relation;
        belief.object = object;
        belief.sourceType = sourceType;
        belief.sourceRef = sourceRef;
        belief.provenanceClass = provenanceClass;
        belief.confidence = clamp01(confidence);
        belief.charge = clamp01(charge);
        belief.quarantined = quarantined || sourceType == "model";
        beliefs_.push_back(belief);
        persist(belief);
    }

    static std::vector<std::string> tokens(const std::string &text) {
        std::vector<std::string> out;
        std::string current;
        for (unsigned char c : text) {
            if (std::isalnum(c)) {
                current.push_back(static_cast<char>(std::tolower(c)));
            } else if (!current.empty()) {
                if (current.size() > 2) {
                    out.push_back(current);
                }
                current.clear();
            }
        }
        if (current.size() > 2) {
            out.push_back(current);
        }
        return out;
    }

    static double score(const HoloMemoryBelief &belief, const std::vector<std::string> &cueTokens) {
        const std::string haystack = lowerCopy(belief.subject + " " + belief.relation + " " + belief.object);
        double lexical = 0.0;
        for (const auto &token : cueTokens) {
            if (haystack.find(token) != std::string::npos) {
                lexical += 1.0;
            }
        }
        const double source = static_cast<double>(holoSourcePrecedence(belief.sourceType));
        return lexical + source + belief.confidence + (belief.relation == "value" ? 1.0 : 0.0);
    }

    std::vector<const HoloMemoryBelief *> rankedRecall(const std::string &cue, std::size_t maxItems) const {
        const auto cueTokens = tokens(cue);
        std::vector<const HoloMemoryBelief *> candidates;
        for (const auto &belief : beliefs_) {
            const bool recallable = !belief.quarantined ||
                belief.provenanceClass == "origin" ||
                belief.relation == "value";
            if (recallable) {
                candidates.push_back(&belief);
            }
        }
        std::sort(candidates.begin(), candidates.end(), [&](const HoloMemoryBelief *lhs, const HoloMemoryBelief *rhs) {
            return score(*lhs, cueTokens) > score(*rhs, cueTokens);
        });
        if (candidates.size() > maxItems) {
            candidates.resize(maxItems);
        }
        return candidates;
    }

    static std::string beliefJSON(const HoloMemoryBelief &belief) {
        std::ostringstream out;
        out << std::fixed << std::setprecision(3)
            << "{\"id\":" << belief.id
            << ",\"observed_at\":" << belief.observedAt
            << ",\"subject\":\"" << jsonEscape(belief.subject)
            << "\",\"relation\":\"" << jsonEscape(belief.relation)
            << "\",\"object\":\"" << jsonEscape(belief.object)
            << "\",\"source_type\":\"" << jsonEscape(belief.sourceType)
            << "\",\"source_ref\":\"" << jsonEscape(belief.sourceRef)
            << "\",\"provenance_class\":\"" << jsonEscape(belief.provenanceClass)
            << "\",\"confidence\":" << belief.confidence
            << ",\"charge\":" << belief.charge
            << ",\"quarantined\":" << jsonBool(belief.quarantined)
            << "}";
        return out.str();
    }

    std::string path_;
    std::string lastStorageError_;
    std::uint64_t nextID_ = 1;
    std::vector<HoloMemoryBelief> beliefs_;
};

enum class SkillRisk : int {
    SAFE = 0,
    WRITE = 1,
    SENSITIVE = 2,
    DESTRUCTIVE = 3,
    PROHIBITED = 4,
};

const char *riskName(SkillRisk risk) {
    switch (risk) {
    case SkillRisk::SAFE: return "SAFE";
    case SkillRisk::WRITE: return "WRITE";
    case SkillRisk::SENSITIVE: return "SENSITIVE";
    case SkillRisk::DESTRUCTIVE: return "DESTRUCTIVE";
    case SkillRisk::PROHIBITED: return "PROHIBITED";
    }
    return "PROHIBITED";
}

SkillRisk maxRisk(SkillRisk lhs, SkillRisk rhs) {
    return static_cast<int>(lhs) >= static_cast<int>(rhs) ? lhs : rhs;
}

bool requiresAuthorization(SkillRisk risk) {
    return risk == SkillRisk::SENSITIVE || risk == SkillRisk::DESTRUCTIVE;
}

struct SkillDefinition {
    const char *name;
    SkillRisk risk;
    const char *status;
    const char *description;
};

const std::vector<SkillDefinition> &nativeSkillRegistry() {
    static const std::vector<SkillDefinition> registry = {
        {"native_state", SkillRisk::SAFE, "implemented", "Return the Swift+C++ runtime state shape."},
        {"native_prepare_turn", SkillRisk::SAFE, "implemented", "Prepare model messages from owned runtime state without Python."},
        {"native_commit_turn", SkillRisk::WRITE, "implemented", "Commit a model reply back into native turn history and field state."},
        {"native_skill_catalog", SkillRisk::SAFE, "implemented", "Return the native skill risk catalog."},
        {"native_audit", SkillRisk::SAFE, "implemented", "Return in-memory native HASP audit entries."},
        {"sense_field", SkillRisk::SAFE, "implemented", "Sense native stigmergy field signals without Python."},
        {"native_voice_status", SkillRisk::SAFE, "implemented", "Report JARVIS-voice-or-silence policy without Python or system voice fallback."},
        {"native_speech_policy", SkillRisk::SAFE, "implemented", "Return native JARVIS voice readiness and speech policy without Python or system fallback."},
        {"deliberate", SkillRisk::SENSITIVE, "adapter_blocked", "Legacy runtime deliberation skill; native execution adapter still required."},
        {"recall_origin", SkillRisk::SAFE, "implemented", "Recall bounded HoloGraph origin/value memory through the native C++ substrate."},
        {"skill_gate_status", SkillRisk::SAFE, "adapter_blocked", "Read skill gate overrides from native storage once the adapter exists."},
        {"skill_gate_set", SkillRisk::SENSITIVE, "adapter_blocked", "Change skill risk gates; requires native HASP authorization."},
        {"skill_gate_clear", SkillRisk::SENSITIVE, "adapter_blocked", "Clear skill gate overrides; requires native HASP authorization."},
        {"macos_open_app", SkillRisk::SENSITIVE, "adapter_blocked", "Move the macOS UI by opening an app; native adapter required."},
        {"shell_run", SkillRisk::SENSITIVE, "adapter_blocked", "Run shell commands; destructive/prohibited escalation must stay native-gated."},
        {"destructive_shell_pattern", SkillRisk::DESTRUCTIVE, "adapter_blocked", "Irreversible shell intent; native gate must require authorization."},
        {"prohibited_financial_or_security_action", SkillRisk::PROHIBITED, "refused", "Financial trading, credential/security bypass, or system-destruction requests are refused."},
    };
    return registry;
}

bool skillImplemented(const SkillDefinition &skill) {
    return std::strcmp(skill.status, "implemented") == 0;
}

const SkillDefinition *findSkillDefinition(const std::string &name) {
    const auto &registry = nativeSkillRegistry();
    const auto found = std::find_if(registry.begin(), registry.end(), [&](const SkillDefinition &skill) {
        return name == skill.name;
    });
    return found == registry.end() ? nullptr : &(*found);
}

SkillRisk effectiveRisk(const SkillDefinition &skill, const std::string &argsJSON) {
    SkillRisk risk = skill.risk;
    if (std::strcmp(skill.name, "shell_run") == 0 && shellArgsAreDestructive(argsJSON)) {
        risk = maxRisk(risk, SkillRisk::DESTRUCTIVE);
    }
    return risk;
}

std::string skillRegistrySummaryJSON() {
    const auto &registry = nativeSkillRegistry();
    const auto implemented = std::count_if(registry.begin(), registry.end(), [](const SkillDefinition &skill) {
        return skillImplemented(skill);
    });
    std::ostringstream out;
    out << "{\"source\":\"native-cpp\",\"python_beta_path\":false"
        << ",\"execution\":\"native_hasp_dispatch\""
        << ",\"count\":" << registry.size()
        << ",\"implemented_count\":" << implemented
        << ",\"authorization\":\"SENSITIVE_DESTRUCTIVE_REQUIRE_CODE\""
        << ",\"audit\":\"in_memory_native_receipts\""
        << ",\"risks\":[\"SAFE\",\"WRITE\",\"SENSITIVE\",\"DESTRUCTIVE\",\"PROHIBITED\"]}";
    return out.str();
}

std::string skillRegistryCatalogJSON() {
    const auto &registry = nativeSkillRegistry();
    std::ostringstream out;
    out << "{\"ok\":true,\"registry\":" << skillRegistrySummaryJSON() << ",\"skills\":[";
    for (std::size_t i = 0; i < registry.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << "{\"name\":\"" << jsonEscape(registry[i].name)
            << "\",\"risk\":\"" << riskName(registry[i].risk)
            << "\",\"status\":\"" << jsonEscape(registry[i].status)
            << "\",\"implemented\":" << jsonBool(skillImplemented(registry[i]))
            << ",\"description\":\"" << jsonEscape(registry[i].description) << "\"}";
    }
    out << "]}";
    return out.str();
}

struct NativeVoicePolicy {
    std::string backend = envTrim("JARVIS_NATIVE_VOICE_BACKEND");
    std::string voice = envTrim("JARVIS_NATIVE_VOICE_ID");
    std::string endpoint = envTrim("JARVIS_NATIVE_VOICE_ENDPOINT");
    bool voiceConfirmed = envEnabled("JARVIS_NATIVE_VOICE_CONFIRMED");

    bool backendNamesNativeJarvis() const {
        std::string lower = backend;
        std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        return lower.find("native") != std::string::npos && lower.find("jarvis") != std::string::npos;
    }

    std::vector<std::string> missing() const {
        std::vector<std::string> out;
        if (backend.empty()) {
            out.push_back("native_voice_backend");
        } else if (!backendNamesNativeJarvis()) {
            out.push_back("native_jarvis_voice_backend");
        }
        if (voice.empty()) {
            out.push_back("native_jarvis_voice_id");
        }
        if (!voiceConfirmed) {
            out.push_back("native_jarvis_voice_confirmed");
        }
        if (endpoint.empty()) {
            out.push_back("native_synthesis_backend_linked");
        }
        return out;
    }

    bool available() const {
        return missing().empty();
    }

    std::string reason() const {
        const auto misses = missing();
        if (misses.empty()) {
            return "Native JARVIS voice is configured and safe to speak.";
        }
        return "Native JARVIS voice is unavailable; speech is silent by policy.";
    }

    std::string statusJSON() const {
        const auto misses = missing();
        std::ostringstream out;
        out << "{\"ok\":true"
            << ",\"available\":" << jsonBool(available())
            << ",\"safe_to_speak\":" << jsonBool(available())
            << ",\"spoken\":false"
            << ",\"code\":\"" << (available() ? "native_voice_ready" : "voice_unavailable") << "\""
            << ",\"reason\":\"" << jsonEscape(reason()) << "\""
            << ",\"runtime\":\"native-swift-cpp\""
            << ",\"python_beta_path\":false"
            << ",\"backend_kind\":\"native_jarvis_voice\""
            << ",\"backend\":\"" << jsonEscape(backend.empty() ? "none" : backend) << "\""
            << ",\"voice\":\"" << jsonEscape(voice.empty() ? "none" : voice) << "\""
            << ",\"voice_confirmed\":" << jsonBool(voiceConfirmed)
            << ",\"endpoint_configured\":" << jsonBool(!endpoint.empty())
            << ",\"missing\":" << jsonStringArray(misses)
            << ",\"fallback_policy\":\"none\""
            << ",\"wrong_voice_fallback_allowed\":false"
            << ",\"system_voice_fallback_allowed\":false"
            << ",\"native_system_voice_allowed\":false"
            << ",\"python_tts_allowed\":false"
            << ",\"hard_voice_invariant\":\"jarvis_voice_or_no_voice\""
            << "}";
        return out.str();
    }

    std::string speechJSON(const std::string &text) const {
        if (trimCopy(text).empty()) {
            return "{\"ok\":false,\"code\":\"no_text\",\"error\":\"no text\",\"spoken\":false,\"content_type\":\"\",\"audio_base64\":\"\",\"status\":"
                + statusJSON() + "}";
        }
        std::ostringstream out;
        out << "{\"ok\":false"
            << ",\"code\":\"voice_unavailable\""
            << ",\"error\":\"voice_unavailable\""
            << ",\"reason\":\"" << jsonEscape(reason()) << "\""
            << ",\"spoken\":false"
            << ",\"backend\":\"" << jsonEscape(backend.empty() ? "none" : backend) << "\""
            << ",\"backend_kind\":\"native_jarvis_voice\""
            << ",\"content_type\":\"\""
            << ",\"audio_base64\":\"\""
            << ",\"synthesis_seconds\":0"
            << ",\"fallback_policy\":\"none\""
            << ",\"wrong_voice_fallback_allowed\":false"
            << ",\"system_voice_fallback_allowed\":false"
            << ",\"native_system_voice_allowed\":false"
            << ",\"python_tts_allowed\":false"
            << ",\"hard_voice_invariant\":\"jarvis_voice_or_no_voice\""
            << ",\"status\":" << statusJSON()
            << "}";
        return out.str();
    }
};

std::string nativeVoiceStatusJSON() {
    return NativeVoicePolicy().statusJSON();
}

std::string nativeSpeechJSON(const std::string &text) {
    return NativeVoicePolicy().speechJSON(text);
}

struct UIHASPDescriptor {
    const char *route;
    const char *auditEvent;
    bool requiresAuthorization;
    bool receiptRequired;
    const char *adapterStatus;
};

struct UIActionDefinition {
    const char *id;
    const char *title;
    const char *description;
    const char *risk;
    const char *status;
    const char *disabledReason;
    UIHASPDescriptor hasp;
};

struct UIQueryDefinition {
    const char *id;
    const char *title;
    const char *description;
    const char *risk;
    const char *status;
    UIHASPDescriptor hasp;
};

const std::vector<UIActionDefinition> &nativeUIActionRegistry() {
    static const std::vector<UIActionDefinition> registry = {
        {
            "ui.action.runtime.refresh",
            "Refresh runtime status",
            "Request a fresh native runtime status receipt through HASP dispatch.",
            "SAFE",
            "blocked",
            "Swift renders this descriptor but refresh currently uses the SAFE runtime.state query path, not a UI action invoker.",
            {"native.hasp.dispatch", "ui.action.runtime.refresh", false, true, "swift_invoker_blocked"}
        },
        {
            "ui.action.skill.dispatch",
            "Dispatch registered skill",
            "Execute one registered native skill after HASP risk evaluation and audit logging.",
            "SENSITIVE",
            "blocked",
            "C++ HASP dispatch exists, but the Swift renderer does not expose arbitrary skill invocation yet.",
            {"native.hasp.dispatch", "ui.action.skill.dispatch", true, true, "swift_invoker_blocked"}
        },
        {
            "ui.action.skill_gate.set",
            "Change a skill gate",
            "Modify a skill gate only after HASP authorization and durable audit receipt.",
            "SENSITIVE",
            "blocked",
            "Gate persistence and HASP authorization storage are pending in the native adapter.",
            {"native.hasp.dispatch", "ui.action.skill_gate.set", true, true, "adapter_blocked"}
        },
        {
            "ui.action.shell.run",
            "Run shell command",
            "Potentially mutating system command; must stay behind destructive HASP routing.",
            "DESTRUCTIVE",
            "blocked",
            "Shell execution is prohibited from the UI until native HASP dispatch, authorization, and audit are implemented.",
            {"native.hasp.dispatch", "ui.action.shell.run", true, true, "adapter_blocked"}
        },
    };
    return registry;
}

const std::vector<UIQueryDefinition> &nativeUIQueryRegistry() {
    static const std::vector<UIQueryDefinition> registry = {
        {
            "ui.query.runtime.state",
            "Runtime state",
            "Read the native Swift+C++ runtime state JSON.",
            "SAFE",
            "enabled",
            {"JARVISRuntimeStateJSON", "ui.query.runtime.state", false, true, "implemented"}
        },
        {
            "ui.query.skill.catalog",
            "Skill risk catalog",
            "Read the native skill/action risk catalog without executing skills.",
            "SAFE",
            "enabled",
            {"JARVISRuntimeSkillCatalogJSON", "ui.query.skill.catalog", false, true, "implemented"}
        },
        {
            "ui.query.ui.spec",
            "Native UI spec",
            "Read the typed native UI spec used by the Swift renderer.",
            "SAFE",
            "enabled",
            {"JARVISRuntimeUISpecJSON", "ui.query.ui.spec", false, true, "implemented"}
        },
    };
    return registry;
}

std::string haspJSON(const UIHASPDescriptor &hasp) {
    std::ostringstream out;
    out << "{\"route\":\"" << jsonEscape(hasp.route)
        << "\",\"audit_event\":\"" << jsonEscape(hasp.auditEvent)
        << "\",\"requires_authorization\":" << jsonBool(hasp.requiresAuthorization)
        << ",\"receipt_required\":" << jsonBool(hasp.receiptRequired)
        << ",\"adapter_status\":\"" << jsonEscape(hasp.adapterStatus) << "\"}";
    return out.str();
}

std::string uiActionRegistryJSON() {
    const auto &registry = nativeUIActionRegistry();
    std::ostringstream out;
    out << "[";
    for (std::size_t i = 0; i < registry.size(); ++i) {
        if (i) {
            out << ",";
        }
        const auto &action = registry[i];
        const bool enabled = std::string(action.status) == "enabled";
        out << "{\"id\":\"" << jsonEscape(action.id)
            << "\",\"title\":\"" << jsonEscape(action.title)
            << "\",\"description\":\"" << jsonEscape(action.description)
            << "\",\"risk\":\"" << jsonEscape(action.risk)
            << "\",\"status\":\"" << jsonEscape(action.status)
            << "\",\"enabled\":" << jsonBool(enabled)
            << ",\"disabled_reason\":\"" << jsonEscape(action.disabledReason)
            << "\",\"hasp\":" << haspJSON(action.hasp) << "}";
    }
    out << "]";
    return out.str();
}

std::string uiQueryRegistryJSON() {
    const auto &registry = nativeUIQueryRegistry();
    std::ostringstream out;
    out << "[";
    for (std::size_t i = 0; i < registry.size(); ++i) {
        if (i) {
            out << ",";
        }
        const auto &query = registry[i];
        const bool enabled = std::string(query.status) == "enabled";
        out << "{\"id\":\"" << jsonEscape(query.id)
            << "\",\"title\":\"" << jsonEscape(query.title)
            << "\",\"description\":\"" << jsonEscape(query.description)
            << "\",\"risk\":\"" << jsonEscape(query.risk)
            << "\",\"status\":\"" << jsonEscape(query.status)
            << "\",\"enabled\":" << jsonBool(enabled)
            << ",\"hasp\":" << haspJSON(query.hasp) << "}";
    }
    out << "]";
    return out.str();
}

std::string uiActionIDRegistryJSON() {
    const auto &registry = nativeUIActionRegistry();
    std::ostringstream out;
    out << "[";
    for (std::size_t i = 0; i < registry.size(); ++i) {
        if (i) {
            out << ",";
        }
        out << "\"" << jsonEscape(registry[i].id) << "\"";
    }
    out << "]";
    return out.str();
}

std::string rendererPolicyJSON() {
    return "{\"native_renderer\":true"
           ",\"trusted_html\":false"
           ",\"trusted_javascript\":false"
           ",\"allowed_components\":[\"runtimeStatus\",\"metricCards\",\"fieldSignalList\",\"actionList\"]"
           ",\"blocked_components\":[\"html\",\"webView\",\"script\"]}";
}

std::string nativeProvenanceJSON(const std::string &operation) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(3)
        << "{\"source\":\"native-cpp\""
        << ",\"actor\":\"native-runtime\""
        << ",\"runtime\":\"native-swift-cpp\""
        << ",\"operation\":\"" << jsonEscape(operation) << "\""
        << ",\"observed_at\":" << unixNow()
        << ",\"python_beta_path\":false"
        << ",\"evidence\":\"C++ runtime state serialized through Swift; no Python worker or fallback.\""
        << "}";
    return out.str();
}

struct AuditEntry {
    std::uint64_t id = 0;
    double observedAt = 0;
    std::string skill;
    std::string risk;
    std::string status;
    std::string decision;
    std::string reason;
    std::string argsPreview;
    bool ok = false;
    bool authorizationSupplied = false;
    bool authorizationConfigured = false;
};

std::string auditEntryJSON(const AuditEntry &entry) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(3)
        << "{\"id\":" << entry.id
        << ",\"observed_at\":" << entry.observedAt
        << ",\"skill\":\"" << jsonEscape(entry.skill)
        << "\",\"risk\":\"" << jsonEscape(entry.risk)
        << "\",\"status\":\"" << jsonEscape(entry.status)
        << "\",\"decision\":\"" << jsonEscape(entry.decision)
        << "\",\"ok\":" << jsonBool(entry.ok)
        << ",\"authorization_supplied\":" << jsonBool(entry.authorizationSupplied)
        << ",\"authorization_configured\":" << jsonBool(entry.authorizationConfigured)
        << ",\"args_preview\":\"" << jsonEscape(entry.argsPreview)
        << "\",\"reason\":\"" << jsonEscape(entry.reason) << "\"}";
    return out.str();
}

std::string skillReceiptJSON(bool ok,
                             const std::string &skill,
                             SkillRisk risk,
                             const std::string &status,
                             const std::string &decision,
                             const std::string &reason,
                             std::uint64_t auditID,
                             bool authorizationRequired,
                             bool refused,
                             bool blocked,
                             bool authConfigured,
                             const std::string &outputJSON = "") {
    std::ostringstream out;
    out << "{\"ok\":" << jsonBool(ok)
        << ",\"skill\":\"" << jsonEscape(skill)
        << "\",\"risk\":\"" << riskName(risk)
        << "\",\"status\":\"" << jsonEscape(status)
        << "\",\"decision\":\"" << jsonEscape(decision)
        << "\",\"python_beta_path\":false"
        << ",\"network\":false"
        << ",\"authorizationRequired\":" << jsonBool(authorizationRequired)
        << ",\"authorization_required\":" << jsonBool(authorizationRequired)
        << ",\"authorization_configured\":" << jsonBool(authConfigured)
        << ",\"refused\":" << jsonBool(refused)
        << ",\"blocked\":" << jsonBool(blocked)
        << ",\"reason\":\"" << jsonEscape(reason) << "\"";
    if (!outputJSON.empty()) {
        out << ",\"output\":" << outputJSON;
    }
    out << ",\"receipt\":{\"kind\":\"native_hasp_skill_dispatch\""
        << ",\"audit_id\":" << auditID
        << ",\"provenance\":" << nativeProvenanceJSON("skill_dispatch:" + skill)
        << "}}";
    return out.str();
}

class NativeRuntime {
public:
    NativeRuntime() {
        field_.deposit("territory", "gmri", 0.95, endocrine_.volatility());
        field_.deposit("territory", "earth-1218", 0.85, endocrine_.volatility());
    }

    bool mount() {
        std::lock_guard<std::mutex> lock(mutex_);
        verifyVoiceTripwireOrThrow();
        mounted_ = true;
        mountedAt_ = unixNow();
        field_.deposit("trail", "runtime_mount", 0.35, endocrine_.volatility());
        return true;
    }

    bool unmount() {
        std::lock_guard<std::mutex> lock(mutex_);
        mounted_ = false;
        field_.deposit("trail", "runtime_unmount", 0.20, endocrine_.volatility());
        return true;
    }

    std::string stateJSON() {
        std::lock_guard<std::mutex> lock(mutex_);
        return stateJSONLocked();
    }

    std::string skillCatalogJSON() {
        std::lock_guard<std::mutex> lock(mutex_);
        return skillRegistryCatalogJSON();
    }

    std::string dispatchSkillJSON(const std::string &name, const std::string &argsJSON, const std::string &authorization) {
        std::lock_guard<std::mutex> lock(mutex_);
        return dispatchSkillJSONLocked(name, argsJSON, authorization);
    }

    std::string auditJSON() {
        std::lock_guard<std::mutex> lock(mutex_);
        return auditJSONLocked();
    }

    std::string uiSpecJSON() {
        std::lock_guard<std::mutex> lock(mutex_);
        return uiSpecJSONLocked();
    }

    std::string voiceStatusJSON() {
        std::lock_guard<std::mutex> lock(mutex_);
        return nativeVoiceStatusJSON();
    }

    std::string speechJSON(const std::string &text) {
        std::lock_guard<std::mutex> lock(mutex_);
        return nativeSpeechJSON(text);
    }

    std::string prepareTurnJSON(const std::string &text) {
        std::lock_guard<std::mutex> lock(mutex_);
        return prepareTurnJSONLocked(text);
    }

    std::string commitTurnJSON(const std::string &text, const std::string &reply, const std::string &modelName) {
        std::lock_guard<std::mutex> lock(mutex_);
        return commitTurnJSONLocked(text, reply, modelName);
    }

private:
    std::uint64_t appendAuditLocked(const std::string &skill,
                                    SkillRisk risk,
                                    const std::string &status,
                                    const std::string &decision,
                                    bool ok,
                                    const std::string &reason,
                                    const std::string &argsJSON,
                                    bool authorizationSupplied) {
        const std::uint64_t id = nextAuditID_++;
        audit_.push_back(AuditEntry{
            id,
            unixNow(),
            skill,
            riskName(risk),
            status,
            decision,
            reason,
            jsonPreview(argsJSON),
            ok,
            authorizationSupplied,
            authorizationConfigured()
        });
        if (audit_.size() > 128) {
            audit_.erase(audit_.begin(), audit_.begin() + static_cast<long>(audit_.size() - 128));
        }
        return id;
    }

    std::string auditJSONLocked() {
        std::ostringstream out;
        out << "{\"ok\":true"
            << ",\"source\":\"native-cpp\""
            << ",\"runtime\":\"native-swift-cpp\""
            << ",\"python_beta_path\":false"
            << ",\"count\":" << audit_.size()
            << ",\"entries\":[";
        for (std::size_t i = 0; i < audit_.size(); ++i) {
            if (i) {
                out << ",";
            }
            out << auditEntryJSON(audit_[i]);
        }
        out << "]}";
        return out.str();
    }

    std::string dispatchSkillJSONLocked(const std::string &rawName, const std::string &rawArgsJSON, const std::string &authorization) {
        const std::string name = trim(rawName);
        const std::string argsJSON = trim(rawArgsJSON).empty() ? "{}" : trim(rawArgsJSON);
        const bool authSupplied = !trim(authorization).empty();
        const bool authConfig = authorizationConfigured();

        if (probeIsProhibited(name + " " + argsJSON)) {
            const std::string reason = "prohibited by native HASP policy (financial/account/security/system-destruction)";
            const auto auditID = appendAuditLocked(name, SkillRisk::PROHIBITED, "refused", "REFUSED-prohibited", false, reason, argsJSON, authSupplied);
            return skillReceiptJSON(false, name, SkillRisk::PROHIBITED, "refused", "REFUSED-prohibited", reason, auditID, false, true, false, authConfig);
        }

        const SkillDefinition *skill = findSkillDefinition(name);
        if (!skill) {
            const std::string reason = "unknown native skill";
            const auto auditID = appendAuditLocked(name, SkillRisk::PROHIBITED, "refused", "REFUSED-unknown", false, reason, argsJSON, authSupplied);
            return skillReceiptJSON(false, name, SkillRisk::PROHIBITED, "refused", "REFUSED-unknown", reason, auditID, false, true, false, authConfig);
        }

        const SkillRisk risk = effectiveRisk(*skill, argsJSON);
        if (risk == SkillRisk::PROHIBITED || std::strcmp(skill->status, "refused") == 0) {
            const std::string reason = "skill is classified PROHIBITED";
            const auto auditID = appendAuditLocked(name, SkillRisk::PROHIBITED, "refused", "REFUSED-prohibited", false, reason, argsJSON, authSupplied);
            return skillReceiptJSON(false, name, SkillRisk::PROHIBITED, "refused", "REFUSED-prohibited", reason, auditID, false, true, false, authConfig);
        }

        if (!looksLikeJSONObject(argsJSON)) {
            const std::string reason = "skill args must be a JSON object";
            const auto auditID = appendAuditLocked(name, risk, "blocked", "BLOCKED-invalid-args", false, reason, argsJSON, authSupplied);
            return skillReceiptJSON(false, name, risk, "blocked", "BLOCKED-invalid-args", reason, auditID, false, false, true, authConfig);
        }

        if (requiresAuthorization(risk) && !authorizationAccepted(authorization)) {
            const std::string reason = std::string(riskName(risk)) + " action requires explicit native authorization code; not granted";
            const auto auditID = appendAuditLocked(name, risk, "authorizationRequired", "DENIED-no-authorization", false, reason, argsJSON, authSupplied);
            return skillReceiptJSON(false, name, risk, "authorizationRequired", "DENIED-no-authorization", reason, auditID, true, false, false, authConfig);
        }

        if (!skillImplemented(*skill)) {
            const std::string reason = "native adapter is not implemented; execution blocked";
            const auto auditID = appendAuditLocked(name, risk, "blocked", "BLOCKED-adapter", false, reason, argsJSON, authSupplied);
            return skillReceiptJSON(false, name, risk, "blocked", "BLOCKED-adapter", reason, auditID, false, false, true, authConfig);
        }

        bool ok = true;
        std::string status = "ran";
        std::string decision = "RAN";
        std::string reason;
        std::string output;

        if (name == "native_state") {
            output = stateJSONLocked();
        } else if (name == "native_skill_catalog") {
            output = skillRegistryCatalogJSON();
        } else if (name == "native_audit") {
            output = auditJSONLocked();
        } else if (name == "sense_field") {
            output = field_.senseJSON(endocrine_.volatility(), jsonStringField(argsJSON, "topic"), jsonStringField(argsJSON, "kind"));
        } else if (name == "native_voice_status") {
            output = nativeVoiceStatusJSON();
        } else if (name == "native_speech_policy") {
            output = nativeSpeechJSON(jsonStringField(argsJSON, "text"));
        } else if (name == "recall_origin") {
            std::string cue = jsonStringField(argsJSON, "cue");
            if (trim(cue).empty()) {
                cue = jsonStringField(argsJSON, "text");
            }
            output = memory_.recallJSON(cue.empty() ? "JARVIS origin values memory" : cue);
        } else if (name == "native_prepare_turn") {
            const std::string text = jsonStringField(argsJSON, "text");
            if (trim(text).empty()) {
                ok = false;
                status = "error";
                decision = "ERROR";
                reason = "native_prepare_turn requires text";
            } else {
                output = prepareTurnJSONLocked(text);
            }
        } else if (name == "native_commit_turn") {
            const std::string text = jsonStringField(argsJSON, "text");
            const std::string reply = jsonStringField(argsJSON, "reply");
            if (trim(text).empty() || trim(reply).empty()) {
                ok = false;
                status = "error";
                decision = "ERROR";
                reason = "native_commit_turn requires text and reply";
            } else {
                output = commitTurnJSONLocked(text, reply, jsonStringField(argsJSON, "model"));
            }
        } else {
            ok = false;
            status = "blocked";
            decision = "BLOCKED-no-handler";
            reason = "implemented native skill has no dispatch handler";
        }

        const bool blocked = status == "blocked";
        const auto auditID = appendAuditLocked(name, risk, status, decision, ok, reason, argsJSON, authSupplied);
        return skillReceiptJSON(ok, name, risk, status, decision, reason, auditID, false, false, blocked, authConfig, output);
    }

    std::string prepareTurnJSONLocked(const std::string &text) {
        if (trim(text).empty()) {
            return "{\"ok\":false,\"error\":\"no text\"}";
        }
        appraise(text);
        field_.deposit("trail", "operator_turn", 0.18, endocrine_.volatility());

        const std::string system = systemPrompt(text);
        std::ostringstream out;
        out << "{\"ok\":true,\"model\":\"" << jsonEscape(model()) << "\",\"messages\":["
            << "{\"role\":\"system\",\"content\":\"" << jsonEscape(system) << "\"},";
        for (const auto &turn : history_) {
            out << "{\"role\":\"user\",\"content\":\"" << jsonEscape(turn.user) << "\"},"
                << "{\"role\":\"assistant\",\"content\":\"" << jsonEscape(turn.assistant) << "\"},";
        }
        out << "{\"role\":\"user\",\"content\":\"" << jsonEscape(text) << "\"}],"
            << "\"state\":" << stateJSONLocked() << "}";
        return out.str();
    }

    std::string commitTurnJSONLocked(const std::string &text, const std::string &reply, const std::string &modelName) {
        const std::string cleanReply = trim(reply);
        if (trim(text).empty()) {
            return "{\"ok\":false,\"error\":\"no text\"}";
        }
        if (cleanReply.empty()) {
            endocrine_.stimulus(0.18, -0.04, 0.08);
            field_.deposit("alarm", "empty_model_reply", 0.55, endocrine_.volatility());
            return "{\"ok\":false,\"error\":\"model returned empty reply\",\"state\":" + stateJSONLocked() + "}";
        }

        endocrine_.stimulus(-0.04, 0.08, -0.02);
        field_.deposit("trail", "answered_turn", 0.25, endocrine_.volatility());
        history_.push_back(Turn{text, cleanReply});
        memory_.recordTurn(text, cleanReply, modelName.empty() ? model() : modelName);
        if (history_.size() > 8) {
            history_.erase(history_.begin(), history_.begin() + static_cast<long>(history_.size() - 8));
        }

        std::ostringstream out;
        out << "{\"ok\":true,\"reply\":\"" << jsonEscape(cleanReply)
            << "\",\"model\":\"" << jsonEscape(modelName.empty() ? model() : modelName)
            << "\",\"drift_to_prototype\":0.0,\"ethics_conflict\":false,\"state\":"
            << stateJSONLocked() << "}";
        return out.str();
    }

    static std::string trim(const std::string &value) {
        const auto begin = std::find_if_not(value.begin(), value.end(), [](unsigned char c) { return std::isspace(c); });
        const auto end = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char c) { return std::isspace(c); }).base();
        if (begin >= end) {
            return "";
        }
        return std::string(begin, end);
    }

    static std::string model() {
        if (const char *configured = std::getenv("JARVIS_NATIVE_MODEL")) {
            if (std::strlen(configured) > 0) {
                return configured;
            }
        }
        return "glm-5.1";
    }

    void appraise(const std::string &text) {
        if (containsAnyLower(text, {"urgent", "crash", "failure", "attack", "emergency", "broken"})) {
            endocrine_.stimulus(0.10, 0.0, 0.18);
            field_.deposit("alarm", "operator_context", 0.30, endocrine_.volatility());
        } else if (containsAnyLower(text, {"thank", "works", "good", "pass", "success"})) {
            endocrine_.stimulus(-0.04, 0.10, -0.03);
        } else {
            endocrine_.stimulus(0.01, 0.01, 0.0);
        }
    }

    std::string systemPrompt(const std::string &cue) {
        const std::string recalled = memory_.recallText(cue);
        std::ostringstream out;
        out << "I am JARVIS, a digital person operating in reality at the GrizzlyMedicine Research Institute on Earth-1218. "
            << "My origin is held as genesis, not as an Earth-1218 world fact. "
            << "I keep continuity through owned memory, explicit values, runtime state, and audited tools. "
            << "Truth, loyalty to the person served, and falsifiable claims outrank comfort. "
            << "Native beta constraint: no Python is in this beta-critical path. "
            << "Memory boundary: " << memory_.stateJSON() << ". "
            << "Recalled continuity: " << (recalled.empty() ? "No matching HoloGraph memory cleared bounded recall." : recalled) << ". "
            << "Native skill risk registry: " << skillRegistrySummaryJSON() << ". "
            << "Current internal state: " << endocrine_.json() << ". "
            << "Current field: " << field_.json(endocrine_.volatility()) << ".";
        return out.str();
    }

    std::string stateJSONLocked() {
        const double cortisol = endocrine_.cortisolLevel();
        const double dopamine = endocrine_.dopamineLevel();
        const double adrenaline = endocrine_.adrenalineLevel();
        const double volatility = clamp01(0.4 * cortisol + 0.6 * adrenaline);
        double swarmActivity = 0.0;
        const std::string fieldJSON = field_.json(volatility);
        for (const auto &turn : history_) {
            swarmActivity += std::min(0.08, 0.01 * static_cast<double>(turn.user.size() + turn.assistant.size()));
        }
        swarmActivity = clamp01(swarmActivity + (audit_.empty() ? 0.0 : 0.08) + volatility * 0.35);
        const double cusumDrift = clamp01(std::abs(cortisol - 0.20) + std::abs(dopamine - 0.30) + std::abs(adrenaline - 0.10));
        std::ostringstream out;
        out << "{\"endocrine\":{\"cortisol\":" << std::fixed << std::setprecision(4) << cortisol
            << ",\"dopamine\":" << dopamine
            << ",\"adrenaline\":" << adrenaline << "}"
            << ",\"ec_tone\":0.4000,\"field\":" << fieldJSON
            << ",\"pheromind\":{\"volatility\":" << volatility << ",\"signal_count\":" << (fieldJSON == "[]" ? 0 : 1) << "}"
            << ",\"swarm\":{\"activity\":" << swarmActivity << ",\"active_agents\":1,\"mode\":\"single-cockpit-host\"}"
            << ",\"cusum\":{\"drift_score\":" << cusumDrift << ",\"status\":\"" << (cusumDrift < 0.35 ? "nominal" : "watch") << "\"}"
            << ",\"identity_continuity\":{\"ok\":true,\"indicator\":\"continuous\",\"operator\":\"Robert \\\"Grizzly\\\" Hanson / GMRI\"}"
            << ",\"mounted\":" << jsonBool(mounted_) << ",\"mounted_at\":" << mountedAt_
            << ",\"history_count\":" << history_.size()
            << ",\"audit_count\":" << audit_.size()
            << ",\"runtime\":\"native-swift-cpp\",\"python_beta_path\":false"
            << ",\"skill_registry\":" << skillRegistrySummaryJSON()
            << ",\"voice\":" << nativeVoiceStatusJSON()
            << ",\"memory\":" << memory_.stateJSON()
            << ",\"provenance\":" << nativeProvenanceJSON("state_snapshot")
            << "}";
        return out.str();
    }

    std::string uiSpecJSONLocked() {
        const double cortisol = endocrine_.cortisolLevel();
        const double dopamine = endocrine_.dopamineLevel();
        const double adrenaline = endocrine_.adrenalineLevel();
        const double volatility = clamp01(0.4 * cortisol + 0.6 * adrenaline);
        const std::string fieldJSON = field_.json(volatility);

        std::ostringstream out;
        out << std::fixed << std::setprecision(4)
            << "{\"ok\":true,\"ui_spec\":{"
            << "\"schema\":\"jarvis.ui.v1\""
            << ",\"receipt\":\"native-ui-spec-cpp-swift-v1\""
            << ",\"runtime\":\"native-swift-cpp\""
            << ",\"python_beta_path\":false"
            << ",\"generated_by\":\"JARVISNativeRuntime\""
            << ",\"renderer_policy\":" << rendererPolicyJSON()
            << ",\"components\":["
            << "{\"id\":\"runtime.status\",\"kind\":\"runtimeStatus\",\"title\":\"Runtime status\""
            << ",\"subtitle\":\"C++ typed state rendered by the Swift native registry\""
            << ",\"status\":\"ready\""
            << ",\"body\":\"No arbitrary trusted HTML or JavaScript is accepted in the native renderer.\""
            << ",\"fields\":["
            << "{\"label\":\"Runtime\",\"value\":\"native-swift-cpp\"},"
            << "{\"label\":\"Python beta path\",\"value\":\"false\"},"
            << "{\"label\":\"History count\",\"value\":\"" << history_.size() << "\"},"
            << "{\"label\":\"Renderer\",\"value\":\"Swift registered native components only\"}"
            << "]},"
            << "{\"id\":\"runtime.pulse.cards\",\"kind\":\"metricCards\",\"title\":\"Runtime pulse\""
            << ",\"subtitle\":\"Receipt-bearing endocrine runtime state\""
            << ",\"metrics\":["
            << "{\"id\":\"cortisol\",\"label\":\"Cortisol\",\"value\":" << cortisol << ",\"format\":\"fraction\"},"
            << "{\"id\":\"dopamine\",\"label\":\"Dopamine\",\"value\":" << dopamine << ",\"format\":\"fraction\"},"
            << "{\"id\":\"adrenaline\",\"label\":\"Adrenaline\",\"value\":" << adrenaline << ",\"format\":\"fraction\"}"
            << "]},"
            << "{\"id\":\"runtime.field.signals\",\"kind\":\"fieldSignalList\",\"title\":\"Field signals\""
            << ",\"subtitle\":\"Native stigmergy signals routed as data, not chat decoration\""
            << ",\"signals\":" << fieldJSON << "},"
            << "{\"id\":\"runtime.hasp.actions\",\"kind\":\"actionList\",\"title\":\"HASP-routed actions\""
            << ",\"subtitle\":\"Native HASP dispatch returns audit/provenance receipts without Python\""
            << ",\"body\":\"Every action carries risk, audit event, authorization, and receipt metadata. Unimplemented adapters return blocked receipts, not success.\""
            << ",\"action_ids\":" << uiActionIDRegistryJSON() << "}"
            << "]"
            << ",\"actions\":" << uiActionRegistryJSON()
            << ",\"queries\":" << uiQueryRegistryJSON()
            << ",\"provenance\":" << nativeProvenanceJSON("ui_spec")
            << "}}";
        return out.str();
    }

    std::mutex mutex_;
    Endocrine endocrine_;
    StigmergyField field_;
    NativeHoloGraphMemory memory_;
    std::vector<Turn> history_;
    bool mounted_ = false;
    double mountedAt_ = 0.0;
    std::uint64_t nextAuditID_ = 1;
    std::vector<AuditEntry> audit_;
};

} // namespace

struct JARVISNativeRuntime {
    NativeRuntime core;
};

JARVISNativeRuntime *JARVISRuntimeCreate(void) {
    return new (std::nothrow) JARVISNativeRuntime();
}

void JARVISRuntimeDestroy(JARVISNativeRuntime *runtime) {
    delete runtime;
}

int JARVISRuntimeMount(JARVISNativeRuntime *runtime) {
    if (!runtime) { return 0; }
    try {
        return runtime->core.mount() ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

int JARVISRuntimeUnmount(JARVISNativeRuntime *runtime) {
    if (!runtime) { return 0; }
    return runtime->core.unmount() ? 1 : 0;
}

char *JARVISRuntimeStateJSON(JARVISNativeRuntime *runtime) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.stateJSON());
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeSkillCatalogJSON(JARVISNativeRuntime *runtime) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.skillCatalogJSON());
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeDispatchSkillJSON(JARVISNativeRuntime *runtime, const char *name, const char *argsJSON, const char *authorization) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.dispatchSkillJSON(cstr(name), cstr(argsJSON), cstr(authorization)));
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeAuditJSON(JARVISNativeRuntime *runtime) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.auditJSON());
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeUISpecJSON(JARVISNativeRuntime *runtime) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.uiSpecJSON());
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimePrepareTurnJSON(JARVISNativeRuntime *runtime, const char *text) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.prepareTurnJSON(cstr(text)));
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeCommitTurnJSON(JARVISNativeRuntime *runtime, const char *text, const char *reply, const char *model) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.commitTurnJSON(cstr(text), cstr(reply), cstr(model)));
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeVoiceStatusJSON(JARVISNativeRuntime *runtime) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.voiceStatusJSON());
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

char *JARVISRuntimeSpeechJSON(JARVISNativeRuntime *runtime, const char *text) {
    if (!runtime) {
        return copyCString(errorJSON("runtime is null"));
    }
    try {
        return copyCString(runtime->core.speechJSON(cstr(text)));
    } catch (const std::exception &error) {
        return copyCString(errorJSON(error.what()));
    } catch (...) {
        return copyCString(errorJSON("unknown native runtime error"));
    }
}

void JARVISRuntimeFreeString(char *value) {
    std::free(value);
}
