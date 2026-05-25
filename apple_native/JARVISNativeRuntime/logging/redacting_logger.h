#pragma once

// JARVIS Redacting Logger — C++ 20, header + implementation, no external deps.
//
// Design contract:
//   • Redaction is DEFAULT ON for all fields named in SENSITIVE_FIELDS.md.
//   • A per-subsystem opt-in (runtime config, default: OFF) is required to see
//     operator-content in plaintext.
//   • Non-blocking emit: caller pushes to a bounded in-process queue; a single
//     background worker thread drains the queue and writes to disk.
//   • Disk footprint is bounded (ring-buffer rotation + eviction).
//   • Thread-safe: any thread may call emit() concurrently.
//   • No stdout/stderr pollution — all I/O goes to the log directory only.
//   • Logs are structured JSON Lines: one UTF-8 JSON object per line, LF-terminated.
//
// Output format (one line per entry):
//   {"ts":1716508800.123,"seq":1,"lvl":"INFO","sub":"runtime","evt":"boot",
//    "fields":{"version":"1.0","voice_text":"<redacted:12-chars hash:a3f2>"}}

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

// ─── C ABI ───────────────────────────────────────────────────────────────────
// Safe to call from Swift (via bridging header) or plain C.

#ifdef __cplusplus
extern "C" {
#endif

/// Apply JSON configuration.  Any key may be omitted to keep its current value.
/// Keys:
///   "log_dir"        : string  – absolute path for log files
///                                (default: ~/Library/Logs/JARVIS)
///   "max_disk_bytes" : number  – total bytes cap, default 104857600 (100 MB)
///   "max_seg_bytes"  : number  – per-segment size cap, default 10485760 (10 MB)
///   "min_level"      : string  – TRACE|DEBUG|INFO|WARN|ERROR|FATAL (default: TRACE)
///
/// Idempotent; safe to call multiple times.  Starts the background worker on
/// first call.
void JARVISLog_configure(const char *config_json);

/// Emit one log entry (non-blocking — drops if queue is full).
///
/// level      : 0=TRACE 1=DEBUG 2=INFO 3=WARN 4=ERROR 5=FATAL
/// subsystem  : short ASCII label, e.g. "runtime", "voice", "belief"
/// event      : machine-readable identifier, e.g. "boot", "utterance"
/// fields_json: flat JSON object {"key":"value","key2":42}
///              Values for sensitive field names are replaced with a redaction
///              token unless the subsystem is explicitly opted in.
void JARVISLog_emit(int level, const char *subsystem, const char *event,
                    const char *fields_json);

/// Enable (enabled=1) or disable (enabled=0) full un-redacted logging for a
/// named subsystem.  Default is 0 (redacted) for every subsystem.
void JARVISLog_set_subsystem_optin(const char *subsystem, int enabled);

/// Flush the queue, close the current segment, and stop the background worker.
/// Call before process exit.  Calling emit() after shutdown() is a no-op.
void JARVISLog_shutdown(void);

/// Return the total bytes currently stored in the log directory.
uint64_t JARVISLog_bytes_on_disk(void);

#ifdef __cplusplus
} // extern "C"

// ─── C++ API ─────────────────────────────────────────────────────────────────

namespace jarvis {

enum class LogLevel : int {
    TRACE = 0,
    DEBUG = 1,
    INFO  = 2,
    WARN  = 3,
    ERROR = 4,
    FATAL = 5,
};

/// A single key-value field in a log entry.
struct LogField {
    std::string name;
    std::string value;
    /// When false (default) value is a plain string and will be JSON-quoted +
    /// escaped before emission.  When true, value is emitted verbatim (use for
    /// numbers, booleans, nulls, or pre-serialised JSON fragments).
    bool rawJSON = false;

