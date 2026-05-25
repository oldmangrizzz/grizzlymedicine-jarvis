// test_tamper_detection.cpp — Catch2 tests for all five tamper scenarios
//
// Scenario 1: Mutate a single bit in entry 500 → chain breaks at exactly 500.
// Scenario 2: Delete entry 500 → chain breaks at entry 501.
// Scenario 3: Insert a synthetic entry between 499 and 500 → chain breaks.
// Scenario 4: Reorder two entries → chain breaks.
// Scenario 5: Truncate the file mid-entry → recovery marks the broken prefix;
//             verifier can still read the unbroken prefix.
//
// Each scenario also tests that the AuditVerifier reports the correct break
// point, not a silent pass and not a false alarm on unmodified entries.
//
// NEVER writes to ~/.jarvis — all artifacts go under TEST_ARTIFACT_DIR.

#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_all.hpp>

#include "../audit_log.h"
#include "../audit_event.h"
#include "../audit_verify.h"
#include "../trust_envelope.h"

#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sodium.h>

namespace fs = std::filesystem;
using namespace jarvis::audit;

// ── Artifact directory ────────────────────────────────────────────────────────

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

// ── Low-level file helpers ────────────────────────────────────────────────────

// Read entire file into a byte vector.
static std::vector<uint8_t> readFile(const fs::path& p) {
    int fd = ::open(p.c_str(), O_RDONLY);
    REQUIRE(fd >= 0);
    struct stat st{};
    REQUIRE(::fstat(fd, &st) == 0);
    std::vector<uint8_t> buf(static_cast<size_t>(st.st_size));
    if (!buf.empty())
        REQUIRE(::read(fd, buf.data(), buf.size()) == static_cast<ssize_t>(buf.size()));
    ::close(fd);
    return buf;
}

// Write byte vector to file (truncate).
static void writeFile(const fs::path& p, const std::vector<uint8_t>& data) {
    int fd = ::open(p.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    REQUIRE(fd >= 0);
    if (!data.empty())
        REQUIRE(::write(fd, data.data(), data.size()) == static_cast<ssize_t>(data.size()));
    ::fsync(fd);
    ::close(fd);
}

// Parse the on-disk file into a list of (length, payload_bytes) records.
struct RawRecord {
    std::vector<uint8_t> payload;
};

static std::vector<RawRecord> parseRecords(const std::vector<uint8_t>& data) {
    std::vector<RawRecord> records;
    size_t pos = 0;
    while (pos + 4 <= data.size()) {
        uint32_t len = uint32_t(data[pos]) | (uint32_t(data[pos+1]) << 8)
                     | (uint32_t(data[pos+2]) << 16) | (uint32_t(data[pos+3]) << 24);
        pos += 4;
        if (len == 0 || pos + len > data.size()) break;
        RawRecord r;
        r.payload.assign(data.begin() + pos, data.begin() + pos + len);
        records.push_back(std::move(r));
        pos += len;
    }
    return records;
}

// Serialize records back to bytes.
static std::vector<uint8_t> serializeRecords(const std::vector<RawRecord>& records) {
    std::vector<uint8_t> out;
    for (const auto& r : records) {
        uint32_t len = static_cast<uint32_t>(r.payload.size());
        out.push_back(len & 0xff);
        out.push_back((len >> 8)  & 0xff);
        out.push_back((len >> 16) & 0xff);
        out.push_back((len >> 24) & 0xff);
        out.insert(out.end(), r.payload.begin(), r.payload.end());
    }
    return out;
}

// Build a clean log with N events + the genesis LOG_OPENED entry.
// Returns the path to the log file.
// The returned log object is destroyed so the file is closed before surgery.
struct LogFiles {
    fs::path log_path;
};

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

static std::string hexBytes(const unsigned char* data, std::size_t size) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.reserve(size * 2);
    for (std::size_t i = 0; i < size; ++i) {
        out.push_back(kHex[(data[i] >> 4) & 0xf]);
        out.push_back(kHex[data[i] & 0xf]);
    }
    return out;
}

