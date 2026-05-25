// egress_audit.cpp
// JARVIS digital-personhood project — GMRI

#include "egress_audit.h"

#include <openssl/evp.h>
#include <openssl/rand.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <stdexcept>

// RedactingLogger (C ABI) — used for structured JSON-L emission.
#include "../../logging/redacting_logger.h"

namespace jarvis::security::egress {

// ── HMAC-SHA256 helper ────────────────────────────────────────────────────────

namespace {

std::array<uint8_t, 32> hmac_sha256(std::span<const uint8_t, 32> key,
                                     std::string_view data) {
    std::array<uint8_t, 32> out{};

    EVP_MAC* mac = EVP_MAC_fetch(nullptr, "HMAC", nullptr);
    if (!mac) return out;

    EVP_MAC_CTX* ctx = EVP_MAC_CTX_new(mac);
    if (!ctx) { EVP_MAC_free(mac); return out; }

    char digest_name[] = "SHA256";
    OSSL_PARAM params[] = {
        OSSL_PARAM_construct_utf8_string("digest", digest_name,
                                         sizeof(digest_name) - 1),
        OSSL_PARAM_construct_end()
    };

    if (EVP_MAC_init(ctx, key.data(), key.size(), params) == 1) {
        EVP_MAC_update(ctx,
                       reinterpret_cast<const uint8_t*>(data.data()),
                       data.size());
        size_t out_len = 32;
        EVP_MAC_final(ctx, out.data(), &out_len, 32);
    }

    EVP_MAC_CTX_free(ctx);
    EVP_MAC_free(mac);
    return out;
}

std::string to_hex(std::span<const uint8_t> bytes) {
    std::string out;
    out.resize(bytes.size() * 2);
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        std::snprintf(&out[2 * i], 3, "%02x", bytes[i]);
    }
    return out;
}

std::string to_hex_arr(const std::array<uint8_t, 32>& arr) {
    return to_hex(std::span<const uint8_t>{arr.data(), arr.size()});
}

double unix_time_now() {
    using namespace std::chrono;
    auto now = system_clock::now();
    auto dur = now.time_since_epoch();
    return duration<double>(dur).count();
}

}  // namespace

// ── EgressAudit ───────────────────────────────────────────────────────────────

EgressAudit::EgressAudit() {
    // Generate per-session random keys.  Neither key is ever written to disk.
    if (RAND_bytes(fingerprint_key_.data(), 32) != 1
        || RAND_bytes(chain_key_.data(), 32) != 1) {
        throw std::runtime_error("EgressAudit: RAND_bytes failed — "
                                 "cannot initialise HMAC keys");
    }

    // Random genesis hash — makes the chain unguessable without the key.
    uint8_t genesis_buf[32];
    if (RAND_bytes(genesis_buf, 32) != 1) {
        throw std::runtime_error("EgressAudit: RAND_bytes failed for genesis");
    }
    genesis_hash_    = to_hex({genesis_buf, 32});
    last_chain_hash_ = genesis_hash_;
}

EgressAudit& EgressAudit::instance() {
    static EgressAudit inst;
    return inst;
}

// ── serialise_for_chain ───────────────────────────────────────────────────────

std::string EgressAudit::serialise_for_chain(const AuditRecord& e) {
    // Canonical, stable serialisation.  Numeric fields have fixed field names.
    // Designed so that altering any field changes the serialised output.
    char buf[512];
    std::snprintf(buf, sizeof(buf),
        "ts=%.6f|host=%s|port=%u|bytes=%zu|ct=%s|sys=%zu|hist=%zu|fp=%s|res=%s",
        e.timestamp,
        e.host.c_str(),
        static_cast<unsigned>(e.port),
        e.bytes_sent,
        e.content_type.c_str(),
        e.stripped_system_messages,
        e.stripped_history_messages,
        e.payload_fingerprint.c_str(),
        egress_result_cstr(e.result));
    return buf;
}

// ── compute_fingerprint ───────────────────────────────────────────────────────

