// test_egress_allowlist.cpp
// JARVIS digital-personhood project — GMRI
//
// Catch2 v3 unit tests for EgressAllowlist.

#include <catch2/catch_test_macros.hpp>

#include "../egress_allowlist.h"

using namespace jarvis::security::egress;

TEST_CASE("EgressAllowlist — all 11 pinned hosts are allowed on port 443",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();

    REQUIRE(al.is_allowed("api.deepgram.com",                  443));
    REQUIRE(al.is_allowed("ollama.com",                        443));
    REQUIRE(al.is_allowed("accounts.google.com",               443));
    REQUIRE(al.is_allowed("oauth2.googleapis.com",             443));
    REQUIRE(al.is_allowed("generativelanguage.googleapis.com", 443));
    REQUIRE(al.is_allowed("aiplatform.googleapis.com",         443));
    REQUIRE(al.is_allowed("github.com",                        443));
    REQUIRE(al.is_allowed("api.github.com",                    443));
    REQUIRE(al.is_allowed("api.githubcopilot.com",             443));
    REQUIRE(al.is_allowed("fleet-goose-114.convex.cloud",      443));
    REQUIRE(al.is_allowed("convex.cloud",                      443));
}

TEST_CASE("EgressAllowlist — unknown host is denied",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();

    REQUIRE_FALSE(al.is_allowed("evil.example.com", 443));
    REQUIRE_FALSE(al.is_allowed("exfil.attacker.net", 443));
    REQUIRE_FALSE(al.is_allowed("api.deepgram.com.attacker.com", 443));
    REQUIRE_FALSE(al.is_allowed("", 443));
}

TEST_CASE("EgressAllowlist — port 443 only; other ports denied even for known host",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();

    // Port 80 (HTTP) — must be denied even for a known host.
    REQUIRE_FALSE(al.is_allowed("api.deepgram.com", 80));
    REQUIRE_FALSE(al.is_allowed("ollama.com",        80));
    REQUIRE_FALSE(al.is_allowed("api.github.com",    8080));
    REQUIRE_FALSE(al.is_allowed("convex.cloud",      0));
}

TEST_CASE("EgressAllowlist — no wildcards: prefix/suffix tricks are rejected",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();

    REQUIRE_FALSE(al.is_allowed(".api.deepgram.com",  443));
    REQUIRE_FALSE(al.is_allowed("api.deepgram.com.",  443));
    REQUIRE_FALSE(al.is_allowed("xapi.deepgram.com",  443));
    REQUIRE_FALSE(al.is_allowed("api.deepgram.com/",  443));
}

TEST_CASE("EgressAllowlist — enforce() throws EgressDenied for unknown host",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();

    REQUIRE_THROWS_AS(al.enforce("evil.example.com", 443), EgressDenied);
    REQUIRE_THROWS_AS(al.enforce("api.deepgram.com",  80),  EgressDenied);
}

TEST_CASE("EgressAllowlist — enforce() does not throw for known host + 443",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();

    REQUIRE_NOTHROW(al.enforce("api.deepgram.com", 443));
    REQUIRE_NOTHROW(al.enforce("fleet-goose-114.convex.cloud", 443));
}

TEST_CASE("EgressDenied exception carries host and non-empty sha256",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();
    try {
        al.enforce("evil.example.com", 443);
        FAIL("Should have thrown");
    } catch (const EgressDenied& e) {
        REQUIRE(e.denied_host == "evil.example.com");
        REQUIRE(e.host_sha256_hex.size() == 64);
        REQUIRE(!e.message.empty());
    }
}

TEST_CASE("EgressAllowlist — allowed_hosts() returns exactly 11 entries",
          "[allowlist]") {
    const auto& al = EgressAllowlist::global();
    REQUIRE(al.allowed_hosts().size() == 11);
}
