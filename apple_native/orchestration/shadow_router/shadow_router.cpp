#include "shadow_router.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace jarvis::cutover::shadow {

FunctionOrganEndpoint::FunctionOrganEndpoint(std::function<OrganResponse(const OrganRequest&)> fn) : fn_(std::move(fn)) {}
OrganResponse FunctionOrganEndpoint::dispatch(const OrganRequest& request) { return fn_(request); }

UnixDomainSocketOrganEndpoint::UnixDomainSocketOrganEndpoint(std::string socket_path, std::chrono::milliseconds timeout)
    : socket_path_(std::move(socket_path)), timeout_(timeout) {}

OrganResponse UnixDomainSocketOrganEndpoint::dispatch(const OrganRequest& request) {
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) throw std::runtime_error("socket_failed");
    timeval tv{};
    tv.tv_sec = static_cast<int>(timeout_.count() / 1000);
    tv.tv_usec = static_cast<int>((timeout_.count() % 1000) * 1000);
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (socket_path_.size() >= sizeof(addr.sun_path)) {
        ::close(fd);
        throw std::runtime_error("socket_path_too_long");
    }
    std::strncpy(addr.sun_path, socket_path_.c_str(), sizeof(addr.sun_path) - 1);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        throw std::runtime_error("connect_failed:" + socket_path_);
    }
    const std::string wire = request.id + "\n" + request.payload + "\n";
    if (::send(fd, wire.data(), wire.size(), 0) != static_cast<ssize_t>(wire.size())) {
        ::close(fd);
        throw std::runtime_error("send_failed");
    }
    std::string out;
    char buf[4096];
    for (;;) {
        const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
        if (n > 0) out.append(buf, static_cast<std::size_t>(n));
        if (n <= 0 || out.find('\n') != std::string::npos) break;
    }
    ::close(fd);
    if (!out.empty() && out.back() == '\n') out.pop_back();
    return OrganResponse{out, 1.0};
}

ShadowRouter::ShadowRouter(std::string organ_name,
                           std::shared_ptr<OrganEndpoint> python,
                           std::shared_ptr<OrganEndpoint> native,
                           EquivalenceTolerance tolerance)
    : organ_name_(std::move(organ_name)), python_(std::move(python)), native_(std::move(native)), tolerance_(tolerance) {
    if (!python_ || !native_) throw std::invalid_argument("shadow_router_requires_both_organs");
}

void ShadowRouter::begin_shadow() { authority_ = Authority::shadow; }
void ShadowRouter::promote_native() { authority_ = Authority::native; }
void ShadowRouter::rollback_python() { authority_ = Authority::python; }

DispatchResult ShadowRouter::dispatch(const OrganRequest& request) {
    if (authority_ == Authority::native) return {native_->dispatch(request), Authority::native, std::nullopt};
    if (authority_ == Authority::python) return {python_->dispatch(request), Authority::python, std::nullopt};
    const auto py = python_->dispatch(request);
    const auto nat = native_->dispatch(request);
    auto divergence = compare(request, py, nat, tolerance_);
    if (divergence) divergences_.push_back(*divergence);
    return {py, Authority::shadow, divergence};
}

static std::optional<double> parse_double(std::string_view s) {
    try {
        size_t idx = 0;
        const double v = std::stod(std::string(s), &idx);
        return idx == s.size() ? std::optional<double>{v} : std::nullopt;
    } catch (...) { return std::nullopt; }
}

std::optional<DivergenceRecord> ShadowRouter::compare(const OrganRequest& request,
                                                      const OrganResponse& python,
                                                      const OrganResponse& native,
                                                      const EquivalenceTolerance& tolerance) {
    if (tolerance.mode == ToleranceMode::recall_at_1) {
        const bool match = python.payload == native.payload;
        const double recall = match ? 1.0 : 0.0;
        if (recall < tolerance.minimum) {
            return DivergenceRecord{request.id, python.payload, native.payload, "recall_at_1_below_minimum", 1.0 - recall};
        }
        return std::nullopt;
    }
    if (tolerance.mode == ToleranceMode::epsilon) {
        const auto py = parse_double(python.payload);
        const auto nat = parse_double(native.payload);
        if (py && nat) {
            const double delta = std::fabs(*py - *nat);
            if (delta > tolerance.epsilon) return DivergenceRecord{request.id, python.payload, native.payload, "epsilon_exceeded", delta};
            return std::nullopt;
        }
    }
    if (python.payload != native.payload) {
        return DivergenceRecord{request.id, python.payload, native.payload,
                                tolerance.identity_critical ? "identity_critical_mismatch" : "oracle_mismatch", 1.0};
    }
    return std::nullopt;
}

std::string to_string(Authority authority) {
    switch (authority) { case Authority::python: return "python"; case Authority::shadow: return "shadow"; case Authority::native: return "native"; }
    return "unknown";
}
std::string to_string(ToleranceMode mode) {
    switch (mode) { case ToleranceMode::bit_exact: return "bit_exact"; case ToleranceMode::oracle_exact: return "oracle_exact"; case ToleranceMode::epsilon: return "epsilon"; case ToleranceMode::recall_at_1: return "recall_at_1"; }
    return "oracle_exact";
}
ToleranceMode tolerance_mode_from_string(std::string_view value) {
    if (value == "bit_exact") return ToleranceMode::bit_exact;
    if (value == "epsilon") return ToleranceMode::epsilon;
    if (value == "recall_at_1") return ToleranceMode::recall_at_1;
    return ToleranceMode::oracle_exact;
}

} // namespace jarvis::cutover::shadow
