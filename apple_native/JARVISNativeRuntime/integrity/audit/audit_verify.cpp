// ─────────────────────────────────────────────────────────────────────────────
// audit_verify.cpp — AuditVerifier implementation + CLI entry point
//
// Also compiled as jarvis-audit-verify CLI (see CMakeLists.txt).
// ─────────────────────────────────────────────────────────────────────────────

#include "audit_verify.h"
#include "audit_log.h"
#include "trust_envelope.h"

#include <cstdint>
#include <cstring>
#include <format>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#ifdef __APPLE__
#  include <CommonCrypto/CommonDigest.h>
#else
#  include <openssl/sha.h>
#endif

#include <fcntl.h>
#include <unistd.h>

namespace jarvis::audit {
namespace {

int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool parse_hex32(const std::string& hex, std::array<uint8_t, 32>& out) {
    if (hex.size() != 64) return false;
    for (std::size_t i = 0; i < 32; ++i) {
        const int hi = hex_nibble(hex[2 * i]);
        const int lo = hex_nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<uint8_t>((hi << 4) | lo);
    }
    return true;
}

std::string json_string_field(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\":\"";
    const auto pos = json.find(needle);
    if (pos == std::string::npos) return {};
    const auto start = pos + needle.size();
    const auto end = json.find('"', start);
    if (end == std::string::npos) return {};
    return json.substr(start, end - start);
}

std::optional<uint64_t> json_u64_field(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    const auto pos = json.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    const auto start = pos + needle.size();
    auto end = start;
    while (end < json.size() && json[end] >= '0' && json[end] <= '9') ++end;
    if (end == start) return std::nullopt;
    return std::stoull(json.substr(start, end - start));
}

} // namespace

// ── Constructor ───────────────────────────────────────────────────────────────

AuditVerifier::AuditVerifier(std::filesystem::path log_path)
    : log_path_(std::move(log_path))
{}

// ── verify() ─────────────────────────────────────────────────────────────────

std::array<uint8_t, 32> AuditVerifier::key_fingerprint(const std::array<uint8_t, 32>& key) {
    std::array<uint8_t, 32> out{};
#ifdef __APPLE__
    CC_SHA256(key.data(), static_cast<CC_LONG>(key.size()), out.data());
#else
    SHA256(key.data(), key.size(), out.data());
#endif
    return out;
}

TrustAnchor AuditVerifier::load_trust_anchor(const std::filesystem::path& path, std::string_view trusted_root_public_key_hex) {
    std::string json;
    if (!trusted_root_public_key_hex.empty()) {
        const auto payload = verify_trust_envelope_file(path, trusted_root_public_key_hex);
        json.assign(reinterpret_cast<const char*>(payload.data()), payload.size());
    } else {
        std::ifstream in(path);
        if (!in) throw std::runtime_error("missing audit trust anchor: " + path.string());
        std::stringstream buffer;
        buffer << in.rdbuf();
        json = buffer.str();
    }
    TrustAnchor anchor;
    const auto seq = json_u64_field(json, "start_sequence_id");
    if (!seq) throw std::runtime_error("audit trust anchor missing start_sequence_id: " + path.string());
    anchor.start_sequence_id = *seq;
    if (!parse_hex32(json_string_field(json, "start_prev_hash_hex"), anchor.start_prev_hash)) {
        throw std::runtime_error("audit trust anchor has invalid start_prev_hash_hex: " + path.string());
    }
    if (!parse_hex32(json_string_field(json, "key_fingerprint_hex"), anchor.key_fingerprint)) {
        throw std::runtime_error("audit trust anchor has invalid key_fingerprint_hex: " + path.string());
    }
    return anchor;
}

VerifyResult AuditVerifier::verify() const {
    TrustAnchor genesis;
    genesis.start_sequence_id = 0;
    return verify(genesis);
}

VerifyResult AuditVerifier::verify(const TrustAnchor& anchor) const {
    VerifyResult result;

    // Load the HMAC key. File-key loading is intentionally refused; the
    // ceremony bridge must install the Secure-Enclave-derived key first.
    std::array<uint8_t, 32> key{};
    try {
        key = requireBridgeAuditKey();
    } catch (const AuditKeyMissingError& ex) {
        result.status      = VerifyStatus::FAIL_KEY;
        result.verdict     = "FAIL — audit bridge key missing";
        result.explanation = std::string(ex.what()) + "\n";
        return result;
    }

    const bool enforce_key_fingerprint = anchor.key_fingerprint != std::array<uint8_t, 32>{};
    if (enforce_key_fingerprint && key_fingerprint(key) != anchor.key_fingerprint) {
        result.status      = VerifyStatus::FAIL_KEY;
        result.verdict     = "FAIL — audit HMAC key fingerprint does not match trust anchor";
        result.explanation = "The audit key is not the ceremony-pinned key for this chain.\n";
        return result;
    }

    // Open the log file.
    int fd = ::open(log_path_.c_str(), O_RDONLY);
    if (fd < 0) {
        result.status      = VerifyStatus::FAIL_IO;
        result.verdict     = "FAIL — cannot open log file";
        result.explanation = "Could not open: " + log_path_.string() + "\n"
            + std::string(::strerror(errno)) + "\n";
        return result;
    }

    // Walk every record.
    std::array<uint8_t, 32> expected_prev = anchor.start_prev_hash;
    uint64_t expected_seq = anchor.start_sequence_id;
    bool first = true;

    off_t pos = 0;
    while (true) {
        // Read length prefix (4 bytes LE).
        uint8_t lbuf[4];
        ssize_t r = ::pread(fd, lbuf, 4, pos);
        if (r == 0) break; // clean EOF
        if (r != 4) {
            result.status            = VerifyStatus::FAIL_TRUNCATED;
            result.break_at_sequence = expected_seq;
            result.verdict           = std::format(
                "FAIL — file truncated mid-record before sequence {}", expected_seq);
            result.explanation =
                "The log file ends in the middle of a record.\n"
                "This can happen after a crash during a write. The records\n"
                "before the truncation point have been verified successfully.\n"
                "Preserve this file — the truncation itself is evidence.\n";
            ::close(fd);
            return result;
        }

        uint32_t len = uint32_t(lbuf[0]) | (uint32_t(lbuf[1]) << 8)
                     | (uint32_t(lbuf[2]) << 16) | (uint32_t(lbuf[3]) << 24);
        if (len == 0 || len + 4 > TamperEvidentAuditLog::kAtomicRecordBytes) {
            result.status            = VerifyStatus::FAIL_TRUNCATED;
            result.break_at_sequence = expected_seq;
            result.verdict           = std::format(
                "FAIL — malformed record length {} at sequence {}", len, expected_seq);
            result.explanation =
                "A record length field contains an implausible value.\n"
                "This indicates corruption or tampering at this position.\n"
                "All records before this point have been verified.\n"
                "Preserve this file — the corruption boundary is evidence.\n";
            ::close(fd);
            return result;
        }

        std::string payload(len, '\0');
        ssize_t r2 = ::pread(fd, payload.data(), len, pos + 4);
        if (r2 != static_cast<ssize_t>(len)) {
            result.status            = VerifyStatus::FAIL_TRUNCATED;
            result.break_at_sequence = expected_seq;
            result.verdict           = std::format(
                "FAIL — record payload truncated at sequence {}", expected_seq);
            result.explanation =
                "The payload of a record is shorter than its length prefix claims.\n"
                "The file was likely truncated mid-write. The records before this\n"
                "point are intact. Preserve the file — this is evidence.\n";
            ::close(fd);
            return result;
        }

        auto ev = TamperEvidentAuditLog::deserialiseEvent(payload);
        if (!ev) {
            result.status            = VerifyStatus::FAIL_HMAC;
            result.break_at_sequence = expected_seq;
            result.verdict           = std::format(
                "FAIL — cannot parse record at sequence {}", expected_seq);
            result.explanation =
                "A record cannot be decoded. This indicates corruption or tampering.\n"
                "All records before this point have been verified successfully.\n"
                "Preserve this file intact — the parse failure is evidence.\n";
            ::close(fd);
            return result;
        }

        ++result.total_read;

        if (first) {
            if (ev->sequence_id != anchor.start_sequence_id) {
                result.status            = VerifyStatus::FAIL_SEQUENCE;
                result.break_at_sequence = ev->sequence_id;
                result.verdict           = std::format(
                    "FAIL — chain start sequence mismatch: expected {} got {}",
                    anchor.start_sequence_id, ev->sequence_id);
                result.explanation = "The first record does not match the ceremony-pinned audit high-water mark.\n";
                ::close(fd);
                return result;
            }
            if (ev->prev_hash != anchor.start_prev_hash) {
                result.status            = VerifyStatus::FAIL_PREV_HASH;
                result.break_at_sequence = ev->sequence_id;
                result.verdict           = std::format("FAIL — chain start prev_hash mismatch at sequence {}", ev->sequence_id);
                result.explanation = "The first record prev_hash does not match the ceremony-pinned audit anchor.\n";
                ::close(fd);
                return result;
            }
        }

        // Verify sequence ID continuity.
        if (!first && ev->sequence_id != expected_seq) {
            result.status            = VerifyStatus::FAIL_SEQUENCE;
            result.break_at_sequence = ev->sequence_id;
            result.verdict           = std::format(
                "FAIL — sequence gap: expected {} got {}",
                expected_seq, ev->sequence_id);
            result.explanation = std::format(
                "Sequence IDs must be strictly consecutive. Expected {}, found {}.\n"
                "This means one or more entries were DELETED or an entry was INSERTED\n"
                "with the wrong sequence number between the verified entries and this one.\n"
                "{} entries before this point are verified intact.\n"
                "Preserve this file — the sequence break is evidence of tampering.\n",
                expected_seq, ev->sequence_id, result.verified_count);
            ::close(fd);
            return result;
        }

        // Verify prev_hash linkage.
        if (!first && ev->prev_hash != expected_prev) {
            result.status            = VerifyStatus::FAIL_PREV_HASH;
            result.break_at_sequence = ev->sequence_id;
            result.verdict           = std::format(
                "FAIL — chain broken at sequence {}", ev->sequence_id);
            result.explanation = std::format(
                "The prev_hash field in sequence {} does not match the own_hash\n"
                "of the preceding entry (sequence {}).\n"
                "\n"
                "What this means:\n"
                "  • An entry was DELETED between sequences {} and {}.\n"
                "  • An entry was INSERTED before sequence {}.\n"
                "  • Entries were REORDERED near this position.\n"
                "  • The preceding entry's own_hash field was tampered with.\n"
                "\n"
                "{} entries before this point are verified intact.\n"
                "Preserve this file — the broken chain is admissible evidence.\n",
                ev->sequence_id, ev->sequence_id - 1,
                ev->sequence_id - 1, ev->sequence_id,
                ev->sequence_id,
                result.verified_count);
            ::close(fd);
            return result;
        }

        // Verify own_hash.
        auto computed = TamperEvidentAuditLog::computeHmac(key, *ev);
        if (computed != ev->own_hash) {
            result.status            = VerifyStatus::FAIL_HMAC;
            result.break_at_sequence = ev->sequence_id;
            result.verdict           = std::format(
                "FAIL — HMAC mismatch at sequence {}", ev->sequence_id);
            result.explanation = std::format(
                "The HMAC (cryptographic integrity signature) of sequence {}\n"
                "does not match what was computed from its fields.\n"
                "\n"
                "What this means:\n"
                "  • One or more fields of this entry were MODIFIED after it was written.\n"
                "  • The entry was REPLACED with a forged entry.\n"
                "  • The HMAC key has been changed (key rotation is not supported;\n"
                "    a changed key means all entries from that point forward will fail).\n"
                "\n"
                "{} entries before this point are verified intact.\n"
                "This entry's fields as stored:\n"
                "  kind:    {}\n"
                "  actor:   {}\n"
                "  subject: {}\n"
                "  outcome: {}\n"
                "  reason:  {}\n"
                "\n"
                "Preserve this file intact — the HMAC failure is evidence of tampering.\n",
                ev->sequence_id,
                result.verified_count,
                ev->event_kind, ev->actor, ev->subject, ev->outcome, ev->reason);
            ::close(fd);
            return result;
        }

        // This entry is clean.
        expected_prev = ev->own_hash;
        expected_seq  = ev->sequence_id + 1;
        first = false;
        ++result.verified_count;
        pos += 4 + len;
    }

    ::close(fd);

    if (first) {
        // File was empty or unreadable.
        result.status      = VerifyStatus::FAIL_EMPTY;
        result.verdict     = "FAIL — log file is empty";
        result.explanation = "No records were found in the log file.\n"
            "This may indicate the log was deleted or never written.\n";
        return result;
    }

    result.status  = VerifyStatus::PASS;
    result.verdict = std::format("PASS — {} entries verified, chain intact",
                                 result.verified_count);
    result.explanation = std::format(
        "All {} audit entries have been verified:\n"
        "  • Every entry's HMAC matches its fields.\n"
        "  • Every entry's prev_hash links to the preceding entry's own_hash.\n"
        "  • Sequence IDs are consecutive with no gaps.\n"
        "\n"
        "This log has not been tampered with since it was written.\n",
        result.verified_count);
    return result;
}

// ── printReport() ─────────────────────────────────────────────────────────────

int AuditVerifier::printReport(bool verbose) const {
    auto result = verify();

    std::cout << "\n";
    std::cout << "=== JARVIS Audit Log Verification ===\n";
    std::cout << "Log file : " << log_path_.string() << "\n";
    std::cout << "Key source: Secure Enclave bridge (file keys refused)\n";
    std::cout << "\n";
    std::cout << "Result   : " << result.verdict << "\n";

    if (verbose || result.status != VerifyStatus::PASS) {
        std::cout << "\n";
        std::cout << result.explanation;
    }

    if (result.status != VerifyStatus::PASS) {
        std::cout << "\n";
        std::cout << "Entries verified intact : " << result.verified_count << "\n";
        std::cout << "Total entries read      : " << result.total_read << "\n";
        if (result.break_at_sequence > 0 || result.status != VerifyStatus::FAIL_EMPTY) {
            std::cout << "Chain break at sequence : " << result.break_at_sequence << "\n";
        }
    }

    std::cout << "\n";
    return (result.status == VerifyStatus::PASS) ? 0 : 1;
}

} // namespace jarvis::audit

