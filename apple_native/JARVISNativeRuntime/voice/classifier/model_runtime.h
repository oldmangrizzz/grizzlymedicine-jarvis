#pragma once
// model_runtime.h — CoreML audio scene classifier runtime wrapper.
//
// Pure C++ interface. Implementation is Objective-C++ (model_runtime.mm)
// because CoreML is an Objective-C framework with no C++ API.
//
// Thread-safety: predict() is safe to call concurrently from multiple threads
// once the model is loaded. load() is NOT thread-safe.

#include <memory>
#include <string>
#include <string_view>

namespace jarvis {

// ─── Scene taxonomy ───────────────────────────────────────────────────────────

/// Scene classes produced by the classifier.
/// Routing decisions are in scene_classifier.h.
enum class SceneClass : uint8_t {
    speech_directed = 0, ///< Speech addressed to JARVIS   → STT
    speech_ambient  = 1, ///< Background / third-party speech → log only (privacy)
    music           = 2, ///< Instrumental or vocal music    → regulation channel
    noise           = 3, ///< Environmental noise            → suppress
    silence         = 4, ///< Below energy threshold         → suppress
    _count          = 5,
};

static constexpr int kNumSceneClasses = static_cast<int>(SceneClass::_count);

/// Human-readable name for a scene class — safe to log.
const char* sceneClassName(SceneClass cls) noexcept;

// ─── Prediction result ────────────────────────────────────────────────────────

struct ModelPrediction {
    SceneClass top_class  {SceneClass::silence};
    float      confidence {0.0f};
    float      scores[kNumSceneClasses]{};  ///< Softmax scores per class (index = SceneClass)
    bool       from_model {false};          ///< false = heuristic fallback
};

// ─── Runtime ─────────────────────────────────────────────────────────────────

/// CoreML model runtime wrapper.
///
/// Wraps an MLModel compiled for the ANE (MLComputeUnitsAll).
/// Input feature name:  "logmel"  — MLMultiArray float32 shape [1, 1, n_frames, n_mels]
/// Output feature name: "scores"  — MLMultiArray float32 shape [1, kNumSceneClasses]
class ModelRuntime {
public:
    ModelRuntime();
    ~ModelRuntime();

    ModelRuntime(const ModelRuntime&)            = delete;
    ModelRuntime& operator=(const ModelRuntime&) = delete;

    /// Load a CoreML .mlpackage or .mlmodelc.
    /// Returns false on failure; logs warning via redacting_logger.
    bool load(std::string_view model_path);

    /// Synchronous inference.
    ///
    /// @param logmel   Row-major float32 log-mel buffer [n_frames × n_mels].
    /// @param n_frames Number of time frames.
    /// @param n_mels   Number of mel bins.
    /// @returns        ModelPrediction — from_model=false if model not loaded.
    ModelPrediction predict(const float* logmel, int n_frames, int n_mels) const;

    bool        isLoaded()  const noexcept;
    std::string modelPath() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace jarvis
