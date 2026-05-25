// scene_classifier.cpp — RawAudioSceneClassifier implementation.
// See header for design notes.

#include "scene_classifier.h"
#include "../../logging/redacting_logger.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstring>

namespace jarvis {

// ─── Routing ─────────────────────────────────────────────────────────────────

SceneRouting routingFor(SceneClass cls) noexcept {
    switch (cls) {
        case SceneClass::speech_directed: return SceneRouting::stt;
        case SceneClass::speech_ambient:  return SceneRouting::log_only;
        case SceneClass::music:           return SceneRouting::regulation;
        case SceneClass::noise:
        case SceneClass::silence:
        default:                          return SceneRouting::suppress;
    }
}

// ─── Construction ────────────────────────────────────────────────────────────

RawAudioSceneClassifier::RawAudioSceneClassifier(
    std::string_view model_path,
    int window_ms,
    int hop_ms,
    float energy_threshold_dbfs)
    : window_ms_(window_ms)
    , hop_ms_(hop_ms)
    , energy_threshold_dbfs_(energy_threshold_dbfs)
    , extractor_({})   // default: 16 kHz, 25 ms/10 ms frames, 64 mels
    , model_()
{
    window_samples_ = (window_ms_ * sample_rate_) / 1000;
    hop_samples_    = (hop_ms_    * sample_rate_) / 1000;

    ring_buf_.assign(window_samples_, 0);
    ring_fill_ = 0;

    n_logmel_frames_ = extractor_.n_frames(window_samples_);
    logmel_buf_.assign(n_logmel_frames_ * extractor_.n_mels(), 0.0f);

    for (auto& h : debounce_hist_) h = SceneClass::silence;

    if (!model_path.empty()) {
        if (!model_.load(model_path)) {
            logWarn("scene_classifier", "model_unavailable_using_heuristic",
                    { LogField::str("path", std::string(model_path)) });
        }
    }

    logInfo("scene_classifier", "init",
            { LogField::num("window_ms",    std::to_string(window_ms_)),
              LogField::num("hop_ms",        std::to_string(hop_ms_)),
              LogField::boolean("model_loaded", model_.isLoaded()),
              LogField::num("mel_frames",    std::to_string(n_logmel_frames_)),
              LogField::num("n_mels",        std::to_string(extractor_.n_mels())) });
}

// ─── Public API ──────────────────────────────────────────────────────────────

void RawAudioSceneClassifier::on_scene_change(std::function<void(SceneEvent)> cb) {
    scene_change_cb_ = std::move(cb);
}

bool RawAudioSceneClassifier::is_model_loaded() const noexcept {
    return model_.isLoaded();
}

std::optional<SceneEvent> RawAudioSceneClassifier::feed_audio(
    std::span<const int16_t> samples, int /*sample_rate*/)
{
    std::optional<SceneEvent> last_result;
    const int16_t* src       = samples.data();
    int            remaining = static_cast<int>(samples.size());

    while (remaining > 0) {
        const int space = window_samples_ - ring_fill_;
        const int take  = std::min(space, remaining);

        std::memcpy(ring_buf_.data() + ring_fill_, src, static_cast<size_t>(take) * sizeof(int16_t));
        ring_fill_ += take;
        src        += take;
        remaining  -= take;

        if (ring_fill_ < window_samples_) break;   // window not yet full

        last_result = classify_window();

        // Slide: keep (window − hop) most recent samples
        const int keep = window_samples_ - hop_samples_;
        if (keep > 0)
            std::memmove(ring_buf_.data(), ring_buf_.data() + hop_samples_,
                         static_cast<size_t>(keep) * sizeof(int16_t));
        ring_fill_  = keep;
        elapsed_ms_ += hop_ms_;
    }

    return last_result;
}

// ─── Window classification ───────────────────────────────────────────────────

SceneEvent RawAudioSceneClassifier::classify_window() {
    const int      n_samps = window_samples_;
    const int16_t* pcm     = ring_buf_.data();

    // ── Energy gate (silence) ─────────────────────────────────────────────────
    // Computed over raw samples; no FFT needed for silence.
    float sum_sq = 0.0f;
    for (int i = 0; i < n_samps; ++i) {
        const float s = static_cast<float>(pcm[i]) * (1.0f / 32768.0f);
        sum_sq += s * s;
    }
    const float rms  = std::sqrt(sum_sq / static_cast<float>(n_samps));
    const float dbfs = (rms > 1e-9f) ? 20.0f * std::log10(rms) : -120.0f;

    SceneEvent evt;
    evt.start_ms = elapsed_ms_;
    evt.end_ms   = elapsed_ms_ + window_ms_;

    if (dbfs < energy_threshold_dbfs_) {
        evt.label      = SceneClass::silence;
        evt.confidence = 1.0f;
        evt.from_model = false;
    } else {
        // Feature extraction (zero-alloc: writes into pre-allocated logmel_buf_)
        const int frames_written = extractor_.extract(
            { pcm, static_cast<size_t>(n_samps) }, logmel_buf_.data());

        ModelPrediction pred{};

        if (model_.isLoaded()) {
            pred = model_.predict(logmel_buf_.data(), frames_written, extractor_.n_mels());
        }
        if (!pred.from_model) {
            pred = heuristic_classify(pcm, n_samps,
                                      logmel_buf_.data(), frames_written,
                                      extractor_.n_mels());
        }

        evt.label      = pred.top_class;
        evt.confidence = pred.confidence;
        evt.from_model = pred.from_model;
    }

    // ── Debounce & transition callback ────────────────────────────────────────
    // NOTE: only label + timestamp + confidence are logged — never audio data.
    if (update_debounce(evt.label)) {
        logInfo("scene_classifier", "scene_change",
                { LogField::str("from",       sceneClassName(committed_scene_)),
                  LogField::str("to",         sceneClassName(evt.label)),
                  LogField::num("confidence", std::to_string(evt.confidence)),
                  LogField::num("start_ms",   std::to_string(evt.start_ms)) });

        committed_scene_ = evt.label;
        if (scene_change_cb_) scene_change_cb_(evt);
    }

    return evt;
}

// ─── Debounce ─────────────────────────────────────────────────────────────────

bool RawAudioSceneClassifier::update_debounce(SceneClass cls) {
    debounce_hist_[debounce_idx_] = cls;
    debounce_idx_ = (debounce_idx_ + 1) % kDebounceDepth;

    int votes[kNumSceneClasses]{};
    for (auto h : debounce_hist_) votes[static_cast<int>(h)]++;

    int top = 0;
    for (int i = 1; i < kNumSceneClasses; ++i)
        if (votes[i] > votes[top]) top = i;

    const auto proposed = static_cast<SceneClass>(top);
    return (votes[top] >= 2 && proposed != committed_scene_);
}

// ─── Heuristic classifier ────────────────────────────────────────────────────
//
// When no CoreML model is loaded this signal-processing heuristic provides a
// meaningful fallback.  It is less accurate than the CNN but captures clear
// cases reliably:
//
//   silence  → energy gate (handled above, never reaches here)
//   noise    → high ZCR rate OR high spectral flatness
//   music    → strong harmonicity + low ZCR + low spectral flatness
//   speech   → ZCR in voiced-speech range + mid spectral centroid
//
// All computations use the log-mel buffer already filled by the feature
// extractor — no second FFT pass.

ModelPrediction RawAudioSceneClassifier::heuristic_classify(
    const int16_t* pcm, int n_samples,
    const float* logmel, int n_frames, int n_mels) const
{
    // ── Zero Crossing Rate ────────────────────────────────────────────────────
    int zcr_count = 0;
    for (int i = 1; i < n_samples; ++i)
        if ((pcm[i] >= 0) != (pcm[i - 1] >= 0)) ++zcr_count;

    // ZCR expressed as crossings per second
    const float window_sec = static_cast<float>(n_samples) / static_cast<float>(sample_rate_);
    const float zcr_hz     = static_cast<float>(zcr_count) / window_sec;

    // ── Mel-domain spectral features (middle frame, linear scale) ─────────────
    const int   mid_frame  = n_frames / 2;
    const float* mel_row   = logmel + mid_frame * n_mels;

    float mel_linear[64]{};  // n_mels ≤ 64
    float mel_sum = 0.0f;
    for (int m = 0; m < n_mels; ++m) {
        mel_linear[m] = std::exp(mel_row[m]);
        mel_sum       += mel_linear[m];
    }
    if (mel_sum < 1e-12f) mel_sum = 1e-12f;

    // Normalised spectral centroid (0 = low freq, 1 = high freq)
    float centroid = 0.0f;
    for (int m = 0; m < n_mels; ++m)
        centroid += static_cast<float>(m) * mel_linear[m];
    centroid /= (mel_sum * static_cast<float>(n_mels));

    // Spectral flatness = geometric mean / arithmetic mean of mel energies
    float log_sum = 0.0f;
    for (int m = 0; m < n_mels; ++m)
        log_sum += std::log(mel_linear[m] + 1e-12f);
    const float geo_mean    = std::exp(log_sum / static_cast<float>(n_mels));
    const float arith_mean  = mel_sum / static_cast<float>(n_mels);
    const float flatness    = (arith_mean > 1e-12f) ? geo_mean / arith_mean : 0.0f;

    // Low-band energy fraction: fraction of energy in lower third of mel bins
    // (music/speech tend to have more energy there than broadband noise)
    float low_energy = 0.0f;
    const int lo_limit = n_mels / 3;
    for (int m = 0; m < lo_limit; ++m) low_energy += mel_linear[m];
    const float low_frac = low_energy / mel_sum;

    // ── Classification rules ──────────────────────────────────────────────────
    // Ordered from most-reliable to least.

    // Rule 1: Broadband noise — high ZCR (clicks, HVAC) or flat spectrum
    const bool is_noisy = (zcr_hz > 5000.0f) || (flatness > 0.55f);

    // Rule 2: Music — tonal (low flatness) + low-band dominant + low ZCR
    //         Synthetic harmonics and real instruments both satisfy this.
    const bool is_music = (!is_noisy)
                       && (flatness    < 0.25f)
                       && (low_frac   > 0.50f)
                       && (zcr_hz     < 2000.0f);

    // Rule 3: Speech — ZCR in voiced/fricative range + mid centroid
    //         TTS output is spectrally clean; this fires reliably on oracle WAVs.
    const bool is_speech = (!is_noisy) && (!is_music)
                        && (zcr_hz  > 200.0f  && zcr_hz  < 5000.0f)
                        && (centroid > 0.08f   && centroid < 0.65f);

    ModelPrediction pred{};
    pred.from_model = false;

    SceneClass cls;
    if (is_noisy) {
        cls = SceneClass::noise;
        pred.confidence = 0.70f;
    } else if (is_music) {
        cls = SceneClass::music;
        pred.confidence = 0.65f;
    } else if (is_speech) {
        // All speech defaults to speech_directed; wakeword/speaker context
        // distinguishes ambient from directed — that layer is not yet built.
        cls = SceneClass::speech_directed;
        pred.confidence = 0.62f;
    } else {
        cls = SceneClass::noise;
        pred.confidence = 0.48f;
    }

    pred.top_class = cls;
    pred.scores[static_cast<int>(cls)] = pred.confidence;

    const float residual = (1.0f - pred.confidence) / static_cast<float>(kNumSceneClasses - 1);
    for (int i = 0; i < kNumSceneClasses; ++i)
        if (i != static_cast<int>(cls)) pred.scores[i] = residual;

    return pred;
}

} // namespace jarvis
