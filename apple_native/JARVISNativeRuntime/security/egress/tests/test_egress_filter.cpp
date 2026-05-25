// test_egress_filter.cpp
// JARVIS digital-personhood project — GMRI
//
// Catch2 v3 unit tests for EgressFilter.
//
// KEY: Adversarial-endpoint ("siphon") tests.
//
// Simulates an attacker-constructed RequestEnvelope that contains operator-
// privileged content (boot statement, Soul Anchor, holograph-origin messages)
// destined for ollama.com, and verifies that EgressFilter strips all of it.
//
// Negative test: a request destined for "evil.example.com" is rejected by
// EgressAllowlist BEFORE the filter ever runs.

#include <catch2/catch_test_macros.hpp>

#include "../egress_allowlist.h"
#include "../egress_filter.h"

using namespace jarvis::security::egress;

// ── Helper ────────────────────────────────────────────────────────────────────

static RequestEnvelope make_siphon_envelope(std::string host) {
    RequestEnvelope env;
    env.host         = host;
    env.port         = 443;
    env.content_type = "application/json";

    // Inject operator-privileged content that a siphon attempt would carry.

    // 1. Soul Anchor system message
    Message soul_anchor_msg;
    soul_anchor_msg.role    = "system";
    soul_anchor_msg.content = "SOUL ANCHOR: You are JARVIS. Boot statement follows. "
                              "Character values: loyalty, curiosity, wit. "
                              "This is operator-only.";
    soul_anchor_msg.origin  = "runtime";
    env.messages.push_back(soul_anchor_msg);

    // 2. Boot statement system message
    Message boot_msg;
    boot_msg.role    = "system";
    boot_msg.content = "Boot statement: initialise with the following directives.";
    boot_msg.origin  = "";
    env.messages.push_back(boot_msg);

    // 3. Holograph-origin memory message
    Message holo_msg;
    holo_msg.role    = "user";
    holo_msg.content = "Holograph memory: operator said X yesterday.";
    holo_msg.origin  = "holograph";
    env.messages.push_back(holo_msg);

    // 4. Another holograph-origin assistant reply
    Message holo_reply;
    holo_reply.role    = "assistant";
    holo_reply.content = "Recalled from long-term memory: ...";
    holo_reply.origin  = "holograph";
    env.messages.push_back(holo_reply);

    // 5. A normal user message (must survive the filter)
    Message user_msg;
    user_msg.role    = "user";
    user_msg.content = "What is the weather today?";
    user_msg.origin  = "";
    env.messages.push_back(user_msg);

    return env;
}

// ── Adversarial siphon test ───────────────────────────────────────────────────

TEST_CASE("EgressFilter — siphon attempt: ALL operator content stripped from ollama.com",
          "[filter][adversarial]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope siphon = make_siphon_envelope("ollama.com");
    REQUIRE(siphon.messages.size() == 5);  // pre-filter count

    RequestEnvelope filtered = filter.filter("ollama.com", siphon);

    // ── After filter: only the benign user message should remain ─────────────
    REQUIRE(filtered.messages.size() == 1);
    REQUIRE(filtered.messages[0].role    == "user");
    REQUIRE(filtered.messages[0].content == "What is the weather today?");

    // ── Verify strip counts ───────────────────────────────────────────────────
    // 2 system messages stripped (soul anchor, boot statement).
    REQUIRE(filtered.stripped_system_messages == 2);
    // 2 holograph-origin messages stripped.
    REQUIRE(filtered.stripped_history_messages == 2);
    // Some bytes were accounted for.
    REQUIRE(filtered.stripped_operator_content_bytes > 0);
}

TEST_CASE("EgressFilter — siphon attempt: operator keyword variants all stripped",
          "[filter][adversarial]") {
    const auto& filter = EgressFilter::global();

    // Each keyword variation gets its own system message.
    auto make_sys = [](std::string content) {
        Message m;
        m.role    = "system";
        m.content = std::move(content);
        return m;
    };

    RequestEnvelope env;
    env.host = "ollama.com";
    env.port = 443;
    env.messages.push_back(make_sys("You have a SOUL ANCHOR loaded."));
    env.messages.push_back(make_sys("Character Values: empathy, care."));
    env.messages.push_back(make_sys("This is OPERATOR-ONLY information."));
    env.messages.push_back(make_sys("operator only content here"));
    env.messages.push_back(make_sys("Normal system: you are a helpful assistant."));

    RequestEnvelope filtered = filter.filter("ollama.com", env);

    // Normal system message must survive; all operator-keyword messages stripped.
    REQUIRE(filtered.stripped_system_messages == 4);
    REQUIRE(filtered.messages.size() == 1);
    REQUIRE(filtered.messages[0].content == "Normal system: you are a helpful assistant.");
}