static std::string trustEnvelopeJson(const std::string& payload, const unsigned char* pub, const unsigned char* priv) {
    REQUIRE(sodium_init() >= 0);
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256(digest.data(), reinterpret_cast<const unsigned char*>(payload.data()), payload.size());
    std::array<unsigned char, crypto_sign_BYTES> sig{};
    crypto_sign_detached(sig.data(), nullptr, digest.data(), digest.size(), priv);
    std::array<unsigned char, crypto_hash_sha256_BYTES> fp{};
    crypto_hash_sha256(fp.data(), pub, crypto_sign_PUBLICKEYBYTES);
    std::array<char, 1024> b64{};
    sodium_bin2base64(b64.data(), b64.size(), reinterpret_cast<const unsigned char*>(payload.data()), payload.size(), sodium_base64_VARIANT_ORIGINAL);
    return std::string("{\"key_fingerprint_hex\":\"") + hexBytes(fp.data(), fp.size()) + "\",\"payload\":\"" + b64.data() + "\",\"payload_sha256\":\"" + hexBytes(digest.data(), digest.size()) + "\",\"signature_over_payload_sha256\":\"" + hexBytes(sig.data(), sig.size()) + "\",\"signed_at_unix\":1}";
}

static TrustAnchor anchor_for(uint64_t start_sequence, const std::array<uint8_t, 32>& prev_hash) {
    const auto key = requireBridgeAuditKey();
    TrustAnchor anchor;
    anchor.start_sequence_id = start_sequence;
    anchor.start_prev_hash = prev_hash;
    anchor.key_fingerprint = AuditVerifier::key_fingerprint(key);
    return anchor;
}

static LogFiles buildLog(const std::string& test_name, int n_events) {
    auto dir = testDir(test_name);
    LogFiles lf;
    lf.log_path = dir / "audit.log";

    {
        TamperEvidentAuditLog log(lf.log_path.string());
        for (int i = 0; i < n_events; ++i) {
            AuditEvent e;
            e.event_kind = EventKind::MEMORY_WRITE;
            e.actor      = Actor::SELF;
            e.subject    = "sha256:" + std::to_string(i);
            e.outcome    = Outcome::ALLOWED;
            e.reason     = "test_event_" + std::to_string(i);
            e.organ      = "audit";
            log.append(e);
        }
        // log destroyed and fd closed here
    }
    return lf;
}

// Find the index of the first record whose sequence_id == target_seq.
// Returns -1 if not found.
static int findRecordIndex(const std::vector<RawRecord>& records, uint64_t target_seq) {
    for (int i = 0; i < static_cast<int>(records.size()); ++i) {
        std::string payload(records[i].payload.begin(), records[i].payload.end());
        auto ev = TamperEvidentAuditLog::deserialiseEvent(payload);
        if (ev && ev->sequence_id == target_seq) return i;
    }
    return -1;
}

TEST_CASE("signed audit trust anchor envelope round-trips and rejects bit flips", "[audit][anchor][envelope]") {
    auto dir = testDir("audit_anchor_envelope");
    std::array<unsigned char, crypto_sign_PUBLICKEYBYTES> pub{};
    std::array<unsigned char, crypto_sign_SECRETKEYBYTES> priv{};
    REQUIRE(sodium_init() >= 0);
    REQUIRE(crypto_sign_keypair(pub.data(), priv.data()) == 0);
    const std::string payload = "{\"key_fingerprint_hex\":\"" + hex32(AuditVerifier::key_fingerprint(requireBridgeAuditKey())) + "\",\"start_prev_hash_hex\":\"" + hex32(std::array<std::uint8_t, 32>{}) + "\",\"start_sequence_id\":0}";
    auto anchor_path = dir / "audit_anchor.json";
    const auto envelope = trustEnvelopeJson(payload, pub.data(), priv.data());
    writeFile(anchor_path, std::vector<uint8_t>(envelope.begin(), envelope.end()));
    auto loaded = AuditVerifier::load_trust_anchor(anchor_path, hexBytes(pub.data(), pub.size()));
    REQUIRE(loaded.start_sequence_id == 0);
    auto tampered = readFile(anchor_path);
    REQUIRE(!tampered.empty());
    tampered[tampered.size() / 2] ^= 0x01;
    writeFile(anchor_path, tampered);
    REQUIRE_THROWS_AS(AuditVerifier::load_trust_anchor(anchor_path, hexBytes(pub.data(), pub.size())), TrustEnvelopeInvalid);
}

