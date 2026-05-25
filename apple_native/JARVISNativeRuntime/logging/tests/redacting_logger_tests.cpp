// JARVIS Redacting Logger — test suite
// Compile and run:
//   clang++ -std=c++20 -O2 -pthread \
//       -I.. \
//       redacting_logger_tests.cpp ../redacting_logger.cpp \
//       -o redacting_logger_tests && ./redacting_logger_tests
//
// Exit code 0 = all tests pass.

#include "../redacting_logger.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// ─── Minimal JSON validator ────────────────────────────────────────────────────
// Returns true if the given string is a valid JSON object (shallow check:
// balanced braces, no embedded newlines outside strings).
static bool isValidJSONObject(const std::string& line) {
    if (line.empty() || line.front() != '{') return false;
    int depth = 0;
    bool inStr = false;
    for (std::size_t i = 0; i < line.size(); ++i) {
        char c = line[i];
        if (inStr) {
            if (c == '\\') { ++i; continue; }
            if (c == '"') inStr = false;
        } else {
            if (c == '"') inStr = true;
            else if (c == '{' || c == '[') ++depth;
            else if (c == '}' || c == ']') { --depth; if (depth < 0) return false; }
        }
    }
    return depth == 0;
}

// ─── Test harness ─────────────────────────────────────────────────────────────
static int  g_tests  = 0;
static int  g_passed = 0;
static int  g_failed = 0;

#define CHECK(cond, msg) do { \
    ++g_tests; \
    if (cond) { \
        ++g_passed; \
        std::printf("  PASS  %s\n", msg); \
    } else { \
        ++g_failed; \
        std::printf("  FAIL  %s  [%s:%d]\n", msg, __FILE__, __LINE__); \
    } \
} while(0)

// ─── Helpers ─────────────────────────────────────────────────────────────────

static std::vector<std::string> readLines(const std::filesystem::path& p) {
    std::vector<std::string> lines;
    std::ifstream f(p);
    std::string ln;
    while (std::getline(f, ln)) {
        if (!ln.empty()) lines.push_back(ln);
    }
    return lines;
}

static std::vector<std::string> readAllLogLines(const std::filesystem::path& dir) {
    std::vector<std::string> all;
    if (!std::filesystem::exists(dir)) return all;
    std::vector<std::filesystem::path> files;
    for (const auto& ent : std::filesystem::directory_iterator(dir)) {
        if (ent.path().extension() == ".jsonl") {
            files.push_back(ent.path());
        }
    }
    std::sort(files.begin(), files.end());
    for (const auto& f : files) {
        auto lines = readLines(f);
        all.insert(all.end(), lines.begin(), lines.end());
    }
    return all;
}

