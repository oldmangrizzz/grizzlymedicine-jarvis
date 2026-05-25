// deepgram_stt.cpp
// JARVIS digital-personhood project — GMRI
//
// Deepgram nova-2 WebSocket streaming STT — C++20 implementation.
// Operator-private: raw transcripts NEVER hit os_log or stdout.
// SPKI-pinned, fail-closed. API key from macOS Keychain.

#include "deepgram_stt.h"

#include "../../logging/redacting_logger.h"
#include "../../security/cert_pinning.h"
#include "../../security/pins_embedded.h"
#include "../../security/egress/egress_allowlist.h"
#include "../../security/egress/egress_audit.h"
#include "../../security/egress/egress_filter.h"
#include "../../integrity/audit/audit_event.h"
#include "../../integrity/audit/audit_log.h"

#include <libwebsockets.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/err.h>

#include <nlohmann/json.hpp>

#ifdef __APPLE__
#include <Security/Security.h>
#endif

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>

using json = nlohmann::json;
using namespace std::chrono_literals;

namespace jarvis::audio::stt_deepgram {

void SslCtxDeleter::operator()(ssl_ctx_st* ctx) const noexcept {
    if (ctx) SSL_CTX_free(ctx);
}

namespace {

constexpr const char* kAuditSubject = "wss://api.deepgram.com/v1/listen";

std::span<const uint8_t> bytes_view(const std::vector<uint8_t>& bytes, size_t offset = 0) {
    if (offset >= bytes.size()) return {};
    return {bytes.data() + offset, bytes.size() - offset};
}

std::string escape_json_value(std::string_view v) {
    std::string out;
    out.reserve(v.size() + 8);
    for (char c : v) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += c; break;
        }
    }
    return out;
}

}  // namespace

// ── SPKI pin verify callback ──────────────────────────────────────────────────
// Installed on the SSL_CTX provided to libwebsockets. Called by OpenSSL for
// each cert in the chain; we pin the leaf (depth 0).

struct SpkiVerifyData {
    std::string                              host;
    const jarvis::security::CertPinStore*   store;
    std::atomic<bool>*                       pin_rejected;
};

static int spki_verify_callback(int preverify_ok, X509_STORE_CTX* x509_ctx) {
    // Chain check must pass first
    if (!preverify_ok) return 0;

    // Only pin the leaf certificate
    int depth = X509_STORE_CTX_get_error_depth(x509_ctx);
    if (depth != 0) return 1;

    // Retrieve our context from SSL_CTX app data
    SSL* ssl = static_cast<SSL*>(
        X509_STORE_CTX_get_ex_data(x509_ctx, SSL_get_ex_data_X509_STORE_CTX_idx()));
    if (!ssl) return 0;
    SSL_CTX* ssl_ctx = SSL_get_SSL_CTX(ssl);
    if (!ssl_ctx) return 0;
    auto* vd = static_cast<SpkiVerifyData*>(SSL_CTX_get_app_data(ssl_ctx));
    if (!vd) return 0;  // fail closed if pinning context is missing

    X509* cert = X509_STORE_CTX_get_current_cert(x509_ctx);
    auto result = jarvis::security::validate_leaf_cert(cert, vd->host, *vd->store);
    if (result != jarvis::security::PinResult::Valid) {
        if (vd->pin_rejected) vd->pin_rejected->store(true);
        jarvis::logError("stt", "cert_pin_rejected", {
            jarvis::LogField::str("host", vd->host),
            jarvis::LogField::str("pin_result",
                jarvis::security::pin_result_cstr(result)),
        });
        return 0;  // fail-closed
    }
    return 1;
}

// ── macOS Keychain helper ─────────────────────────────────────────────────────