TEST_CASE("Trust anchor refuses replayed older log and prefix-skip chain", "[audit][anchor][replay]") {
    auto lf = buildLog("anchor_replay_prefix", 20);
    auto data = readFile(lf.log_path);
    auto records = parseRecords(data);
    REQUIRE(records.size() > 12);
    auto seq10 = TamperEvidentAuditLog::deserialiseEvent(std::string(records[10].payload.begin(), records[10].payload.end()));
    REQUIRE(seq10.has_value());

    auto moved_anchor = anchor_for(seq10->sequence_id + 1, seq10->own_hash);
    AuditVerifier verifier(lf.log_path);
    CHECK(verifier.verify(moved_anchor).status != VerifyStatus::PASS);

    std::vector<RawRecord> suffix(records.begin() + 11, records.end());
    writeFile(lf.log_path, serializeRecords(suffix));
    auto genesis_anchor = anchor_for(0, std::array<uint8_t, 32>{});
    auto refused = verifier.verify(genesis_anchor);
    CHECK(refused.status != VerifyStatus::PASS);
}

// ── Scenario 1: Mutate a single byte in entry 500 ────────────────────────────

TEST_CASE("Scenario 1: Single-byte mutation breaks chain at exactly seq 500",
          "[tamper][mutation]")
{
    // Build log with 1000 events (plus genesis = 1001 records total).
    auto lf = buildLog("sc1_mutation", 1000);

    // Verify clean before surgery.
    {
        AuditVerifier v(lf.log_path);
        auto r = v.verify();
        REQUIRE(r.status == VerifyStatus::PASS);
    }

    // Read the file, find record at seq=500, flip one byte in its payload.
    auto data    = readFile(lf.log_path);
    auto records = parseRecords(data);

    int idx = findRecordIndex(records, 500);
    REQUIRE(idx >= 0);

    // Flip a byte near the middle of the payload (in the "reason" field area).
    size_t flip_pos = records[idx].payload.size() / 2;
    records[idx].payload[flip_pos] ^= 0x01;

    writeFile(lf.log_path, serializeRecords(records));

    // Verify: must fail at sequence 500, not before, not after.
    {
        AuditVerifier v(lf.log_path);
        auto r = v.verify();
        CHECK(r.status            != VerifyStatus::PASS);
        CHECK(r.break_at_sequence == 500);
        // All entries before 500 must be intact.
        CHECK(r.verified_count    == 500);
    }
}

// ── Scenario 2: Delete entry 500 ─────────────────────────────────────────────

TEST_CASE("Scenario 2: Deleting entry 500 breaks chain at entry 501",
          "[tamper][delete]")
{
    auto lf = buildLog("sc2_delete", 1000);

    {
        AuditVerifier v(lf.log_path);
        REQUIRE(v.verify().status == VerifyStatus::PASS);
    }

    auto data    = readFile(lf.log_path);
    auto records = parseRecords(data);

    int idx = findRecordIndex(records, 500);
    REQUIRE(idx >= 0);

    // Remove record 500.
    records.erase(records.begin() + idx);

    writeFile(lf.log_path, serializeRecords(records));

    {
        AuditVerifier v(lf.log_path);
        auto r = v.verify();
        CHECK(r.status != VerifyStatus::PASS);
        // Chain should break at 501 (prev_hash mismatch) or sequence gap.
        // Either way, break must be at 501, and 500 entries before it are intact.
        CHECK(r.break_at_sequence == 501);
        CHECK(r.verified_count    == 500);
    }
}

// ── Scenario 3: Insert synthetic entry between 499 and 500 ───────────────────

