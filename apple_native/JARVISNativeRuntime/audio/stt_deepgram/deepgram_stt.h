// deepgram_stt.h
// JARVIS digital-personhood project — GMRI
//
// DeepgramStreamingClient: WebSocket streaming STT client for Deepgram nova-2.
//
// Usage:
//   DeepgramStreamingClient client("jarvis.deepgram"); // Keychain service name
//   auto session = client.start_session();
//   session->on_final([](FinalResult r){ process(r); });
//   session->on_interim([](std::string_view t){ show_partial(t); });
//   // Feed audio from AudioFrontend callbacks
//   session->close();
//
// Security:
//   • API key loaded from macOS Keychain (SecItemCopyMatching). Never embedded.
//   • SPKI pinned against pins_embedded.h kDeepgram set. Fail-closed.
//   • Raw transcripts never reach os_log. All through RedactingLogger.
//
// Networking:
//   • WSS to api.deepgram.com/v1/listen
//   • libwebsockets 4.x with OpenSSL backend
//   • Exponential backoff reconnect (base 1s, max 30s, ±25% jitter)
//
// Audio format expected by feed_audio(): PCM16 mono 16 kHz

#pragma once

#include "stt_session.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

// Forward declare lws/OpenSSL types to avoid pulling C headers into every TU.
struct lws_context;
struct lws;
struct ssl_ctx_st;

namespace jarvis::audit { class TamperEvidentAuditLog; }
namespace jarvis::security::egress { struct RequestEnvelope; }

namespace jarvis::audio::stt_deepgram {

struct SpkiVerifyData;

struct SslCtxDeleter {
    void operator()(ssl_ctx_st* ctx) const noexcept;
};

// ── Key reference ────────────────────────────────────────────────────────────

/// How the client loads its Deepgram API key.
enum class ApiKeySource : uint8_t {
    Keychain,   // macOS Keychain (default, production)
    EnvVar,     // DEEPGRAM_API_KEY env var (operator config / CI)
};

struct ApiKeyRef {
    ApiKeySource source{ApiKeySource::Keychain};
    std::string  ref;   // service name (Keychain), var name (EnvVar), or literal

    static ApiKeyRef keychain(std::string service = "JARVIS_DEEPGRAM_API_KEY") {
        return {ApiKeySource::Keychain, std::move(service)};
    }
    static ApiKeyRef env(std::string var = "DEEPGRAM_API_KEY") {
        return {ApiKeySource::EnvVar, std::move(var)};
    }
};

// ── Config ────────────────────────────────────────────────────────────────────

struct DeepgramConfig {
    // Deepgram model / language
    std::string model{"nova-2"};
    std::string language{"en"};

    // Streaming features
    bool interim_results{true};
    bool vad_events{true};
    int  endpointing_ms{350};

    // Privacy
    bool mip_opt_out{true};    // opt out of Deepgram model improvement program
    bool smart_format{true};
    bool punctuate{true};
    bool diarize{false};       // speaker diarization (adds latency)

    // Reconnect policy
    double reconnect_base_sec{1.0};
    double reconnect_max_sec{30.0};
    double reconnect_jitter_frac{0.25};

    // WSS endpoint (override for testing)
    std::string host{"api.deepgram.com"};
    int         port{443};
    std::string path{"/v1/listen"};
    bool        use_ssl{true};
    bool        skip_pin_check{false};  // MUST remain false in production

    // Tamper-evident audit log path. The HMAC key must be installed by the Secure Enclave bridge.
    std::string audit_log_path{"~/.jarvis/audit.log"};
    std::string audit_key_path{};
};

// ── Client ────────────────────────────────────────────────────────────────────

class DeepgramStreamingClient {
public:
    /// Construct with Keychain service name (production default).
    /// Equivalent to: DeepgramStreamingClient(ApiKeyRef::keychain(keychain_service))
    explicit DeepgramStreamingClient(
        std::string        keychain_service = "JARVIS_DEEPGRAM_API_KEY",
        DeepgramConfig     cfg              = {}
    );

    /// Construct with explicit key source (test / CI).
    DeepgramStreamingClient(ApiKeyRef key_ref, DeepgramConfig cfg = {});

    ~DeepgramStreamingClient();

    // Non-copyable, moveable
    DeepgramStreamingClient(const DeepgramStreamingClient&)            = delete;
    DeepgramStreamingClient& operator=(const DeepgramStreamingClient&) = delete;
    DeepgramStreamingClient(DeepgramStreamingClient&&)                 = default;
    DeepgramStreamingClient& operator=(DeepgramStreamingClient&&)      = default;

