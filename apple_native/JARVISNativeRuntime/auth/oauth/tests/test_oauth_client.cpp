#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_string.hpp>

#include "../oauth_client.h"
#include "../keychain_token_store.h"
#include "../../../integrity/audit/audit_log.h"
#include "../../../logging/redacting_logger.h"
#include "../../../security/egress/egress_audit.h"

#include <array>
#include <filesystem>
#include <map>
#include <memory>

using namespace jarvis::auth::oauth;
using Catch::Matchers::ContainsSubstring;

namespace {

class MemoryStore final : public TokenStore {
public:
    void save(const ProviderConfig& provider, const TokenSet& tokens) override { tokens_[provider.id] = tokens; }
    std::optional<TokenSet> load(const ProviderConfig& provider) override {
        auto it = tokens_.find(provider.id);
        if (it == tokens_.end()) return std::nullopt;
        return it->second;
    }
    void remove(const ProviderConfig& provider) override { tokens_.erase(provider.id); }
private:
    std::map<std::string, TokenSet> tokens_;
};

class MockTransport final : public HttpTransport {
public:
    HttpResponse response{200, R"({"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","expires_in":3600,"scope":"read:user"})"};
    std::vector<HttpRequest> requests;
    HttpResponse send(const HttpRequest& request) override {
        requests.push_back(request);
        return response;
    }
};

std::unique_ptr<jarvis::audit::TamperEvidentAuditLog> testAudit(const char* name) {
    auto dir = std::filesystem::path(OAUTH_TEST_ARTIFACT_DIR) / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    std::array<std::uint8_t, 32> key{};
    key.fill(0xA7);
    jarvis::audit::installBridgeAuditKey(key.data(), key.size());
    return std::make_unique<jarvis::audit::TamperEvidentAuditLog>((dir / "audit.log").string());
}

OAuthClient makeClient(ProviderConfig cfg, MemoryStore& store, MockTransport& transport, jarvis::audit::TamperEvidentAuditLog& audit) {
    return OAuthClient(std::move(cfg), OAuthClientRegistration{"public-client-id", "jarvis://oauth/callback"}, store, transport, &audit);
}

}  // namespace

TEST_CASE("PKCE generation produces S256 challenge and no client secret", "[oauth]") {
    auto pkce = OAuthClient::generate_pkce();
    REQUIRE(pkce.method == "S256");
    REQUIRE(pkce.verifier.size() >= 43);
    REQUIRE(pkce.challenge.size() >= 43);
    REQUIRE(pkce.verifier.find('=') == std::string::npos);

    MemoryStore store;
    MockTransport transport;
    auto audit = testAudit("pkce");
    auto client = makeClient(gemini_provider_config(), store, transport, *audit);
    auto url = client.authorization_url("state-123", pkce);
    REQUIRE_THAT(url, ContainsSubstring("https://accounts.google.com/o/oauth2/v2/auth"));
    REQUIRE_THAT(url, ContainsSubstring("code_challenge_method=S256"));
    REQUIRE_THAT(url, ContainsSubstring("scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fgenerativelanguage"));
    REQUIRE(url.find("client_secret") == std::string::npos);
}

TEST_CASE("authorization code grant stores tokens and audits without token logging", "[oauth]") {
    MemoryStore store;
    MockTransport transport;
    auto audit = testAudit("grant");
    auto client = makeClient(gemini_provider_config(), store, transport, *audit);

    auto tokens = client.exchange_authorization_code("code-1", OAuthClient::generate_pkce(), "state", "state");
    REQUIRE(tokens.access_token == "access-1");
    REQUIRE(store.load(gemini_provider_config()).has_value());
    REQUIRE(transport.requests.size() == 1);
    REQUIRE(transport.requests[0].host == "oauth2.googleapis.com");
    REQUIRE(transport.requests[0].body.find("client_secret") == std::string::npos);
    REQUIRE(transport.requests[0].body.find("code_verifier=") != std::string::npos);
    REQUIRE(audit->verify_chain());
}