#ifdef __APPLE__
static std::string load_key_from_keychain(const std::string& service) {
    CFStringRef svc = CFStringCreateWithCString(
        kCFAllocatorDefault, service.c_str(), kCFStringEncodingUTF8);

    const void* keys[]   = {kSecClass, kSecAttrService, kSecReturnData, kSecMatchLimit};
    const void* values[] = {kSecClassGenericPassword, svc, kCFBooleanTrue, kSecMatchLimitOne};

    CFDictionaryRef query = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    CFTypeRef result = nullptr;
    OSStatus status = SecItemCopyMatching(query, &result);

    CFRelease(query);
    CFRelease(svc);

    if (status != errSecSuccess || !result) {
        jarvis::logError("stt", "keychain_lookup_failed", {
            jarvis::LogField::str("service", service),
            jarvis::LogField::num("osstatus", std::to_string(status)),
        });
        return {};
    }

    CFDataRef data = static_cast<CFDataRef>(result);
    std::string key(
        reinterpret_cast<const char*>(CFDataGetBytePtr(data)),
        static_cast<size_t>(CFDataGetLength(data)));
    CFRelease(result);
    return key;
}
#endif  // __APPLE__

// ── DeepgramStreamingClient ───────────────────────────────────────────────────

DeepgramStreamingClient::DeepgramStreamingClient(
    std::string    keychain_service,
    DeepgramConfig cfg)
    : key_ref_(ApiKeyRef::keychain(std::move(keychain_service)))
    , cfg_(std::move(cfg))
{}

DeepgramStreamingClient::DeepgramStreamingClient(ApiKeyRef key_ref, DeepgramConfig cfg)
    : key_ref_(std::move(key_ref))
    , cfg_(std::move(cfg))
{}

DeepgramStreamingClient::~DeepgramStreamingClient() = default;

std::string DeepgramStreamingClient::resolve_api_key() const {
    switch (key_ref_.source) {
        case ApiKeySource::Keychain:
#ifdef __APPLE__
            return load_key_from_keychain(key_ref_.ref);
#else
            return {};
#endif
        case ApiKeySource::EnvVar: {
            const char* v = std::getenv(key_ref_.ref.c_str());
            return v ? std::string(v) : std::string{};
        }
    }
    return {};
}

std::unique_ptr<SttSession> DeepgramStreamingClient::start_session() {
    std::string key = resolve_api_key();
    if (key.empty()) {
        throw std::runtime_error(
            "DeepgramStreamingClient: API key unavailable. "
            "Set it in the Keychain under service '" + key_ref_.ref + "'.");
    }

    DeepgramSession::ConnectParams p;
    p.api_key   = std::move(key);
    p.cfg       = cfg_;
    p.test_mode = (!cfg_.use_ssl || cfg_.skip_pin_check || cfg_.host == "127.0.0.1" || cfg_.host == "localhost");

    return std::make_unique<DeepgramSession>(std::move(p));
}

// ── libwebsockets protocol callback (C linkage trampoline) ───────────────────

static int deepgram_lws_callback(
    struct lws* wsi, enum lws_callback_reasons reason,
    void* user, void* in, size_t len)
{
    // lws passes the user data we set on the connection; for our sessions that
    // is a raw pointer to the DeepgramSession.
    auto* session = static_cast<DeepgramSession*>(
        lws_wsi_user(wsi) ? lws_wsi_user(wsi)
                           : user);
    if (!session) return 0;
    return session->lws_event(wsi, static_cast<int>(reason), in, len);
}

static struct lws_protocols kProtocols[] = {
    {
        "deepgram-stt",       // protocol name (must match Upgrade header)
        deepgram_lws_callback,
        0,                    // per-session data size (we manage externally)
        65536,                // rx buffer size
        0, nullptr, 0
    },
    { nullptr, nullptr, 0, 0, 0, nullptr, 0 }  // terminator
};

// ── DeepgramSession implementation ───────────────────────────────────────────

DeepgramSession::DeepgramSession(ConnectParams params)
    : params_(std::move(params))
    , audit_log_(std::make_unique<jarvis::audit::TamperEvidentAuditLog>(
          params_.cfg.audit_log_path))
{
    audit_session_event(jarvis::audit::EventKind::STT_SESSION_OPENED,
                        jarvis::audit::Outcome::ALLOWED);

    jarvis::logInfo("stt", "session_created", {
        jarvis::LogField::str("model",    params_.cfg.model),
        jarvis::LogField::str("language", params_.cfg.language),
        jarvis::LogField::str("host",     params_.cfg.host),
    });

    // Build the SSL context (SPKI pinning) before we launch the service thread.
    if (params_.cfg.use_ssl && !params_.cfg.skip_pin_check && !params_.test_mode) {
        if (!build_ssl_ctx()) {
            state_.store(SessionState::Error);
            return;
        }
    }

    // Launch libwebsockets service thread.
    service_thread_ = std::thread(&DeepgramSession::service_thread_main, this);
}