static std::filesystem::path makeTempLogDir(const std::string& suffix) {
    std::filesystem::path dir =
        std::filesystem::current_path() / ("jarvis_test_logs_" + suffix);
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

static void flushLogger(int ms = 200) {
    // Give the worker thread time to drain the queue.
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// ─── Test 1: Redaction default ON ─────────────────────────────────────────────
static void testRedactionDefaultOn() {
    std::printf("\n=== Test 1: Redaction default ON ===\n");

    using namespace jarvis;

    // Build a line with a sensitive field and a non-sensitive field.
    // Use the public helper to avoid disk I/O for this unit test.
    RedactingLogger& log = RedactingLogger::instance();

    std::vector<LogField> fields = {
        LogField::str("voice_text",        "the operator said something private"),
        LogField::str("transcript",        "full transcript text here"),
        LogField::str("belief",            "internal belief value"),
        LogField::str("operator_content",  "operator wrote this"),
        LogField::str("prompt",            "system prompt text"),
        LogField::str("response",          "model response here"),
        LogField::str("non_sensitive",     "this is fine"),
        LogField::str("version",           "1.0"),
    };

    std::string line = log.buildEntryLine(LogLevel::INFO, "voice", "utterance",
                                           fields, /* optedIn= */ false);

    CHECK(line.find("<redacted:") != std::string::npos,
          "sensitive field produces redaction token");
    CHECK(line.find("the operator said something private") == std::string::npos,
          "voice_text plaintext absent when not opted in");
    CHECK(line.find("full transcript text here") == std::string::npos,
          "transcript plaintext absent when not opted in");
    CHECK(line.find("internal belief value") == std::string::npos,
          "belief plaintext absent when not opted in");
    CHECK(line.find("operator wrote this") == std::string::npos,
          "operator_content plaintext absent when not opted in");
    CHECK(line.find("system prompt text") == std::string::npos,
          "prompt plaintext absent when not opted in");
    CHECK(line.find("model response here") == std::string::npos,
          "response plaintext absent when not opted in");
    CHECK(line.find("\"this is fine\"") != std::string::npos,
          "non-sensitive field is present in plaintext");
    CHECK(line.find("\"1.0\"") != std::string::npos,
          "version field is present in plaintext");

    // Verify the redaction token format: <redacted:N-chars hash:XXXX>
    const std::string prefix = "<redacted:";
    auto pos = line.find(prefix);
    CHECK(pos != std::string::npos, "redaction token has correct prefix");
    if (pos != std::string::npos) {
        auto end = line.find('>', pos);
        CHECK(end != std::string::npos, "redaction token is closed");
        std::string token = line.substr(pos, end - pos + 1);
        CHECK(token.find("-chars hash:") != std::string::npos,
              "redaction token contains -chars hash: segment");
    }
}

// ─── Test 2: Opt-in enables full logging ──────────────────────────────────────
static void testOptInEnablesFullLogging() {
    std::printf("\n=== Test 2: Opt-in enables full logging ===\n");

    using namespace jarvis;

    RedactingLogger& log = RedactingLogger::instance();

    std::vector<LogField> fields = {
        LogField::str("voice_text",    "opted-in plaintext voice"),
        LogField::str("transcript",    "opted-in plaintext transcript"),
        LogField::str("non_sensitive", "plain value"),
    };

    std::string line = log.buildEntryLine(LogLevel::INFO, "voice_optin", "utterance",
                                           fields, /* optedIn= */ true);

    CHECK(line.find("opted-in plaintext voice") != std::string::npos,
          "voice_text appears in plaintext when opted in");
    CHECK(line.find("opted-in plaintext transcript") != std::string::npos,
          "transcript appears in plaintext when opted in");
    CHECK(line.find("<redacted:") == std::string::npos,
          "no redaction tokens when opted in");
    CHECK(line.find("\"plain value\"") != std::string::npos,
          "non-sensitive field unaffected by opt-in");
}

// ─── Test 3: Ring-buffer rotation and eviction ────────────────────────────────
static void testRingBufferRotation() {
    std::printf("\n=== Test 3: Ring-buffer rotation and eviction ===\n");

    auto dir = makeTempLogDir("rotation");

    // Configure: tiny segments (4 KB) and tight disk cap (20 KB).
    JARVISLog_configure(("{\"log_dir\":\"" + dir.string() +
                          "\",\"max_disk_bytes\":20480"
                          ",\"max_seg_bytes\":4096"
                          ",\"min_level\":\"TRACE\"}").c_str());

    // Write enough data to force multiple rotations.
    // Each line is ~120 chars; 200 lines ≈ 24 KB > 20 KB cap.
    const int N = 300;
    for (int i = 0; i < N; ++i) {
        std::string payload = "rotation test entry number " + std::to_string(i) +
                              " padding padding padding padding padding padding";
        JARVISLog_emit(2, "rotation_test", "entry",
                       ("{\"seq\":" + std::to_string(i) +
                        ",\"non_sensitive\":\"" + payload + "\"}").c_str());
    }

    flushLogger(500);
    JARVISLog_shutdown();

    // Verify: at least 2 segment files exist (rotation happened).
    std::vector<std::filesystem::path> segs;
    for (const auto& ent : std::filesystem::directory_iterator(dir)) {
        if (ent.path().extension() == ".jsonl") segs.push_back(ent.path());
    }
    std::sort(segs.begin(), segs.end());

    CHECK(segs.size() >= 2, "at least 2 segment files after rotation");

    // Verify: total bytes on disk ≤ 20 KB (eviction worked).
    uint64_t total = 0;
    for (const auto& p : segs) {
        std::error_code ec;
        total += std::filesystem::file_size(p, ec);
    }
    CHECK(total <= 20480 + 4096, // allow one segment's slack for the last write
          "total disk usage within cap after eviction");

    std::printf("  INFO  %zu segments, %llu bytes on disk\n",
                segs.size(), static_cast<unsigned long long>(total));

    // Verify: oldest entries were evicted (we can't find seq=0 if cap enforced).
    // (This is probabilistic for small N; the cap is tight enough to force it.)
    auto allLines = readAllLogLines(dir);
    bool found0 = false;
    for (const auto& ln : allLines) {
        if (ln.find("\"seq\":0") != std::string::npos) { found0 = true; break; }
    }
    CHECK(!found0, "oldest entries evicted from ring buffer");

    std::filesystem::remove_all(dir);
}

// ─── Test 4: Thread safety ────────────────────────────────────────────────────
static void testThreadSafety() {
    std::printf("\n=== Test 4: Thread safety (concurrent writers) ===\n");

    auto dir = makeTempLogDir("threads");

    JARVISLog_configure(("{\"log_dir\":\"" + dir.string() +
                          "\",\"max_disk_bytes\":104857600"
                          ",\"max_seg_bytes\":10485760"
                          ",\"min_level\":\"TRACE\"}").c_str());

    const int THREADS = 8;
    const int ENTRIES_PER_THREAD = 500;

    std::vector<std::thread> workers;
    workers.reserve(THREADS);
    for (int t = 0; t < THREADS; ++t) {
        workers.emplace_back([t, &dir]() {
            for (int i = 0; i < ENTRIES_PER_THREAD; ++i) {
                std::string fields =
                    "{\"thread\":" + std::to_string(t) +
                    ",\"idx\":" + std::to_string(i) +
                    ",\"non_sensitive\":\"thread_safety_test\"}";
                JARVISLog_emit(2, "thread_test", "emit", fields.c_str());
            }
        });
    }
    for (auto& w : workers) w.join();

    flushLogger(800);
    JARVISLog_shutdown();

    auto allLines = readAllLogLines(dir);
    int validJSON = 0;
    int tornLines = 0;
    for (const auto& ln : allLines) {
        if (isValidJSONObject(ln)) ++validJSON;
        else                       ++tornLines;
    }

    CHECK(tornLines == 0, "zero torn (malformed) log lines under concurrent writes");
    std::printf("  INFO  %d total lines written, %d valid JSON, %d torn\n",
                static_cast<int>(allLines.size()), validJSON, tornLines);

    int expected = THREADS * ENTRIES_PER_THREAD;
    // Some may be dropped if queue fills, but most should make it through.
    CHECK(validJSON >= expected * 8 / 10,
          "at least 80% of entries persisted (drop tolerance)");

    std::filesystem::remove_all(dir);
}

// ─── Test 5: JSON parsability ─────────────────────────────────────────────────
static void testJSONParsability() {
    std::printf("\n=== Test 5: JSON parsability ===\n");

    auto dir = makeTempLogDir("json");

    JARVISLog_configure(("{\"log_dir\":\"" + dir.string() +
                          "\",\"max_disk_bytes\":104857600"
                          ",\"max_seg_bytes\":10485760"
                          ",\"min_level\":\"TRACE\"}").c_str());

    // Emit entries covering: sensitive (redacted), non-sensitive, numeric,
    // special characters in values, empty fields.
    JARVISLog_emit(0, "json_test", "trace_entry",
                   "{\"non_sensitive\":\"hello\",\"count\":42,\"flag\":true}");
    JARVISLog_emit(2, "json_test", "sensitive_entry",
                   "{\"voice_text\":\"secret\",\"transcript\":\"also secret\","
                   "\"non_sensitive\":\"plain\"}");
    JARVISLog_emit(3, "json_test", "special_chars",
                   "{\"non_sensitive\":\"tab\\there newline\\nquote\\\"end\"}");
    JARVISLog_emit(4, "json_test", "empty_fields", "{}");
    JARVISLog_emit(5, "json_test", "fatal_entry",
                   "{\"non_sensitive\":\"fatal test\"}");

    // Opt-in test: enable and emit, then disable.
    JARVISLog_set_subsystem_optin("json_test", 1);
    JARVISLog_emit(2, "json_test", "optin_entry",
                   "{\"voice_text\":\"visible after optin\","
                   "\"non_sensitive\":\"also visible\"}");
    JARVISLog_set_subsystem_optin("json_test", 0);
    JARVISLog_emit(2, "json_test", "post_optin_entry",
                   "{\"voice_text\":\"now redacted again\","
                   "\"non_sensitive\":\"still visible\"}");

    flushLogger(300);
    JARVISLog_shutdown();

    auto allLines = readAllLogLines(dir);
    CHECK(!allLines.empty(), "log file contains entries");

    int valid = 0;
    int invalid = 0;
    for (const auto& ln : allLines) {
        if (isValidJSONObject(ln)) ++valid;
        else { ++invalid; std::printf("  BAD LINE: %s\n", ln.c_str()); }
    }
    CHECK(invalid == 0, "all log lines are valid JSON objects");
    CHECK(valid >= 7,   "all 7+ emitted entries present");

    // Find opt-in entry and verify plaintext present.
    bool optinVisible = false;
    for (const auto& ln : allLines) {
        if (ln.find("optin_entry") != std::string::npos &&
            ln.find("visible after optin") != std::string::npos) {
            optinVisible = true;
        }
    }
    CHECK(optinVisible, "opt-in entry shows voice_text in plaintext");

    // Find post-opt-in entry and verify it's redacted again.
    bool postOptinRedacted = false;
    for (const auto& ln : allLines) {
        if (ln.find("post_optin_entry") != std::string::npos &&
            ln.find("<redacted:") != std::string::npos) {
            postOptinRedacted = true;
        }
    }
    CHECK(postOptinRedacted, "disabling opt-in restores redaction");

    std::filesystem::remove_all(dir);
}

// ─── Test 6: Performance baseline ────────────────────────────────────────────
static void testPerformance() {
    std::printf("\n=== Test 6: Performance baseline ===\n");

    auto dir = makeTempLogDir("perf");

    JARVISLog_configure(("{\"log_dir\":\"" + dir.string() +
                          "\",\"max_disk_bytes\":524288000"  // 500 MB cap
                          ",\"max_seg_bytes\":10485760"
                          ",\"min_level\":\"TRACE\"}").c_str());

    const int N = 50'000;
    auto t0 = std::chrono::steady_clock::now();

    for (int i = 0; i < N; ++i) {
        JARVISLog_emit(2, "perf_test", "entry",
                       "{\"non_sensitive\":\"perf benchmark payload\","
                       "\"count\":1234}");
    }

    auto t1 = std::chrono::steady_clock::now();
    double emitMs = std::chrono::duration<double, std::milli>(t1 - t0).count();
    double emitPerSec = N / (emitMs / 1000.0);

    std::printf("  INFO  %d emit() calls in %.1f ms — %.0f emit/sec (non-blocking)\n",
                N, emitMs, emitPerSec);
    CHECK(emitPerSec > 100'000,
          "emit() throughput > 100k/sec (non-blocking queue push)");

    flushLogger(1500);
    JARVISLog_shutdown();

    uint64_t bytes = 0;
    for (const auto& ent : std::filesystem::directory_iterator(dir)) {
        if (ent.path().extension() == ".jsonl") {
            std::error_code ec;
            bytes += std::filesystem::file_size(ent.path(), ec);
        }
    }
    std::printf("  INFO  %.1f KB written to disk\n", bytes / 1024.0);

    std::filesystem::remove_all(dir);
}

// ─── Test 7: C ABI round-trip ────────────────────────────────────────────────
static void testCABIRoundTrip() {
    std::printf("\n=== Test 7: C ABI — configure / emit / bytes_on_disk ===\n");

    auto dir = makeTempLogDir("cabi");
    std::string cfg =
        "{\"log_dir\":\"" + dir.string() + "\""
        ",\"max_disk_bytes\":10485760"
        ",\"max_seg_bytes\":1048576"
        ",\"min_level\":\"DEBUG\"}";
    JARVISLog_configure(cfg.c_str());

    JARVISLog_emit(1, "cabi", "debug_entry", "{\"non_sensitive\":\"debug\"}");
    JARVISLog_emit(2, "cabi", "info_entry",  "{\"non_sensitive\":\"info\"}");
    JARVISLog_emit(4, "cabi", "error_entry",
                   "{\"voice_text\":\"should be redacted\",\"non_sensitive\":\"err\"}");

    // TRACE entries should be filtered (min_level is DEBUG).
    JARVISLog_emit(0, "cabi", "trace_should_not_appear",
                   "{\"non_sensitive\":\"filtered\"}");

    flushLogger(300);
    uint64_t bytes = JARVISLog_bytes_on_disk();
    CHECK(bytes > 0, "bytes_on_disk() > 0 after writes");

    JARVISLog_shutdown();

    auto allLines = readAllLogLines(dir);
    bool tracePresent = false;
    bool errorRedacted = false;
    for (const auto& ln : allLines) {
        if (ln.find("trace_should_not_appear") != std::string::npos)
            tracePresent = true;
        if (ln.find("error_entry") != std::string::npos &&
            ln.find("<redacted:") != std::string::npos)
            errorRedacted = true;
    }
    CHECK(!tracePresent, "TRACE entries filtered when min_level=DEBUG");
    CHECK(errorRedacted,  "voice_text redacted in ERROR entry via C ABI");

    std::filesystem::remove_all(dir);
}

// ─── main ─────────────────────────────────────────────────────────────────────
int main() {
    std::printf("JARVIS Redacting Logger — test suite\n");
    std::printf("=====================================\n");

    testRedactionDefaultOn();
    testOptInEnablesFullLogging();
    testRingBufferRotation();
    testThreadSafety();
    testJSONParsability();
    testPerformance();
    testCABIRoundTrip();

    std::printf("\n=====================================\n");
    std::printf("Results: %d/%d passed", g_passed, g_tests);
    if (g_failed > 0) {
        std::printf(", %d FAILED", g_failed);
    }
    std::printf("\n");

    return g_failed > 0 ? 1 : 0;
}