TEST_CASE("expired token refreshes automatically; refresh failure requires reauth", "[oauth]") {
    MemoryStore store;
    MockTransport transport;
    auto audit = testAudit("refresh");
    auto client = makeClient(gemini_provider_config(), store, transport, *audit);

    TokenSet expired{"old-access", "refresh-1", "Bearer", "scope", std::chrono::system_clock::now() - std::chrono::minutes(5)};
    store.save(gemini_provider_config(), expired);
    auto refreshed = client.valid_token();
    REQUIRE(refreshed.access_token == "access-1");
    REQUIRE(transport.requests.back().body.find("grant_type=refresh_token") != std::string::npos);

    transport.response = {401, R"({"error":"invalid_grant"})"};
    TokenSet expired2{"old-access", "refresh-bad", "Bearer", "scope", std::chrono::system_clock::now() - std::chrono::minutes(5)};
    store.save(gemini_provider_config(), expired2);
    REQUIRE_THROWS_AS(client.valid_token(), ReauthRequired);
    REQUIRE_FALSE(store.load(gemini_provider_config()).has_value());
}

TEST_CASE("revocation calls provider when public revoke exists and cleans keychain store", "[oauth]") {
    MemoryStore store;
    MockTransport transport;
    auto audit = testAudit("revoke");
    auto client = makeClient(gemini_provider_config(), store, transport, *audit);
    store.save(gemini_provider_config(), TokenSet{"access", "refresh", "Bearer", "scope", std::chrono::system_clock::now() + std::chrono::hours(1)});

    client.revoke();
    REQUIRE(transport.requests.size() == 1);
    REQUIRE(transport.requests[0].host == "oauth2.googleapis.com");
    REQUIRE(transport.requests[0].path == "/revoke");
    REQUIRE_FALSE(store.load(gemini_provider_config()).has_value());
}

TEST_CASE("GitHub Copilot documents no public-client revocation and still cleans local tokens", "[oauth]") {
    MemoryStore store;
    MockTransport transport;
    auto audit = testAudit("github-revoke");
    auto cfg = github_copilot_provider_config();
    REQUIRE_FALSE(cfg.public_revocation_supported);
    auto client = makeClient(cfg, store, transport, *audit);
    store.save(github_copilot_provider_config(), TokenSet{"access", "refresh", "Bearer", "read:user", std::chrono::system_clock::now() + std::chrono::hours(1)});

    client.revoke();
    REQUIRE(transport.requests.empty());
    REQUIRE_FALSE(store.load(github_copilot_provider_config()).has_value());
}

TEST_CASE("API calls pass egress minimization and audit", "[oauth]") {
    jarvis::security::egress::EgressAudit::instance().reset_for_test();
    MemoryStore store;
    MockTransport transport;
    auto audit = testAudit("api-call");
    auto client = makeClient(gemini_provider_config(), store, transport, *audit);

    jarvis::security::egress::RequestEnvelope env;
    env.host = "generativelanguage.googleapis.com";
    env.content_type = "application/json";
    env.messages.push_back({"system", "boot statement and character values", "", {}});
    env.messages.push_back({"user", "operator context", "holograph", {}});
    env.messages.push_back({"user", "minimal cloud prompt", "", {}});
    std::array<uint8_t, 2> payload{1, 2};

    auto filtered = client.prepare_api_call(std::move(env), payload);
    REQUIRE(filtered.messages.size() == 1);
    REQUIRE(filtered.stripped_system_messages == 1);
    REQUIRE(filtered.stripped_history_messages == 1);
    REQUIRE(jarvis::security::egress::EgressAudit::instance().verify_chain());
    REQUIRE(jarvis::security::egress::EgressAudit::instance().records().size() == 1);
}

TEST_CASE("token-like logger fields are redacted", "[oauth][logging]") {
    REQUIRE(jarvis::RedactingLogger::isSensitiveField("access_token"));
    REQUIRE(jarvis::RedactingLogger::isSensitiveField("refresh_token"));
    REQUIRE(jarvis::RedactingLogger::isSensitiveField("authorization"));
    auto redacted = jarvis::RedactingLogger::redactValue("secret-token-value");
    REQUIRE(redacted.find("secret-token-value") == std::string::npos);
}
