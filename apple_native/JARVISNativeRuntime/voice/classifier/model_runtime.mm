// model_runtime.mm — CoreML inference wrapper (Objective-C++).
//
// Objective-C++ is required because CoreML exposes an Objective-C API only.
// The external interface (model_runtime.h) is pure C++.

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#include "model_runtime.h"
#include "../../logging/redacting_logger.h"

#include <algorithm>
#include <cmath>
#include <string>

namespace jarvis {

// ─── sceneClassName ──────────────────────────────────────────────────────────

const char* sceneClassName(SceneClass cls) noexcept {
    switch (cls) {
        case SceneClass::speech_directed: return "speech_directed";
        case SceneClass::speech_ambient:  return "speech_ambient";
        case SceneClass::music:           return "music";
        case SceneClass::noise:           return "noise";
        case SceneClass::silence:         return "silence";
        default:                          return "unknown";
    }
}

// ─── Impl ─────────────────────────────────────────────────────────────────────

struct ModelRuntime::Impl {
    MLModel*  model{nil};
    NSString* path{nil};
};

// ─── ModelRuntime ────────────────────────────────────────────────────────────

ModelRuntime::ModelRuntime()  : impl_(std::make_unique<Impl>()) {}
ModelRuntime::~ModelRuntime() = default;

bool ModelRuntime::load(std::string_view path) {
    @autoreleasepool {
        NSString* nsPath = [NSString stringWithUTF8String:path.data()];
        NSURL*    url    = [NSURL fileURLWithPath:nsPath];

        MLModelConfiguration* cfg = [[MLModelConfiguration alloc] init];
        cfg.computeUnits = MLComputeUnitsAll;   // target ANE when available

        NSError* err = nil;
        MLModel* m = [MLModel modelWithContentsOfURL:url configuration:cfg error:&err];

        if (!m || err) {
            logWarn("scene_classifier", "model_load_failed",
                    { jarvis::LogField::str("path",  std::string(path)),
                      jarvis::LogField::str("error", err ? err.localizedDescription.UTF8String : "nil model") });
            return false;
        }

        impl_->model = m;
        impl_->path  = nsPath;

        logInfo("scene_classifier", "model_loaded",
                { jarvis::LogField::str("path", std::string(path)),
                  jarvis::LogField::str("compute_units", "all") });
        return true;
    }
}

bool ModelRuntime::isLoaded() const noexcept {
    return impl_->model != nil;
}

std::string ModelRuntime::modelPath() const {
    return impl_->path ? std::string(impl_->path.UTF8String) : "";
}

ModelPrediction ModelRuntime::predict(const float* logmel,
                                      int n_frames, int n_mels) const {
    ModelPrediction result{};

    if (!impl_->model) return result;   // caller falls back to heuristic

    @autoreleasepool {
        // Build input MLMultiArray: shape [1, 1, n_frames, n_mels]
        NSArray<NSNumber*>* shape = @[@1, @1, @(n_frames), @(n_mels)];
        NSError* err = nil;

        MLMultiArray* input = [[MLMultiArray alloc] initWithShape:shape
                                                         dataType:MLMultiArrayDataTypeFloat32
                                                            error:&err];
        if (!input || err) {
            logWarn("scene_classifier", "multiarray_alloc_failed",
                    { jarvis::LogField::str("error",
                        err ? err.localizedDescription.UTF8String : "nil array") });
            return result;
        }

        // Copy log-mel data — MLMultiArray guarantees contiguous float32 storage
        std::copy(logmel, logmel + n_frames * n_mels,
                  static_cast<float*>(input.dataPointer));

        // Build feature provider
        MLFeatureValue* fv = [MLFeatureValue featureValueWithMultiArray:input];
        NSDictionary<NSString*, MLFeatureValue*>* dict = @{ @"logmel": fv };

        MLDictionaryFeatureProvider* provider =
            [[MLDictionaryFeatureProvider alloc] initWithDictionary:dict error:&err];
        if (!provider || err) {
            logWarn("scene_classifier", "feature_provider_failed", {});
            return result;
        }

        // Synchronous prediction
        id<MLFeatureProvider> output =
            [impl_->model predictionFromFeatures:provider error:&err];
        if (!output || err) {
            logWarn("scene_classifier", "prediction_failed",
                    { jarvis::LogField::str("error",
                        err ? err.localizedDescription.UTF8String : "") });
            return result;
        }

        // Extract "scores" output
        MLFeatureValue* outFV = [output featureValueForName:@"scores"];
        if (!outFV || outFV.type != MLFeatureTypeMultiArray) {
            logWarn("scene_classifier", "output_format_unexpected", {});
            return result;
        }

        MLMultiArray* scores = outFV.multiArrayValue;
        const int n = static_cast<int>(std::min(static_cast<NSInteger>(kNumSceneClasses),
                                                 scores.count));
        for (int i = 0; i < n; ++i)
            result.scores[i] = scores[i].floatValue;

        // Top class
        int top = 0;
        for (int i = 1; i < kNumSceneClasses; ++i)
            if (result.scores[i] > result.scores[top]) top = i;

        result.top_class  = static_cast<SceneClass>(top);
        result.confidence = result.scores[top];
        result.from_model = true;
    }
    return result;
}

} // namespace jarvis