DeepgramSession::~DeepgramSession() {
    if (state_.load() != SessionState::Closed &&
        state_.load() != SessionState::Error) {
        close(2000);
    }
    stop_requested_.store(true);
    if (service_thread_.joinable()) service_thread_.join();

    if (lws_ctx_) {
        lws_context_destroy(lws_ctx_);
        lws_ctx_ = nullptr;
    }
    ssl_ctx_.reset();
    spki_verify_data_.reset();
}

// ── SSL_CTX construction with SPKI pinning ────────────────────────────────────

bool DeepgramSession::build_ssl_ctx() {
    std::unique_ptr<SSL_CTX, decltype(&SSL_CTX_free)> ctx(SSL_CTX_new(TLS_client_method()), SSL_CTX_free);
    if (!ctx) {
        jarvis::logError("stt", "ssl_ctx_alloc_failed", {});
        return false;
    }

    // Load system CA bundle so normal chain validation works
    if (SSL_CTX_set_default_verify_paths(ctx.get()) != 1) {
        jarvis::logWarn("stt", "ssl_default_verify_paths_failed", {});
    }

    SSL_CTX_set_verify(ctx.get(), SSL_VERIFY_PEER, spki_verify_callback);
    SSL_CTX_set_verify_depth(ctx.get(), 5);

    spki_verify_data_ = std::make_unique<SpkiVerifyData>(SpkiVerifyData{
        params_.cfg.host,
        &jarvis::security::CertPinStore::global(),
        &pin_rejected_
    });
    SSL_CTX_set_app_data(ctx.get(), spki_verify_data_.get());

    ssl_ctx_.reset(ctx.release());
    return true;
}

// ── Egress envelope, query string, and tamper-evident session audit ──────────

jarvis::security::egress::RequestEnvelope DeepgramSession::build_egress_envelope() const {
    const auto& c = params_.cfg;
    jarvis::security::egress::RequestEnvelope env;
    env.host = c.host;
    env.port = static_cast<uint16_t>(c.port);
    env.content_type = "audio/linear16";
    env.metadata["model"] = c.model;
    env.metadata["encoding"] = "linear16";
    env.metadata["sample_rate"] = "16000";
    env.raw_body = "streaming-audio-frame";
    return env;
}

std::string DeepgramSession::build_query_string() const {
    const auto filtered = jarvis::security::egress::EgressFilter::global().filter(
        params_.cfg.host, build_egress_envelope());

    std::ostringstream oss;
    oss << "model=" << filtered.metadata.at("model")
        << "&language=" << params_.cfg.language
        << "&encoding=" << filtered.metadata.at("encoding")
        << "&sample_rate=" << filtered.metadata.at("sample_rate")
        << "&channels=1"
        << "&interim_results=" << (params_.cfg.interim_results ? "true" : "false")
        << "&vad_events=" << (params_.cfg.vad_events ? "true" : "false")
        << "&endpointing=" << params_.cfg.endpointing_ms
        << "&smart_format=" << (params_.cfg.smart_format ? "true" : "false")
        << "&punctuate=" << (params_.cfg.punctuate ? "true" : "false");
    if (params_.cfg.diarize) oss << "&diarize=true";
    if (params_.cfg.mip_opt_out) oss << "&mip_opt_out=true";
    return oss.str();
}

void DeepgramSession::audit_session_event(std::string event_kind,
                                           std::string outcome,
                                           std::string reason) noexcept {
    if (!audit_log_) return;
    try {
        jarvis::audit::AuditEvent e;
        e.event_kind = std::move(event_kind);
        e.actor = jarvis::audit::Actor::SELF;
        e.subject = kAuditSubject;
        e.outcome = std::move(outcome);
        e.reason = std::move(reason);
        e.redacted_metadata = std::string{"{\"host\":\""} +
            escape_json_value(params_.cfg.host) + "\",\"path\":\"/v1/listen\"}";
        audit_log_->append(std::move(e));
    } catch (...) {
        jarvis::logError("stt", "tamper_audit_append_failed", {});
    }
}