std::string EgressAudit::compute_fingerprint(
        std::span<const uint8_t> payload) const {
    // HMAC over the raw payload bytes.  Size-zero payloads (e.g. WebSocket
    // control frames) get a well-defined fingerprint of their own.
    std::string data_sv(reinterpret_cast<const char*>(payload.data()),
                        payload.size());
    auto raw = hmac_sha256(
        std::span<const uint8_t, 32>{fingerprint_key_.data(), 32},
        data_sv);
    return to_hex_arr(raw);
}

// ── compute_chain_hash ────────────────────────────────────────────────────────

std::string EgressAudit::compute_chain_hash(const std::string& prev_hash,
                                             const AuditRecord& entry) const {
    // Chain input = prev_hash (64 hex chars) || "|" || canonical serialisation.
    std::string input = prev_hash + "|" + serialise_for_chain(entry);
    auto raw = hmac_sha256(
        std::span<const uint8_t, 32>{chain_key_.data(), 32},
        input);
    return to_hex_arr(raw);
}

// ── record ────────────────────────────────────────────────────────────────────

void EgressAudit::record(const RequestEnvelope& env,
                          std::span<const uint8_t> payload_bytes,
                          EgressResult result) {
    AuditRecord entry;
    entry.timestamp                 = unix_time_now();
    entry.host                      = env.host;
    entry.port                      = env.port;
    entry.bytes_sent                = payload_bytes.size();
    entry.content_type              = env.content_type;
    entry.stripped_system_messages  = env.stripped_system_messages;
    entry.stripped_history_messages = env.stripped_history_messages;
    entry.payload_fingerprint       = compute_fingerprint(payload_bytes);
    entry.result                    = result;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        entry.chain_hash  = compute_chain_hash(last_chain_hash_, entry);
        last_chain_hash_  = entry.chain_hash;
        records_.push_back(entry);
    }

    // Emit via RedactingLogger — only safe fields, never payload content.
    // Using the C ABI so this compiles without the C++ logger template headers.
    char fields_json[1024];
    std::snprintf(fields_json, sizeof(fields_json),
        "{"
        "\"host\":\"%s\","
        "\"port\":%u,"
        "\"bytes_sent\":%zu,"
        "\"content_type\":\"%s\","
        "\"stripped_system_msgs\":%zu,"
        "\"stripped_history_msgs\":%zu,"
        "\"payload_fp\":\"%s\","
        "\"result\":\"%s\","
        "\"chain_hash\":\"%.*s\""
        "}",
        entry.host.c_str(),
        static_cast<unsigned>(entry.port),
        entry.bytes_sent,
        entry.content_type.c_str(),
        entry.stripped_system_messages,
        entry.stripped_history_messages,
        entry.payload_fingerprint.c_str(),
        egress_result_cstr(entry.result),
        16, entry.chain_hash.c_str());  // first 16 hex chars of chain hash

    JARVISLog_emit(/*INFO=*/2, "egress_audit", "outbound_request", fields_json);
}

// ── verify_chain ─────────────────────────────────────────────────────────────

bool EgressAudit::verify_chain() const {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string prev = genesis_hash_;
    for (const auto& entry : records_) {
        std::string expected = compute_chain_hash(prev, entry);
        if (expected != entry.chain_hash) {
            return false;  // tampered or deleted record detected
        }
        prev = entry.chain_hash;
    }
    return true;
}

// ── reset_for_test ────────────────────────────────────────────────────────────

void EgressAudit::reset_for_test() {
    std::lock_guard<std::mutex> lock(mutex_);
    records_.clear();
    last_chain_hash_ = genesis_hash_;
}

// ── test_only_inject_tampered_hash ────────────────────────────────────────────

void EgressAudit::test_only_inject_tampered_hash(std::size_t idx,
                                                   std::string_view corrupted) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (idx < records_.size()) {
        records_[idx].chain_hash = std::string(corrupted);
    }
}

}  // namespace jarvis::security::egress
