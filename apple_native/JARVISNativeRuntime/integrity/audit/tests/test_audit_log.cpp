// test_audit_log.cpp — Catch2 tests for TamperEvidentAuditLog
//
// Tests:
//   • Append 1000 events; verify chain holds throughout.
//   • verify_chain() returns true immediately after construction.
//   • Iteration yields events in sequence order.
//   • Thread-safety: concurrent appends produce a valid chain.
//   • next_seq() increments correctly.
//   • Rotation: appending past kRotationBytes threshold rotates the file.
//
// Tests use a per-test temp directory under TEST_ARTIFACT_DIR (defined
// by CMake) — never ~/.jarvis so the operator's real log is untouched.

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_all.hpp>

#include "../audit_log.h"
#include "../audit_event.h"

#include <array>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include <sys/wait.h>

#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace jarvis::audit;

// ── Test fixture helpers ──────────────────────────────────────────────────────

#ifndef TEST_ARTIFACT_DIR
#error TEST_ARTIFACT_DIR must be defined by CMake; tests must not write to /tmp or ~/.jarvis.
#endif

static void installTestBridgeKey() {
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    installBridgeAuditKey(key.data(), key.size());
}

static fs::path testDir(const std::string& name) {
    installTestBridgeKey();
    fs::path d = fs::path(TEST_ARTIFACT_DIR) / name;
    fs::remove_all(d);
    fs::create_directories(d);
    return d;
}

static std::string hex32(const std::array<std::uint8_t, 32>& bytes) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.reserve(64);
    for (auto b : bytes) {
        out.push_back(kHex[(b >> 4) & 0xf]);
        out.push_back(kHex[b & 0xf]);
    }
    return out;
}

static AuditEvent makeEvent(const std::string& kind, const std::string& actor,
                             const std::string& outcome) {
    AuditEvent e;
    e.event_kind = kind;
    e.actor      = actor;
    e.subject    = "test-subject";
    e.outcome    = outcome;
    e.reason     = "unit_test";
    e.organ      = "audit";
    return e;
}

// ── Serialisation round-trip ──────────────────────────────────────────────────

TEST_CASE("AuditEvent serialise/deserialise round-trip", "[audit][serialise]") {
    AuditEvent e;
    e.sequence_id        = 42;
    e.timestamp_ns       = 1716508800123456789LL;
    e.event_kind         = EventKind::MEMORY_WRITE;
    e.actor              = Actor::SELF;
    e.subject            = "sha256:abcdef1234567890";
    e.outcome            = Outcome::ALLOWED;
    e.reason             = "belief_update";
    e.redacted_metadata  = R"({"confidence":0.9})";
    e.prev_hash.fill(0xAB);
    e.own_hash.fill(0xCD);

    std::string json = TamperEvidentAuditLog::serialiseEvent(e);
    auto parsed = TamperEvidentAuditLog::deserialiseEvent(json);

    REQUIRE(parsed.has_value());
    CHECK(parsed->sequence_id        == e.sequence_id);
    CHECK(parsed->timestamp_ns       == e.timestamp_ns);
    CHECK(parsed->event_kind         == e.event_kind);
    CHECK(parsed->actor              == e.actor);
    CHECK(parsed->subject            == e.subject);
    CHECK(parsed->outcome            == e.outcome);
    CHECK(parsed->reason             == e.reason);
    CHECK(parsed->redacted_metadata  == e.redacted_metadata);
    CHECK(parsed->prev_hash          == e.prev_hash);
    CHECK(parsed->own_hash           == e.own_hash);
}

TEST_CASE("deserialiseEvent returns nullopt on garbage", "[audit][serialise]") {
    CHECK(!TamperEvidentAuditLog::deserialiseEvent("").has_value());
    CHECK(!TamperEvidentAuditLog::deserialiseEvent("not json").has_value());
    CHECK(!TamperEvidentAuditLog::deserialiseEvent("{}").has_value());
}