// ── Service thread ─────────────────────────────────────────────────────────────

void DeepgramSession::service_thread_main() {
    attempt_connect();

    while (!stop_requested_.load()) {
        if (lws_ctx_) {
            lws_service(lws_ctx_, 50 /* ms poll timeout */);
        } else {
            std::this_thread::sleep_for(50ms);
        }

        auto s = state_.load();

        // If close was requested, issue lws_callback_on_writable from here
        // (the service thread), where it is guaranteed to be processed.
        // close() uses lws_cancel_service() to wake us up promptly; we then
        // do the writable request ourselves so drain_audio_queue() can send
        // CloseStream from the correct thread context.
        if (close_requested_.load() &&
            s == SessionState::Closing &&
            wsi_ != nullptr)
        {
            lws_callback_on_writable(wsi_);
        }

        // Handle reconnect: destroy old context and create new one outside callback
        if (s == SessionState::Error && !stop_requested_.load() &&
            !pin_rejected_.load())
        {
            auto now = std::chrono::steady_clock::now();
            if (now >= reconnect_until_) {
                // Safe to destroy here — we are NOT inside a lws callback
                if (lws_ctx_) {
                    lws_context_destroy(lws_ctx_);
                    lws_ctx_ = nullptr;
                    wsi_     = nullptr;
                }
                state_.store(SessionState::Connecting);
                attempt_connect();
            }
        }

        // Handle close completion
        if (s == SessionState::Closing) {
            std::unique_lock<std::mutex> lk(close_mutex_);
            if (server_closed_) {
                state_.store(SessionState::Closed);
                close_cv_.notify_all();
                break;
            }
        }

        if (s == SessionState::Closed) break;
    }
}

void DeepgramSession::attempt_connect() {
    if (!params_.test_mode) {
        try {
            jarvis::security::egress::EgressAllowlist::global().enforce(
                params_.cfg.host, static_cast<uint16_t>(params_.cfg.port));
        } catch (const jarvis::security::egress::EgressDenied&) {
            audit_session_event(jarvis::audit::EventKind::EGRESS_DENIED,
                                jarvis::audit::Outcome::DENIED,
                                "allowlist_miss");
            auto env = build_egress_envelope();
            jarvis::security::egress::EgressAudit::instance().record(
                env, {}, jarvis::security::egress::EgressResult::DeniedByAllowlist);
            state_.store(SessionState::Error);
            dispatch_error("egress_denied");
            return;
        }
    }

    if (lws_ctx_) {
        lws_context_destroy(lws_ctx_);
        lws_ctx_ = nullptr;
        wsi_     = nullptr;
    }
    // Reset transient connection state for the new attempt.
    {
        std::lock_guard<std::mutex> lk(close_mutex_);
        server_closed_ = false;
        close_sent_    = false;
    }

    lws_context_creation_info info{};
    info.port     = CONTEXT_PORT_NO_LISTEN;
    info.protocols = kProtocols;
    // Do NOT set LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT — it is a server option
    // and causes client SSL init failures in subsequent sessions.
    // SSL for this client connection is handled by provided_client_ssl_ctx below.
    info.options  = 0;
    info.gid      = -1;
    info.uid      = -1;

    if (ssl_ctx_) {
        info.provided_client_ssl_ctx = ssl_ctx_.get();
    }

    lws_ctx_ = lws_create_context(&info);
    if (!lws_ctx_) {
        jarvis::logError("stt", "lws_context_create_failed", {});
        state_.store(SessionState::Error);
        return;
    }

    std::string query = build_query_string();
    std::string uri   = params_.cfg.path + "?" + query;

    lws_client_connect_info ccinfo{};
    ccinfo.context        = lws_ctx_;
    ccinfo.address        = params_.cfg.host.c_str();
    ccinfo.port           = params_.cfg.port;
    ccinfo.path           = uri.c_str();
    ccinfo.host           = params_.cfg.host.c_str();
    ccinfo.origin         = params_.cfg.host.c_str();
    ccinfo.protocol       = kProtocols[0].name;
    ccinfo.ssl_connection = params_.cfg.use_ssl ? LCCSCF_USE_SSL : 0;
    ccinfo.userdata       = this;

    wsi_ = lws_client_connect_via_info(&ccinfo);
    if (!wsi_) {
        jarvis::logError("stt", "lws_connect_failed", {
            jarvis::LogField::str("host", params_.cfg.host),
        });
        state_.store(SessionState::Error);
        // Schedule backoff reconnect
        schedule_reconnect();
    }
}

