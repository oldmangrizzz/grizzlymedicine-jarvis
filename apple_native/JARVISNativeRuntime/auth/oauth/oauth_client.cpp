#include "oauth_client.h"

#include "../../integrity/audit/audit_event.h"
#include "../../integrity/audit/audit_log.h"
#include "../../security/egress/egress_allowlist.h"
#include "../../security/egress/egress_audit.h"
#include "../../logging/redacting_logger.h"

#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <sstream>

namespace jarvis::auth::oauth {
namespace {

std::string base64url(const uint8_t* data, std::size_t len) {
    const int out_len = 4 * static_cast<int>((len + 2) / 3);
    std::string out(static_cast<std::size_t>(out_len), '\0');
    EVP_EncodeBlock(reinterpret_cast<unsigned char*>(out.data()), data, static_cast<int>(len));
    for (char& c : out) {
        if (c == '+') c = '-';
        else if (c == '/') c = '_';
    }
    while (!out.empty() && out.back() == '=') out.pop_back();
    return out;
}

std::string json_value(std::string_view body, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    const auto pos = body.find(needle);
    if (pos == std::string_view::npos) return {};
    auto colon = body.find(':', pos + needle.size());
    if (colon == std::string_view::npos) return {};
    while (++colon < body.size() && std::isspace(static_cast<unsigned char>(body[colon]))) {}
    if (colon >= body.size()) return {};
    if (body[colon] == '"') {
        std::string out;
        for (std::size_t i = colon + 1; i < body.size(); ++i) {
            if (body[i] == '"') return out;
            if (body[i] == '\\' && i + 1 < body.size()) ++i;
            out.push_back(body[i]);
        }
        return {};
    }
    std::size_t end = colon;
    while (end < body.size() && body[end] != ',' && body[end] != '}') ++end;
    return std::string(body.substr(colon, end - colon));
}

int64_t json_int(std::string_view body, std::string_view key, int64_t fallback) {
    auto raw = json_value(body, key);
    if (raw.empty()) return fallback;
    try { return std::stoll(raw); } catch (...) { return fallback; }
}

std::string scope_join(const std::vector<std::string>& scopes) {
    std::string out;
    for (std::size_t i = 0; i < scopes.size(); ++i) {
        if (i) out += ' ';
        out += scopes[i];
    }
    return out;
}

}  // namespace

ReauthRequired::ReauthRequired(const std::string& provider_id)
    : std::runtime_error("OAuth refresh failed for " + provider_id + "; operator re-auth required") {}

ProviderConfig gemini_provider_config() {
    return ProviderConfig{
        .provider = OAuthProvider::Gemini,
        .id = "gemini",
        .display_name = "Google Gemini",
        .service_name = "org.gmri.jarvis.oauth.gemini",
        .auth_host = "accounts.google.com",
        .auth_path = "/o/oauth2/v2/auth",
        .token_host = "oauth2.googleapis.com",
        .token_path = "/token",
        .revoke_host = "oauth2.googleapis.com",
        .revoke_path = "/revoke",
        .api_host = "generativelanguage.googleapis.com",
        .scopes = {"https://www.googleapis.com/auth/generativelanguage"},
        .requests_per_minute = 60,
        .public_pkce_only = true,
        .public_revocation_supported = true,
    };
}

ProviderConfig github_copilot_provider_config() {
    return ProviderConfig{
        .provider = OAuthProvider::GitHubCopilot,
        .id = "github_copilot",
        .display_name = "GitHub Copilot",
        .service_name = "org.gmri.jarvis.oauth.github-copilot",
        .auth_host = "github.com",
        .auth_path = "/login/oauth/authorize",
        .token_host = "github.com",
        .token_path = "/login/oauth/access_token",
        .revoke_host = "",
        .revoke_path = "",
        .api_host = "api.githubcopilot.com",
        .scopes = {"read:user"},
        .requests_per_minute = 30,
        .public_pkce_only = true,
        .public_revocation_supported = false,
    };
}

std::vector<ProviderConfig> default_provider_configs() {
    return {gemini_provider_config(), github_copilot_provider_config()};
}

OAuthClient::OAuthClient(ProviderConfig provider,
                         OAuthClientRegistration registration,
                         TokenStore& token_store,
                         HttpTransport& transport,
                         jarvis::audit::TamperEvidentAuditLog* audit_log)
    : provider_(std::move(provider)), registration_(std::move(registration)),
      token_store_(token_store), transport_(transport), audit_log_(audit_log) {
    if (registration_.client_id.empty() || registration_.redirect_uri.empty()) {
        throw std::invalid_argument("OAuth registration requires client_id and redirect_uri");
    }
}

PkcePair OAuthClient::generate_pkce() {
    std::array<uint8_t, 32> random{};
    if (RAND_bytes(random.data(), static_cast<int>(random.size())) != 1) {
        throw std::runtime_error("RAND_bytes failed for OAuth PKCE verifier");
    }
    PkcePair pkce;
    pkce.verifier = base64url(random.data(), random.size());
    std::array<uint8_t, SHA256_DIGEST_LENGTH> digest{};
    SHA256(reinterpret_cast<const unsigned char*>(pkce.verifier.data()), pkce.verifier.size(), digest.data());
    pkce.challenge = base64url(digest.data(), digest.size());
    return pkce;
}

std::string OAuthClient::authorization_url(std::string state, const PkcePair& pkce) const {
    std::map<std::string, std::string> q{{"client_id", registration_.client_id},
                                         {"redirect_uri", registration_.redirect_uri},
                                         {"response_type", "code"},
                                         {"scope", scope_join(provider_.scopes)},
                                         {"state", std::move(state)},
                                         {"code_challenge", pkce.challenge},
                                         {"code_challenge_method", pkce.method},
                                         {"access_type", "offline"},
                                         {"prompt", "consent"}};
    return "https://" + provider_.auth_host + provider_.auth_path + "?" + form_encode(q);
}

TokenSet OAuthClient::exchange_authorization_code(std::string code, const PkcePair& pkce,
                                                  std::string expected_state,
                                                  std::string actual_state) {
    if (expected_state.empty() || expected_state != actual_state) {
        audit_token_event("OAUTH_TOKEN_GRANT", "denied", "state_mismatch");
        throw std::runtime_error("OAuth state mismatch");
    }
    auto response = post_form(provider_.token_host, provider_.token_path,
        {{"client_id", registration_.client_id}, {"code", std::move(code)},
         {"code_verifier", pkce.verifier}, {"grant_type", "authorization_code"},
         {"redirect_uri", registration_.redirect_uri}});
    auto tokens = parse_token_response(response);
    token_store_.save(provider_, tokens);
    audit_token_event("OAUTH_TOKEN_GRANT", "allowed", "pkce_authorization_code");
    return tokens;
}

TokenSet OAuthClient::valid_token() {
    auto stored = token_store_.load(provider_);
    if (!stored) throw ReauthRequired(provider_.id);
    if (stored->expires_at <= std::chrono::system_clock::now() + std::chrono::minutes(1)) {
        return refresh();
    }
    return *stored;
}

TokenSet OAuthClient::refresh() {
    auto stored = token_store_.load(provider_);
    if (!stored || stored->refresh_token.empty()) {
        audit_token_event("OAUTH_TOKEN_REFRESH", "denied", "missing_refresh_token");
        throw ReauthRequired(provider_.id);
    }
    auto response = post_form(provider_.token_host, provider_.token_path,
        {{"client_id", registration_.client_id}, {"grant_type", "refresh_token"},
         {"refresh_token", stored->refresh_token}});
    if (response.status < 200 || response.status >= 300) {
        token_store_.remove(provider_);
        audit_token_event("OAUTH_TOKEN_REFRESH", "denied", "provider_refresh_failed");
        throw ReauthRequired(provider_.id);
    }
    auto tokens = parse_token_response(response);
    if (tokens.refresh_token.empty()) tokens.refresh_token = stored->refresh_token;
    token_store_.save(provider_, tokens);
    audit_token_event("OAUTH_TOKEN_REFRESH", "allowed", "refresh_token");
    return tokens;
}

void OAuthClient::revoke() {
    auto stored = token_store_.load(provider_);
    if (stored && provider_.public_revocation_supported && !provider_.revoke_host.empty()) {
        auto token = !stored->refresh_token.empty() ? stored->refresh_token : stored->access_token;
        (void)post_form(provider_.revoke_host, provider_.revoke_path, {{"token", token}});
        audit_token_event("OAUTH_TOKEN_REVOKE", "allowed", "provider_revoke_called");
    } else if (stored) {
        audit_token_event("OAUTH_TOKEN_REVOKE", "deferred", "provider_public_revoke_unavailable");
    }
    token_store_.remove(provider_);
}

jarvis::security::egress::RequestEnvelope OAuthClient::prepare_api_call(
    jarvis::security::egress::RequestEnvelope envelope,
    std::span<const uint8_t> serialized_payload) {
    using namespace jarvis::security::egress;
    if (envelope.host.empty()) envelope.host = provider_.api_host;
    envelope.port = 443;
    EgressAllowlist::global().enforce(envelope.host, envelope.port);
    auto filtered = EgressFilter::global().filter(envelope.host, std::move(envelope));
    EgressAudit::instance().record(filtered, serialized_payload, EgressResult::Success);
    audit_token_event("OAUTH_API_CALL", "allowed", "egress_filtered_audited");
    return filtered;
}

TokenSet OAuthClient::parse_token_response(const HttpResponse& response) const {
    if (response.status < 200 || response.status >= 300) {
        throw std::runtime_error("OAuth token endpoint returned non-2xx");
    }
    TokenSet tokens;
    tokens.access_token = json_value(response.body, "access_token");
    tokens.refresh_token = json_value(response.body, "refresh_token");
    tokens.token_type = json_value(response.body, "token_type");
    tokens.scope = json_value(response.body, "scope");
    if (tokens.token_type.empty()) tokens.token_type = "Bearer";
    const auto expires = json_int(response.body, "expires_in", 3600);
    tokens.expires_at = std::chrono::system_clock::now() + std::chrono::seconds(expires);
    if (tokens.access_token.empty()) throw std::runtime_error("OAuth token response missing access_token");
    return tokens;
}

HttpResponse OAuthClient::post_form(const std::string& host, const std::string& path,
                                    const std::map<std::string, std::string>& fields) {
    using namespace jarvis::security::egress;
    EgressAllowlist::global().enforce(host, 443);
    auto body = form_encode(fields);
    RequestEnvelope envelope;
    envelope.host = host;
    envelope.port = 443;
    envelope.content_type = "application/x-www-form-urlencoded";
    auto filtered = EgressFilter::global().filter(host, std::move(envelope));
    HttpRequest req{"POST", host, path,
                    {{"Accept", "application/json"}, {"Content-Type", "application/x-www-form-urlencoded"}},
                    body};
    auto response = transport_.send(req);
    EgressAudit::instance().record(filtered,
        std::span<const uint8_t>{reinterpret_cast<const uint8_t*>(body.data()), body.size()},
        (response.status >= 200 && response.status < 300) ? EgressResult::Success : EgressResult::NetworkFail);
    return response;
}

void OAuthClient::audit_token_event(std::string_view event_kind,
                                    std::string_view outcome,
                                    std::string_view reason) const {
    jarvis::audit::AuditEvent event;
    event.event_kind = std::string(event_kind);
    event.actor = jarvis::audit::Actor::OPERATOR;
    event.subject = provider_.id;
    event.outcome = std::string(outcome);
    event.reason = std::string(reason);
    event.redacted_metadata = "{\"provider\":\"" + provider_.id + "\",\"service\":\"" + provider_.service_name + "\"}";
    if (audit_log_) {
        audit_log_->append(event);
    } else {
        jarvis::audit::TamperEvidentAuditLog default_log;
        default_log.append(event);
    }
    jarvis::logInfo("oauth", std::string(event_kind),
                    {jarvis::LogField::str("provider", provider_.id),
                     jarvis::LogField::str("outcome", std::string(outcome)),
                     jarvis::LogField::str("reason", std::string(reason))});
}

std::string url_encode(std::string_view value) {
    std::ostringstream out;
    const char* hex = "0123456789ABCDEF";
    for (unsigned char c : value) {
        if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') out << c;
        else { out << '%' << hex[c >> 4] << hex[c & 15]; }
    }
    return out.str();
}

std::string form_encode(const std::map<std::string, std::string>& fields) {
    std::string out;
    for (const auto& [k, v] : fields) {
        if (!out.empty()) out += '&';
        out += url_encode(k);
        out += '=';
        out += url_encode(v);
    }
    return out;
}

}  // namespace jarvis::auth::oauth
