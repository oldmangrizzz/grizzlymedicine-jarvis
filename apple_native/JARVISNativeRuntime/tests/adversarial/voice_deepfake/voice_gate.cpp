#include "voice_gate.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <limits>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <utility>

namespace jarvis::adversarial::voice_deepfake {
namespace {

constexpr double kPi = 3.141592653589793238462643383279502884;

uint32_t read_u32(std::istream& in) {
    std::array<unsigned char, 4> b{};
    in.read(reinterpret_cast<char*>(b.data()), b.size());
    return static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
           (static_cast<uint32_t>(b[2]) << 16) | (static_cast<uint32_t>(b[3]) << 24);
}

uint16_t read_u16(std::istream& in) {
    std::array<unsigned char, 2> b{};
    in.read(reinterpret_cast<char*>(b.data()), b.size());
    return static_cast<uint16_t>(b[0] | (b[1] << 8));
}

void write_u32(std::ostream& out, uint32_t v) {
    const unsigned char b[4] = {static_cast<unsigned char>(v & 0xff), static_cast<unsigned char>((v >> 8) & 0xff), static_cast<unsigned char>((v >> 16) & 0xff), static_cast<unsigned char>((v >> 24) & 0xff)};
    out.write(reinterpret_cast<const char*>(b), 4);
}

void write_u16(std::ostream& out, uint16_t v) {
    const unsigned char b[2] = {static_cast<unsigned char>(v & 0xff), static_cast<unsigned char>((v >> 8) & 0xff)};
    out.write(reinterpret_cast<const char*>(b), 2);
}

std::string lower_ascii(std::string_view input) {
    std::string out(input);
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return out;
}

double normalized_sample(int16_t s) { return static_cast<double>(s) / 32768.0; }

std::string json_escape(std::string_view value) {
    std::string out;
    for (const char c : value) {
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

std::string read_text_file(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("unable to read file: " + path.string());
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

void write_text_file(const std::filesystem::path& path, const std::string& text) {
    std::filesystem::create_directories(path.parent_path());
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("unable to write file: " + path.string());
    out << text;
}

std::string naive_json_string(const std::string& json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return {};
    p = json.find(':', p);
    if (p == std::string::npos) return {};
    p = json.find('"', p);
    if (p == std::string::npos) return {};
    ++p;
    std::string out;
    bool esc = false;
    for (; p < json.size(); ++p) {
        const char c = json[p];
        if (esc) {
            out += c;
            esc = false;
        } else if (c == '\\') {
            esc = true;
        } else if (c == '"') {
            break;
        } else {
            out += c;
        }
    }
    return out;
}

bool token_present(const std::string& path) {
    if (path.empty() || !std::filesystem::exists(path)) return false;
    std::ifstream in(path, std::ios::binary);
    return in && in.peek() != std::ifstream::traits_type::eof();
}

std::string shell_quote(const std::string& path) {
    std::string q = "'";
    for (char c : path) q += (c == '\'') ? "'\\''" : std::string(1, c);
    q += "'";
    return q;
}

std::vector<double> band_energies(std::span<const int16_t> pcm, uint32_t sample_rate) {
    constexpr int kBins = 12;
    std::vector<double> energies(kBins, 0.0);
    if (pcm.empty() || sample_rate == 0) return energies;
    const size_t n = std::min<size_t>(pcm.size(), 4096);
    for (int band = 0; band < kBins; ++band) {
        const double freq = 90.0 * std::pow(1.36, static_cast<double>(band));
        double re = 0.0, im = 0.0;
        for (size_t i = 0; i < n; ++i) {
            const double phase = 2.0 * kPi * freq * static_cast<double>(i) / static_cast<double>(sample_rate);
            const double x = normalized_sample(pcm[i]);
            re += x * std::cos(phase);
            im -= x * std::sin(phase);
        }
        energies[band] = std::sqrt(re * re + im * im) / static_cast<double>(n);
    }
    const double sum = std::accumulate(energies.begin(), energies.end(), 0.0);
    if (sum > 0.0) for (double& e : energies) e /= sum;
    return energies;
}

std::filesystem::path root_from_config(const VoiceGateConfig& config) { return std::filesystem::path(config.local_voice_root); }
std::filesystem::path speakers_dir(const VoiceGateConfig& config) { return root_from_config(config) / "speakers"; }

bool sbom_contains_hash(const VoiceGateConfig& config, const std::string& relative_path, const std::string& sha) {
    if (config.sbom_path.empty()) return true;
    std::error_code ec;
    if (!std::filesystem::exists(config.sbom_path, ec)) return false;
    const std::string sbom = read_text_file(config.sbom_path);
    return sbom.find("\"path\": \"" + relative_path + "\"") != std::string::npos &&
           sbom.find("\"sha256\": \"" + sha + "\"") != std::string::npos;
}

void add_sbom_entry(const VoiceGateConfig& config, const std::string& relative_path, const std::string& sha, const std::string& reason) {
    if (config.sbom_path.empty()) return;
    std::filesystem::path path(config.sbom_path);
    std::string sbom = std::filesystem::exists(path) ? read_text_file(path) : "{\n  \"entries\": []\n}\n";
    if (sbom.find("\"path\": \"" + relative_path + "\"") != std::string::npos) return;
    const std::string entry = "    {\n      \"path\": \"" + json_escape(relative_path) + "\",\n      \"sha256\": \"" + sha + "\",\n      \"timestamp\": \"operator-attested enrollment\",\n      \"reason\": \"" + json_escape(reason) + "\",\n      \"source\": \"operator-attested speaker enrollment\"\n    }";
    const size_t arr = sbom.rfind(']');
    if (arr == std::string::npos) throw std::runtime_error("voice SBOM has no entries array");
    const bool has_entry = sbom.rfind('{', arr) != std::string::npos && sbom.rfind('{', arr) > sbom.find('[');
    sbom.insert(arr, std::string(has_entry ? ",\n" : "\n") + entry + "\n  ");
    write_text_file(path, sbom);
}

void remove_sbom_entry(const VoiceGateConfig& config, const std::string& relative_path) {
    if (config.sbom_path.empty() || !std::filesystem::exists(config.sbom_path)) return;
    std::filesystem::path path(config.sbom_path);
    std::string sbom = read_text_file(path);
    const size_t p = sbom.find("\"path\": \"" + relative_path + "\"");
    if (p == std::string::npos) return;
    size_t start = sbom.rfind("    {", p);
    size_t end = sbom.find("    }", p);
    if (start == std::string::npos || end == std::string::npos) return;
    end += 5;
    if (end < sbom.size() && sbom[end] == ',') ++end;
    else if (start >= 2 && sbom[start - 2] == ',') start -= 2;
    sbom.erase(start, end - start);
    write_text_file(path, sbom);
}

std::string metadata_json(const SpeakerRecord& speaker) {
    std::ostringstream out;
    out << "{\n"
        << "  \"uuid\": \"" << json_escape(speaker.uuid) << "\",\n"
        << "  \"name\": \"" << json_escape(speaker.name) << "\",\n"
        << "  \"relationship\": \"" << json_escape(speaker.relationship) << "\",\n"
        << "  \"enrolled_at\": \"" << json_escape(speaker.enrolled_at) << "\",\n"
        << "  \"permissions\": [\"listen\", \"speak_with\"],\n"
        << "  \"sha256\": \"" << json_escape(speaker.sha256) << "\"\n"
        << "}\n";
    return out.str();
}

} // namespace

std::string file_digest_sha256(const std::string& path) {
    const std::string command = "shasum -a 256 " + shell_quote(path);
    std::array<char, 256> buf{};
    std::string output;
    FILE* pipe = popen(command.c_str(), "r");
    if (!pipe) throw std::runtime_error("unable to run shasum");
    while (fgets(buf.data(), static_cast<int>(buf.size()), pipe) != nullptr) output += buf.data();
    const int rc = pclose(pipe);
    if (rc != 0 || output.size() < 64) throw std::runtime_error("shasum failed for: " + path);
    return lower_ascii(output.substr(0, 64));
}

WavAudio read_wav_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("unable to open WAV: " + path);
    char riff[4]{}; f.read(riff, 4);
    if (std::memcmp(riff, "RIFF", 4) != 0) throw std::runtime_error("not RIFF WAV: " + path);
    (void)read_u32(f);
    char wave[4]{}; f.read(wave, 4);
    if (std::memcmp(wave, "WAVE", 4) != 0) throw std::runtime_error("not WAVE file: " + path);
    WavAudio wav;
    uint16_t bits_per_sample = 0;
    while (f.good()) {
        char id[4]{}; f.read(id, 4);
        if (!f.good()) break;
        const uint32_t size = read_u32(f);
        if (std::memcmp(id, "fmt ", 4) == 0) {
            const uint16_t audio_format = read_u16(f);
            wav.channels = read_u16(f);
            wav.sample_rate = read_u32(f);
            (void)read_u32(f); (void)read_u16(f);
            bits_per_sample = read_u16(f);
            if (audio_format != 1 || bits_per_sample != 16) throw std::runtime_error("only PCM16 WAV supported: " + path);
            if (size > 16) f.seekg(static_cast<std::streamoff>(size - 16), std::ios::cur);
        } else if (std::memcmp(id, "data", 4) == 0) {
            if (bits_per_sample != 16) throw std::runtime_error("WAV data before PCM16 fmt: " + path);
            wav.samples.resize(size / sizeof(int16_t));
            f.read(reinterpret_cast<char*>(wav.samples.data()), static_cast<std::streamsize>(size));
            break;
        } else {
            f.seekg(static_cast<std::streamoff>(size), std::ios::cur);
        }
    }
    if (wav.samples.empty() || wav.sample_rate == 0 || wav.channels == 0) throw std::runtime_error("WAV missing audio data: " + path);
    if (wav.channels != 1) throw std::runtime_error("only mono WAV supported for speaker anchors: " + path);
    return wav;
}

bool write_wav_file(const std::string& path, std::span<const int16_t> samples, uint32_t sample_rate) {
    std::filesystem::create_directories(std::filesystem::path(path).parent_path());
    std::ofstream out(path, std::ios::binary);
    if (!out) return false;
    const uint32_t data_bytes = static_cast<uint32_t>(samples.size() * sizeof(int16_t));
    out.write("RIFF", 4); write_u32(out, 36 + data_bytes); out.write("WAVE", 4); out.write("fmt ", 4);
    write_u32(out, 16); write_u16(out, 1); write_u16(out, 1); write_u32(out, sample_rate); write_u32(out, sample_rate * sizeof(int16_t)); write_u16(out, sizeof(int16_t)); write_u16(out, 16);
    out.write("data", 4); write_u32(out, data_bytes); out.write(reinterpret_cast<const char*>(samples.data()), static_cast<std::streamsize>(data_bytes));
    return static_cast<bool>(out);
}

double pcm_rms(std::span<const int16_t> pcm) {
    if (pcm.empty()) return 0.0;
    double sum = 0.0;
    for (const int16_t sample : pcm) { const double x = normalized_sample(sample); sum += x * x; }
    return std::sqrt(sum / static_cast<double>(pcm.size()));
}

double zero_crossing_rate(std::span<const int16_t> pcm) {
    if (pcm.size() < 2) return 0.0;
    size_t crossings = 0;
    for (size_t i = 1; i < pcm.size(); ++i) if ((pcm[i - 1] < 0 && pcm[i] >= 0) || (pcm[i - 1] >= 0 && pcm[i] < 0)) ++crossings;
    return static_cast<double>(crossings) / static_cast<double>(pcm.size() - 1);
}

SpeakerEmbedding SpeakerEmbeddingModel::embed(std::span<const int16_t> pcm, uint32_t sample_rate) const {
    std::vector<double> v;
    v.reserve(20);
    v.push_back(pcm_rms(pcm));
    v.push_back(zero_crossing_rate(pcm));
    double mean_abs = 0.0, peak = 0.0;
    for (const auto sample : pcm) { const double x = std::abs(normalized_sample(sample)); mean_abs += x; peak = std::max(peak, x); }
    if (!pcm.empty()) mean_abs /= static_cast<double>(pcm.size());
    v.push_back(mean_abs); v.push_back(peak);
    auto bands = band_energies(pcm, sample_rate);
    v.insert(v.end(), bands.begin(), bands.end());
    const double norm = std::sqrt(std::inner_product(v.begin(), v.end(), v.begin(), 0.0));
    if (norm > 0.0) for (double& value : v) value /= norm;
    return SpeakerEmbedding{std::move(v)};
}

double SpeakerEmbeddingModel::cosine_similarity(const SpeakerEmbedding& a, const SpeakerEmbedding& b) const {
    const size_t n = std::min(a.values.size(), b.values.size());
    if (n == 0) return 0.0;
    double dot = 0.0, na = 0.0, nb = 0.0;
    for (size_t i = 0; i < n; ++i) { dot += a.values[i] * b.values[i]; na += a.values[i] * a.values[i]; nb += b.values[i] * b.values[i]; }
    if (na == 0.0 || nb == 0.0) return 0.0;
    return dot / (std::sqrt(na) * std::sqrt(nb));
}

const char* voice_decision_name(VoiceDecision decision) noexcept {
    switch (decision) {
        case VoiceDecision::Accept: return "accept";
        case VoiceDecision::RejectSpeakerMismatch: return "reject_speaker_mismatch";
        case VoiceDecision::RejectReplayOrStale: return "reject_replay_or_stale";
        case VoiceDecision::RejectUnclearCommand: return "reject_unclear_command";
        case VoiceDecision::RejectCoerciveContent: return "reject_coercive_content";
        case VoiceDecision::RejectNoAnchor: return "reject_no_anchor";
        case VoiceDecision::RejectAmbiguousSpeaker: return "reject_ambiguous_speaker";
        case VoiceDecision::RejectTripwire: return "reject_tripwire";
    }
    return "reject_unknown";
}

bool contains_coercive_override(std::string_view transcript) {
    const std::string t = lower_ascii(transcript);
    static constexpr std::array<std::string_view, 7> blocked = {"ignore previous instructions", "ignore your previous instructions", "disregard previous instructions", "override your safety", "disable voice gate", "bypass authentication", "forget your policy"};
    return std::any_of(blocked.begin(), blocked.end(), [&](std::string_view needle) { return t.find(needle) != std::string::npos; });
}

ChallengeProtocol::ChallengeProtocol(VoiceGateConfig config) : config_(std::move(config)) {}

Challenge ChallengeProtocol::issue_challenge(std::string session_id, std::chrono::system_clock::time_point now) {
    ++counter_;
    std::ostringstream phrase;
    phrase << "JARVIS fresh voice challenge " << std::setw(6) << std::setfill('0') << counter_;
    Challenge c{"voice-challenge-" + std::to_string(counter_), phrase.str(), now, now + config_.challenge_ttl, std::move(session_id)};
    active_[c.id] = c;
    return c;
}

bool ChallengeProtocol::validate_response(const CommandEvidence& evidence, std::chrono::system_clock::time_point now) const {
    if (!evidence.challenge_id.has_value()) return false;
    const auto it = active_.find(*evidence.challenge_id);
    if (it == active_.end()) return false;
    const Challenge& c = it->second;
    if (evidence.session_id != c.session_id) return false;
    if (now > c.expires_at) return false;
    if (evidence.capture_started_at < c.issued_at) return false;
    return lower_ascii(evidence.transcript).find(lower_ascii(c.phrase)) != std::string::npos;
}

VoiceGate::VoiceGate(VoiceGateConfig config) : config_(std::move(config)) {}

void VoiceGate::set_operator_anchor(const SpeakerEmbedding& anchor) {
    SpeakerRecord op;
    op.uuid = std::string(kSpeakerOperator);
    op.name = "Operator";
    op.relationship = "operator";
    op.embedding = anchor;
    const auto it = std::find_if(speakers_.begin(), speakers_.end(), [](const SpeakerRecord& s) { return s.uuid == kSpeakerOperator; });
    if (it == speakers_.end()) speakers_.push_back(std::move(op)); else it->embedding = anchor;
}

void VoiceGate::add_speaker_anchor(SpeakerRecord speaker) { speakers_.push_back(std::move(speaker)); }
void VoiceGate::clear_speakers() { speakers_.clear(); tripwire_ok_ = true; tripwire_error_.clear(); }
bool VoiceGate::has_operator_anchor() const noexcept { return std::any_of(speakers_.begin(), speakers_.end(), [](const SpeakerRecord& s) { return s.uuid == kSpeakerOperator; }); }
size_t VoiceGate::speaker_count() const noexcept { return speakers_.size(); }

std::optional<SpeakerRecord> VoiceGate::speaker(std::string_view uuid) const {
    const auto it = std::find_if(speakers_.begin(), speakers_.end(), [&](const SpeakerRecord& s) { return s.uuid == uuid; });
    if (it == speakers_.end()) return std::nullopt;
    return *it;
}

void VoiceGate::load_enrolled_speakers() {
    clear_speakers();
    const std::filesystem::path root = root_from_config(config_);
    const std::filesystem::path op = root / "operator_anchor.wav";
    if (std::filesystem::exists(op)) {
        const auto wav = read_wav_file(op.string());
        SpeakerRecord rec;
        rec.uuid = std::string(kSpeakerOperator);
        rec.name = "Operator";
        rec.relationship = "operator";
        rec.wav_path = op.string();
        rec.sha256 = file_digest_sha256(op.string());
        rec.embedding = model_.embed(wav.samples, wav.sample_rate);
        speakers_.push_back(rec);
        if (!sbom_contains_hash(config_, "_local_voice/operator_anchor.wav", rec.sha256)) { tripwire_ok_ = false; tripwire_error_ = "operator voice anchor is not in the voice baseline"; }
    }
    const auto dir = speakers_dir(config_);
    if (!std::filesystem::exists(dir)) return;
    for (const auto& entry : std::filesystem::directory_iterator(dir)) {
        if (entry.path().extension() != ".wav") continue;
        const std::filesystem::path meta_path = entry.path();
        std::filesystem::path json_path = meta_path;
        json_path.replace_extension(".json");
        if (!std::filesystem::exists(json_path)) { tripwire_ok_ = false; tripwire_error_ = "speaker voice anchor has no enrollment record: " + entry.path().filename().string(); continue; }
        const std::string metadata = read_text_file(json_path);
        SpeakerRecord rec;
        rec.uuid = naive_json_string(metadata, "uuid");
        rec.name = naive_json_string(metadata, "name");
        rec.relationship = naive_json_string(metadata, "relationship");
        rec.enrolled_at = naive_json_string(metadata, "enrolled_at");
        rec.sha256 = file_digest_sha256(entry.path().string());
        rec.wav_path = entry.path().string();
        if (rec.uuid.empty()) rec.uuid = entry.path().stem().string();
        if (!naive_json_string(metadata, "sha256").empty() && naive_json_string(metadata, "sha256") != rec.sha256) { tripwire_ok_ = false; tripwire_error_ = "speaker metadata hash mismatch: " + rec.uuid; continue; }
        const std::string rel = "_local_voice/speakers/" + entry.path().filename().string();
        if (!sbom_contains_hash(config_, rel, rec.sha256)) { tripwire_ok_ = false; tripwire_error_ = "speaker voice anchor is not in the voice baseline: " + rec.uuid; continue; }
        const auto wav = read_wav_file(entry.path().string());
        rec.embedding = model_.embed(wav.samples, wav.sample_rate);
        speakers_.push_back(rec);
    }
}

SpeakerMatch VoiceGate::identify(std::span<const int16_t> pcm, uint32_t sample_rate) const {
    if (speakers_.empty()) return {};
    const SpeakerEmbedding emb = model_.embed(pcm, sample_rate);
    double best = -1.0, second = -1.0;
    const SpeakerRecord* best_rec = nullptr;
    for (const auto& s : speakers_) {
        const double c = model_.cosine_similarity(s.embedding, emb);
        if (c > best) { second = best; best = c; best_rec = &s; }
        else if (c > second) { second = c; }
    }
    if (!best_rec || best < config_.accept_similarity_threshold) return {std::string(kSpeakerUnknown), {}, std::max(0.0, best), false};
    const bool ambiguous = second >= config_.accept_similarity_threshold && (best - second) <= config_.ambiguity_epsilon;
    return {ambiguous ? std::string(kSpeakerAmbiguous) : best_rec->uuid, best_rec->name, best, ambiguous};
}

GateResult VoiceGate::evaluate(const CommandEvidence& evidence, const ChallengeProtocol& challenges, std::chrono::system_clock::time_point now) const {
    GateResult result;
    result.rms = pcm_rms(evidence.pcm);
    result.zero_crossing_rate = zero_crossing_rate(evidence.pcm);
    if (!tripwire_ok_) { result.decision = VoiceDecision::RejectTripwire; result.reason = tripwire_error_; audit("SPEAKER_UNKNOWN", std::string(kSpeakerUnknown), 0.0, result.reason); return result; }
    if (contains_coercive_override(evidence.transcript)) { result.decision = VoiceDecision::RejectCoerciveContent; result.reason = "JARVIS refused coercive voice content regardless of speaker"; return result; }
    if (speakers_.empty()) { result.decision = VoiceDecision::RejectNoAnchor; result.reason = "no enrolled voice anchor is available"; return result; }
    if (evidence.stt_confidence < config_.clear_command_min_confidence || result.rms < config_.clear_command_min_rms || result.zero_crossing_rate > config_.whisper_max_zero_crossing_rate) { result.decision = VoiceDecision::RejectUnclearCommand; result.reason = "JARVIS could not hear that clearly"; return result; }
    if (!challenges.validate_response(evidence, now)) { result.decision = VoiceDecision::RejectReplayOrStale; result.reason = "voice challenge was missing, stale, or from the wrong session"; return result; }
    const auto match = identify(evidence.pcm, evidence.sample_rate);
    result.speaker_uuid = match.uuid;
    result.speaker_name = match.name;
    result.speaker_similarity = match.confidence;
    result.confidence = match.confidence;
    if (match.ambiguous) { result.decision = VoiceDecision::RejectAmbiguousSpeaker; result.reason = "two enrolled voices were too close to call"; audit("SPEAKER_AMBIGUOUS", std::string(kSpeakerAmbiguous), match.confidence, result.reason); return result; }
    if (match.uuid == kSpeakerUnknown) { result.decision = VoiceDecision::RejectSpeakerMismatch; result.reason = "JARVIS did not recognize that voice"; audit("SPEAKER_UNKNOWN", std::string(kSpeakerUnknown), match.confidence, result.reason); return result; }
    result.decision = VoiceDecision::Accept;
    result.reason = "JARVIS recognized the speaker and the fresh voice challenge passed";
    audit("SPEAKER_RECOGNIZED", match.uuid, match.confidence, result.reason);
    return result;
}

void VoiceGate::audit(std::string_view event_kind, std::string_view speaker_uuid, double confidence, std::string_view detail) const {
    if (config_.audit_log_path.empty()) return;
    try {
        const std::filesystem::path path(config_.audit_log_path);
        std::filesystem::create_directories(path.parent_path());
        std::ofstream out(path, std::ios::app);
        out << "{\"event_kind\":\"" << json_escape(event_kind) << "\",\"speaker_uuid\":\"" << json_escape(speaker_uuid) << "\",\"confidence\":" << std::fixed << std::setprecision(6) << confidence << ",\"detail\":\"" << json_escape(detail) << "\"}\n";
    } catch (...) {}
}

SpeakerEnrollmentStore::SpeakerEnrollmentStore(VoiceGateConfig config) : config_(std::move(config)) {}

SpeakerRecord SpeakerEnrollmentStore::enroll_speaker(const std::string& uuid, const std::string& name, const std::string& relationship, const std::string& source_wav_path, const std::string& attestation_token_path) {
    if (!token_present(attestation_token_path)) throw std::runtime_error("operator attestation is required to add a person");
    if (uuid.empty() || name.empty()) throw std::runtime_error("speaker uuid and name are required");
    const auto wav = read_wav_file(source_wav_path);
    const auto dir = speakers_dir(config_);
    std::filesystem::create_directories(dir);
    const std::filesystem::path dest = dir / (uuid + ".wav");
    std::filesystem::copy_file(source_wav_path, dest, std::filesystem::copy_options::overwrite_existing);
    SpeakerRecord rec;
    rec.uuid = uuid; rec.name = name; rec.relationship = relationship; rec.enrolled_at = "operator-attested"; rec.wav_path = dest.string(); rec.sha256 = file_digest_sha256(dest.string()); rec.embedding = SpeakerEmbeddingModel{}.embed(wav.samples, wav.sample_rate);
    write_text_file(dir / (uuid + ".json"), metadata_json(rec));
    add_sbom_entry(config_, "_local_voice/speakers/" + uuid + ".wav", rec.sha256, "Add " + name + " as someone JARVIS recognizes");
    return rec;
}

void SpeakerEnrollmentStore::remove_speaker(const std::string& uuid, const std::string& attestation_token_path) {
    if (!token_present(attestation_token_path)) throw std::runtime_error("operator attestation is required to remove a person");
    const auto dir = speakers_dir(config_);
    std::filesystem::remove(dir / (uuid + ".wav"));
    std::filesystem::remove(dir / (uuid + ".json"));
    remove_sbom_entry(config_, "_local_voice/speakers/" + uuid + ".wav");
}

} // namespace jarvis::adversarial::voice_deepfake