    /// Open a new streaming session. Connects to Deepgram WSS.
    /// Throws std::runtime_error if the API key is unavailable.
    /// The session transitions to Error state (not throws) on pin mismatch
    /// detected during the TLS handshake — check session->state() and on_error.
    [[nodiscard]] std::unique_ptr<SttSession> start_session();

    const DeepgramConfig& config() const noexcept { return cfg_; }

private:
    std::string    resolve_api_key() const;

    ApiKeyRef      key_ref_;
    DeepgramConfig cfg_;
};

// ── Internal: DeepgramSession (public for tests) ─────────────────────────────
// Concrete SttSession. Exposed in the header so tests can introspect state.
// Normal callers use the SttSession* interface.

class DeepgramSession final : public SttSession {
public:
    struct ConnectParams {
        std::string api_key;
        DeepgramConfig cfg;
        bool test_mode{false};   // suppress pin check (for mock WSS servers)
    };

    explicit DeepgramSession(ConnectParams params);
    ~DeepgramSession() override;

    // SttSession interface
    void feed_audio(std::span<const int16_t> pcm) override;
    void on_interim(std::function<void(std::string_view)> cb) override;
    void on_final(std::function<void(FinalResult)>        cb) override;
    void on_endpoint(std::function<void(SilenceMs)>       cb) override;
    void on_error(std::function<void(std::string_view)>   cb) override;
    void close(int timeout_ms = 5000) override;
    [[nodiscard]] SessionState state() const noexcept override;

    // For testing: expose metrics
    [[nodiscard]] int  reconnect_count()   const noexcept { return reconnect_count_.load(); }
    [[nodiscard]] bool cert_pin_rejected() const noexcept { return pin_rejected_.load(); }

    // ── libwebsockets callback (must be public; called via C function pointer)
    int lws_event(struct lws* wsi, int reason, void* in, size_t len);

private:
    void     service_thread_main();
    void     attempt_connect();
    bool     build_ssl_ctx();             // creates SSL_CTX with SPKI pin callback
    void     schedule_reconnect();
    void     dispatch_interim(std::string text);
    void     dispatch_final(FinalResult result);
    void     dispatch_endpoint(double silence_ms);
    void     dispatch_error(std::string reason);

    // Called from lws callback on LWS_CALLBACK_CLIENT_WRITEABLE
    int      drain_audio_queue(struct lws* wsi);

    // Build the WSS query string from config after the egress filter has run.
    std::string build_query_string() const;
    jarvis::security::egress::RequestEnvelope build_egress_envelope() const;
    void audit_session_event(std::string event_kind,
                             std::string outcome,
                             std::string reason = {}) noexcept;

    // Parse a Deepgram JSON message; dispatch callbacks as appropriate
    void handle_server_message(std::string_view json_text);

    ConnectParams   params_;
    std::unique_ptr<jarvis::audit::TamperEvidentAuditLog> audit_log_;

    // Service thread
    std::thread             service_thread_;
    std::atomic<bool>       stop_requested_{false};
    std::atomic<SessionState> state_{SessionState::Connecting};

    // Callbacks (set before open; read from service thread)
    std::mutex                                       cb_mutex_;
    std::function<void(std::string_view)>            cb_interim_;
    std::function<void(FinalResult)>                 cb_final_;
    std::function<void(SilenceMs)>                   cb_endpoint_;
    std::function<void(std::string_view)>            cb_error_;

    // Audio queue: audio thread → service thread
    std::mutex              audio_mutex_;
    std::deque<int16_t>     audio_queue_;    // raw PCM16 samples
    static constexpr size_t kMaxAudioQueueSamples = 16000 * 5; // 5s buffer

    // Close sequencing — set flags from any thread; service thread acts on them
    std::atomic<bool>       close_requested_{false};  // set by close(); acted on in LWS_CALLBACK_CLIENT_WRITEABLE
    std::mutex              close_mutex_;
    std::condition_variable close_cv_;
    bool                    close_sent_{false};
    bool                    server_closed_{false};

    // Reconnect state
    std::atomic<int>        reconnect_count_{0};
    std::atomic<bool>       pin_rejected_{false};
    std::chrono::steady_clock::time_point reconnect_until_{std::chrono::steady_clock::now()};

    // libwebsockets context + connection
    struct lws_context*     lws_ctx_{nullptr};
    struct lws*             wsi_{nullptr};
    std::unique_ptr<ssl_ctx_st, SslCtxDeleter> ssl_ctx_;
    std::unique_ptr<SpkiVerifyData> spki_verify_data_;

    // Timing: first_audio_sent used for latency measurement
    std::atomic<bool>        first_audio_sent_{false};
    std::chrono::steady_clock::time_point first_audio_time_;
    std::atomic<bool>        first_interim_received_{false};
    std::chrono::steady_clock::time_point first_interim_time_;
};

}  // namespace jarvis::audio::stt_deepgram