void DeepgramSession::schedule_reconnect() {
    if (pin_rejected_.load() || stop_requested_.load()) return;

    int count = reconnect_count_.fetch_add(1);
    double base   = params_.cfg.reconnect_base_sec;
    double mx     = params_.cfg.reconnect_max_sec;
    double jfrac  = params_.cfg.reconnect_jitter_frac;
    double delay  = std::min(base * (1 << std::min(count, 5)), mx);

    std::mt19937 rng(std::random_device{}());
    std::uniform_real_distribution<double> jitter(
        1.0 - jfrac, 1.0 + jfrac);
    delay *= jitter(rng);
    delay  = std::min(delay, mx);

    jarvis::logWarn("stt", "reconnect_scheduled", {
        jarvis::LogField::num("attempt",   std::to_string(count + 1)),
        jarvis::LogField::num("delay_sec", std::to_string(delay)),
    });

    reconnect_until_ = std::chrono::time_point_cast<std::chrono::steady_clock::duration>(
        std::chrono::steady_clock::now() + std::chrono::duration<double>(delay));

    dispatch_error("network");
    // NOTE: Do NOT destroy lws_ctx_ here — this may be called from within the
    // lws callback, and destroying the context from inside a callback is unsafe.
    // The service_thread_main() loop will detect state_==Error and handle
    // context destruction + reconnect OUTSIDE the callback.
}

// ── libwebsockets event handler ────────────────────────────────────────────────

int DeepgramSession::lws_event(struct lws* wsi, int reason, void* in, size_t len) {
    switch (static_cast<lws_callback_reasons>(reason)) {

    case LWS_CALLBACK_CLIENT_ESTABLISHED:
        state_.store(SessionState::Open);
        first_audio_sent_.store(false);
        first_interim_received_.store(false);
        audit_session_event(jarvis::audit::EventKind::STT_SESSION_CONNECTED,
                            jarvis::audit::Outcome::ALLOWED);
        if (!params_.test_mode) {
            auto env = build_egress_envelope();
            jarvis::security::egress::EgressAudit::instance().record(
                env, {}, jarvis::security::egress::EgressResult::Success);
        }
        jarvis::logInfo("stt", "wss_connected", {
            jarvis::LogField::str("host", params_.cfg.host),
        });
        // Immediately request writable to drain any queued audio
        lws_callback_on_writable(wsi);
        break;

    case LWS_CALLBACK_CLIENT_WRITEABLE:
        return drain_audio_queue(wsi);

    case LWS_CALLBACK_CLIENT_RECEIVE: {
        std::string_view msg(static_cast<const char*>(in), len);
        handle_server_message(msg);
        break;
    }

    case LWS_CALLBACK_CLIENT_CONNECTION_ERROR: {
        std::string reason_str = in
            ? std::string(static_cast<const char*>(in), len)
            : "unknown";
        jarvis::logError("stt", "wss_connection_error", {
            jarvis::LogField::str("reason", reason_str),
        });
        wsi_ = nullptr;  // lws destroys wsi after this callback
        // Check if it was a pin rejection
        if (pin_rejected_.load()) {
            audit_session_event(jarvis::audit::EventKind::STT_SESSION_ERROR,
                                jarvis::audit::Outcome::DENIED,
                                "pin_mismatch");
            if (!params_.test_mode) {
                auto env = build_egress_envelope();
                jarvis::security::egress::EgressAudit::instance().record(
                    env, {}, jarvis::security::egress::EgressResult::CertPinFail);
            }
            dispatch_error("pin_mismatch");
            state_.store(SessionState::Error);
        } else {
            audit_session_event(jarvis::audit::EventKind::STT_SESSION_ERROR,
                                jarvis::audit::Outcome::DEFERRED,
                                "network");
            if (!params_.test_mode) {
                auto env = build_egress_envelope();
                jarvis::security::egress::EgressAudit::instance().record(
                    env, {}, jarvis::security::egress::EgressResult::NetworkFail);
            }
            state_.store(SessionState::Error);
            schedule_reconnect();
        }
        break;
    }

    case LWS_CALLBACK_CLIENT_CLOSED:
        wsi_ = nullptr;  // lws destroys wsi after this callback
        jarvis::logInfo("stt", "wss_closed", {});
        {
            std::lock_guard<std::mutex> lk(close_mutex_);
            server_closed_ = true;
        }
        close_cv_.notify_all();
        if (state_.load() != SessionState::Closing) {
            // Unexpected close from server; reconnect
            state_.store(SessionState::Error);
            schedule_reconnect();
        }
        break;

    default:
        break;
    }
    return 0;
}