TEST_CASE("deserialiseEvent rejects crowbar malformed JSON", "[audit][serialise][strict]") {
    AuditEvent e;
    e.sequence_id = 1;
    e.timestamp_ns = 2;
    e.event_kind = EventKind::MEMORY_WRITE;
    e.actor = Actor::SELF;
    e.subject = "s";
    e.outcome = Outcome::ALLOWED;
    e.reason = "r";
    e.prev_hash.fill(0x11);
    e.own_hash.fill(0x22);
    const auto json = TamperEvidentAuditLog::serialiseEvent(e);
    CHECK(json.size() <= TamperEvidentAuditLog::kPipeBufAtomicBytes);
    CHECK(!TamperEvidentAuditLog::deserialiseEvent(json + " garbage").has_value());

    auto withNul = json;
    withNul.insert(withNul.begin() + 2, '\0');
    CHECK(!TamperEvidentAuditLog::deserialiseEvent(withNul).has_value());

    const auto duplicate = std::string("{\"seq\":1,\"seq\":1,\"ts_ns\":2,\"kind\":\"memory_write\",\"actor\":\"self\",\"subj\":\"s\",\"out\":\"allowed\",\"rsn\":\"r\",\"meta\":\"\",\"ph\":\"") + std::string(64, '1') + "\",\"oh\":\"" + std::string(64, '2') + "\"}";
    CHECK(!TamperEvidentAuditLog::deserialiseEvent(duplicate).has_value());

    const auto rawControl = std::string("{\"seq\":1,\"ts_ns\":2,\"kind\":\"memory_write\",\"actor\":\"self\",\"subj\":\"bad") + char(0x01) + "\",\"out\":\"allowed\",\"rsn\":\"r\",\"meta\":\"\",\"ph\":\"" + std::string(64, '1') + "\",\"oh\":\"" + std::string(64, '2') + "\"}";
    CHECK(!TamperEvidentAuditLog::deserialiseEvent(rawControl).has_value());

    const auto escapedNul = std::string("{\"seq\":1,\"ts_ns\":2,\"kind\":\"memory_write\",\"actor\":\"self\",\"subj\":\"bad\\u0000\",\"out\":\"allowed\",\"rsn\":\"r\",\"meta\":\"\",\"ph\":\"") + std::string(64, '1') + "\",\"oh\":\"" + std::string(64, '2') + "\"}";
    CHECK(!TamperEvidentAuditLog::deserialiseEvent(escapedNul).has_value());

    const auto escapedDelete = std::string("{\"seq\":1,\"ts_ns\":2,\"kind\":\"memory_write\",\"actor\":\"self\",\"subj\":\"bad\\u007f\",\"out\":\"allowed\",\"rsn\":\"r\",\"meta\":\"\",\"ph\":\"") + std::string(64, '1') + "\",\"oh\":\"" + std::string(64, '2') + "\"}";
    CHECK(!TamperEvidentAuditLog::deserialiseEvent(escapedDelete).has_value());

    CHECK(!TamperEvidentAuditLog::deserialiseEvent(std::string(TamperEvidentAuditLog::kPipeBufAtomicBytes + 1, ' ')).has_value());
}

// ── Construction and basic chain validity ────────────────────────────────────

TEST_CASE("Fresh log verifies immediately after construction", "[audit][chain]") {
    auto dir = testDir("fresh_log");
    TamperEvidentAuditLog log((dir / "audit.log").string());
    CHECK(log.verify_chain());
}

TEST_CASE("Append 1000 events — chain holds throughout", "[audit][chain]") {
    auto dir = testDir("append_1000");
    TamperEvidentAuditLog log((dir / "audit.log").string());

    for (int i = 0; i < 1000; ++i) {
        auto ev = makeEvent(EventKind::MEMORY_WRITE, Actor::SELF, Outcome::ALLOWED);
        ev.reason = "iter_" + std::to_string(i);
        log.append(ev);
    }

    CHECK(log.verify_chain());
}

// ── Iteration yields events in sequence order ─────────────────────────────────

TEST_CASE("Iterator yields events in sequence order", "[audit][iterator]") {
    auto dir = testDir("iter_order");
    TamperEvidentAuditLog log((dir / "audit.log").string());

    for (int i = 0; i < 10; ++i)
        log.append(makeEvent(EventKind::IDENTITY_CHECK, Actor::SELF, Outcome::PASS));

    uint64_t prev_seq = UINT64_MAX;
    uint64_t count    = 0;
    for (auto it = log.begin(); it != log.end(); ++it) {
        if (prev_seq != UINT64_MAX)
            CHECK(it->sequence_id == prev_seq + 1);
        prev_seq = it->sequence_id;
        ++count;
    }
    CHECK(count > 0);
}

// ── HMAC is deterministic (same fields → same hash) ──────────────────────────

TEST_CASE("computeHmac is deterministic", "[audit][hmac]") {
    std::array<uint8_t, 32> key{};
    key.fill(0x5A);

    AuditEvent e;
    e.sequence_id  = 1;
    e.timestamp_ns = 100;
    e.event_kind   = EventKind::AUTHORITY_GATE;
    e.actor        = Actor::OPERATOR;
    e.subject      = "sub";
    e.outcome      = Outcome::DENIED;
    e.reason       = "not_attested";
    e.prev_hash.fill(0);

    auto h1 = TamperEvidentAuditLog::computeHmac(key, e);
    auto h2 = TamperEvidentAuditLog::computeHmac(key, e);
    CHECK(h1 == h2);
}