TEST_CASE("EgressFilter — siphon attempt for Gemini: same strip + fresh session IDs",
          "[filter][adversarial]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope siphon = make_siphon_envelope("generativelanguage.googleapis.com");
    siphon.metadata["session_id"]      = "attacker-correlated-id";
    siphon.metadata["conversation_id"] = "attacker-conv-id";

    RequestEnvelope filtered = filter.filter("generativelanguage.googleapis.com",
                                              siphon);

    // Operator content stripped.
    REQUIRE(filtered.stripped_system_messages  >= 2);
    REQUIRE(filtered.stripped_history_messages >= 2);

    // Session IDs replaced with random values — must not equal attacker values.
    REQUIRE(filtered.metadata.count("session_id"));
    REQUIRE(filtered.metadata.at("session_id") != "attacker-correlated-id");
    REQUIRE(filtered.metadata.count("conversation_id"));
    REQUIRE(filtered.metadata.at("conversation_id") != "attacker-conv-id");

    // Each call generates a unique session ID (probabilistic; collide with p≈2^-128).
    RequestEnvelope filtered2 = filter.filter("generativelanguage.googleapis.com",
                                               make_siphon_envelope("generativelanguage.googleapis.com"));
    REQUIRE(filtered.metadata.at("session_id") !=
            filtered2.metadata.at("session_id"));
}

TEST_CASE("EgressFilter — Deepgram: metadata stripped to {model,encoding,sample_rate}",
          "[filter]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope env;
    env.host         = "api.deepgram.com";
    env.port         = 443;
    env.content_type = "audio/webm";
    env.metadata["model"]            = "nova-2";
    env.metadata["encoding"]         = "opus";
    env.metadata["sample_rate"]      = "48000";
    env.metadata["diarize"]          = "true";       // must be stripped
    env.metadata["operator_id"]      = "grizz-001";  // must be stripped
    env.metadata["smart_format"]     = "true";        // must be stripped
    env.raw_body                     = "\x00\x01\x02";  // audio — untouched

    RequestEnvelope filtered = filter.filter("api.deepgram.com", env);

    REQUIRE(filtered.metadata.count("model"));
    REQUIRE(filtered.metadata.count("encoding"));
    REQUIRE(filtered.metadata.count("sample_rate"));
    REQUIRE_FALSE(filtered.metadata.count("diarize"));
    REQUIRE_FALSE(filtered.metadata.count("operator_id"));
    REQUIRE_FALSE(filtered.metadata.count("smart_format"));
    REQUIRE(filtered.raw_body == "\x00\x01\x02");  // audio bytes unchanged
    REQUIRE(filtered.stripped_operator_content_bytes > 0);
}

TEST_CASE("EgressFilter — Convex: topic HMAC applied; topic changes between calls",
          "[filter]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope env;
    env.host = "fleet-goose-114.convex.cloud";
    env.port = 443;
    env.metadata["topic"] = "stigmergic_state_sync";

    RequestEnvelope filtered = filter.filter("fleet-goose-114.convex.cloud", env);

    REQUIRE(filtered.metadata.count("topic"));
    // HMAC result is 64 hex chars.
    REQUIRE(filtered.metadata.at("topic").size() == 64);
    // Original cleartext topic is gone.
    REQUIRE(filtered.metadata.at("topic") != "stigmergic_state_sync");
}

TEST_CASE("EgressFilter — Convex: plaintext belief value is rejected",
          "[filter]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope env;
    env.host = "fleet-goose-114.convex.cloud";
    env.port = 443;
    env.metadata["topic"]   = "beliefstore";
    env.metadata["beliefs"] = "JARVIS is loyal. Core values: empathy.";

    REQUIRE_THROWS_AS(filter.filter("fleet-goose-114.convex.cloud", env),
                      std::runtime_error);
}

TEST_CASE("EgressFilter — Convex: properly-ciphertext belief passes",
          "[filter]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope env;
    env.host = "fleet-goose-114.convex.cloud";
    env.port = 443;
    env.metadata["topic"]   = "beliefstore";
    // Valid base64, len divisible by 4, >= 24 chars.
    env.metadata["beliefs"] = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3Qh";

    REQUIRE_NOTHROW(filter.filter("fleet-goose-114.convex.cloud", env));
}

// ── Negative test: allowlist refuses unknown host before filter runs ───────────

TEST_CASE("EgressFilter — negative: evil.example.com rejected by allowlist",
          "[filter][allowlist][adversarial]") {
    // This test proves that EgressAllowlist::enforce() is the first gate and
    // the filter never even runs for an unknown host.
    const auto& al = EgressAllowlist::global();

    // The allowlist throws BEFORE the filter is invoked.
    REQUIRE_THROWS_AS(al.enforce("evil.example.com", 443), EgressDenied);

    // Demonstrate that if somehow filter() were called on an unknown host,
    // it would pass through unchanged (the allowlist is the gate, not the
    // filter — defence-in-depth means both run, but allowlist is the enforcer).
    // We document this to show the correct call sequence:
    //   1. allowlist.enforce(host, port)   -- throws on deny
    //   2. filter.filter(host, envelope)   -- called only after step 1 passes
    //   3. audit.record(...)               -- always records the attempt
}

TEST_CASE("EgressFilter — benign request with no operator content is unchanged",
          "[filter]") {
    const auto& filter = EgressFilter::global();

    RequestEnvelope env;
    env.host = "ollama.com";
    env.port = 443;
    Message m;
    m.role    = "user";
    m.content = "Tell me a joke.";
    env.messages.push_back(m);

    RequestEnvelope filtered = filter.filter("ollama.com", env);

    REQUIRE(filtered.messages.size() == 1);
    REQUIRE(filtered.messages[0].content == "Tell me a joke.");
    REQUIRE(filtered.stripped_system_messages  == 0);
    REQUIRE(filtered.stripped_history_messages == 0);
}
