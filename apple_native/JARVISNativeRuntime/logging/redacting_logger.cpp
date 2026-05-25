// JARVIS Redacting Logger — implementation
// See redacting_logger.h for API contract and design notes.
//
// Internal layout
// ───────────────
//  emit() (any thread)
//    → acquires queue lock
//    → formats entry (applies redaction under config lock)
//    → pushes serialised JSON-Lines string onto bounded queue (drop on full)
//    → signals worker thread
//
//  workerLoop() (dedicated thread, started on first configure())
//    → waits on condition variable
//    → pops batch from queue
//    → calls writeToSegment() which:
//        - rotates segment if current file is full
//        - evicts oldest segments when total disk usage exceeds cap
//        - writes serialised line + newline via POSIX write()
//
// Log segment filename:  jarvis_YYYYMMDDTHHMMSS_<6-digit-seq>.jsonl
// Segments are listed newest-last so eviction deletes from the front.

#include "redacting_logger.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <ctime>
#include <format>
#include <iomanip>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <system_error>
#include <unordered_map>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
#  include <pwd.h>
#endif

// ─── File-scope constants and helpers ────────────────────────────────────────
// Placed BEFORE namespace jarvis so these are also visible to the C ABI
// functions defined at file scope after the namespace block.

namespace {

// Canonical set of field names that are ALWAYS redacted unless the subsystem
// is explicitly opted in.  Must be kept in sync with SENSITIVE_FIELDS.md.
static const std::unordered_set<std::string> kSensitiveFields = {
    "operator_content",
    "transcript",
    "belief",
    "memory",
    "voice_text",
    "prompt",
    "response",
    "utterance",
    "reply",
    "input_text",
    "output_text",
    "raw_llm_response",
    "raw_stt_text",
    "tts_input",
    "conversation_turn",
    "system_prompt",
    "user_message",
    "assistant_message",
    "access_token",
    "refresh_token",
    "id_token",
    "token",
    "authorization",
    "auth_header",
    "bearer",
    "client_secret",
    "code_verifier",
    "sensitive",
};

static const char* kLevelNames[] = {
    "TRACE", "DEBUG", "INFO", "WARN", "ERROR", "FATAL"
};

// FNV-1a 32-bit hash, returns first 4 hex nibbles (16-bit portion).
static std::string shortHash(const std::string& s) {
    uint32_t h = 2166136261u;
    for (unsigned char c : s) {
        h ^= c;
        h *= 16777619u;
    }
    // XOR-fold to 16 bits for compactness
    uint16_t h16 = static_cast<uint16_t>(h ^ (h >> 16));
    char buf[5];
    std::snprintf(buf, sizeof(buf), "%04x", static_cast<unsigned>(h16));
    return std::string(buf, 4);
}

// JSON-escape a UTF-8 string (no surrounding quotes).
static std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 4);
    for (unsigned char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b";  break;
        case '\f': out += "\\f";  break;
        case '\n': out += "\\n";  break;
        case '\r': out += "\\r";  break;
        case '\t': out += "\\t";  break;
        default:
            if (c < 0x20) {
                char hex[7];
                std::snprintf(hex, sizeof(hex), "\\u%04x", c);
                out += hex;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out;
}

// Current UTC timestamp as a double (seconds.fraction since Unix epoch).
static double nowSeconds() {
    using namespace std::chrono;
    return duration<double>(system_clock::now().time_since_epoch()).count();
}

// Format a UTC timestamp as ISO-8601 for segment file names.
static std::string timestampForFilename() {
    auto now = std::chrono::system_clock::now();
    std::time_t t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    gmtime_r(&t, &tm);
    char buf[20];
    std::strftime(buf, sizeof(buf), "%Y%m%dT%H%M%S", &tm);
    return std::string(buf);
}

// Return default log directory (~/Library/Logs/JARVIS).
static std::filesystem::path defaultLogDir() {
#ifdef __APPLE__
    const char* home = std::getenv("HOME");
    if (!home) {
        struct passwd* pw = getpwuid(getuid());
        if (pw) home = pw->pw_dir;
    }
    if (home) {
        return std::filesystem::path(home) / "Library" / "Logs" / "JARVIS";
    }
#endif
    return std::filesystem::temp_directory_path() / "JARVIS_logs";
}

// ── Minimal flat-JSON-object parser ──────────────────────────────────────────
//
// Parses {"key": value, ...} where values are strings, numbers, booleans,
// or null.  Nested objects/arrays are captured verbatim as raw JSON.
// This is intentionally minimal — it handles only the shapes emitted by the
// Swift bridge and by hand-constructed test strings.

static bool skipWS(const char* p, std::size_t len, std::size_t& i) {
    while (i < len && (p[i] == ' ' || p[i] == '\t' ||
                       p[i] == '\n' || p[i] == '\r')) ++i;
    return i < len;
}

static bool parseString(const char* p, std::size_t len,
                         std::size_t& i, std::string& out) {
    if (i >= len || p[i] != '"') return false;
    ++i;
    out.clear();
    while (i < len && p[i] != '"') {
        if (p[i] == '\\' && i + 1 < len) {
            ++i;
            switch (p[i]) {
            case '"':  out += '"';  break;
            case '\\': out += '\\'; break;
            case '/':  out += '/';  break;
            case 'b':  out += '\b'; break;
            case 'f':  out += '\f'; break;
            case 'n':  out += '\n'; break;
            case 'r':  out += '\r'; break;
            case 't':  out += '\t'; break;
            case 'u': {
                // 4-hex escape — re-encode as UTF-8 (BMP only)
                if (i + 4 < len) {
                    char hex[5] = {p[i+1], p[i+2], p[i+3], p[i+4], 0};
                    uint32_t cp = static_cast<uint32_t>(std::strtoul(hex, nullptr, 16));
                    i += 4;
                    if (cp < 0x80) {
                        out += static_cast<char>(cp);
                    } else if (cp < 0x800) {
                        out += static_cast<char>(0xC0 | (cp >> 6));
                        out += static_cast<char>(0x80 | (cp & 0x3F));
                    } else {
                        out += static_cast<char>(0xE0 | (cp >> 12));
                        out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                        out += static_cast<char>(0x80 | (cp & 0x3F));
                    }
                }
                break;
            }
            default: out += p[i]; break;
            }
        } else {
            out += p[i];
        }
        ++i;
    }
    if (i < len && p[i] == '"') { ++i; return true; }
    return false;
}

// Parse any JSON value; for strings returns decoded content (isString=true),
// for other types returns the raw JSON token (isString=false).
static bool parseRawValue(const char* p, std::size_t len,
                           std::size_t& i, std::string& raw, bool& isString) {
    skipWS(p, len, i);
    if (i >= len) return false;

    if (p[i] == '"') {
        std::string sv;
        if (!parseString(p, len, i, sv)) return false;
        raw = sv;
        isString = true;
        return true;
    }
    isString = false;
    if (p[i] == '{' || p[i] == '[') {
        char open = p[i], close = (open == '{') ? '}' : ']';
        int depth = 0;
        std::size_t start = i;
        bool inStr = false;
        while (i < len) {
            char c = p[i];
            if (inStr) {
                if (c == '\\') { ++i; }
                else if (c == '"') inStr = false;
            } else {
                if (c == '"') inStr = true;
                else if (c == open) ++depth;
                else if (c == close) { --depth; if (depth == 0) { ++i; break; } }
            }
            ++i;
        }
        raw = std::string(p + start, i - start);
        return true;
    }
    // literal (number, bool, null)
    std::size_t start = i;
    while (i < len && p[i] != ',' && p[i] != '}' && p[i] != ']' &&
           p[i] != ' ' && p[i] != '\n' && p[i] != '\r' && p[i] != '\t') {
        ++i;
    }
    raw = std::string(p + start, i - start);
    return !raw.empty();
}

struct ParsedField {
    std::string name;
    std::string value;
    bool rawJSON; // true for numbers/bools/null/nested; false for strings
};

static std::vector<ParsedField> parseFieldsJSON(const char* json) {
    std::vector<ParsedField> fields;
    if (!json) return fields;
    std::size_t len = std::strlen(json);
    std::size_t i = 0;
    skipWS(json, len, i);
    if (i >= len || json[i] != '{') return fields;
    ++i;
    while (true) {
        skipWS(json, len, i);
        if (i >= len || json[i] == '}') break;
        std::string key;
        if (!parseString(json, len, i, key)) break;
        skipWS(json, len, i);
        if (i >= len || json[i] != ':') break;
        ++i;
        skipWS(json, len, i);
        std::string val;
        bool isStr = false;
        if (!parseRawValue(json, len, i, val, isStr)) break;
        fields.push_back({std::move(key), std::move(val), !isStr});
        skipWS(json, len, i);
        if (i < len && json[i] == ',') ++i;
    }
    return fields;
}

static std::unordered_map<std::string, std::string>
parseConfigJSON(const char* json) {
    std::unordered_map<std::string, std::string> out;
    if (!json) return out;
    std::size_t len = std::strlen(json);
    std::size_t i = 0;
    skipWS(json, len, i);
    if (i >= len || json[i] != '{') return out;
    ++i;
    while (true) {
        skipWS(json, len, i);
        if (i >= len || json[i] == '}') break;
        std::string key;
        if (!parseString(json, len, i, key)) break;
        skipWS(json, len, i);
        if (i >= len || json[i] != ':') break;
        ++i;
        skipWS(json, len, i);
        std::string val;
        bool isStr = false;
        if (!parseRawValue(json, len, i, val, isStr)) break;
        out[key] = val;
        skipWS(json, len, i);
        if (i < len && json[i] == ',') ++i;
    }
    return out;
}

} // anonymous namespace (file scope)

