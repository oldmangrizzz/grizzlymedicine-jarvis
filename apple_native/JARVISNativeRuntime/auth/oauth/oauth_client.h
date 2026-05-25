#pragma once

#include <chrono>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "../../security/egress/egress_filter.h"

namespace jarvis::audit { class TamperEvidentAuditLog; }

namespace jarvis::auth::oauth {

enum class OAuthProvider { Gemini, GitHubCopilot };

struct ProviderConfig {
    OAuthProvider provider;
    std::string id;
    std::string display_name;
    std::string service_name;
    std::string auth_host;
    std::string auth_path;
    std::string token_host;
    std::string token_path;
    std::string revoke_host;
    std::string revoke_path;
    std::string api_host;
    std::vector<std::string> scopes;
    uint32_t requests_per_minute{0};
    bool public_pkce_only{true};
    bool public_revocation_supported{true};
};

struct OAuthClientRegistration {
    std::string client_id;
    std::string redirect_uri;
};

struct PkcePair {
    std::string verifier;
    std::string challenge;
    std::string method{"S256"};
};

struct TokenSet {
    std::string access_token;
    std::string refresh_token;
    std::string token_type{"Bearer"};
    std::string scope;
    std::chrono::system_clock::time_point expires_at{};
};

struct HttpRequest {
    std::string method;
    std::string host;
    std::string path;
    std::map<std::string, std::string> headers;
    std::string body;
};

struct HttpResponse {
    int status{0};
    std::string body;
};

class HttpTransport {
public:
    virtual ~HttpTransport() = default;
    virtual HttpResponse send(const HttpRequest& request) = 0;
};

class TokenStore {
public:
    virtual ~TokenStore() = default;
    virtual void save(const ProviderConfig& provider, const TokenSet& tokens) = 0;
    virtual std::optional<TokenSet> load(const ProviderConfig& provider) = 0;
    virtual void remove(const ProviderConfig& provider) = 0;
};

class ReauthRequired : public std::runtime_error {
public:
    explicit ReauthRequired(const std::string& provider_id);
};

class OAuthClient {
public:
    OAuthClient(ProviderConfig provider,
                OAuthClientRegistration registration,
                TokenStore& token_store,
                HttpTransport& transport,
                jarvis::audit::TamperEvidentAuditLog* audit_log = nullptr);

    static PkcePair generate_pkce();
    [[nodiscard]] std::string authorization_url(std::string state,
                                                const PkcePair& pkce) const;
    TokenSet exchange_authorization_code(std::string code,
                                         const PkcePair& pkce,
                                         std::string expected_state,
                                         std::string actual_state);
    TokenSet valid_token();
    TokenSet refresh();
    void revoke();

    [[nodiscard]] jarvis::security::egress::RequestEnvelope prepare_api_call(
        jarvis::security::egress::RequestEnvelope envelope,
        std::span<const uint8_t> serialized_payload);

    [[nodiscard]] const ProviderConfig& provider() const noexcept { return provider_; }

private:
    TokenSet parse_token_response(const HttpResponse& response) const;
    HttpResponse post_form(const std::string& host,
                           const std::string& path,
                           const std::map<std::string, std::string>& fields);
    void audit_token_event(std::string_view event_kind,
                           std::string_view outcome,
                           std::string_view reason) const;

    ProviderConfig provider_;
    OAuthClientRegistration registration_;
    TokenStore& token_store_;
    HttpTransport& transport_;
    jarvis::audit::TamperEvidentAuditLog* audit_log_{nullptr};
};

[[nodiscard]] ProviderConfig gemini_provider_config();
[[nodiscard]] ProviderConfig github_copilot_provider_config();
[[nodiscard]] std::vector<ProviderConfig> default_provider_configs();

[[nodiscard]] std::string form_encode(const std::map<std::string, std::string>& fields);
[[nodiscard]] std::string url_encode(std::string_view value);

}  // namespace jarvis::auth::oauth