// ── Audio drain ────────────────────────────────────────────────────────────────

int DeepgramSession::drain_audio_queue(struct lws* wsi) {
    // If close was requested, send CloseStream and initiate WS close
    if (close_requested_.exchange(false)) {
        const char* close_msg = R"({"type":"CloseStream"})";
        size_t len = std::strlen(close_msg);
        std::vector<uint8_t> buf(LWS_PRE + len);
        std::memcpy(buf.data() + LWS_PRE, close_msg, len);
        lws_write(wsi, buf.data() + LWS_PRE, len, LWS_WRITE_TEXT);
        {
            std::lock_guard<std::mutex> lk(close_mutex_);
            close_sent_ = true;
        }
        // Initiate the WebSocket close handshake
        lws_close_reason(wsi, LWS_CLOSE_STATUS_NORMAL, nullptr, 0);
        return -1;  // lws will close this connection
    }

    if (state_.load() != SessionState::Open) return 0;

    // Send up to one chunk of audio per writable event.
    // Deepgram recommends 20-100ms frames; we batch up to 20ms = 320 samples.
    constexpr size_t kChunkSamples = 320; // 20ms @ 16kHz
    std::vector<int16_t> chunk;
    chunk.reserve(kChunkSamples);

    {
        std::lock_guard<std::mutex> lk(audio_mutex_);
        size_t n = std::min(audio_queue_.size(), kChunkSamples);
        if (n == 0) return 0;
        chunk.assign(audio_queue_.begin(), audio_queue_.begin() + n);
        audio_queue_.erase(audio_queue_.begin(), audio_queue_.begin() + n);
    }

    if (chunk.empty()) return 0;

    // libwebsockets requires LWS_PRE bytes of padding before the payload.
    size_t payload_bytes = chunk.size() * sizeof(int16_t);
    std::vector<uint8_t> buf(LWS_PRE + payload_bytes);
    std::memcpy(buf.data() + LWS_PRE, chunk.data(), payload_bytes);

    int written = lws_write(wsi,
        buf.data() + LWS_PRE,
        payload_bytes,
        LWS_WRITE_BINARY);

    if (written < 0) {
        jarvis::logError("stt", "lws_write_failed", {
            jarvis::LogField::num("written", std::to_string(written)),
        });
        if (!params_.test_mode) {
            auto env = build_egress_envelope();
            jarvis::security::egress::EgressAudit::instance().record(
                env, bytes_view(buf, LWS_PRE), jarvis::security::egress::EgressResult::NetworkFail);
        }
        return -1;
    }

    if (!params_.test_mode) {
        auto env = build_egress_envelope();
        jarvis::security::egress::EgressAudit::instance().record(
            env, bytes_view(buf, LWS_PRE), jarvis::security::egress::EgressResult::Success);
    }

    // Track first audio for latency measurement
    if (!first_audio_sent_.exchange(true)) {
        first_audio_time_ = std::chrono::steady_clock::now();
    }

    // If more audio in queue, request another writable immediately
    {
        std::lock_guard<std::mutex> lk(audio_mutex_);
        if (!audio_queue_.empty()) {
            lws_callback_on_writable(wsi);
        }
    }

    // If we're closing, send the CloseStream control message after draining
    {
        std::lock_guard<std::mutex> lk(close_mutex_);
        if (close_sent_) return 0;
        // Check if queue is now empty and close was requested
    }

    return 0;
}

