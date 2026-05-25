#pragma once

#include "oauth_client.h"

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <optional>
#include <stdexcept>
#include <string>

extern "C" {
int32_t JARVISOAuthKeychainSave(const char* service, const char* account, const char* token_json);
char* JARVISOAuthKeychainLoad(const char* service, const char* account);
int32_t JARVISOAuthKeychainDelete(const char* service, const char* account);
void JARVISOAuthKeychainFree(char* ptr);
}

namespace jarvis::auth::oauth {

class SwiftKeychainTokenStore final : public TokenStore {
public:
    void save(const ProviderConfig& provider, const TokenSet& tokens) override {
        const auto json = token_json(tokens);
        if (JARVISOAuthKeychainSave(provider.service_name.c_str(), provider.id.c_str(), json.c_str()) != 0) {
            throw std::runtime_error("Swift Keychain bridge failed to save OAuth token for " + provider.id);
        }
    }

    std::optional<TokenSet> load(const ProviderConfig& provider) override {
        char* raw = JARVISOAuthKeychainLoad(provider.service_name.c_str(), provider.id.c_str());
        if (!raw) return std::nullopt;
        std::string json(raw);
        JARVISOAuthKeychainFree(raw);
        return parse_token_json(json);
    }

    void remove(const ProviderConfig& provider) override {
        if (JARVISOAuthKeychainDelete(provider.service_name.c_str(), provider.id.c_str()) != 0) {
            throw std::runtime_error("Swift Keychain bridge failed to delete OAuth token for " + provider.id);
        }
    }

private:
    static std::string escape(const std::string& value) {
        std::string out;
        for (char c : value) {
            if (c == '"' || c == '\\') out.push_back('\\');
            out.push_back(c);
        }
        return out;
    }

    static std::string token_json(const TokenSet& tokens) {
        const auto expires = std::chrono::duration_cast<std::chrono::seconds>(
            tokens.expires_at.time_since_epoch()).count();
        return "{\"accessToken\":\"" + escape(tokens.access_token) +
               "\",\"refreshToken\":\"" + escape(tokens.refresh_token) +
               "\",\"tokenType\":\"" + escape(tokens.token_type) +
               "\",\"scope\":\"" + escape(tokens.scope) +
               "\",\"expiresAtUnix\":" + std::to_string(expires) + "}";
    }

    static std::string json_string(const std::string& json, const std::string& key) {
        const std::string needle = "\"" + key + "\"";
        auto pos = json.find(needle);
        if (pos == std::string::npos) return {};
        pos = json.find(':', pos + needle.size());
        pos = json.find('"', pos == std::string::npos ? 0 : pos);
        if (pos == std::string::npos) return {};
        std::string out;
        for (++pos; pos < json.size(); ++pos) {
            if (json[pos] == '"') return out;
            if (json[pos] == '\\' && pos + 1 < json.size()) ++pos;
            out.push_back(json[pos]);
        }
        return {};
    }

    static int64_t json_int(const std::string& json, const std::string& key) {
        const std::string needle = "\"" + key + "\"";
        auto pos = json.find(needle);
        if (pos == std::string::npos) return 0;
        pos = json.find(':', pos + needle.size());
        if (pos == std::string::npos) return 0;
        auto end = json.find_first_of(",}", pos + 1);
        try { return std::stoll(json.substr(pos + 1, end - pos - 1)); } catch (...) { return 0; }
    }

    static TokenSet parse_token_json(const std::string& json) {
        TokenSet tokens;
        tokens.access_token = json_string(json, "accessToken");
        tokens.refresh_token = json_string(json, "refreshToken");
        tokens.token_type = json_string(json, "tokenType");
        tokens.scope = json_string(json, "scope");
        tokens.expires_at = std::chrono::system_clock::time_point(std::chrono::seconds(json_int(json, "expiresAtUnix")));
        if (tokens.token_type.empty()) tokens.token_type = "Bearer";
        return tokens;
    }
};

}  // namespace jarvis::auth::oauth