// ─────────────────────────────────────────────────────────────────────────────

namespace jarvis {

// ─── Sensitive field registry ─────────────────────────────────────────────────

bool RedactingLogger::isSensitiveField(const std::string& name) {
    return kSensitiveFields.count(name) > 0;
}

const std::unordered_set<std::string>& RedactingLogger::sensitiveFields() {
    return kSensitiveFields;
}

// ─── Redaction ────────────────────────────────────────────────────────────────

std::string RedactingLogger::redactValue(const std::string& value) {
    std::size_t n = value.size();
    return std::format("<redacted:{}-chars hash:{}>", n, shortHash(value));
}

// ─── Singleton ────────────────────────────────────────────────────────────────

RedactingLogger& RedactingLogger::instance() {
    static RedactingLogger inst;
    return inst;
}

RedactingLogger::RedactingLogger() = default;

RedactingLogger::~RedactingLogger() {
    shutdown();
}

// ─── Entry formatting ─────────────────────────────────────────────────────────

std::string RedactingLogger::buildEntryLine(
        LogLevel level, const std::string& sub, const std::string& evt,
        const std::vector<LogField>& fields, bool optedIn) const {

    uint64_t seq = seqCounter_.fetch_add(1, std::memory_order_relaxed) + 1;
    double ts = nowSeconds();

    const char* lvlName =
        (static_cast<int>(level) >= 0 && static_cast<int>(level) <= 5)
        ? kLevelNames[static_cast<int>(level)]
        : "UNKNOWN";

    std::string line;
    line.reserve(256);
    line += std::format(
        "{{\"ts\":{:.6f},\"seq\":{},\"lvl\":\"{}\",\"sub\":\"{}\",\"evt\":\"{}\",\"fields\":{{",
        ts, seq, lvlName, jsonEscape(sub), jsonEscape(evt));

    bool first = true;
    for (const auto& f : fields) {
        if (!first) line += ',';
        first = false;
        line += '"';
        line += jsonEscape(f.name);
        line += "\":";

        bool sensitive = isSensitiveField(f.name);
        if (sensitive && !optedIn) {
            // Always redact: even rawJSON values get redacted (value is the
            // serialised form, but we redact based on the string representation).
            line += '"';
            line += jsonEscape(redactValue(f.value));
            line += '"';
        } else {
            if (f.rawJSON) {
                line += f.value; // emit as-is: number, bool, null, nested object
            } else {
                line += '"';
                line += jsonEscape(f.value);
                line += '"';
            }
        }
    }
    line += "}}";
    return line;
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

void RedactingLogger::configure(const Config& cfg) {
    {
        std::lock_guard<std::mutex> lk(configMtx_);
        config_ = cfg;
        if (config_.logDirectory.empty()) {
            config_.logDirectory = defaultLogDir();
        }
        queueCapacity_ = config_.queueCapacity;
        configured_ = true;
    }
    startWorker();
}

void RedactingLogger::startWorker() {
    std::lock_guard<std::mutex> lk(workerMtx_);
    if (worker_.joinable()) return; // already running
    shutdownRequested_.store(false, std::memory_order_relaxed);
    worker_ = std::thread([this]{ workerLoop(); });
}

void RedactingLogger::shutdown() {
    shutdownRequested_.store(true, std::memory_order_relaxed);
    queueCv_.notify_all();
    std::thread joinable;
    {
        std::lock_guard<std::mutex> lk(workerMtx_);
        joinable = std::move(worker_);
    }
    if (joinable.joinable()) {
        joinable.join();
    }
    if (currentFd_ >= 0) {
        ::close(currentFd_);
        currentFd_ = -1;
    }
}

// ─── Opt-in ───────────────────────────────────────────────────────────────────

void RedactingLogger::setSubsystemOptIn(const std::string& subsystem, bool enabled) {
    std::lock_guard<std::mutex> lk(configMtx_);
    if (enabled) optedIn_.insert(subsystem);
    else         optedIn_.erase(subsystem);
}

bool RedactingLogger::isOptedIn(const std::string& subsystem) const {
    std::lock_guard<std::mutex> lk(configMtx_);
    return optedIn_.count(subsystem) > 0;
}

// ─── Emit ─────────────────────────────────────────────────────────────────────

void RedactingLogger::emit(LogLevel level, const std::string& subsystem,
                            const std::string& event, std::vector<LogField> fields) {
    // Check min level under config lock (avoid unnecessary work).
    {
        std::lock_guard<std::mutex> lk(configMtx_);
        if (!configured_) {
            // Auto-configure with defaults on first emit so the caller doesn't
            // need to call configure() explicitly.
            config_.logDirectory = defaultLogDir();
            configured_ = true;
        }
        if (level < config_.minLevel) return;
    }

    bool optedIn = isOptedIn(subsystem);
    std::string line = buildEntryLine(level, subsystem, event, fields, optedIn);

    {
        std::unique_lock<std::mutex> lk(queueMtx_);
        if (queue_.size() >= queueCapacity_) {
            dropped_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        queue_.push(std::move(line));
    }
    queueCv_.notify_one();

    // Lazy-start worker if not yet running (protected against concurrent calls
    // by startWorker()'s internal workerMtx_).
    startWorker();
}

// ─── Worker thread ────────────────────────────────────────────────────────────

void RedactingLogger::workerLoop() {
    // Ensure log directory exists.
    {
        std::filesystem::path dir;
        {
            std::lock_guard<std::mutex> lk(configMtx_);
            dir = config_.logDirectory;
        }
        try {
            std::filesystem::create_directories(dir);
        } catch (...) {}

        // Discover existing segment files (sorted lexicographically = time order).
        try {
            for (const auto& ent : std::filesystem::directory_iterator(dir)) {
                if (ent.path().extension() == ".jsonl") {
                    segments_.push_back(ent.path());
                }
            }
            std::sort(segments_.begin(), segments_.end());
        } catch (...) {}
    }

    openNewSegment();

    while (true) {
        std::vector<std::string> batch;
        batch.reserve(64);

        {
            std::unique_lock<std::mutex> lk(queueMtx_);
            queueCv_.wait(lk, [this]{
                return !queue_.empty() || shutdownRequested_.load(std::memory_order_relaxed);
            });
            // Drain the queue into local batch.
            while (!queue_.empty()) {
                batch.push_back(std::move(queue_.front()));
                queue_.pop();
            }
        }

        // Inject a diagnostic entry if entries were dropped since last flush.
        uint64_t dropped = dropped_.exchange(0, std::memory_order_relaxed);
        if (dropped > 0) {
            std::string diag = std::format(
                "{{\"ts\":{:.6f},\"seq\":{},\"lvl\":\"WARN\","
                "\"sub\":\"logger\",\"evt\":\"entries_dropped\","
                "\"fields\":{{\"count\":{}}}}}",
                nowSeconds(),
                seqCounter_.fetch_add(1, std::memory_order_relaxed) + 1,
                dropped);
            batch.insert(batch.begin(), std::move(diag));
        }

        for (const auto& line : batch) {
            writeToSegment(line);
        }

        if (shutdownRequested_.load(std::memory_order_relaxed)) {
            // Drain any last entries pushed between the wait and this check.
            std::vector<std::string> tail;
            {
                std::unique_lock<std::mutex> lk(queueMtx_);
                while (!queue_.empty()) {
                    tail.push_back(std::move(queue_.front()));
                    queue_.pop();
                }
            }
            for (const auto& line : tail) writeToSegment(line);
            break;
        }
    }

    if (currentFd_ >= 0) {
        ::close(currentFd_);
        currentFd_ = -1;
    }
}

// ─── Segment management (worker-thread only) ──────────────────────────────────

void RedactingLogger::openNewSegment() {
    if (currentFd_ >= 0) {
        ::close(currentFd_);
        currentFd_ = -1;
    }

    std::filesystem::path dir;
    {
        std::lock_guard<std::mutex> lk(configMtx_);
        dir = config_.logDirectory;
    }

    ++segSeq_;
    std::string fname = std::format("jarvis_{}_{:06d}.jsonl", timestampForFilename(), segSeq_);
    currentPath_ = dir / fname;

    int fd = ::open(currentPath_.c_str(),
                    O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd < 0) {
        // If we can't open the file, continue without disk persistence (silent).
        currentFd_ = -1;
        currentSegBytes_ = 0;
        return;
    }

    // Determine existing size (append mode opens at end).
    struct stat st{};
    if (::fstat(fd, &st) == 0) {
        currentSegBytes_ = static_cast<uint64_t>(st.st_size);
    }
    currentFd_ = fd;
    segments_.push_back(currentPath_);
}

void RedactingLogger::rotateIfNeeded() {
    uint64_t maxSeg;
    {
        std::lock_guard<std::mutex> lk(configMtx_);
        maxSeg = config_.maxSegmentBytes;
    }
    if (currentSegBytes_ >= maxSeg) {
        openNewSegment();
        evictIfNeeded();
    }
}

void RedactingLogger::evictIfNeeded() {
    uint64_t maxDisk;
    {
        std::lock_guard<std::mutex> lk(configMtx_);
        maxDisk = config_.maxDiskBytes;
    }

    // Evict oldest segments until we are within budget.
    // Always keep the current segment even if it alone exceeds the limit.
    while (segments_.size() > 1 && computeDiskUsage() > maxDisk) {
        const auto& oldest = segments_.front();
        try {
            std::filesystem::remove(oldest);
        } catch (...) {}
        segments_.erase(segments_.begin());
    }
}

uint64_t RedactingLogger::computeDiskUsage() const {
    uint64_t total = 0;
    for (const auto& p : segments_) {
        std::error_code ec;
        auto sz = std::filesystem::file_size(p, ec);
        if (!ec) total += sz;
    }
    return total;
}

void RedactingLogger::writeToSegment(const std::string& line) {
    if (currentFd_ < 0) {
        // Try to recover (directory may have been created late).
        openNewSegment();
        if (currentFd_ < 0) return;
    }

    rotateIfNeeded();

    // Write line + newline.  POSIX write is atomic for sizes <= PIPE_BUF on
    // most file systems, but we're only writing from one thread so no partial
    // write concern.
    std::string out = line + '\n';
    ssize_t written = ::write(currentFd_, out.data(), out.size());
    if (written > 0) {
        currentSegBytes_ += static_cast<uint64_t>(written);
    }
}

// ─── Diagnostics ─────────────────────────────────────────────────────────────

uint64_t RedactingLogger::bytesOnDisk() const {
    // Safe to call from any thread — only reads filesystem metadata.
    std::filesystem::path dir;
    {
        std::lock_guard<std::mutex> lk(configMtx_);
        dir = config_.logDirectory;
    }
    if (dir.empty()) return 0;
    uint64_t total = 0;
    std::error_code ec;
    for (const auto& ent : std::filesystem::directory_iterator(dir, ec)) {
        if (ent.path().extension() == ".jsonl") {
            auto sz = std::filesystem::file_size(ent.path(), ec);
            if (!ec) total += sz;
        }
    }
    return total;
}

} // namespace jarvis

// ─── C ABI implementation ─────────────────────────────────────────────────────

using jarvis::RedactingLogger;
using jarvis::LogLevel;
using jarvis::LogField;

void JARVISLog_configure(const char* config_json) {
    auto kv = parseConfigJSON(config_json);

    RedactingLogger::Config cfg;
    {
        // Seed from current config so partial updates are safe.
        // We access the singleton's config by reading back current values
        // through a temporary emit that we discard — actually, just apply
        // defaults here; callers who want to do partial updates should call
        // configure() multiple times or use the C++ API directly.
        cfg.logDirectory    = defaultLogDir();
        cfg.maxDiskBytes    = 100ULL * 1024 * 1024;
        cfg.maxSegmentBytes =  10ULL * 1024 * 1024;
        cfg.queueCapacity   = 65'536;
        cfg.minLevel        = LogLevel::TRACE;
    }

    auto it = kv.find("log_dir");
    if (it != kv.end() && !it->second.empty()) {
        cfg.logDirectory = it->second;
    }
    it = kv.find("max_disk_bytes");
    if (it != kv.end()) {
        cfg.maxDiskBytes = static_cast<uint64_t>(std::stoull(it->second));
    }
    it = kv.find("max_seg_bytes");
    if (it != kv.end()) {
        cfg.maxSegmentBytes = static_cast<uint64_t>(std::stoull(it->second));
    }
    it = kv.find("min_level");
    if (it != kv.end()) {
        const auto& lvl = it->second;
        if      (lvl == "TRACE") cfg.minLevel = LogLevel::TRACE;
        else if (lvl == "DEBUG") cfg.minLevel = LogLevel::DEBUG;
        else if (lvl == "INFO")  cfg.minLevel = LogLevel::INFO;
        else if (lvl == "WARN")  cfg.minLevel = LogLevel::WARN;
        else if (lvl == "ERROR") cfg.minLevel = LogLevel::ERROR;
        else if (lvl == "FATAL") cfg.minLevel = LogLevel::FATAL;
    }

    RedactingLogger::instance().configure(cfg);
}

void JARVISLog_emit(int level, const char* subsystem, const char* event,
                     const char* fields_json) {
    auto lvl = static_cast<LogLevel>(
        (level >= 0 && level <= 5) ? level : static_cast<int>(LogLevel::INFO));

    std::vector<LogField> fields;
    for (const auto& pf : parseFieldsJSON(fields_json)) {
        fields.push_back({pf.name, pf.value, pf.rawJSON});
    }

    RedactingLogger::instance().emit(
        lvl,
        subsystem ? subsystem : "",
        event     ? event     : "",
        std::move(fields));
}

void JARVISLog_set_subsystem_optin(const char* subsystem, int enabled) {
    if (subsystem) {
        RedactingLogger::instance().setSubsystemOptIn(subsystem, enabled != 0);
    }
}

void JARVISLog_shutdown(void) {
    RedactingLogger::instance().shutdown();
}

uint64_t JARVISLog_bytes_on_disk(void) {
    return RedactingLogger::instance().bytesOnDisk();
}
