// ─────────────────────────────────────────────────────────────────────────────
// audit_log.cpp — TamperEvidentAuditLog implementation
//
// This log records JARVIS's operational integrity. It cannot be silently
// disabled. Tampering with the on-disk file breaks the HMAC chain detectably.
// ─────────────────────────────────────────────────────────────────────────────

#include "audit_log.h"
#include "memory_security.h"

#include <algorithm>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <format>
#include <iomanip>
#include <map>
#include <memory>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <system_error>
#include <unordered_map>
#include <utility>

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#ifdef __APPLE__
#  include <CommonCrypto/CommonHMAC.h>
#else
#  include <openssl/hmac.h>
#  include <openssl/sha.h>
#endif

// ── Minimal JSON helpers (no external dep) ────────────────────────────────────
// We only need to produce and consume a well-defined subset of JSON:
// flat objects with string and hex-array fields. This avoids pulling in
// a JSON library.

namespace {

// ── Hex encoding / decoding ───────────────────────────────────────────────────

static const char* kHexChars = "0123456789abcdef";

std::string toHex(const std::array<uint8_t, 32>& bytes) {
    std::string s;
    s.reserve(64);
    for (uint8_t b : bytes) {
        s += kHexChars[(b >> 4) & 0xf];
        s += kHexChars[ b       & 0xf];
    }
    return s;
}

bool fromHex(const std::string& hex, std::array<uint8_t, 32>& out) {
    if (hex.size() != 64) return false;
    for (int i = 0; i < 32; ++i) {
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int hi = nibble(hex[2*i]);
        int lo = nibble(hex[2*i+1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

// ── JSON string escaping ──────────────────────────────────────────────────────

std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

// ── Minimal JSON parser for AuditEvent ───────────────────────────────────────
// Parses a flat JSON object, extracting known keys. Not a general parser.

struct JsonObj {
    std::unordered_map<std::string, std::string> fields;

    // Returns empty string for missing keys.
    const std::string& get(const std::string& key) const {
        static const std::string empty;
        auto it = fields.find(key);
        return (it != fields.end()) ? it->second : empty;
    }
};

// Scan past whitespace
static size_t skipWs(const std::string& s, size_t i) {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
        ++i;
    return i;
}

int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::optional<uint16_t> parseUnicodeUnit(const std::string& s, size_t& pos) {
    if (pos + 4 > s.size()) return std::nullopt;
    uint16_t value = 0;
    for (int i = 0; i < 4; ++i) {
        const int nibble = hexNibble(s[pos++]);
        if (nibble < 0) return std::nullopt;
        value = static_cast<uint16_t>((value << 4) | nibble);
    }
    return value;
}

bool appendUtf8(std::string& out, uint32_t cp) {
    if (cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return false;
    if (cp <= 0x7f) {
        out.push_back(static_cast<char>(cp));
    } else if (cp <= 0x7ff) {
        out.push_back(static_cast<char>(0xc0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        out.push_back(static_cast<char>(0xe0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    } else {
        out.push_back(static_cast<char>(0xf0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3f)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3f)));
    }
    return true;
}

bool parseUnicodeEscape(const std::string& s, size_t& pos, std::string& out) {
    auto first = parseUnicodeUnit(s, pos);
    if (!first) return false;
    uint32_t cp = *first;
    if (cp >= 0xd800 && cp <= 0xdbff) {
        if (pos + 6 > s.size() || s[pos] != '\\' || s[pos + 1] != 'u') return false;
        pos += 2;
        auto second = parseUnicodeUnit(s, pos);
        if (!second || *second < 0xdc00 || *second > 0xdfff) return false;
        cp = 0x10000 + (((cp - 0xd800) << 10) | (*second - 0xdc00));
    } else if (cp >= 0xdc00 && cp <= 0xdfff) {
        return false;
    }
    if (cp < 0x20 || cp == 0x7f) return false;
    return appendUtf8(out, cp);
}

// Parse a JSON string starting at pos (which must point to '"'). Returns
// the unescaped string and advances pos past the closing '"'.
static std::optional<std::string> parseString(const std::string& s, size_t& pos) {
    if (pos >= s.size() || s[pos] != '"') return std::nullopt;
    ++pos; // skip opening "
    std::string out;
    while (pos < s.size()) {
        char c = s[pos++];
        if (c == '"') return out;
        if (c == '\\') {
            if (pos >= s.size()) return std::nullopt;
            char e = s[pos++];
            switch (e) {
                case '"':  out += '"';  break;
                case '\\': out += '\\'; break;
                case '/':  out += '/';  break;
                case 'b':  out += '\b'; break;
                case 'f':  out += '\f'; break;
                case 'n':  out += '\n'; break;
                case 'r':  out += '\r'; break;
                case 't':  out += '\t'; break;
                case 'u':
                    if (!parseUnicodeEscape(s, pos, out)) return std::nullopt;
                    break;
                default:
                    return std::nullopt;
            }
        } else {
            if (static_cast<unsigned char>(c) < 0x20) return std::nullopt;
            out += c;
        }
    }
    return std::nullopt;
}

// Parse a flat JSON object. Only string values and integer values supported.
static std::optional<JsonObj> parseJsonObj(const std::string& s) {
    JsonObj obj;
    size_t i = skipWs(s, 0);
    if (i >= s.size() || s[i] != '{') return std::nullopt;
    ++i;
    i = skipWs(s, i);
    if (i < s.size() && s[i] == '}') {
        ++i;
        i = skipWs(s, i);
        return i == s.size() ? std::optional<JsonObj>{obj} : std::nullopt;
    }

    while (i < s.size()) {
        i = skipWs(s, i);
        // key
        auto key = parseString(s, i);
        if (!key) return std::nullopt;
        i = skipWs(s, i);
        if (i >= s.size() || s[i] != ':') return std::nullopt;
        ++i;
        i = skipWs(s, i);
        // value: string or number
        if (i >= s.size()) return std::nullopt;
        std::string value;
        if (s[i] == '"') {
            auto v = parseString(s, i);
            if (!v) return std::nullopt;
            value = *v;
        } else {
            // consume until , or } or whitespace
            size_t start = i;
            while (i < s.size() && s[i] != ',' && s[i] != '}' && s[i] != ' ' && s[i] != '\n')
                ++i;
            value = s.substr(start, i - start);
        }
        if (obj.fields.find(*key) != obj.fields.end()) return std::nullopt;
        obj.fields[*key] = value;
        i = skipWs(s, i);
        if (i >= s.size()) break;
        if (s[i] == '}') { ++i; break; }
        if (s[i] == ',') { ++i; continue; }
        return std::nullopt;
    }
    i = skipWs(s, i);
    if (i != s.size()) return std::nullopt;
    return obj;
}

// ── Little-endian byte helpers ────────────────────────────────────────────────

void writeLE64(std::vector<uint8_t>& buf, uint64_t v) {
    for (int i = 0; i < 8; ++i)
        buf.push_back(static_cast<uint8_t>((v >> (8*i)) & 0xff));
}

void writeLE32(std::vector<uint8_t>& buf, uint32_t v) {
    for (int i = 0; i < 4; ++i)
        buf.push_back(static_cast<uint8_t>((v >> (8*i)) & 0xff));
}

void writeLengthPrefixedStr(std::vector<uint8_t>& buf, const std::string& s) {
    writeLE32(buf, static_cast<uint32_t>(s.size()));
    for (char c : s) buf.push_back(static_cast<uint8_t>(c));
}

// ── Tilde expansion ───────────────────────────────────────────────────────────

std::filesystem::path expandTilde(const std::string& p) {
    if (!p.empty() && p[0] == '~') {
        const char* home = std::getenv("HOME");
        if (!home || !*home) throw std::runtime_error("HOME is not set; cannot expand audit path");
        return std::filesystem::path(home) / p.substr(p.size() > 1 && p[1] == '/' ? 2 : 1);
    }
    return std::filesystem::path(p);
}

// ── Current time in nanoseconds since epoch ───────────────────────────────────

int64_t nowNs() {
    using namespace std::chrono;
    return static_cast<int64_t>(
        duration_cast<nanoseconds>(system_clock::now().time_since_epoch()).count()
    );
}

// ── Timestamp string for rotation filenames ───────────────────────────────────

std::string timestampStr() {
    using namespace std::chrono;
    auto now = system_clock::now();
    auto t   = system_clock::to_time_t(now);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y%m%dT%H%M%S", std::gmtime(&t));
    return buf;
}

// ── HMAC-SHA256 ───────────────────────────────────────────────────────────────

std::array<uint8_t, 32> hmacSha256(
    const std::array<uint8_t, 32>& key,
    const uint8_t* data, size_t len
) {
    std::array<uint8_t, 32> out{};
#ifdef __APPLE__
    CCHmac(kCCHmacAlgSHA256,
           key.data(), key.size(),
           data, len,
           out.data());
#else
    unsigned int outLen = 32;
    HMAC(EVP_sha256(),
         key.data(), static_cast<int>(key.size()),
         data, len,
         out.data(), &outLen);
#endif
    return out;
}

} // anonymous namespace

// ─────────────────────────────────────────────────────────────────────────────
// TamperEvidentAuditLog implementation
// ─────────────────────────────────────────────────────────────────────────────

namespace jarvis::audit {

namespace {
std::mutex g_bridge_key_mutex;
std::optional<std::array<uint8_t, 32>> g_bridge_key;
}

void installBridgeAuditKey(const uint8_t* key, size_t key_len) {
    if (key == nullptr || key_len != 32) {
        throw std::invalid_argument("bridge audit HMAC key must be exactly 32 bytes");
    }
    std::array<uint8_t, 32> installed{};
    std::copy(key, key + key_len, installed.begin());
    jarvis::security::memory::ensure_sodium_initialized();
    std::lock_guard<std::mutex> lock(g_bridge_key_mutex);
    if (g_bridge_key) {
        jarvis::security::memory::secure_zero(g_bridge_key->data(), g_bridge_key->size());
        jarvis::security::memory::unlock_no_swap(g_bridge_key->data(), g_bridge_key->size());
    }
    g_bridge_key = installed;
    jarvis::security::memory::lock_no_swap(g_bridge_key->data(), g_bridge_key->size());
    jarvis::security::memory::secure_zero(installed.data(), installed.size());
}

void clearBridgeAuditKeyForTesting() {
    std::lock_guard<std::mutex> lock(g_bridge_key_mutex);
    if (g_bridge_key) {
        jarvis::security::memory::secure_zero(g_bridge_key->data(), g_bridge_key->size());
        jarvis::security::memory::unlock_no_swap(g_bridge_key->data(), g_bridge_key->size());
        g_bridge_key.reset();
    }
}

bool bridgeAuditKeyAvailable() {
    std::lock_guard<std::mutex> lock(g_bridge_key_mutex);
    return g_bridge_key.has_value();
}

std::array<uint8_t, 32> requireBridgeAuditKey() {
    std::lock_guard<std::mutex> lock(g_bridge_key_mutex);
    if (!g_bridge_key) {
        throw AuditKeyMissingError("audit HMAC key missing: Secure Enclave bridge key was not installed; file-key loading is refused");
    }
    return *g_bridge_key;
}

// ── Static helpers ────────────────────────────────────────────────────────────

// Organ allowlist: every organ that may produce audit records.
// append() rejects records whose organ is not listed here.
// Organ names must match [a-zA-Z0-9_.-].
const std::unordered_set<std::string> TamperEvidentAuditLog::kAllowedOrgans = {
    "audit",                // integrity/audit internal events (LOG_OPENED, LOG_ROTATED, etc.)
    "ceremony",             // JARVISCeremony / SOUL_ANCHOR_ISSUED
    "soul_anchor",          // soul anchor events
    "cusum",                // monitoring/cusum
    "continuity",           // identity/continuity
    "character_values",     // identity/character_values
    "operator_attestation", // identity/operator_attestation
    "coercion_refusal",     // identity/coercion_refusal
    "self_health",          // identity/self_health
    "resilience",           // resilience/degradation
    "distress",             // identity/distress
    "beliefstore",          // holograph/beliefstore
    "http",                 // http organ
    "wire",                 // wire protocol organ
    "se",                   // Secure Enclave bridge
    "voice",                // voice organ
    "egress",               // security/egress
};

std::array<uint8_t, 32> TamperEvidentAuditLog::computeHmac(
    const std::array<uint8_t, 32>& key,
    const AuditEvent& e
) {
    // Canonical byte representation of all fields EXCEPT own_hash.
    std::vector<uint8_t> buf;
    buf.reserve(256);

    writeLE64(buf, e.sequence_id);
    writeLE64(buf, static_cast<uint64_t>(static_cast<int64_t>(e.timestamp_ns)));
    writeLengthPrefixedStr(buf, e.event_kind);
    writeLengthPrefixedStr(buf, e.actor);
    writeLengthPrefixedStr(buf, e.subject);
    writeLengthPrefixedStr(buf, e.outcome);
    writeLengthPrefixedStr(buf, e.reason);
    writeLengthPrefixedStr(buf, e.redacted_metadata);
    // Schema v2+: key_version included between redacted_metadata and prev_hash.
    // Schema v1 (legacy on-disk records): key_version omitted for back-compat.
    if (e.schema_version >= 2) {
        writeLE32(buf, e.key_version);
    }
    for (uint8_t b : e.prev_hash) buf.push_back(b);

    auto out = hmacSha256(key, buf.data(), buf.size());
    jarvis::security::memory::secure_zero(buf.data(), buf.size());
    return out;
}

std::string TamperEvidentAuditLog::serialiseEvent(const AuditEvent& e) {
    std::ostringstream ss;
    ss << '{'
       << "\"seq\":"      << e.sequence_id
       << ",\"ts_ns\":"   << e.timestamp_ns
       << ",\"kind\":\""  << jsonEscape(e.event_kind) << '"'
       << ",\"actor\":\"" << jsonEscape(e.actor)      << '"'
       << ",\"subj\":\""  << jsonEscape(e.subject)    << '"'
       << ",\"out\":\""   << jsonEscape(e.outcome)    << '"'
       << ",\"rsn\":\""   << jsonEscape(e.reason)     << '"'
       << ",\"meta\":\""  << jsonEscape(e.redacted_metadata) << '"'
       << ",\"sv\":"      << e.schema_version
       << ",\"kv\":"      << e.key_version
       << ",\"organ\":\"" << jsonEscape(e.organ)      << '"'
       << ",\"ph\":\""    << toHex(e.prev_hash) << '"'
       << ",\"oh\":\""    << toHex(e.own_hash)  << '"'
       << '}';
    return ss.str();
}

std::optional<AuditEvent> TamperEvidentAuditLog::deserialiseEvent(
    const std::string& json
) {
    auto rejectMalformed = [](const char* reason) {
        std::fputs(reason, stderr);
        std::fputc('\n', stderr);
        return std::optional<AuditEvent>{std::nullopt};
    };
    if (json.size() + sizeof(uint32_t) > TamperEvidentAuditLog::kAtomicRecordBytes) {
        return rejectMalformed("AuditRecordTooLarge");
    }
    auto obj = parseJsonObj(json);
    if (!obj) return rejectMalformed("AuditEventMalformed: strict JSON parse failed");

    AuditEvent e;
    try {
        const std::string& seq = obj->get("seq");
        const std::string& ts  = obj->get("ts_ns");
        if (seq.empty() || ts.empty()) return std::nullopt;
        e.sequence_id  = std::stoull(seq);
        e.timestamp_ns = std::stoll(ts);
    } catch (...) {
        return std::nullopt;
    }

    e.event_kind        = obj->get("kind");
    e.actor             = obj->get("actor");
    e.subject           = obj->get("subj");
    e.outcome           = obj->get("out");
    e.reason            = obj->get("rsn");
    e.redacted_metadata = obj->get("meta");

    // Schema version: absent in old records → defaults to 1 (legacy format).
    {
        const std::string& sv = obj->get("sv");
        e.schema_version = sv.empty() ? 1u : static_cast<uint32_t>(std::stoull(sv));
        const std::string& kv = obj->get("kv");
        e.key_version = kv.empty() ? 0u : static_cast<uint32_t>(std::stoull(kv));
        e.organ = obj->get("organ");
    }

    if (!fromHex(obj->get("ph"), e.prev_hash)) return std::nullopt;
    if (!fromHex(obj->get("oh"), e.own_hash))  return std::nullopt;

    return e;
}

// ── Constructor / Destructor ──────────────────────────────────────────────────


TamperEvidentAuditLog::TamperEvidentAuditLog(
    std::string path,
    const uint8_t* key,
    size_t key_len
)
    : log_path_(expandTilde(path))
{
    if (key == nullptr || key_len != key_.size()) {
        throw AuditKeyMissingError("audit HMAC bridge key must be exactly 32 bytes");
    }
    ensureDir(log_path_.parent_path());

    jarvis::security::memory::ensure_sodium_initialized();
    std::copy(key, key + key_len, key_.begin());
    jarvis::security::memory::lock_no_swap(key_.data(), key_.size());
    openLog();
}

TamperEvidentAuditLog::TamperEvidentAuditLog(std::string path)
    : log_path_(expandTilde(path))
{
    ensureDir(log_path_.parent_path());

    jarvis::security::memory::ensure_sodium_initialized();
    key_ = requireBridgeAuditKey();
    jarvis::security::memory::lock_no_swap(key_.data(), key_.size());
    openLog();
}

TamperEvidentAuditLog::~TamperEvidentAuditLog() {
    jarvis::security::memory::secure_zero(key_.data(), key_.size());
    jarvis::security::memory::unlock_no_swap(key_.data(), key_.size());
    if (fd_ >= 0) {
        ::fsync(fd_);
        ::close(fd_);
        fd_ = -1;
    }
}

// ── Private helpers ───────────────────────────────────────────────────────────

void TamperEvidentAuditLog::ensureDir(const std::filesystem::path& p) {
    if (p.empty()) return;
    std::error_code ec;
    std::filesystem::create_directories(p, ec);
    // mode 0700 for the jarvis data directory
    if (std::filesystem::exists(p))
        ::chmod(p.c_str(), 0700);
}

void TamperEvidentAuditLog::openLog() {
    // Open or create the log file. We use O_RDWR so we can read existing
    // content on startup to pick up the chain state.
    fd_ = ::open(log_path_.c_str(), O_RDWR | O_CREAT | O_APPEND, 0600);
    if (fd_ < 0)
        throw std::system_error(errno, std::generic_category(),
                                "open audit log: " + log_path_.string());

    // Determine current file size for rotation tracking.
    struct stat st{};
    if (::fstat(fd_, &st) == 0)
        file_bytes_ = static_cast<uint64_t>(st.st_size);

    // Walk existing entries: verify the full HMAC chain and build next_seq_ /
    // last_hash_.  Any truncation, mutation, framing error, or HMAC mismatch
    // throws AuditChainTruncatedError — fail closed, §2.
    if (file_bytes_ > 0) {
        off_t pos = 0;
        std::array<uint8_t, 32> expected_prev{};
        expected_prev.fill(0);
        uint64_t expected_seq = 0;
        bool first = true;

        while (pos < static_cast<off_t>(file_bytes_)) {
            uint8_t lbuf[4];
            ssize_t r = ::pread(fd_, lbuf, 4, pos);
            if (r != 4) {
                // Partial tail record — stop walk; tail will be excluded from
                // the chain.  Only throw if we read SOME bytes (corrupt framing).
                if (r > 0) {
                    throw AuditChainTruncatedError(
                        "audit log partial record framing at offset "
                        + std::to_string(pos) + ": " + log_path_.string());
                }
                break;
            }
            uint32_t len = uint32_t(lbuf[0]) | (uint32_t(lbuf[1]) << 8)
                         | (uint32_t(lbuf[2]) << 16) | (uint32_t(lbuf[3]) << 24);
            if (len == 0 || len + 4 > kAtomicRecordBytes) {
                throw AuditChainTruncatedError(
                    "audit log record framing corrupt at offset "
                    + std::to_string(pos) + ": " + log_path_.string());
            }
            std::string payload(len, '\0');
            ssize_t r2 = ::pread(fd_, payload.data(), len, pos + 4);
            if (r2 != static_cast<ssize_t>(len)) {
                throw AuditChainTruncatedError(
                    "audit log record body truncated at offset "
                    + std::to_string(pos) + ": " + log_path_.string());
            }
            auto ev = deserialiseEvent(payload);
            if (!ev) {
                throw AuditChainTruncatedError(
                    "audit log record malformed at offset "
                    + std::to_string(pos) + ": " + log_path_.string());
            }
            if (!first) {
                if (ev->sequence_id != expected_seq) {
                    throw AuditChainTruncatedError(
                        "audit log sequence gap: expected "
                        + std::to_string(expected_seq) + " got "
                        + std::to_string(ev->sequence_id) + ": " + log_path_.string());
                }
                if (ev->prev_hash != expected_prev) {
                    throw AuditChainTruncatedError(
                        "audit log chain link broken at sequence "
                        + std::to_string(ev->sequence_id) + ": " + log_path_.string());
                }
            }
            auto computed = computeHmac(key_, *ev);
            if (computed != ev->own_hash) {
                throw AuditChainTruncatedError(
                    "audit log HMAC mismatch at sequence "
                    + std::to_string(ev->sequence_id) + ": " + log_path_.string());
            }
            expected_prev = ev->own_hash;
            expected_seq  = ev->sequence_id + 1;
            next_seq_  = ev->sequence_id + 1;
            last_hash_ = ev->own_hash;
            first = false;
            pos += 4 + len;
        }
    }

    // Seek to end for appending.
    ::lseek(fd_, 0, SEEK_END);

    // Emit a LOG_OPENED event (on fresh file this establishes the genesis entry).
    AuditEvent open_ev;
    open_ev.event_kind = EventKind::LOG_OPENED;
    open_ev.actor      = Actor::SELF;
    open_ev.subject    = log_path_.filename().string();
    open_ev.outcome    = Outcome::ALLOWED;
    open_ev.reason     = "startup";
    open_ev.organ      = "audit";
    append(open_ev);
}

void TamperEvidentAuditLog::reloadStateFromDiskLocked() {
    struct stat st{};
    const uint64_t current_size = (::fstat(fd_, &st) == 0) ? static_cast<uint64_t>(st.st_size) : 0;

    // Fail closed: if the file shrank, it was truncated — §2 no silent fallback.
    if (file_bytes_ > current_size) {
        throw AuditChainTruncatedError(
            "audit log truncated: file shrank from "
            + std::to_string(file_bytes_) + " to "
            + std::to_string(current_size) + ": " + log_path_.string());
    }

    // Walk and verify any new records appended since our last known position.
    // We hold the exclusive flock, so no concurrent writer is active; any
    // partial read is a real error, not a race.
    off_t pos = static_cast<off_t>(file_bytes_);
    std::array<uint8_t, 32> expected_prev = last_hash_;

    while (pos < static_cast<off_t>(current_size)) {
        uint8_t lbuf[4];
        ssize_t r = ::pread(fd_, lbuf, 4, pos);
        if (r != 4) {
            throw AuditChainTruncatedError(
                "audit log partial record framing at offset "
                + std::to_string(pos) + " (expected 4, got "
                + std::to_string(r) + "): " + log_path_.string());
        }
        uint32_t len = uint32_t(lbuf[0]) | (uint32_t(lbuf[1]) << 8)
                     | (uint32_t(lbuf[2]) << 16) | (uint32_t(lbuf[3]) << 24);
        if (len == 0 || len + 4 > kAtomicRecordBytes) {
            throw AuditChainTruncatedError(
                "audit log record framing corrupt at offset "
                + std::to_string(pos) + ": " + log_path_.string());
        }
        std::string payload(len, '\0');
        ssize_t r2 = ::pread(fd_, payload.data(), len, pos + 4);
        if (r2 != static_cast<ssize_t>(len)) {
            throw AuditChainTruncatedError(
                "audit log record body truncated at offset "
                + std::to_string(pos) + ": " + log_path_.string());
        }
        auto ev = deserialiseEvent(payload);
        if (!ev) {
            throw AuditChainTruncatedError(
                "audit log record malformed at offset "
                + std::to_string(pos) + ": " + log_path_.string());
        }
        if (ev->sequence_id != next_seq_) {
            throw AuditChainTruncatedError(
                "audit log sequence gap: expected "
                + std::to_string(next_seq_) + " got "
                + std::to_string(ev->sequence_id) + ": " + log_path_.string());
        }
        if (ev->prev_hash != expected_prev) {
            throw AuditChainTruncatedError(
                "audit log chain link broken at sequence "
                + std::to_string(ev->sequence_id) + ": " + log_path_.string());
        }
        auto computed = computeHmac(key_, *ev);
        if (computed != ev->own_hash) {
            throw AuditChainTruncatedError(
                "audit log HMAC mismatch at sequence "
                + std::to_string(ev->sequence_id) + ": " + log_path_.string());
        }
        expected_prev = ev->own_hash;
        next_seq_     = ev->sequence_id + 1;
        last_hash_    = ev->own_hash;
        pos += 4 + len;
        file_bytes_ = static_cast<uint64_t>(pos);
    }
    ::lseek(fd_, 0, SEEK_END);
}

void TamperEvidentAuditLog::writeRecordLocked(const std::string& payload) {
    const uint32_t len = static_cast<uint32_t>(payload.size());
    if (sizeof(uint32_t) + len > kAtomicRecordBytes) {
        throw AuditRecordTooLarge("audit record exceeds PIPE_BUF=512 atomic append cap");
    }
    uint8_t lbuf[4] = {
        uint8_t(len & 0xff),
        uint8_t((len >> 8)  & 0xff),
        uint8_t((len >> 16) & 0xff),
        uint8_t((len >> 24) & 0xff)
    };

    struct iovec iov_storage[2];
    iov_storage[0].iov_base = lbuf;
    iov_storage[0].iov_len = sizeof(lbuf);
    iov_storage[1].iov_base = const_cast<char*>(payload.data());
    iov_storage[1].iov_len = len;
    struct iovec* iov = iov_storage;
    int iovcnt = 2;

    while (iovcnt > 0) {
        ssize_t w = ::writev(fd_, iov, iovcnt);
        if (w < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            throw std::system_error(errno, std::generic_category(), "atomic write audit record");
        }
        if (w == 0) throw std::system_error(EIO, std::generic_category(), "atomic write audit record");
        ssize_t remaining = w;
        while (iovcnt > 0 && remaining >= static_cast<ssize_t>(iov[0].iov_len)) {
            remaining -= static_cast<ssize_t>(iov[0].iov_len);
            ++iov;
            --iovcnt;
        }
        if (iovcnt > 0 && remaining > 0) {
            iov[0].iov_base = static_cast<char*>(iov[0].iov_base) + remaining;
            iov[0].iov_len -= static_cast<std::size_t>(remaining);
        }
    }
    if (::fsync(fd_) != 0) {
        throw std::system_error(errno, std::generic_category(), "fsync audit record");
    }
    file_bytes_ += sizeof(lbuf) + len;
}

void TamperEvidentAuditLog::rotateLog() {
    // Flush and close current file.
    ::fsync(fd_);
    ::close(fd_);
    fd_ = -1;

    // Rename current log to audit.log.<timestamp>
    std::string archived = log_path_.string() + "." + timestampStr();
    std::filesystem::rename(log_path_, archived);

    // Open a new log file. The chain continues: last_hash_ from the previous
    // file becomes prev_hash of the first entry in the new file.
    file_bytes_ = 0;
    fd_ = ::open(log_path_.c_str(), O_RDWR | O_CREAT | O_TRUNC | O_APPEND, 0600);
    if (fd_ < 0)
        throw std::system_error(errno, std::generic_category(),
                                "open new audit log after rotation: "
                                + log_path_.string());

    // Emit a LOG_ROTATED marker entry. Its prev_hash is last_hash_ (final hash
    // from the archived file), maintaining chain continuity across rotations.
    AuditEvent rot_ev;
    rot_ev.event_kind         = EventKind::LOG_ROTATED;
    rot_ev.actor              = Actor::SELF;
    rot_ev.subject            = archived;
    rot_ev.outcome            = Outcome::ALLOWED;
    rot_ev.reason             = "size_rotation";
    rot_ev.organ              = "audit";
    rot_ev.schema_version     = kCurrentSchemaVersion;
    // prev_hash is set by append()
    // Don't call append() recursively; serialise inline without lock re-entry.
    rot_ev.sequence_id  = next_seq_++;
    rot_ev.timestamp_ns = nowNs();
    rot_ev.prev_hash    = last_hash_;
    rot_ev.own_hash     = computeHmac(key_, rot_ev);
    last_hash_          = rot_ev.own_hash;
    writeRecordLocked(serialiseEvent(rot_ev));
}

// ── Public API ────────────────────────────────────────────────────────────────

void TamperEvidentAuditLog::append(AuditEvent e) {
    // ── Organ allowlist + injection guard (before lock) ───────────────────────
    // Reject before acquiring mutex so bad callers get fast feedback.
    {
        static const std::regex kOrganCharSet("^[a-zA-Z0-9_.\\-]+$");
        if (!std::regex_match(e.organ, kOrganCharSet)) {
            throw AuditIllegalOrganError(
                "audit organ contains illegal chars or is empty: \"" + e.organ + "\"");
        }
        if (kAllowedOrgans.find(e.organ) == kAllowedOrgans.end()) {
            throw AuditIllegalOrganError(
                "audit organ not in allowlist: \"" + e.organ + "\"");
        }
    }
    // Always stamp the current schema version; callers set key_version.
    e.schema_version = kCurrentSchemaVersion;

    std::lock_guard<std::mutex> lock(mutex_);

    struct FlockGuard {
        int fd;
        explicit FlockGuard(int value) : fd(value) {
            while (::flock(fd, LOCK_EX) != 0) {
                if (errno != EINTR) throw std::system_error(errno, std::generic_category(), "lock audit log");
            }
        }
        ~FlockGuard() { (void)::flock(fd, LOCK_UN); }
    } flock_guard(fd_);

    reloadStateFromDiskLocked();

    // Rotate BEFORE writing if we're at or over the limit.
    if (file_bytes_ >= kRotationBytes)
        rotateLog();

    e.sequence_id = next_seq_;
    if (e.timestamp_ns == 0)
        e.timestamp_ns = nowNs();
    e.prev_hash = last_hash_;
    e.own_hash = computeHmac(key_, e);

    std::string payload = serialiseEvent(e);
    writeRecordLocked(payload);

    ++next_seq_;
    last_hash_ = e.own_hash;
}

bool TamperEvidentAuditLog::verify_chain() const {
    std::lock_guard<std::mutex> lock(mutex_);

    int rfd = ::open(log_path_.c_str(), O_RDONLY);
    if (rfd < 0) return false;

    std::array<uint8_t, 32> expected_prev{};
    uint64_t expected_seq = 0;
    bool first = true;

    off_t pos = 0;
    while (true) {
        uint8_t lbuf[4];
        ssize_t r = ::pread(rfd, lbuf, 4, pos);
        if (r == 0) break; // EOF
        if (r != 4) { ::close(rfd); return false; }

        uint32_t len = uint32_t(lbuf[0]) | (uint32_t(lbuf[1]) << 8)
                     | (uint32_t(lbuf[2]) << 16) | (uint32_t(lbuf[3]) << 24);
        if (len == 0 || len + 4 > kAtomicRecordBytes) { ::close(rfd); return false; }

        std::string payload(len, '\0');
        ssize_t r2 = ::pread(rfd, payload.data(), len, pos + 4);
        if (r2 != static_cast<ssize_t>(len)) { ::close(rfd); return false; }

        auto ev = deserialiseEvent(payload);
        if (!ev) { ::close(rfd); return false; }

        // Verify sequence continuity.
        if (!first && ev->sequence_id != expected_seq) { ::close(rfd); return false; }

        // Verify prev_hash linkage.
        if (!first && ev->prev_hash != expected_prev) { ::close(rfd); return false; }

        // Verify own_hash.
        auto computed = computeHmac(key_, *ev);
        if (computed != ev->own_hash) { ::close(rfd); return false; }

        expected_prev = ev->own_hash;
        expected_seq  = ev->sequence_id + 1;
        first = false;
        pos += 4 + len;
    }

    ::close(rfd);
    return !first; // false if file was completely empty
}

uint64_t TamperEvidentAuditLog::next_seq() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return next_seq_;
}

AuditLogIterator TamperEvidentAuditLog::begin() const {
    return AuditLogIterator(log_path_);
}

AuditLogIterator TamperEvidentAuditLog::end() const {
    return AuditLogIterator{};
}

// ── AuditLogIterator ──────────────────────────────────────────────────────────

AuditLogIterator::AuditLogIterator(std::filesystem::path path)
    : done_(false)
{
    fd_ = ::open(path.c_str(), O_RDONLY);
    if (fd_ < 0) { done_ = true; return; }
    readNext();
}

void AuditLogIterator::readNext() {
    uint8_t lbuf[4];
    ssize_t r = ::read(fd_, lbuf, 4);
    if (r != 4) {
        done_ = true;
        if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
        return;
    }
    uint32_t len = uint32_t(lbuf[0]) | (uint32_t(lbuf[1]) << 8)
                 | (uint32_t(lbuf[2]) << 16) | (uint32_t(lbuf[3]) << 24);
    if (len == 0 || len + 4 > TamperEvidentAuditLog::kAtomicRecordBytes) {
        done_ = true;
        ::close(fd_); fd_ = -1;
        return;
    }
    std::string payload(len, '\0');
    ssize_t r2 = ::read(fd_, payload.data(), len);
    if (r2 != static_cast<ssize_t>(len)) {
        done_ = true;
        ::close(fd_); fd_ = -1;
        return;
    }
    auto ev = TamperEvidentAuditLog::deserialiseEvent(payload);
    if (!ev) {
        done_ = true;
        ::close(fd_); fd_ = -1;
        return;
    }
    current_ = *ev;
}

AuditLogIterator& AuditLogIterator::operator++() {
    readNext();
    return *this;
}

TamperEvidentAuditLog& processAuditLog(std::string path) {
    static std::mutex registry_mutex;
    static std::map<std::string, std::unique_ptr<TamperEvidentAuditLog>> registry;

    std::lock_guard<std::mutex> lock(registry_mutex);
    auto it = registry.find(path);
    if (it == registry.end()) {
        it = registry.emplace(path, std::make_unique<TamperEvidentAuditLog>(path)).first;
    }
    return *it->second;
}

} // namespace jarvis::audit
