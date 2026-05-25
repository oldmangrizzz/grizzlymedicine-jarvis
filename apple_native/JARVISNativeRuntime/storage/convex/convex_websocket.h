#pragma once

#include <string>

namespace jarvis::storage::convex {

class ConvexWebSocketProbe {
public:
    explicit ConvexWebSocketProbe(std::string wss_url);
    bool host_is_allowed_and_pinned() const;

private:
    std::string url_;
    std::string host_;
};

} // namespace jarvis::storage::convex
