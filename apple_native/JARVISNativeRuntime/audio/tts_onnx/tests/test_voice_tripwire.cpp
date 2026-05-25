#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_string.hpp>

#include "../voice_integrity.h"
#include "audit_log.h"

#include <array>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#ifndef VOICE_STATE_PATH
#  define VOICE_STATE_PATH "/Users/rbhanson/research/jarvis/_local_voice/jarvis_voice_state.safetensors"
#endif
#ifndef TEST_ARTIFACT_DIR
#  error TEST_ARTIFACT_DIR must be defined by CMake; tests must not write to /tmp.
#endif
#ifndef JARVIS_VOICE_CMAKE_MODULE_DIR
#  error JARVIS_VOICE_CMAKE_MODULE_DIR must be defined by CMake.
#endif

namespace fs = std::filesystem;
using namespace jarvis::tts::onnx::voice_integrity;

namespace {

void install_test_audit_key() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
}

fs::path test_dir(const std::string& name) {
    install_test_audit_key();
    fs::path d = fs::path(TEST_ARTIFACT_DIR) / name;
    fs::remove_all(d);
    fs::create_directories(d);
    return d;
}

void write_file(const fs::path& path, const std::string& contents) {
    fs::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary);
    REQUIRE(out.good());
    out << contents;
}

std::string read_file(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

bool audit_contains(const fs::path& log_path, const fs::path& key_path, const std::string& kind_or_reason) {
    (void)key_path;
    install_test_audit_key();
    jarvis::audit::TamperEvidentAuditLog audit(log_path.string());
    REQUIRE(audit.verify_chain());
    for (const auto& event : audit) {
        if (event.event_kind == kind_or_reason || event.reason == kind_or_reason) return true;
    }
    return false;
}

} // namespace

TEST_CASE("test_voice_tripwire_match") {
    const auto dir = test_dir("match");
    REQUIRE_NOTHROW(verify_voice_integrity_or_throw({
        {VOICE_STATE_PATH, "_local_voice/jarvis_voice_state.safetensors"},
    }, VoiceIntegrityOptions{dir / "audit.log", dir / "audit.key", false}));
}

TEST_CASE("test_voice_tripwire_mismatch") {
    const auto dir = test_dir("mismatch");
    const auto bad_voice = dir / "jarvis_voice_state.safetensors";
    write_file(bad_voice, "not Paul Bettany canonical weights");

    VoiceIntegrityOptions options{dir / "audit.log", dir / "audit.key", true};
    REQUIRE_THROWS_WITH(verify_voice_integrity_or_throw({
        {bad_voice, "_local_voice/jarvis_voice_state.safetensors"},
    }, options), Catch::Matchers::ContainsSubstring("CRITICAL_VOICE_INTEGRITY_VIOLATION"));
    REQUIRE(audit_contains(options.audit_log_path, options.audit_key_path, "CRITICAL_VOICE_INTEGRITY_VIOLATION"));
}

TEST_CASE("test_voice_tripwire_rotation_requires_attestation") {
    const auto dir = test_dir("rotation_requires_attestation");
    const auto candidate = dir / "candidate.safetensors";
    write_file(candidate, "candidate voice weights");

    const std::string command = "/Users/rbhanson/research/jarvis/apple_native/tools/rotate_voice.sh \"" +
        candidate.string() + "\" \"test rotation must be refused\" > \"" +
        (dir / "rotate.log").string() + "\" 2>&1";
    const int rc = std::system(command.c_str());
    REQUIRE(rc != 0);
    REQUIRE(read_file(dir / "rotate.log").find("operator-attestation token is required") != std::string::npos);
}

TEST_CASE("test_voice_tripwire_build_refusal") {
    const auto dir = test_dir("build_refusal");
    const auto source = dir / "src";
    const auto build = dir / "build";
    fs::create_directories(source);
    write_file(source / "dummy.cpp", "int jarvis_voice_tripwire_dummy() { return 42; }\n");
    write_file(source / "fake_voice.safetensors", "wrong voice");
    write_file(source / "voice-weights-baseline.json", R"JSON({
  "entries": [
    {"path":"_local_voice/jarvis_voice_state.safetensors","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
  ]
}
)JSON");
    write_file(source / "CMakeLists.txt",
        std::string("cmake_minimum_required(VERSION 3.20)\n") +
        "project(voice_refusal LANGUAGES CXX)\n"
        "add_library(dummy STATIC dummy.cpp)\n"
        "list(APPEND CMAKE_MODULE_PATH \"" + std::string(JARVIS_VOICE_CMAKE_MODULE_DIR) + "\")\n"
        "include(VoiceIntegrityGate)\n"
        "set(VOICE_STATE_PATH \"" + (source / "fake_voice.safetensors").string() + "\")\n"
        "set(VOICE_WEIGHTS_BASELINE_JSON \"" + (source / "voice-weights-baseline.json").string() + "\")\n"
        "jarvis_configure_voice_integrity(dummy \"${CMAKE_CURRENT_SOURCE_DIR}\" \"${CMAKE_CURRENT_BINARY_DIR}\")\n");

    const std::string command = "cmake -S \"" + source.string() + "\" -B \"" + build.string() +
        "\" > \"" + (dir / "configure.log").string() + "\" 2>&1";
    const int rc = std::system(command.c_str());
    REQUIRE(rc != 0);
    const auto log = read_file(dir / "configure.log");
    REQUIRE(log.find("Voice weights changed without operator authorization") != std::string::npos);
    REQUIRE(log.find("JARVIS cannot ship") != std::string::npos);
    REQUIRE(log.find("apple_native/tools/rotate_voice.sh (operator-attestation gated)") != std::string::npos);
}