// ── JSON message parsing ───────────────────────────────────────────────────────

void DeepgramSession::handle_server_message(std::string_view json_text) {
    json msg;
    try {
        msg = json::parse(json_text);
    } catch (const json::exception& e) {
        jarvis::logWarn("stt", "json_parse_error", {
            jarvis::LogField::str("error", e.what()),
        });
        return;
    }

    auto type_it = msg.find("type");
    if (type_it == msg.end() || !type_it->is_string()) return;
    std::string type = type_it->get<std::string>();

    if (type == "Results") {
        bool is_final = msg.value("is_final", false);

        // Extract transcript
        std::string transcript;
        double confidence = 0.0;
        double start_sec  = msg.value("start", 0.0);
        double dur_sec    = msg.value("duration", 0.0);
        std::optional<int> speaker_id;
        std::vector<WordResult> words;

        try {
            auto& alt = msg.at("channel").at("alternatives").at(0);
            transcript = alt.value("transcript", std::string{});
            confidence = alt.value("confidence", 0.0);

            if (alt.contains("words") && alt["words"].is_array()) {
                for (auto& w : alt["words"]) {
                    WordResult wr;
                    wr.word             = w.value("word", std::string{});
                    wr.punctuated_word  = w.value("punctuated_word", wr.word);
                    wr.start_sec        = w.value("start", 0.0);
                    wr.end_sec          = w.value("end", 0.0);
                    wr.confidence       = w.value("confidence", 0.0);
                    wr.speaker          = w.value("speaker", -1);
                    if (wr.speaker >= 0 && !speaker_id) speaker_id = wr.speaker;
                    words.push_back(std::move(wr));
                }
            }
        } catch (const json::exception&) {
            // Malformed; abstain (same discipline as Python baseline)
        }

        if (is_final) {
            FinalResult r;
            r.text         = transcript;
            r.confidence   = confidence;
            r.start_ms     = start_sec * 1000.0;
            r.end_ms       = (start_sec + dur_sec) * 1000.0;
            r.speaker_id   = speaker_id;
            r.words        = std::move(words);
            r.speech_final = msg.value("speech_final", false);

            // Measure first-interim → final path (best effort)
            if (!first_interim_received_.load()) {
                // final arrived before any interim; that's the first result
                if (first_audio_sent_.load()) {
                    auto now = std::chrono::steady_clock::now();
                    double ms = std::chrono::duration<double, std::milli>(
                        now - first_audio_time_).count();
                    jarvis::logInfo("stt", "first_final_latency", {
                        jarvis::LogField::num("latency_ms", std::to_string(ms)),
                    });
                }
            }

            jarvis::logInfo("stt", "final_transcript", {
                // text field is redacted by RedactingLogger
                jarvis::LogField::str("transcript", r.text),
                jarvis::LogField::num("confidence",  std::to_string(r.confidence)),
                jarvis::LogField::num("start_ms",    std::to_string(r.start_ms)),
                jarvis::LogField::num("end_ms",      std::to_string(r.end_ms)),
            });

            dispatch_final(std::move(r));
        } else {
            // Interim: log at TRACE (redacted)
            if (first_audio_sent_.load() && !first_interim_received_.exchange(true)) {
                first_interim_time_ = std::chrono::steady_clock::now();
                double ms = std::chrono::duration<double, std::milli>(
                    first_interim_time_ - first_audio_time_).count();
                jarvis::logInfo("stt", "first_interim_latency", {
                    jarvis::LogField::num("latency_ms", std::to_string(ms)),
                });
            }

            jarvis::log(jarvis::LogLevel::TRACE, "stt", "interim_transcript", {
                jarvis::LogField::str("transcript", transcript),
            });

            dispatch_interim(transcript);
        }

    } else if (type == "UtteranceEnd") {
        double last_word_end = msg.value("last_word_end", 0.0);
        // Convert to ms; treat as silence at the endpoint
        dispatch_endpoint(last_word_end * 1000.0);

    } else if (type == "SpeechStarted") {
        jarvis::logInfo("stt", "speech_started", {
            jarvis::LogField::num("timestamp_sec",
                std::to_string(msg.value("timestamp", 0.0))),
        });

    } else if (type == "Metadata") {
        jarvis::logInfo("stt", "deepgram_metadata", {
            jarvis::LogField::str("request_id", msg.value("request_id", std::string{})),
        });

    } else {
        jarvis::logInfo("stt", "unknown_message_type", {
            jarvis::LogField::str("type", type),
        });
    }
}

