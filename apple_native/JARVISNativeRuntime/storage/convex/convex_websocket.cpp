#include "convex_websocket.h"

#include "../../security/cert_pinning.h"
#include "../../security/egress/egress_allowlist.h"

#include <libwebsockets.h>
#include <regex>
#include <stdexcept>

namespace jarvis::storage::convex {
namespace {
std::string host_from_wss(const std::string& url) {
    static const std::regex re(R"(^wss://([^/:]+)(?::443)?(?:/.*)?$)");
    std::smatch m;
    if (!std::regex_match(url, m, re)) throw std::runtime_error("Convex WSS URL must be wss://host[/path] on port 443");
    return m[1].str();
}
}

ConvexWebSocketProbe::ConvexWebSocketProbe(std::string wss_url)
    : url_(std::move(wss_url)), host_(host_from_wss(url_)) {}

bool ConvexWebSocketProbe::host_is_allowed_and_pinned() const {
    jarvis::security::egress::EgressAllowlist::global().enforce(host_, 443);
    return jarvis::security::CertPinStore::global().is_pinned(host_) && lws_get_library_version() != nullptr;
}

} // namespace jarvis::storage::convex
