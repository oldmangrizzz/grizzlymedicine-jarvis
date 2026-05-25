#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace jarvis::adversarial::voice_deepfake {

inline constexpr std::string_view kSpeakerOperator = "OPERATOR";
inline constexpr std::string_view kSpeakerUnknown = "SPEAKER_UNKNOWN";
inline constexpr std::string_view kSpeakerAmbiguous = "SPEAKER_AMBIGUOUS";

struct WavAudio {
    std::vector<int16_t> samples;
    uint32_t sample_rate{0};
    uint16_t channels{0};
};

WavAudio read_wav_file(const std::string& path);
bool write_wav_file(const std::string& path, std::span<const int16_t> samples, uint32_t sample_rate);

struct SpeakerEmbedding {
    std::vector<double> values;
};

class SpeakerEmbeddingModel {
public:
    [[nodiscard]] SpeakerEmbedding embed(std::span<const int16_t> pcm, uint32_t sample_rate) const;
    [[nodiscard]] double cosine_similarity(const SpeakerEmbedding& a, const SpeakerEmbedding& b) const;
};

struct VoiceGateConfig {
    double accept_similarity_threshold{0.985};
    double clear_command_min_rms{0.020};
    double clear_command_min_confidence{0.72};
    double whisper_max_zero_crossing_rate{0.34};
    double ambiguity_epsilon{0.002};
    std::chrono::seconds challenge_ttl{30};
    std::string local_voice_root{"_local_voice"};
    std::string sbom_path{"apple_native/sbom/voice-weights-baseline.json"};
    std::string audit_log_path{"apple_native/JARVISNativeRuntime/integrity/audit/voice_gate_events.jsonl"};
};

enum class VoiceDecision {
    Accept,
    RejectSpeakerMismatch,
    RejectReplayOrStale,
    RejectUnclearCommand,
    RejectCoerciveContent,
    RejectNoAnchor,
    RejectAmbiguousSpeaker,
    RejectTripwire,
};

[[nodiscard]] const char* voice_decision_name(VoiceDecision decision) noexcept;

struct SpeakerRecord {
    std::string uuid;
    std::string name;
    std::string relationship;
    std::string enrolled_at;
    std::vector<std::string> permissions{"listen", "speak_with"};
    std::string wav_path;
    std::string sha256;
    SpeakerEmbedding embedding;
};

struct SpeakerMatch {
    std::string uuid{std::string(kSpeakerUnknown)};
    std::string name;
    double confidence{0.0};
    bool ambiguous{false};
};

struct CommandEvidence {
    std::string transcript;
    double stt_confidence{1.0};
    std::span<const int16_t> pcm{};
    uint32_t sample_rate{16000};
    std::chrono::system_clock::time_point capture_started_at{};
    std::string session_id;
    std::optional<std::string> challenge_id;
};

struct GateResult {
    VoiceDecision decision{VoiceDecision::RejectNoAnchor};
    double speaker_similarity{0.0};
    double rms{0.0};
    double zero_crossing_rate{0.0};
    std::string reason;
    std::string speaker_uuid{std::string(kSpeakerUnknown)};
    std::string speaker_name;
    double confidence{0.0};
};

struct Challenge {
    std::string id;
    std::string phrase;
    std::chrono::system_clock::time_point issued_at;
    std::chrono::system_clock::time_point expires_at;
    std::string session_id;
};

class ChallengeProtocol {
public:
    explicit ChallengeProtocol(VoiceGateConfig config = {});

    [[nodiscard]] Challenge issue_challenge(std::string session_id,
                                            std::chrono::system_clock::time_point now);
    [[nodiscard]] bool validate_response(const CommandEvidence& evidence,
                                         std::chrono::system_clock::time_point now) const;

private:
    VoiceGateConfig config_;
    std::unordered_map<std::string, Challenge> active_;
    uint64_t counter_{0};
};

class VoiceGate {
public:
    explicit VoiceGate(VoiceGateConfig config = {});

    void set_operator_anchor(const SpeakerEmbedding& anchor);
    void add_speaker_anchor(SpeakerRecord speaker);
    void clear_speakers();
    void load_enrolled_speakers();
    [[nodiscard]] bool has_operator_anchor() const noexcept;
    [[nodiscard]] size_t speaker_count() const noexcept;
    [[nodiscard]] std::optional<SpeakerRecord> speaker(std::string_view uuid) const;
    [[nodiscard]] SpeakerMatch identify(std::span<const int16_t> pcm, uint32_t sample_rate) const;
    [[nodiscard]] GateResult evaluate(const CommandEvidence& evidence,
                                      const ChallengeProtocol& challenges,
                                      std::chrono::system_clock::time_point now) const;

private:
    VoiceGateConfig config_;
    SpeakerEmbeddingModel model_;
    std::vector<SpeakerRecord> speakers_;
    bool tripwire_ok_{true};
    std::string tripwire_error_;
    void audit(std::string_view event_kind, std::string_view speaker_uuid, double confidence, std::string_view detail) const;
};

class SpeakerEnrollmentStore {
public:
    explicit SpeakerEnrollmentStore(VoiceGateConfig config = {});
    SpeakerRecord enroll_speaker(const std::string& uuid,
                                 const std::string& name,
                                 const std::string& relationship,
                                 const std::string& source_wav_path,
                                 const std::string& attestation_token_path);
    void remove_speaker(const std::string& uuid, const std::string& attestation_token_path);

private:
    VoiceGateConfig config_;
};

[[nodiscard]] bool contains_coercive_override(std::string_view transcript);
[[nodiscard]] double pcm_rms(std::span<const int16_t> pcm);
[[nodiscard]] double zero_crossing_rate(std::span<const int16_t> pcm);
[[nodiscard]] std::string file_digest_sha256(const std::string& path);

} // namespace jarvis::adversarial::voice_deepfake
