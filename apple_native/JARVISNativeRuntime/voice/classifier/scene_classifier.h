#pragma once
// scene_classifier.h — Raw Audio Scene Classifier: front gate of JARVIS hearing.
//
// Separates the raw mic stream into scene classes BEFORE STT is invoked.
//
// Routing policy (binding — from audio_context.py):
//   speech_directed → STT
//   speech_ambient  → log only (privacy: DO NOT transcribe via STT)
//   music           → regulation channel: endocrine dopamine + Pheromind "music" deposit
//   noise / silence → suppress
//
// Design:
//   • 1-second sliding window, 250 ms hop (4 classifications/sec, 75 % overlap)
//   • Zero allocation in hot path — all buffers pre-allocated at construction
//   • CoreML model (ANE-accelerated) when loaded; heuristic fallback otherwise
//   • Scene changes debounced: 2/3 majority over last 3 windows before callback fires

#include "feature_extractor.h"
#include "model_runtime.h"

#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace jarvis {

// ─── SceneEvent ──────────────────────────────────────────────────────────────

/// A classified audio scene window.
struct SceneEvent {
    SceneClass  label      {SceneClass::silence};
    float       confidence {0.0f};
    int64_t     start_ms   {0};     ///< Elapsed ms since classifier was created
    int64_t     end_ms     {0};
    bool        from_model {false}; ///< false = heuristic fallback

    const char* label_name() const noexcept { return sceneClassName(label); }
};

// ─── Routing ─────────────────────────────────────────────────────────────────

/// Downstream routing decision for a classified scene.
enum class SceneRouting {
    stt,        ///< Send to STT pipeline
    log_only,   ///< Log label/timestamp; do NOT send to STT (privacy)
    regulation, ///< Increment endocrine dopamine; deposit "music" in Pheromind
    suppress,   ///< Drop silently
};

SceneRouting routingFor(SceneClass cls) noexcept;

// ─── RawAudioSceneClassifier ─────────────────────────────────────────────────

/// Raw Audio Scene Classifier.
///
/// Usage:
///   RawAudioSceneClassifier clf("/path/to/model.mlpackage");
///   clf.on_scene_change([](SceneEvent e){ /* route by e.label */ });
///   // In mic callback:
///   if (auto evt = clf.feed_audio(samples)) { /* latest window label */ }
class RawAudioSceneClassifier {
public:
    /// @param model_path              CoreML .mlpackage/.mlmodelc path (empty = heuristic)
    /// @param window_ms               Classification window length in ms (default 1000)
    /// @param hop_ms                  Window hop / output rate in ms (default 250 = 4/sec)
    /// @param energy_threshold_dbfs   Silence gate in dBFS (default -50)
    explicit RawAudioSceneClassifier(
        std::string_view model_path          = "",
        int              window_ms           = 1000,
        int              hop_ms              = 250,
        float            energy_threshold_dbfs = -50.0f
    );

    ~RawAudioSceneClassifier() = default;

    RawAudioSceneClassifier(const RawAudioSceneClassifier&)            = delete;
    RawAudioSceneClassifier& operator=(const RawAudioSceneClassifier&) = delete;

    /// Feed raw PCM samples into the classifier (non-blocking).
    ///
    /// Accumulates samples into a ring buffer; once a full window_ms of audio
    /// is ready, runs classification and slides by hop_ms.
    ///
    /// If multiple windows complete in one call, the on_scene_change callback
    /// fires for each; the return value is the most-recently-classified window.
    ///
    /// @param samples     Mono int16 PCM at sample_rate Hz.
    /// @param sample_rate Must be 16 000 Hz (resampling is caller's responsibility).
    /// @returns           SceneEvent for the last completed window, or nullopt.
    std::optional<SceneEvent> feed_audio(
        std::span<const int16_t> samples,
        int sample_rate = 16'000
    );

    /// Register callback fired on debounced scene class transitions.
    /// Called synchronously from feed_audio on the caller's thread.
    void on_scene_change(std::function<void(SceneEvent)> callback);

    bool       is_model_loaded() const noexcept;
    SceneClass current_scene()   const noexcept { return committed_scene_; }
    int        window_ms()       const noexcept { return window_ms_; }
    int        hop_ms()          const noexcept { return hop_ms_; }

private:
    int   window_ms_;
    int   hop_ms_;
    float energy_threshold_dbfs_;
    int   sample_rate_{16'000};

    FeatureExtractor extractor_;
    ModelRuntime     model_;

    // Pre-allocated ring buffer (one full window)
    int window_samples_{0};
    int hop_samples_{0};
    std::vector<int16_t> ring_buf_;
    int ring_fill_{0};

    // Pre-allocated log-mel buffer [n_frames × n_mels]
    std::vector<float> logmel_buf_;
    int n_logmel_frames_{0};

    // Debounce: last 3 window classifications, majority vote before transition
    static constexpr int kDebounceDepth = 3;
    SceneClass debounce_hist_[kDebounceDepth]{};
    int        debounce_idx_{0};

    SceneClass committed_scene_{SceneClass::silence};
    int64_t    elapsed_ms_{0};

    std::function<void(SceneEvent)> scene_change_cb_;

    SceneEvent      classify_window();
    ModelPrediction heuristic_classify(const int16_t* pcm, int n_samples,
                                       const float* logmel, int n_frames, int n_mels) const;
    bool            update_debounce(SceneClass cls);
};

} // namespace jarvis
