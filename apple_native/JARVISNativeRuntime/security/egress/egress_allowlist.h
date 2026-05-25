// egress_allowlist.h
// JARVIS digital-personhood project — GMRI
//
// Hard-coded egress allowlist derived exclusively from the SPKI-pinned host
// table in security/pins_embedded.h.  The allowlist is the SOLE gate for
// every outbound socket connection in the JARVIS native runtime.
//
// Design guarantees:
//   • Fail-closed:  any host not in the list is DENIED.  No warn-only mode.
//   • Port 443 only:  every allowlisted host is restricted to HTTPS/WSS.
//   • Not runtime-configurable:  the list is hardcoded at build time.
//     Adding an endpoint requires a code change + rebuild + new SPKI pin.
//   • Singleton:  EgressAllowlist::global() is initialised once at startup
//     and is read-only thereafter.  Thread-safe.
//
// Usage:
//   // Before opening any socket:
//   EgressAllowlist::global().enforce("api.deepgram.com", 443);  // throws if denied
//   // or:
//   if (!EgressAllowlist::global().is_allowed(host, port)) { ... }
//
// C++20, no external dependencies (beyond pins_embedded.h).

#pragma once

#include <array>
#include <cstdint>
#include <exception>
#include <span>
#include <string>
#include <string_view>

namespace jarvis::security::egress {

// ── EgressDenied exception ────────────────────────────────────────────────────

/// Thrown by EgressAllowlist::enforce() when a host/port combination is not
/// on the allowlist.
///
/// The host name (cleartext) is included because it is a network destination,
/// not operator content — consistent with redacting_logger conventions.
/// The host_sha256_hex is a hex-encoded SHA-256(host) for log correlation
/// when the full host name should not appear inline.
struct EgressDenied : std::exception {
    std::string denied_host;        ///< cleartext host that was denied
    std::string host_sha256_hex;    ///< hex(SHA-256(denied_host)), 64 chars
    std::string message;

    explicit EgressDenied(std::string host, std::string sha256_hex);
    const char* what() const noexcept override { return message.c_str(); }
};

// ── EgressAllowlist ───────────────────────────────────────────────────────────

class EgressAllowlist {
public:
    // ── Singleton ─────────────────────────────────────────────────────────────
    /// Thread-safe after first call.  Read-only singleton.
    static const EgressAllowlist& global() noexcept;

    // ── Query ─────────────────────────────────────────────────────────────────

    /// Returns true iff `host` is in the hardcoded SPKI-pinned allowlist AND
    /// port == 443.  No wildcards.  Case-sensitive exact match on host.
    /// noexcept — safe to call from any context including signal handlers.
    [[nodiscard]] bool is_allowed(std::string_view host,
                                  uint16_t port) const noexcept;

    /// Like is_allowed() but throws EgressDenied if the check fails.
    /// Call this before every socket connect.  Callers MUST NOT catch and
    /// suppress the exception — it must propagate to the caller that initiated
    /// the outbound request.
    void enforce(std::string_view host, uint16_t port) const;

    /// The list of allowed hosts, in insertion order.
    /// Exposed for documentation and audit; do not build logic on the span.
    [[nodiscard]] std::span<const std::string_view> allowed_hosts() const noexcept;

private:
    EgressAllowlist();  // populates hosts_ from pins::kAllPins

    // Parallel arrays: hosts_[i] ↔ pins_embedded.h kAllPins[i].host
    static constexpr std::size_t kCount = 11;
    std::array<std::string_view, kCount> hosts_;
    std::size_t host_count_{0};
};

}  // namespace jarvis::security::egress