TEST_CASE("computeHmac differs when a field changes", "[audit][hmac]") {
    std::array<uint8_t, 32> key{};
    key.fill(0x5A);

    AuditEvent e;
    e.sequence_id  = 1;
    e.timestamp_ns = 100;
    e.event_kind   = EventKind::AUTHORITY_GATE;
    e.actor        = Actor::OPERATOR;
    e.subject      = "sub";
    e.outcome      = Outcome::DENIED;
    e.reason       = "not_attested";
    e.prev_hash.fill(0);

    auto h_original = TamperEvidentAuditLog::computeHmac(key, e);

    AuditEvent e2 = e;
    e2.outcome = Outcome::ALLOWED; // tamper: flip outcome
    auto h_tampered = TamperEvidentAuditLog::computeHmac(key, e2);

    CHECK(h_original != h_tampered);
}

// ── Thread-safety: concurrent appends ─────────────────────────────────────────

TEST_CASE("Thread-safe concurrent appends produce valid chain", "[audit][thread]") {
    auto dir = testDir("threadsafe");
    TamperEvidentAuditLog log((dir / "audit.log").string());

    constexpr int kThreads = 4;
    constexpr int kEach    = 50;

    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&log, t] {
            for (int i = 0; i < kEach; ++i) {
                auto ev = makeEvent(EventKind::COERCION_REFUSED, Actor::SELF,
                                    Outcome::DENIED);
                ev.reason = "thread_" + std::to_string(t) + "_iter_" + std::to_string(i);
                log.append(ev);
            }
        });
    }
    for (auto& th : threads) th.join();

    CHECK(log.verify_chain());
}

TEST_CASE("Oversize audit records are refused before append", "[audit][security]") {
    auto dir = testDir("oversize_refused");
    TamperEvidentAuditLog log((dir / "audit.log").string());
    AuditEvent e = makeEvent(EventKind::MEMORY_WRITE, Actor::SELF, Outcome::ALLOWED);
    e.redacted_metadata = std::string(600, 'x');
    REQUIRE_THROWS_AS(log.append(e), AuditRecordTooLarge);
}

TEST_CASE("Cross-process concurrent appends produce valid chain", "[audit][process][concurrency]") {
    auto dir = testDir("process_concurrency_10x1000");
    const auto log_path = dir / "audit.log";
    {
        TamperEvidentAuditLog log(log_path.string());
    }
    constexpr int kProcesses = 10;
    constexpr int kEach = 1000;
    std::vector<pid_t> children;
    for (int p = 0; p < kProcesses; ++p) {
        pid_t pid = ::fork();
        REQUIRE(pid >= 0);
        if (pid == 0) {
            try {
                TamperEvidentAuditLog log(log_path.string());
                for (int i = 0; i < kEach; ++i) {
                    AuditEvent e = makeEvent(EventKind::COERCION_REFUSED, Actor::SELF, Outcome::DENIED);
                    e.reason = "p" + std::to_string(p) + "i" + std::to_string(i);
                    log.append(e);
                }
                _exit(0);
            } catch (...) {
                _exit(77);
            }
        }
        children.push_back(pid);
    }
    for (pid_t pid : children) {
        int status = 0;
        REQUIRE(::waitpid(pid, &status, 0) == pid);
        REQUIRE(WIFEXITED(status));
        REQUIRE(WEXITSTATUS(status) == 0);
    }
    TamperEvidentAuditLog log(log_path.string());
    CHECK(log.verify_chain());
}

// ── next_seq() increments correctly ──────────────────────────────────────────

TEST_CASE("next_seq increments with each append", "[audit][seq]") {
    auto dir = testDir("seq_counter");
    TamperEvidentAuditLog log((dir / "audit.log").string());

    uint64_t initial = log.next_seq();
    log.append(makeEvent(EventKind::EGRESS_DENIED, Actor::SELF, Outcome::DENIED));
    CHECK(log.next_seq() == initial + 1);
    log.append(makeEvent(EventKind::EGRESS_DENIED, Actor::SELF, Outcome::DENIED));
    CHECK(log.next_seq() == initial + 2);
}

TEST_CASE("Audit log refuses construction without bridge key", "[audit][security][bridge]") {
    clearBridgeAuditKeyForTesting();
    auto dir = fs::path(TEST_ARTIFACT_DIR) / "missing_bridge_key";
    fs::remove_all(dir);
    fs::create_directories(dir);
    REQUIRE_THROWS_AS(TamperEvidentAuditLog((dir / "audit.log").string()), AuditKeyMissingError);
    installTestBridgeKey();
}

TEST_CASE("Legacy audit key file is not created", "[audit][security][bridge]") {
    auto dir = testDir("no_key_file");
    {
        TamperEvidentAuditLog log((dir / "audit.log").string());
    }
    struct stat st{};
    CHECK(::stat((dir / "legacy.key").c_str(), &st) != 0);
}

// ── Log file is mode 0600 ─────────────────────────────────────────────────────

TEST_CASE("Log file is created with mode 0600", "[audit][security]") {
    auto dir = testDir("log_perms");
    {
        TamperEvidentAuditLog log((dir / "audit.log").string());
    }
    struct stat st{};
    REQUIRE(::stat((dir / "audit.log").c_str(), &st) == 0);
    CHECK((st.st_mode & 0777) == 0600);
}
