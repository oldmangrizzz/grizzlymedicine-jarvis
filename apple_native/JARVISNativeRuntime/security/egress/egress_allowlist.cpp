// egress_allowlist.cpp
// JARVIS digital-personhood project — GMRI

#include "egress_allowlist.h"
#include "../pins_embedded.h"

#include <openssl/sha.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <sstream>

namespace jarvis::security::egress {

// ── Helpers ───────────────────────────────────────────────────────────────────

static std::string sha256_hex(std::string_view input) {
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(reinterpret_cast<const unsigned char*>(input.data()),
           input.size(), digest);
    char hex[SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < SHA256_DIGEST_LENGTH; ++i) {
        std::snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    }
    return {hex, SHA256_DIGEST_LENGTH * 2};
}

// ── EgressDenied ──────────────────────────────────────────────────────────────

EgressDenied::EgressDenied(std::string host, std::string sha256_hex_str)
    : denied_host(std::move(host))
    , host_sha256_hex(std::move(sha256_hex_str))
{
    message = "EgressDenied: host not in allowlist — host=" + denied_host
              + " sha256=" + host_sha256_hex.substr(0, 16) + "...";
}

// ── EgressAllowlist ───────────────────────────────────────────────────────────

EgressAllowlist::EgressAllowlist() {
    // Derive the list directly from the SPKI pin table.
    // This is the only authoritative source; do not add hosts elsewhere.
    static_assert(pins::kAllPins.size() == kCount,
                  "EgressAllowlist::kCount must match pins::kAllPins.size()");
    for (std::size_t i = 0; i < kCount; ++i) {
        hosts_[i] = pins::kAllPins[i].host;
    }
    host_count_ = kCount;
}

const EgressAllowlist& EgressAllowlist::global() noexcept {
    static const EgressAllowlist instance;
    return instance;
}

bool EgressAllowlist::is_allowed(std::string_view host,
                                  uint16_t port) const noexcept {
    if (port != 443) return false;
    for (std::size_t i = 0; i < host_count_; ++i) {
        if (hosts_[i] == host) return true;
    }
    return false;
}

void EgressAllowlist::enforce(std::string_view host, uint16_t port) const {
    if (!is_allowed(host, port)) {
        throw EgressDenied(std::string(host), sha256_hex(host));
    }
}

std::span<const std::string_view> EgressAllowlist::allowed_hosts() const noexcept {
    return {hosts_.data(), host_count_};
}

}  // namespace jarvis::security::egress