    // Convenience constructors -------------------------------------------------
    static LogField str(std::string n, std::string v) {
        return {std::move(n), std::move(v), false};
    }
    static LogField num(std::string n, std::string v) {
        return {std::move(n), std::move(v), true};
    }
    static LogField boolean(std::string n, bool v) {
        return {std::move(n), v ? "true" : "false", true};
    }
};

// ─────────────────────────────────────────────────────────────────────────────

class RedactingLogger {
public:
    // ── Configuration ─────────────────────────────────────────────────────────
    struct Config {
        std::filesystem::path logDirectory;          // resolved in configure()
        uint64_t maxDiskBytes    = 100ULL * 1024 * 1024; // 100 MB
        uint64_t maxSegmentBytes =  10ULL * 1024 * 1024; // 10 MB
        std::size_t queueCapacity = 65'536;
        LogLevel    minLevel      = LogLevel::TRACE;
    };

    // ── Singleton ─────────────────────────────────────────────────────────────
    static RedactingLogger& instance();

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    void configure(const Config& cfg);
    void shutdown();

    // ── Emission ─────────────────────────────────────────────────────────────
    void emit(LogLevel level, const std::string& subsystem,
              const std::string& event, std::vector<LogField> fields);

    // ── Redaction policy ─────────────────────────────────────────────────────
    void setSubsystemOptIn(const std::string& subsystem, bool enabled);
    bool isOptedIn(const std::string& subsystem) const;

    // ── Diagnostics ──────────────────────────────────────────────────────────
    uint64_t bytesOnDisk() const;
    uint64_t droppedCount() const { return dropped_.load(std::memory_order_relaxed); }

    // ── Sensitive-field registry ──────────────────────────────────────────────
    static bool isSensitiveField(const std::string& name);
    static const std::unordered_set<std::string>& sensitiveFields();

    // ── Helpers (exposed for testing) ─────────────────────────────────────────
    static std::string redactValue(const std::string& value);
    std::string buildEntryLine(LogLevel level, const std::string& sub,
                               const std::string& evt,
                               const std::vector<LogField>& fields,
                               bool optedIn) const;

private:
    RedactingLogger();
    ~RedactingLogger();
    RedactingLogger(const RedactingLogger&) = delete;
    RedactingLogger& operator=(const RedactingLogger&) = delete;

    void startWorker();
    void workerLoop();

    // Worker-thread-only helpers (no locks required inside these)
    void writeToSegment(const std::string& line);
    void openNewSegment();
    void rotateIfNeeded();
    void evictIfNeeded();
    uint64_t computeDiskUsage() const;

    // --- Config mutex guards: config_, optedIn_, configured_ ---
    mutable std::mutex configMtx_;
    Config config_;
    std::unordered_set<std::string> optedIn_;
    bool configured_{false};

    // --- Queue mutex guards: queue_, queueCapacity_ ---
    mutable std::mutex queueMtx_;
    std::condition_variable queueCv_;
    std::queue<std::string> queue_;
    std::size_t queueCapacity_{65'536};

    std::atomic<uint64_t> dropped_{0};
    mutable std::atomic<uint64_t> seqCounter_{0};
    std::atomic<bool> shutdownRequested_{false};
    std::mutex workerMtx_;   // guards worker_ start/stop
    std::thread worker_;

    // --- Worker-thread state (no locks needed — only the worker touches these) ---
    int      currentFd_{-1};
    uint64_t currentSegBytes_{0};
    uint64_t segSeq_{0};
    std::filesystem::path currentPath_;
    std::vector<std::filesystem::path> segments_; // sorted oldest → newest
};

// ─── Convenience free functions ───────────────────────────────────────────────

inline void log(LogLevel lvl, const std::string& sub, const std::string& evt,
                std::vector<LogField> fields = {}) {
    RedactingLogger::instance().emit(lvl, sub, evt, std::move(fields));
}

inline void logInfo(const std::string& sub, const std::string& evt,
                    std::vector<LogField> fields = {}) {
    RedactingLogger::instance().emit(LogLevel::INFO, sub, evt, std::move(fields));
}

inline void logWarn(const std::string& sub, const std::string& evt,
                    std::vector<LogField> fields = {}) {
    RedactingLogger::instance().emit(LogLevel::WARN, sub, evt, std::move(fields));
}

inline void logError(const std::string& sub, const std::string& evt,
                     std::vector<LogField> fields = {}) {
    RedactingLogger::instance().emit(LogLevel::ERROR, sub, evt, std::move(fields));
}

} // namespace jarvis

#endif // __cplusplus
