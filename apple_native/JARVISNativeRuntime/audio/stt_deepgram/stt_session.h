// stt_session.h
// JARVIS digital-personhood project — GMRI
//
// Per-utterance STT session. Represents one open WebSocket stream to Deepgram.
// Transcripts are operator-private: raw text NEVER reaches os_log or stdout;
// all logging goes through the redacting_logger.
//
// Thread model:
//   • feed_audio()  — caller's thread (typically the CoreAudio callback thread)
//   • on_interim / on_final / on_endpoint callbacks — libwebsockets service thread
//     Callbacks MUST be non-blocking. Do not call feed_audio() from a callback.
//
// Lifecycle:
//   auto session = client.start_session();
//   session->on_final([](FinalResult r){ ... });
//   session->on_interim([](std::string_view t){ ... });
//   session->on_endpoint([](double silence_ms){ ... });
//   // audio flows in via feed_audio()
//   session->close();   // sends CloseStream, awaits server close

#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace jarvis::audio::stt_deepgram {

// ── Result types ─────────────────────────────────────────────────────────────

struct WordResult {
    std::string word;
    std::string punctuated_word;
    double      start_sec{0.0};
    double      end_sec{0.0};
    double      confidence{0.0};
    int         speaker{-1};  // -1 = no speaker diarization
};

struct FinalResult {
    std::string             text;
    double                  confidence{0.0};
    double                  start_ms{0.0};   // segment start in milliseconds
    double                  end_ms{0.0};     // segment end in milliseconds
    std::optional<int>      speaker_id;      // present if diarization enabled
    std::vector<WordResult> words;
    bool                    speech_final{false};  // true = VAD endpoint crossed
};

// Silence duration in milliseconds from UtteranceEnd event
using SilenceMs = double;

// ── Session state ─────────────────────────────────────────────────────────────

enum class SessionState : uint8_t {
    Connecting,     // WebSocket handshake in progress
    Open,           // connected, streaming audio
    Closing,        // CloseStream sent, awaiting server close
    Closed,         // fully closed; object is dead
    Error,          // connection failed (pin mismatch, network, etc.)
};

[[nodiscard]] constexpr const char* session_state_cstr(SessionState s) noexcept {
    switch (s) {
        case SessionState::Connecting: return "Connecting";
        case SessionState::Open:       return "Open";
        case SessionState::Closing:    return "Closing";
        case SessionState::Closed:     return "Closed";
        case SessionState::Error:      return "Error";
    }
    return "Unknown";
}

// ── Session interface ─────────────────────────────────────────────────────────

class SttSession {
public:
    virtual ~SttSession() = default;

    // ── Audio ingestion ──────────────────────────────────────────────────────
    // Non-blocking. PCM16 mono 16 kHz samples. Returns immediately; audio is
    // queued for transmission to Deepgram on the next writable event.
    virtual void feed_audio(std::span<const int16_t> pcm) = 0;

    // ── Callback registration ────────────────────────────────────────────────
    // Must be called before start_session() returns (or immediately after,
    // before the first audio frame arrives). Not thread-safe with feed_audio.

    // Interim partial transcript (is_final=false). May arrive multiple times.
    virtual void on_interim(std::function<void(std::string_view)> cb) = 0;

    // Final transcript for one speech segment (is_final=true).
    virtual void on_final(std::function<void(FinalResult)> cb) = 0;

    // Utterance endpoint from VAD (UtteranceEnd event).
    virtual void on_endpoint(std::function<void(SilenceMs)> cb) = 0;

    // Called when the session transitions to Error state.
    // reason: machine-readable short string, e.g. "pin_mismatch", "network"
    virtual void on_error(std::function<void(std::string_view reason)> cb) = 0;

    // ── Lifecycle ────────────────────────────────────────────────────────────
    // Send CloseStream JSON frame, drain pending audio, await server close.
    // Blocks until closed or timeout_ms elapses.
    virtual void close(int timeout_ms = 5000) = 0;

    // ── State query ─────────────────────────────────────────────────────────
    [[nodiscard]] virtual SessionState state() const noexcept = 0;
};

}  // namespace jarvis::audio::stt_deepgram