// ── SttSession interface implementation ───────────────────────────────────────

void DeepgramSession::feed_audio(std::span<const int16_t> pcm) {
    auto s = state_.load();
    if (s != SessionState::Open && s != SessionState::Connecting) return;

    {
        std::lock_guard<std::mutex> lk(audio_mutex_);
        if (audio_queue_.size() + pcm.size() > kMaxAudioQueueSamples) {
            // Drop oldest to make room (back-pressure protection)
            size_t drop = (audio_queue_.size() + pcm.size()) - kMaxAudioQueueSamples;
            audio_queue_.erase(audio_queue_.begin(), audio_queue_.begin() + drop);
            jarvis::logWarn("stt", "audio_buffer_overflow", {
                jarvis::LogField::num("dropped_samples", std::to_string(drop)),
            });
        }
        audio_queue_.insert(audio_queue_.end(), pcm.begin(), pcm.end());
    }

    // Request writable callback (must be called from the lws service thread context,
    // so we schedule it safely)
    if (wsi_ && state_.load() == SessionState::Open) {
        lws_callback_on_writable(wsi_);
    }
}

void DeepgramSession::on_interim(std::function<void(std::string_view)> cb) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    cb_interim_ = std::move(cb);
}

void DeepgramSession::on_final(std::function<void(FinalResult)> cb) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    cb_final_ = std::move(cb);
}

void DeepgramSession::on_endpoint(std::function<void(SilenceMs)> cb) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    cb_endpoint_ = std::move(cb);
}

void DeepgramSession::on_error(std::function<void(std::string_view)> cb) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    cb_error_ = std::move(cb);
}

void DeepgramSession::close(int timeout_ms) {
    auto s = state_.load();
    if (s == SessionState::Closed || s == SessionState::Error) return;
    if (s == SessionState::Closing) {
        // Already closing; just wait
        std::unique_lock<std::mutex> lk(close_mutex_);
        close_cv_.wait_for(lk,
            std::chrono::milliseconds(timeout_ms),
            [this]{ return server_closed_; });
        return;
    }

    // Wake service thread via lws_cancel_service() (explicitly thread-safe).
    // The service thread will call lws_callback_on_writable(wsi_) from its
    // own context after returning from lws_service().
    state_.store(SessionState::Closing);
    close_requested_.store(true);
    if (lws_ctx_) {
        lws_cancel_service(lws_ctx_);  // thread-safe; wakes lws_service() immediately
    }

    // Wait for the server to acknowledge the close
    std::unique_lock<std::mutex> lk(close_mutex_);
    close_cv_.wait_for(lk,
        std::chrono::milliseconds(timeout_ms),
        [this]{ return server_closed_; });

    state_.store(SessionState::Closed);
    audit_session_event(jarvis::audit::EventKind::STT_SESSION_CLOSED,
                        jarvis::audit::Outcome::PASS);
    jarvis::logInfo("stt", "session_closed", {});
}

SessionState DeepgramSession::state() const noexcept {
    return state_.load();
}

// ── Dispatch helpers ──────────────────────────────────────────────────────────

void DeepgramSession::dispatch_interim(std::string text) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    if (cb_interim_) cb_interim_(text);
}

void DeepgramSession::dispatch_final(FinalResult result) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    if (cb_final_) cb_final_(std::move(result));
}

void DeepgramSession::dispatch_endpoint(double silence_ms) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    if (cb_endpoint_) cb_endpoint_(silence_ms);
}

void DeepgramSession::dispatch_error(std::string reason) {
    std::lock_guard<std::mutex> lk(cb_mutex_);
    if (cb_error_) cb_error_(reason);
}

}  // namespace jarvis::audio::stt_deepgram
