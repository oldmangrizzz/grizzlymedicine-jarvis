// egress_filter.cpp
// JARVIS digital-personhood project — GMRI

#include "egress_filter.h"

#include <openssl/evp.h>
#include <openssl/rand.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <stdexcept>

namespace jarvis::security::egress {

// ── Internal helpers ──────────────────────────────────────────────────────────

namespace {

// Case-insensitive substring search.
bool icontains(std::string_view haystack, std::string_view needle) noexcept {
    if (needle.empty()) return true;
    if (haystack.size() < needle.size()) return false;
    auto it = std::search(
        haystack.begin(), haystack.end(),
        needle.begin(),   needle.end(),
        [](unsigned char a, unsigned char b) {
            return std::tolower(a) == std::tolower(b);
        });
    return it != haystack.end();
}

// Generate a random hex UUID-like string (32 hex chars = 128-bit random).
std::string random_session_id() {
    uint8_t buf[16];
    RAND_bytes(buf, sizeof(buf));
    char hex[33];
    for (int i = 0; i < 16; ++i) {
        std::snprintf(hex + 2 * i, 3, "%02x", buf[i]);
    }
    return {hex, 32};
}

// HMAC-SHA256 using OpenSSL EVP_MAC (OpenSSL 3.x native API).
std::array<uint8_t, 32> hmac_sha256_raw(std::span<const uint8_t, 32> key,
                                         std::string_view data) {
    std::array<uint8_t, 32> out{};

    EVP_MAC* mac = EVP_MAC_fetch(nullptr, "HMAC", nullptr);
    if (!mac) return out;

    EVP_MAC_CTX* ctx = EVP_MAC_CTX_new(mac);
    if (!ctx) {
        EVP_MAC_free(mac);
        return out;
    }

    // OSSL_PARAM requires a non-const char* for the digest name string.
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

// Deepgram metadata keys that are permitted (all others are stripped).
const std::unordered_map<std::string, bool> kDeepgramAllowedKeys = {
    {"model", true}, {"encoding", true}, {"sample_rate", true}
};

}  // namespace

// ── EgressFilter::contains_operator_keywords ─────────────────────────────────

bool EgressFilter::contains_operator_keywords(std::string_view content) noexcept {
    // Ordered from most distinctive to least to minimise search iterations.
    static constexpr std::array kKeywords{
        std::string_view{"soul anchor"},
        std::string_view{"boot statement"},
        std::string_view{"character values"},
        std::string_view{"operator-only"},
        std::string_view{"operator only"},
    };
    for (auto kw : kKeywords) {
        if (icontains(content, kw)) return true;
    }
    return false;
}

// ── EgressFilter::looks_like_ciphertext ──────────────────────────────────────

bool EgressFilter::looks_like_ciphertext(std::string_view value) noexcept {
    // Heuristic: base64-standard alphabet, length divisible by 4, at least
    // 24 chars (18 cleartext bytes minimum for a meaningful encrypted payload).
    if (value.size() < 24) return false;
    if (value.size() % 4 != 0) return false;
    for (char c : value) {
        if (!std::isalnum(static_cast<unsigned char>(c))
            && c != '+' && c != '/' && c != '=') {
            return false;
        }
    }
    return true;
}

// ── EgressFilter::hmac_topic ─────────────────────────────────────────────────

std::string EgressFilter::hmac_topic(std::string_view topic) const {
    std::span<const uint8_t, 32> key{convex_topic_key_.data(), 32};
    auto raw = hmac_sha256_raw(key, topic);
    return to_hex(std::span<const uint8_t>{raw.data(), raw.size()});
}

// ── EgressFilter ─────────────────────────────────────────────────────────────

EgressFilter::EgressFilter() {
    // Hardcoded policy table.  One entry per allowlisted host (11 total).
    // strip_operator_system_messages: strip msgs whose content contains
    //   "soul anchor", "boot statement", "character values", "operator-only".
    // strip_holograph_origin: strip messages tagged origin="holograph".
    // deepgram_metadata_only: keep only {model, encoding, sample_rate}.
    // fresh_session_id: replace any session_id / conversation_id with UUID.
    // convex_hmac_topic: HMAC the "topic" metadata field.
    // convex_require_ciphertext_beliefs: reject plaintext belief values.

    policies_[0] = EndpointPolicy{
        .host                         = "api.deepgram.com",
        .deepgram_metadata_only       = true,
    };
    policies_[1] = EndpointPolicy{
        .host                              = "ollama.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
    };
    policies_[2] = EndpointPolicy{
        .host                              = "accounts.google.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
        .fresh_session_id                  = true,
    };
    policies_[3] = EndpointPolicy{
        .host                              = "oauth2.googleapis.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
        .fresh_session_id                  = true,
    };
    policies_[4] = EndpointPolicy{
        .host                              = "generativelanguage.googleapis.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
        .fresh_session_id                  = true,
    };
    policies_[5] = EndpointPolicy{
        .host                              = "aiplatform.googleapis.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
        .fresh_session_id                  = true,
    };
    policies_[6] = EndpointPolicy{
        .host                              = "github.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
    };
    // GitHub REST API: restrict to code/repo operations only.
    // NOTE: This runtime only calls /repos/{owner}/{repo}/... and
    //       /user endpoints.  System messages and holograph context must
    //       not be included in GitHub API payloads.
    // GAP: exact endpoint restriction (allowlisted path prefixes) is a
    //      Phase 8 hardening item — current filter strips operator content
    //      but does not yet enforce URL path allowlisting.
    policies_[7] = EndpointPolicy{
        .host                              = "api.github.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
    };
    // GitHub Copilot API: same operator-content strip rules as GitHub.
    // Copilot needs: completions, embeddings.
    // GAP: restrict to /v1/completions and /v1/embeddings path prefixes
    //      (Phase 8 path-allowlist item).
    policies_[8] = EndpointPolicy{
        .host                              = "api.githubcopilot.com",
        .strip_operator_system_messages    = true,
        .strip_holograph_origin            = true,
    };
    // Convex fleet: stigmergic field + belief sync.
    // Beliefs MUST be ciphertext (Phase 4 E2E).  Topic is HMAC-hashed.
    policies_[9] = EndpointPolicy{
        .host                                = "fleet-goose-114.convex.cloud",
        .convex_hmac_topic                   = true,
        .convex_require_ciphertext_beliefs   = true,
    };
    // convex.cloud base domain uses the same policy as the fleet subdomain.
    policies_[10] = EndpointPolicy{
        .host                                = "convex.cloud",
        .convex_hmac_topic                   = true,
        .convex_require_ciphertext_beliefs   = true,
    };
}

const EgressFilter& EgressFilter::global() noexcept {
    static EgressFilter instance;
    return instance;
}

void EgressFilter::set_convex_topic_key(
        std::span<const uint8_t, 32> key) noexcept {
    // EgressFilter is a const singleton; this method is the one allowed
    // mutation (keying), called once at startup before any requests.
    // Safe: called before concurrent use begins.
    std::copy(key.begin(), key.end(), convex_topic_key_.begin());
}

const EndpointPolicy* EgressFilter::policy_for(
        std::string_view host) const noexcept {
    for (auto& p : policies_) {
        if (p.host == host) return &p;
    }
    return nullptr;
}

// ── filter() ─────────────────────────────────────────────────────────────────

RequestEnvelope EgressFilter::filter(std::string_view host,
                                      RequestEnvelope envelope) const {
    const EndpointPolicy* policy = policy_for(host);
    if (!policy) {
        // No policy defined for this host — pass through untouched.
        // (The allowlist already rejected unknown hosts before we get here.)
        return envelope;
    }

    // ── Deepgram metadata strip ───────────────────────────────────────────────
    if (policy->deepgram_metadata_only) {
        std::unordered_map<std::string, std::string> filtered_meta;
        for (auto& [k, v] : envelope.metadata) {
            if (kDeepgramAllowedKeys.count(k)) {
                filtered_meta[k] = std::move(v);
            } else {
                envelope.stripped_operator_content_bytes += k.size() + v.size();
            }
        }
        envelope.metadata = std::move(filtered_meta);
        // raw_body is audio bytes — never touched.
    }

    // ── Message-level strip (system + holograph) ──────────────────────────────
    if (policy->strip_operator_system_messages || policy->strip_holograph_origin) {
        std::vector<Message> kept;
        kept.reserve(envelope.messages.size());

        for (auto& msg : envelope.messages) {
            bool stripped = false;

            // Strip holograph-origin messages.
            if (policy->strip_holograph_origin
                && (msg.origin == "holograph"
                    || icontains(msg.origin, "holograph"))) {
                envelope.stripped_history_messages++;
                envelope.stripped_operator_content_bytes += msg.content.size();
                stripped = true;
            }

            // Strip system messages containing operator-privileged keywords.
            if (!stripped
                && policy->strip_operator_system_messages
                && msg.role == "system"
                && contains_operator_keywords(msg.content)) {
                envelope.stripped_system_messages++;
                envelope.stripped_operator_content_bytes += msg.content.size();
                stripped = true;
            }

            if (!stripped) kept.push_back(std::move(msg));
        }
        envelope.messages = std::move(kept);
    }

    // ── Google: fresh request-scoped session ID ───────────────────────────────
    if (policy->fresh_session_id) {
        envelope.metadata["session_id"]      = random_session_id();
        envelope.metadata["conversation_id"] = random_session_id();
        // Erase any pre-existing client-side correlation keys.
        envelope.metadata.erase("x-conversation-id");
        envelope.metadata.erase("x-session-id");
        envelope.metadata.erase("client_id");
    }

    // ── Convex: HMAC topic + ciphertext belief check ──────────────────────────
    if (policy->convex_hmac_topic) {
        auto it = envelope.metadata.find("topic");
        if (it != envelope.metadata.end() && !it->second.empty()) {
            it->second = hmac_topic(it->second);
        }
    }

    if (policy->convex_require_ciphertext_beliefs) {
        auto it = envelope.metadata.find("beliefs");
        if (it != envelope.metadata.end() && !it->second.empty()) {
            if (!looks_like_ciphertext(it->second)) {
                throw std::runtime_error(
                    "EgressFilter: Convex belief value is not ciphertext — "
                    "Phase 4 E2E encryption required before this request can "
                    "be transmitted.  Plaintext beliefs must never leave the "
                    "process.");
            }
        }
        // Per-message belief fields.
        for (auto& msg : envelope.messages) {
            auto bit = msg.metadata.find("belief");
            if (bit != msg.metadata.end() && !bit->second.empty()) {
                if (!looks_like_ciphertext(bit->second)) {
                    throw std::runtime_error(
                        "EgressFilter: Convex message belief is not "
                        "ciphertext — Phase 4 E2E encryption required.");
                }
            }
        }
    }

    return envelope;
}

}  // namespace jarvis::security::egress
