// egress_filter.h
// JARVIS digital-personhood project — GMRI
//
// Per-endpoint content-stripping filter.  Every outbound RequestEnvelope MUST
// pass through EgressFilter::filter() before serialisation and transmission.
//
// Design:
//   • Policy table is hardcoded per endpoint — not runtime-configurable.
//   • Strips operator-privileged content (Soul Anchor, boot statement,
//     holograph-origin messages, character values, operator-only system msgs)
//     before the envelope leaves the process.
//   • Convex: topic field is HMAC-hashed; belief values must be ciphertext.
//   • Google endpoints: request-scoped session ID replaces any client-side
//     conversation-ID to prevent Google correlation.
//   • Deepgram: metadata stripped to {model, encoding, sample_rate} only.
//   • Mutations are counted in RequestEnvelope.stripped_* fields so the
//     EgressAudit can log strip counts without logging content.
//
// C++20, depends on OpenSSL::Crypto (for Convex HMAC) and redacting_logger.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace jarvis::security::egress {

// ── RequestEnvelope ───────────────────────────────────────────────────────────

/// One logical outbound message destined for a single host.
///
/// HTTP clients build this struct, call EgressAllowlist::enforce(), then
/// EgressFilter::filter(), then serialise the filtered envelope to wire bytes.
/// EgressAudit::record() is called after transmission with the wire byte count
/// and result.
struct Message {
    std::string role;     ///< "system", "user", "assistant"
    std::string content;
    std::string origin;   ///< "_origin" tag, e.g. "holograph"; empty if unset
    std::unordered_map<std::string, std::string> metadata;
};

struct RequestEnvelope {
    std::string host;
    uint16_t    port{443};
    std::string content_type;

    /// Chat-style message list (Ollama, Gemini, GitHub Copilot).
    std::vector<Message> messages;

    /// Key-value metadata / query parameters (model, encoding, topic, etc.).
    /// For Deepgram, only {model, encoding, sample_rate} survive the filter.
    /// For Convex, the "topic" key is replaced with its HMAC hash.
    std::unordered_map<std::string, std::string> metadata;

    /// Raw binary / non-message body (e.g. Deepgram audio stream bytes).
    /// The filter never modifies raw_body; it is audio or opaque ciphertext.
    std::string raw_body;

    // ── Audit counters (populated by EgressFilter::filter()) ─────────────────

    /// Number of system messages stripped (soul anchor, boot statement, etc.)
    std::size_t stripped_system_messages{0};

    /// Number of history messages stripped (holograph-origin tagged messages).
    std::size_t stripped_history_messages{0};

    /// Total operator-content bytes removed (approx., for audit sizing).
    std::size_t stripped_operator_content_bytes{0};
};

// ── Endpoint policy ───────────────────────────────────────────────────────────

/// Hardcoded per-endpoint minimisation policy.
/// See README for per-endpoint rationale.
struct EndpointPolicy {
    std::string_view host;

    /// Strip messages whose content contains soul-anchor / boot-statement /
    /// character-values / operator-only keywords (case-insensitive).
    bool strip_operator_system_messages{false};

    /// Strip messages tagged origin == "holograph".
    bool strip_holograph_origin{false};

    /// Deepgram: remove all metadata keys except {model, encoding, sample_rate}.
    bool deepgram_metadata_only{false};

    /// Google: replace any client-side session/conversation ID with a fresh
    /// request-scoped UUID so Google cannot correlate across requests.
    bool fresh_session_id{false};

    /// Convex: HMAC-hash the "topic" metadata field.
    bool convex_hmac_topic{false};

    /// Convex: assert that belief values look like ciphertext (base64);
    /// reject the envelope if any belief value appears to be plaintext.
    bool convex_require_ciphertext_beliefs{false};
};

// ── EgressFilter ─────────────────────────────────────────────────────────────

class EgressFilter {
public:
    // ── Singleton ─────────────────────────────────────────────────────────────
    static const EgressFilter& global() noexcept;

    // ── Key configuration (Convex HMAC) ───────────────────────────────────────

    /// Set the 32-byte key used to HMAC Convex topic fields.
    /// MUST be called before any Convex request is filtered.
    /// The key should match the key used by the Python bridge-gap-defenses
    /// Patch 2 on the Convex side so topic hashes are consistent.
    ///
    /// TODO(Phase 4): derive this key from the Secure Enclave E2E key bundle
    /// so the C++ and Python sides share the same derived key automatically.
    void set_convex_topic_key(std::span<const uint8_t, 32> key) noexcept;

    // ── Policy table accessor ─────────────────────────────────────────────────

    /// Returns the policy for the given host, or nullptr if none applies.
    /// The returned pointer is stable for the lifetime of the process.
    [[nodiscard]] const EndpointPolicy* policy_for(std::string_view host) const noexcept;

    // ── Filter ────────────────────────────────────────────────────────────────

    /// Apply the endpoint policy to `envelope`, strip operator content, and
    /// return the sanitised envelope.
    ///
    /// Precondition: EgressAllowlist::global().enforce(host, 443) has already
    /// been called — filter() does NOT re-check the allowlist.
    ///
    /// After this call, envelope.stripped_* fields record what was removed.
    /// Those counts are safe to pass to EgressAudit::record() without leaking
    /// content.
    ///
    /// Throws std::runtime_error if a Convex belief value is not ciphertext
    /// when convex_require_ciphertext_beliefs is true.
    [[nodiscard]] RequestEnvelope filter(std::string_view host,
                                         RequestEnvelope envelope) const;

private:
    EgressFilter();

    // ── Helpers ───────────────────────────────────────────────────────────────
    static bool contains_operator_keywords(std::string_view content) noexcept;
    static bool looks_like_ciphertext(std::string_view value) noexcept;
    std::string hmac_topic(std::string_view topic) const;

    // Compile-time policy table (11 entries, one per allowlisted host).
    static constexpr std::size_t kPolicyCount = 11;
    std::array<EndpointPolicy, kPolicyCount> policies_;

    // 32-byte key for Convex topic HMAC.
    // Default: all-zeros — REPLACE via set_convex_topic_key() before use.
    std::array<uint8_t, 32> convex_topic_key_{};
};

}  // namespace jarvis::security::egress