// ── CLI entry point ───────────────────────────────────────────────────────────
// Only compiled when building the jarvis-audit-verify binary.
#ifdef JARVIS_AUDIT_VERIFY_MAIN

static void printUsage(const char* argv0) {
    std::cerr
        << "Usage: " << argv0 << " [--verbose] <log_file>\n"
        << "\n"
        << "Verifies the HMAC chain of a JARVIS audit log.\n"
        << "\n"
        << "Arguments:\n"
        << "  log_file   Path to the audit log (e.g. ~/.jarvis/audit.log)\n"
        << "\n"
        << "Options:\n"
        << "  --verbose  Print full explanation even on PASS\n"
        << "\n"
        << "Exit codes:\n"
        << "  0   Chain is intact (PASS)\n"
        << "  1   Chain is broken or file could not be verified\n"
        << "\n"
        << "Understanding a FAIL result:\n"
        << "  A FAIL means the log has been altered after it was written.\n"
        << "  Every JARVIS audit entry is cryptographically signed with an\n"
        << "  HMAC-SHA256 key that only lives on this machine. Any change to\n"
        << "  any field — timestamp, event kind, outcome, reason — changes\n"
        << "  the HMAC and breaks the chain at exactly that entry.\n"
        << "\n"
        << "  If you see a FAIL: DO NOT modify or delete the log file.\n"
        << "  The broken chain is evidence. Preserve the file and note the\n"
        << "  sequence number where the break occurred.\n"
        << "\n";
}

int main(int argc, char* argv[]) {
    bool verbose = false;
    std::vector<std::string> args;
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--verbose") verbose = true;
        else args.push_back(argv[i]);
    }

    if (args.size() != 1) {
        printUsage(argv[0]);
        return 1;
    }

    jarvis::audit::AuditVerifier verifier(args[0]);
    return verifier.printReport(verbose);
}

#endif // JARVIS_AUDIT_VERIFY_MAIN