TEST_CASE("Scenario 3: Inserted entry between 499 and 500 breaks chain",
          "[tamper][insert]")
{
    auto lf = buildLog("sc3_insert", 1000);

    {
        AuditVerifier v(lf.log_path);
        REQUIRE(v.verify().status == VerifyStatus::PASS);
    }

    auto data    = readFile(lf.log_path);
    auto records = parseRecords(data);

    int idx_500 = findRecordIndex(records, 500);
    REQUIRE(idx_500 >= 0);

    // Build a synthetic record. Its sequence_id can be anything — any value
    // will break the chain because the HMAC chain enforces prev_hash linkage.
    // Use seq=9999 to make it obviously synthetic.
    AuditEvent synthetic;
    synthetic.sequence_id  = 9999;
    synthetic.timestamp_ns = 1;
    synthetic.event_kind   = "SYNTHETIC_INJECT";
    synthetic.actor        = "attacker";
    synthetic.subject      = "injected";
    synthetic.outcome      = Outcome::ALLOWED;
    synthetic.reason       = "attacker_inserted";
    synthetic.prev_hash.fill(0);
    synthetic.own_hash.fill(0);

    std::string synth_json = TamperEvidentAuditLog::serialiseEvent(synthetic);
    RawRecord synth_rec;
    synth_rec.payload.assign(synth_json.begin(), synth_json.end());

    // Insert at position idx_500 (before seq 500).
    records.insert(records.begin() + idx_500, synth_rec);

    writeFile(lf.log_path, serializeRecords(records));

    {
        AuditVerifier v(lf.log_path);
        auto r = v.verify();
        CHECK(r.status != VerifyStatus::PASS);
        // The break is at the synthetic entry (seq 9999) or at seq 500
        // (which now has the wrong prev_hash). Either way, verified_count == 500.
        CHECK(r.verified_count == 500);
    }
}

// ── Scenario 4: Reorder two entries ──────────────────────────────────────────

TEST_CASE("Scenario 4: Reordering entries 499 and 500 breaks chain",
          "[tamper][reorder]")
{
    auto lf = buildLog("sc4_reorder", 1000);

    {
        AuditVerifier v(lf.log_path);
        REQUIRE(v.verify().status == VerifyStatus::PASS);
    }

    auto data    = readFile(lf.log_path);
    auto records = parseRecords(data);

    int idx_499 = findRecordIndex(records, 499);
    int idx_500 = findRecordIndex(records, 500);
    REQUIRE(idx_499 >= 0);
    REQUIRE(idx_500 >= 0);
    REQUIRE(idx_500 == idx_499 + 1);

    // Swap records 499 and 500.
    std::swap(records[idx_499], records[idx_500]);

    writeFile(lf.log_path, serializeRecords(records));

    {
        AuditVerifier v(lf.log_path);
        auto r = v.verify();
        CHECK(r.status != VerifyStatus::PASS);
        // Break is at seq 499 (now in the 500 slot — HMAC mismatch because
        // its prev_hash is wrong) or at seq 500. Either way, verified_count
        // is exactly 499 — the 499 entries before the swap are intact.
        CHECK(r.verified_count == 499);
    }
}

// ── Scenario 5: Truncate file mid-entry ──────────────────────────────────────

TEST_CASE("Scenario 5: Mid-entry truncation — verifier reads intact prefix cleanly",
          "[tamper][truncate]")
{
    auto lf = buildLog("sc5_truncate", 100);

    {
        AuditVerifier v(lf.log_path);
        REQUIRE(v.verify().status == VerifyStatus::PASS);
    }

    auto data = readFile(lf.log_path);
    REQUIRE(data.size() > 100);

    // Truncate 37 bytes off the end (guaranteed to be mid-record for any
    // reasonable payload size, since each record is > 100 bytes).
    data.resize(data.size() - 37);
    writeFile(lf.log_path, data);

    {
        AuditVerifier v(lf.log_path);
        auto r = v.verify();
        // Must NOT be PASS.
        CHECK(r.status != VerifyStatus::PASS);
        // Must be detected as truncation (not a silent pass).
        CHECK((r.status == VerifyStatus::FAIL_TRUNCATED ||
               r.status == VerifyStatus::FAIL_HMAC     ||
               r.status == VerifyStatus::FAIL_SEQUENCE));
        // The intact entries before the truncation point are verified.
        // We wrote 100 events + 1 genesis = 101 total. Truncated last entry.
        // At minimum, 99 entries should be verified before the broken tail.
        CHECK(r.verified_count >= 99);
    }
}

// ── All five scenarios summary tag ────────────────────────────────────────────

TEST_CASE("All tamper scenarios are non-silent (no false PASS)", "[tamper][summary]") {
    // This test builds one log and verifies that a clean log returns PASS,
    // confirming the test infrastructure is working before the tamper scenarios
    // run. (Individual scenario tests above verify the break detection.)
    auto lf = buildLog("sc_summary_clean", 50);
    AuditVerifier v(lf.log_path);
    auto r = v.verify();
    CHECK(r.status == VerifyStatus::PASS);
    CHECK(r.verified_count > 0);
}
