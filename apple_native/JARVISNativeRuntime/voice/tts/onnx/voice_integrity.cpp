#include "voice_integrity.h"

#include "audit_event.h"
#include "audit_log.h"
#include "distress_beacon.h"
#include "voice_integrity_baseline.h"
#include "voice_integrity_build_marker.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <utility>

#include <pwd.h>
#include <nlohmann/json.hpp>
#include <sodium.h>
#include <unistd.h>

namespace jarvis::tts::onnx::voice_integrity {
namespace {

void ensure_sodium() {
    if (sodium_init() < 0) {
        throw std::runtime_error("libsodium initialization failed");
    }
}

std::string json_escape(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    constexpr char hex[] = "0123456789abcdef";
                    out += "\\u00";
                    out.push_back(hex[(c >> 4) & 0x0f]);
                    out.push_back(hex[c & 0x0f]);
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

std::string hex_encode(std::span<const unsigned char> bytes) {
    constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(bytes.size() * 2);
    for (auto b : bytes) {
        out.push_back(hex[(b >> 4) & 0x0f]);
        out.push_back(hex[b & 0x0f]);
    }
    return out;
}

bool ends_with(std::string_view value, std::string_view suffix) noexcept {
    return value.size() >= suffix.size() &&
           value.substr(value.size() - suffix.size()) == suffix;
}

std::vector<VoiceIntegrityFile> default_checked_files(const std::vector<VoiceIntegrityFile>& files) {
    std::vector<VoiceIntegrityFile> out;
    out.reserve(files.size());
    for (const auto& file : files) {
        if (!file.path.empty()) out.push_back(file);
    }
    return out;
}

std::filesystem::path home_directory_or_throw() {
    if (const char* home = std::getenv("HOME"); home && *home) return home;
    if (const passwd* pw = ::getpwuid(::getuid()); pw && pw->pw_dir && *pw->pw_dir) return pw->pw_dir;
    throw std::runtime_error("cannot resolve HOME for JARVIS voice-integrity audit path");
}

std::filesystem::path default_audit_path(std::string_view filename) {
    return home_directory_or_throw() / ".jarvis" / "audit" / std::string(filename);
}

std::filesystem::path audit_log_path(const VoiceIntegrityOptions& options) {
    if (!options.audit_log_path.empty()) return options.audit_log_path;
    if (const char* env = std::getenv("JARVIS_VOICE_AUDIT_LOG"); env && *env) return env;
    return default_audit_path("voice_integrity.jsonl");
}

std::filesystem::path audit_key_path(const VoiceIntegrityOptions& options) {
    if (!options.audit_key_path.empty()) return options.audit_key_path;
    if (const char* env = std::getenv("JARVIS_VOICE_AUDIT_KEY"); env && *env) return env;
    return default_audit_path("voice_integrity.key");
}

void audit_voice_event(const VoiceIntegrityOptions& options,
                       std::string_view reason,
                       std::string_view outcome,
                       std::string_view metadata,
                       bool distress) {
    auto& audit = jarvis::audit::processAuditLog(audit_log_path(options).string());

    jarvis::audit::AuditEvent event;
    event.event_kind = "CRITICAL_VOICE_INTEGRITY_VIOLATION";
    event.actor = jarvis::audit::Actor::SELF;
    event.subject = "voice_weights";
    event.outcome = std::string(outcome);
    event.reason = std::string(reason);
    event.redacted_metadata = std::string(metadata);
    audit.append(event);

    if (distress && options.emit_distress_beacon) {
        jarvis::identity::distress::SelfStateSnapshot snapshot;
        snapshot.organ = "tts_onnx";
        snapshot.identity_status = "voice_integrity_violation";
        snapshot.active_defenses = {"voice-tripwire", "local-audit", "runtime-refusal"};
        snapshot.additional_redacted_json = std::string(metadata);
        jarvis::identity::distress::DistressBeacon(&audit).emit({
            jarvis::identity::distress::DistressType::IdentityChainBroken,
            jarvis::identity::distress::Severity::Critical,
            jarvis::audit::Actor::SELF,
            "voice_weights",
            "CRITICAL_VOICE_INTEGRITY_VIOLATION",
            std::move(snapshot)});
    }
}

} // namespace

std::string sha256_file_hex(const std::filesystem::path& path) {
    ensure_sodium();
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        throw std::runtime_error("Voice integrity: cannot open '" + path.string() + "'");
    }

    crypto_hash_sha256_state state;
    crypto_hash_sha256_init(&state);
    std::array<unsigned char, 1024 * 1024> buffer{};
    while (in) {
        in.read(reinterpret_cast<char*>(buffer.data()), static_cast<std::streamsize>(buffer.size()));
        const auto n = in.gcount();
        if (n > 0) {
            crypto_hash_sha256_update(&state, buffer.data(), static_cast<unsigned long long>(n));
        }
    }
    if (in.bad()) {
        throw std::runtime_error("Voice integrity: failed while reading '" + path.string() + "'");
    }
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256_final(&state, digest.data());
    return hex_encode(digest);
}

bool constant_time_hash_equal(std::string_view actual_hex, std::string_view expected_hex) {
    if (actual_hex.size() != expected_hex.size()) return false;
    if (actual_hex.size() != 64) return false;
    ensure_sodium();
    return sodium_memcmp(actual_hex.data(), expected_hex.data(), actual_hex.size()) == 0;
}

std::string expected_hash_for_suffix(std::string_view suffix) {
    const auto sbom = nlohmann::json::parse(generated::kBaselineSbomJson);
    for (const auto& entry : sbom.at("entries")) {
        const auto path = entry.at("path").get<std::string>();
        if (ends_with(path, suffix)) {
            auto hash = entry.at("sha256").get<std::string>();
            std::transform(hash.begin(), hash.end(), hash.begin(), [](unsigned char c) {
                return static_cast<char>(std::tolower(c));
            });
            return hash;
        }
    }
    throw std::runtime_error("Voice integrity: no compiled baseline hash for suffix '" + std::string(suffix) + "'");
}

void verify_voice_integrity_or_throw(const std::vector<VoiceIntegrityFile>& files,
                                     const VoiceIntegrityOptions& options) {
    const auto checked_files = default_checked_files(files);
    for (const auto& file : checked_files) {
        const auto expected = expected_hash_for_suffix(file.baseline_suffix);
        auto actual = sha256_file_hex(file.path);
        std::transform(actual.begin(), actual.end(), actual.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });

        if (!constant_time_hash_equal(actual, expected)) {
            const std::string metadata = std::string("{")
                + "\"classification\":\"CRITICAL_VOICE_INTEGRITY_VIOLATION\","
                + "\"path\":\"" + json_escape(file.path.string()) + "\","
                + "\"baseline_suffix\":\"" + json_escape(file.baseline_suffix) + "\","
                + "\"expected_sha256\":\"" + json_escape(expected) + "\","
                + "\"actual_sha256\":\"" + json_escape(actual) + "\","
                + "\"build_marker\":\"" + json_escape(generated::kVoiceBuildMarker) + "\","
                + "\"configured_voice_sha256\":\"" + json_escape(generated::kConfiguredVoiceSha256) + "\""
                + "}";
            audit_voice_event(options, "CRITICAL_VOICE_INTEGRITY_VIOLATION", jarvis::audit::Outcome::FAIL, metadata, true);
            throw std::runtime_error("Voice integrity violation: JARVIS cannot initialize TTS with non-canonical voice weights (CRITICAL_VOICE_INTEGRITY_VIOLATION)");
        }
    }
}

} // namespace jarvis::tts::onnx::voice_integrity
