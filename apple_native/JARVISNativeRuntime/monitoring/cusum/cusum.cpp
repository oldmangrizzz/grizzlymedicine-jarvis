#include "cusum.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <limits>
#include <optional>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <system_error>
#include <vector>

#include <fcntl.h>
#include <pwd.h>
#include <sodium.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace jarvis::monitoring::cusum {
namespace {

bool finite_positive(double value) noexcept {
    return std::isfinite(value) && value > 0.0;
}

bool contains_regex(std::string_view text, const std::regex& pattern) {
    return std::regex_search(text.begin(), text.end(), pattern);
}

std::size_t word_count(const std::string& text) {
    std::istringstream in(text);
    return static_cast<std::size_t>(std::distance(std::istream_iterator<std::string>{in},
                                                  std::istream_iterator<std::string>{}));
}

std::filesystem::path home_directory_or_throw() {
    if (const char* home = std::getenv("HOME"); home && *home) return home;
    if (const passwd* pw = ::getpwuid(::getuid()); pw && pw->pw_dir && *pw->pw_dir) return pw->pw_dir;
    throw std::runtime_error("cannot resolve HOME for JARVIS CUSUM consumed challenge store");
}

std::int64_t unix_seconds_now() {
    using namespace std::chrono;
    return duration_cast<seconds>(system_clock::now().time_since_epoch()).count();
}

void ensure_parent_dir(const std::filesystem::path& path) {
    const auto parent = path.parent_path();
    if (parent.empty()) return;
    std::filesystem::create_directories(parent);
    ::chmod(parent.c_str(), 0700);
}

void ensure_sodium() {
    if (sodium_init() < 0) throw ResetAttestationError("ConsumedChallengeStore refused: libsodium initialization failed");
}

std::string hex_encode_bytes(const unsigned char* data, std::size_t size) {
    std::string out(size * 2, '0');
    static constexpr char h[] = "0123456789abcdef";
    for (std::size_t i = 0; i < size; ++i) {
        out[2 * i] = h[(data[i] >> 4) & 0xf];
        out[2 * i + 1] = h[data[i] & 0xf];
    }
    return out;
}

// Not an audit-chain key: this per-store HMAC key only authenticates local consumed-challenge replay markers.
std::array<unsigned char, 32> load_or_create_store_key(const std::filesystem::path& store_path) {
    ensure_parent_dir(store_path);
    const auto key_path = store_path.string() + ".key";
    std::array<unsigned char, 32> key{};
    int fd = ::open(key_path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (fd >= 0) {
        const ssize_t n = ::read(fd, key.data(), key.size());
        ::close(fd);
        if (n != static_cast<ssize_t>(key.size())) throw ResetAttestationError("ConsumedChallengeStore refused: corrupt HMAC key");
        return key;
    }
    ensure_sodium();
    randombytes_buf(key.data(), key.size());
    fd = ::open(key_path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) throw ResetAttestationError("ConsumedChallengeStore refused: cannot create HMAC key");
    const ssize_t n = ::write(fd, key.data(), key.size());
    if (::fsync(fd) != 0) { ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: HMAC key fsync failed"); }
    ::close(fd);
    if (n != static_cast<ssize_t>(key.size())) throw ResetAttestationError("ConsumedChallengeStore refused: HMAC key write incomplete");
    return key;
}

std::string json_field(const std::string& line, const std::string& key) {
    const std::string needle = "\"" + key + "\":\"";
    const auto pos = line.find(needle);
    if (pos == std::string::npos) return {};
    const auto start = pos + needle.size();
    const auto end = line.find('"', start);
    if (end == std::string::npos) return {};
    return line.substr(start, end - start);
}

std::string canonical_challenge(const std::string& challenge_id, const std::string& operation, const std::string& subject, std::int64_t issued_at, const std::string& prev_hmac) {
    return "challenge_id=" + challenge_id + "\nissued_at=" + std::to_string(issued_at) + "\noperation=" + operation + "\nprev_hmac=" + prev_hmac + "\nsubject=" + subject + "\n";
}

std::string hmac_line(const std::array<unsigned char, 32>& key, const std::string& canonical) {
    ensure_sodium();
    std::array<unsigned char, crypto_auth_hmacsha256_BYTES> out{};
    crypto_auth_hmacsha256(out.data(), reinterpret_cast<const unsigned char*>(canonical.data()), canonical.size(), key.data());
    return hex_encode_bytes(out.data(), out.size());
}


std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    std::ostringstream os;
                    os << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                    out += os.str();
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

std::optional<std::string> json_string_field_strict(const std::string& line, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    const auto pos = line.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    std::size_t i = pos + needle.size();
    while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    if (i >= line.size() || line[i] != '"') return std::nullopt;
    ++i;
    std::string out;
    while (i < line.size()) {
        const char c = line[i++];
        if (c == '"') return out;
        if (c != '\\') {
            if (static_cast<unsigned char>(c) < 0x20) return std::nullopt;
            out.push_back(c);
            continue;
        }
        if (i >= line.size()) return std::nullopt;
        const char e = line[i++];
        switch (e) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            default: return std::nullopt;
        }
    }
    return std::nullopt;
}

std::optional<double> json_double_field(const std::string& line, const std::string& key) {
    const std::string needle = "\"" + key + "\":";
    const auto pos = line.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    std::size_t i = pos + needle.size();
    while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    std::size_t end = i;
    while (end < line.size()) {
        const char c = line[end];
        if (!(std::isdigit(static_cast<unsigned char>(c)) || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E')) break;
        ++end;
    }
    if (end == i) return std::nullopt;
    try {
        double value = std::stod(line.substr(i, end - i));
        if (!std::isfinite(value)) return std::nullopt;
        return value;
    } catch (...) {
        return std::nullopt;
    }
}

bool mkdirs_0700(const std::filesystem::path& dir) noexcept {
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    if (ec) return false;
    ::chmod(dir.c_str(), 0700);
    return true;
}

bool write_all(int fd, const std::string& data) noexcept {
    const char* p = data.data();
    std::size_t remaining = data.size();
    while (remaining > 0) {
        const ssize_t n = ::write(fd, p, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += n;
        remaining -= static_cast<std::size_t>(n);
    }
    return true;
}

bool same_parameters(const Parameters& a, const Parameters& b) noexcept {
    return a.mean == b.mean && a.sigma == b.sigma && a.slack == b.slack && a.threshold == b.threshold;
}

std::string drift_record_json(const std::string& organ, const Parameters& parameters,
                              double cumulative, double timestamp, const std::string& type) {
    std::ostringstream os;
    os << std::setprecision(17)
       << "{\"cumulative\":" << std::max(0.0, cumulative)
       << ",\"mean\":" << parameters.mean
       << ",\"organ\":\"" << json_escape(organ)
       << "\",\"sigma\":" << parameters.sigma
       << ",\"slack\":" << parameters.slack
       << ",\"threshold\":" << parameters.threshold
       << ",\"ts\":" << timestamp
       << ",\"type\":\"" << json_escape(type)
       << "\",\"updated_unix\":" << unix_seconds_now() << "}\n";
    return os.str();
}

bool valid_reset_verdict(const std::string& organ, const OperatorAttestation& attestation) {
    constexpr std::int64_t kPastFreshnessSeconds = 5 * 60;
    constexpr std::int64_t kFutureJitterSeconds = 1;
    if (!attestation.allowed()) return false;
    if (attestation.bound_operation != "cusum_reset") return false;
    if (attestation.bound_subject != organ) return false;
    if (attestation.bound_challenge_id.empty()) return false;
    if (attestation.monotonic_at) {
        const auto delta = std::chrono::steady_clock::now() - *attestation.monotonic_at;
        return delta >= -std::chrono::seconds(kFutureJitterSeconds) &&
               delta <= std::chrono::seconds(kPastFreshnessSeconds);
    }
    const auto now = unix_seconds_now();
    return attestation.bound_issued_at >= now - kPastFreshnessSeconds &&
           attestation.bound_issued_at <= now + kFutureJitterSeconds;
}

} // namespace

std::filesystem::path ConsumedChallengeStore::default_path() {
    return home_directory_or_throw() / ".jarvis" / "state" / "consumed_challenges.jsonl";
}

std::filesystem::path ScorecardMonitor::default_drift_path() {
    return ConsumedChallengeStore::default_path().parent_path() / "cusum_drift.jsonl";
}

ConsumedChallengeStore::ConsumedChallengeStore(std::filesystem::path path) : path_(std::move(path)) {
    load_existing_();
}

void ConsumedChallengeStore::load_existing_() {
    std::lock_guard<std::mutex> lock(mutex_);
    consumed_.clear();
    const auto key = load_or_create_store_key(path_);
    int fd = ::open(path_.c_str(), O_RDONLY | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) throw ResetAttestationError("ConsumedChallengeStore refused: cannot open chain");
    if (flock(fd, LOCK_SH) != 0) { ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: cannot lock chain"); }
    FILE* file = fdopen(fd, "r");
    if (!file) { ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: fdopen failed"); }
    char* raw = nullptr;
    size_t cap = 0;
    std::string prev(64, '0');
    while (true) {
        const ssize_t n = getline(&raw, &cap, file);
        if (n < 0) break;
        std::string line(raw, static_cast<std::size_t>(n));
        if (!line.empty() && line.back() == '\n') line.pop_back();
        if (line.empty()) continue;
        const auto challenge = json_field(line, "challenge_id");
        const auto operation = json_field(line, "operation");
        const auto subject = json_field(line, "subject");
        const auto prev_hmac = json_field(line, "prev_hmac");
        const auto hmac = json_field(line, "hmac");
        const auto issued_raw = json_field(line, "issued_at");
        if (challenge.empty() || operation.empty() || subject.empty() || prev_hmac.empty() || hmac.empty() || issued_raw.empty()) {
            free(raw); fclose(file); throw ResetAttestationError("ConsumedChallengeStore refused: malformed chain line");
        }
        const auto issued = std::stoll(issued_raw);
        if (prev_hmac != prev) { free(raw); fclose(file); throw ResetAttestationError("ConsumedChallengeStore refused: broken previous-HMAC link"); }
        const auto expected = hmac_line(key, canonical_challenge(challenge, operation, subject, issued, prev_hmac));
        if (expected != hmac) { free(raw); fclose(file); throw ResetAttestationError("ConsumedChallengeStore refused: forged chain line"); }
        consumed_.insert(challenge);
        prev = hmac;
    }
    free(raw);
    flock(fd, LOCK_UN);
    fclose(file);
}

bool ConsumedChallengeStore::consumed(const std::string& challenge_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return consumed_.contains(challenge_id);
}

bool ConsumedChallengeStore::consume(const OperatorAttestation& attestation) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (attestation.bound_challenge_id.empty() || consumed_.contains(attestation.bound_challenge_id)) return false;
    const auto key = load_or_create_store_key(path_);
    ensure_parent_dir(path_);
    int fd = ::open(path_.c_str(), O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd < 0) throw ResetAttestationError("ConsumedChallengeStore refused: cannot open chain for append");
    if (flock(fd, LOCK_EX) != 0) { ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: cannot lock chain for append"); }
    std::string prev(64, '0');
    {
        std::ifstream in(path_);
        std::string line;
        while (std::getline(in, line)) {
            if (!line.empty()) prev = json_field(line, "hmac");
        }
    }
    const auto canonical = canonical_challenge(attestation.bound_challenge_id, attestation.bound_operation, attestation.bound_subject, attestation.bound_issued_at, prev);
    const auto hmac = hmac_line(key, canonical);
    const std::string line = std::string("{\"challenge_id\":\"") + attestation.bound_challenge_id +
        "\",\"hmac\":\"" + hmac +
        "\",\"issued_at\":\"" + std::to_string(attestation.bound_issued_at) +
        "\",\"operation\":\"" + attestation.bound_operation +
        "\",\"prev_hmac\":\"" + prev +
        "\",\"subject\":\"" + attestation.bound_subject + "\"}\n";
    if (line.size() > 512) { flock(fd, LOCK_UN); ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: record exceeds PIPE_BUF"); }
    const char* data = line.data();
    std::size_t remaining = line.size();
    while (remaining > 0) {
        ssize_t n = ::write(fd, data, remaining);
        if (n < 0) {
            if (errno == EINTR) continue;
            flock(fd, LOCK_UN); ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: append failed");
        }
        data += n;
        remaining -= static_cast<std::size_t>(n);
    }
    if (::fsync(fd) != 0) { flock(fd, LOCK_UN); ::close(fd); throw ResetAttestationError("ConsumedChallengeStore refused: fsync failed"); }
    flock(fd, LOCK_UN);
    ::close(fd);
    consumed_.insert(attestation.bound_challenge_id);
    return true;
}

Detector::Detector(Parameters parameters, PersistenceCallback persistence_callback)
    : parameters_(parameters), persistence_callback_(std::move(persistence_callback)) {
    if (!finite_positive(parameters_.sigma)) {
        throw std::invalid_argument("CUSUM sigma must be finite and positive");
    }
    if (!std::isfinite(parameters_.mean) || !std::isfinite(parameters_.slack) ||
        !std::isfinite(parameters_.threshold)) {
        throw std::invalid_argument("CUSUM parameters must be finite");
    }
}

StepResult Detector::preview_(double value, double timestamp, std::string organ) const {
    if (!std::isfinite(value)) value = parameters_.mean;
    const double z = (parameters_.mean - value) / parameters_.sigma;
    const double next = std::max(0.0, cumulative_ + z - parameters_.slack);
    return StepResult{std::move(organ), timestamp, value, z, next, next > parameters_.threshold};
}

StepResult Detector::observe(double value, double timestamp, std::string organ) {
    StepResult step = preview_(value, timestamp, std::move(organ));
    if (persistence_callback_) {
        persistence_callback_(step.organ, parameters_, step.cumulative, timestamp, "observe");
    }
    cumulative_ = step.cumulative;
    return step;
}

void Detector::reset(const std::string& organ, const OperatorAttestation& attestation, ConsumedChallengeStore& challenge_store) {
    if (!valid_reset_verdict(organ, attestation)) {
        throw ResetAttestationError("CUSUM reset refused: verdict is not bound to cusum_reset for this organ within freshness window");
    }
    if (!challenge_store.consume(attestation)) {
        throw ResetAttestationError("CUSUM reset refused: challenge was already consumed or could not be persisted");
    }
    if (persistence_callback_) {
        persistence_callback_(organ, parameters_, 0.0, unix_timestamp_now(), "reset");
    }
    cumulative_ = 0.0;
}

ScorecardMonitor::ScorecardMonitor(Parameters defaults, std::filesystem::path consumed_challenge_path,
                                   audit::TamperEvidentAuditLog* audit_log,
                                   std::filesystem::path drift_store_path)
    : defaults_(defaults),
      challenge_store_(std::move(consumed_challenge_path)),
      audit_log_(audit_log),
      drift_store_path_(std::move(drift_store_path)) {
    (void)replay_drift_records_();
}

void ScorecardMonitor::configure(const std::string& organ, Parameters parameters) {
    std::lock_guard<std::mutex> lock(mutex_);
    detectors_.insert_or_assign(organ, make_detector_(parameters));
}

StepResult ScorecardMonitor::observe(const std::string& organ, double value, double timestamp) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = detectors_.find(organ);
    if (it == detectors_.end()) {
        it = detectors_.emplace(organ, make_detector_(defaults_)).first;
    }
    StepResult step = it->second.observe(value, timestamp, organ);
    latest_[organ] = OrganScore{organ, step.cumulative, it->second.parameters().threshold,
                                step.threshold_crossed, timestamp};
    return step;
}

void ScorecardMonitor::reset(const std::string& organ, const OperatorAttestation& attestation) {
    if (!valid_reset_verdict(organ, attestation)) {
        throw ResetAttestationError("CUSUM scorecard reset refused: verdict is not bound to cusum_reset for this organ within freshness window");
    }
    if (!challenge_store_.consume(attestation)) {
        throw ResetAttestationError("CUSUM scorecard reset refused: challenge was already consumed or could not be persisted");
    }
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = detectors_.find(organ);
    const Parameters parameters = it != detectors_.end() ? it->second.parameters() : defaults_;
    persist_drift_or_throw_(organ, parameters, 0.0, unix_timestamp_now(), "reset");
    if (it != detectors_.end()) {
        it->second = make_detector_(parameters);
    } else {
        detectors_.emplace(organ, make_detector_(parameters));
    }
    latest_[organ] = OrganScore{organ, 0.0, parameters.threshold, false, unix_timestamp_now()};
}

Scorecard ScorecardMonitor::scorecard(double timestamp) const {
    std::lock_guard<std::mutex> lock(mutex_);
    Scorecard out;
    out.timestamp = timestamp;
    out.organs.reserve(latest_.size());
    for (const auto& [_, score] : latest_) out.organs.push_back(score);
    return out;
}


Detector ScorecardMonitor::make_detector_(Parameters parameters) {
    return Detector(parameters, [this](const std::string& organ, const Parameters& p,
                                      double cumulative, double timestamp, const std::string& type) {
        persist_drift_or_throw_(organ, p, cumulative, timestamp, type);
    });
}

void ScorecardMonitor::persist_drift_or_throw_(const std::string& organ, const Parameters& parameters,
                                               double cumulative, double timestamp, const std::string& type) {
    const std::string record = drift_record_json(organ, parameters, cumulative, timestamp, type);
    if (record.size() > audit::TamperEvidentAuditLog::kPipeBufAtomicBytes) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, organ, audit::Outcome::DENIED,
               "record_too_large", "{\"bytes\":" + std::to_string(record.size()) + "}");
        throw CUSUMPersistenceError("CUSUM persistence_unavailable: record exceeds PIPE_BUF");
    }
    if (!append_drift_record_(record)) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, organ, audit::Outcome::DENIED,
               "persistence_unavailable", "{\"type\":\"" + json_escape(type) + "\"}");
        throw CUSUMPersistenceError("CUSUM persistence_unavailable: append failed");
    }
    audit_(audit::EventKind::CUSUM_DRIFT_PERSISTED, organ, audit::Outcome::ALLOWED,
           type == "reset" ? "drift_reset_persisted" : "drift_observe_persisted",
           type == "reset"
               ? ("{\"type\":\"reset\",\"store_id\":\"" + json_escape(challenge_store_.store_id()) + "\"}")
               : ("{\"type\":\"" + json_escape(type) + "\"}"));
}

bool ScorecardMonitor::append_drift_record_(const std::string& record) const noexcept {
    if (record.size() > audit::TamperEvidentAuditLog::kPipeBufAtomicBytes) return false;
    const auto parent = drift_store_path_.parent_path();
    if (!mkdirs_0700(parent)) return false;
    const int fd = ::open(drift_store_path_.c_str(), O_APPEND | O_CREAT | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    bool ok = false;
    do {
        if (::flock(fd, LOCK_EX) != 0) break;
        ::fchmod(fd, 0600);
        if (!write_all(fd, record)) break;
        if (::fsync(fd) != 0) break;
        ok = true;
    } while (false);
    const int saved_errno = errno;
    (void)::flock(fd, LOCK_UN);
    (void)::close(fd);
    errno = saved_errno;
    return ok;
}

bool ScorecardMonitor::replay_drift_records_() noexcept {
    std::error_code exists_error;
    if (!std::filesystem::exists(drift_store_path_, exists_error)) {
        return true;
    }
    if (exists_error) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, "cusum_drift", audit::Outcome::DEFERRED,
               "persistence_unavailable", "{\"phase\":\"reload\"}");
        return false;
    }

    const int fd = ::open(drift_store_path_.c_str(), O_RDONLY | O_CLOEXEC, 0600);
    if (fd < 0) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, "cusum_drift", audit::Outcome::DEFERRED,
               "persistence_unavailable", "{\"phase\":\"reload\"}");
        return false;
    }

    std::string data;
    bool io_ok = true;
    if (::flock(fd, LOCK_EX) != 0) {
        io_ok = false;
    } else {
        ::fchmod(fd, 0600);
        char buffer[4096];
        while (true) {
            const ssize_t n = ::read(fd, buffer, sizeof(buffer));
            if (n < 0) {
                if (errno == EINTR) continue;
                io_ok = false;
                break;
            }
            if (n == 0) break;
            data.append(buffer, static_cast<std::size_t>(n));
        }
    }
    (void)::flock(fd, LOCK_UN);
    (void)::close(fd);
    if (!io_ok) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, "cusum_drift", audit::Outcome::DEFERRED,
               "persistence_unavailable", "{\"phase\":\"reload\"}");
        return false;
    }

    struct RestoredRecord { Parameters parameters; double cumulative; double timestamp; };
    std::unordered_map<std::string, RestoredRecord> latest_by_organ;
    bool saw_invalid = false;
    bool saw_config_drift = false;
    std::size_t start = 0;
    while (start < data.size()) {
        const std::size_t end = data.find('\n', start);
        if (end == std::string::npos) {
            if (start < data.size()) saw_invalid = true;
            break;
        }
        const std::string line = data.substr(start, end - start);
        start = end + 1;
        if (line.empty()) continue;
        if (line.size() + 1 > audit::TamperEvidentAuditLog::kPipeBufAtomicBytes) {
            saw_invalid = true;
            continue;
        }
        const auto type = json_string_field_strict(line, "type");
        const auto organ = json_string_field_strict(line, "organ");
        const auto cumulative = json_double_field(line, "cumulative");
        const auto mean = json_double_field(line, "mean");
        const auto sigma = json_double_field(line, "sigma");
        const auto slack = json_double_field(line, "slack");
        const auto threshold = json_double_field(line, "threshold");
        const auto timestamp = json_double_field(line, "ts");
        if (!type || !organ || !cumulative || !mean || !sigma || !slack || !threshold || !timestamp ||
            (*type != "observe" && *type != "reset")) {
            saw_invalid = true;
            continue;
        }
        Parameters p{*mean, *sigma, *slack, *threshold};
        if (!same_parameters(p, defaults_)) {
            saw_config_drift = true;
            continue;
        }
        latest_by_organ[*organ] = RestoredRecord{p, std::max(0.0, *cumulative), *timestamp};
    }

    for (const auto& [organ, restored] : latest_by_organ) {
        auto detector = make_detector_(restored.parameters);
        detector.restore_(restored.cumulative);
        detectors_.insert_or_assign(organ, std::move(detector));
        latest_[organ] = OrganScore{organ, restored.cumulative, restored.parameters.threshold,
                                    restored.cumulative > restored.parameters.threshold, restored.timestamp};
    }
    if (saw_invalid) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, "cusum_drift", audit::Outcome::DENIED,
               "drift_record_invalid", "{\"phase\":\"reload\"}");
    }
    if (saw_config_drift) {
        audit_(audit::EventKind::CUSUM_PERSISTENCE_DENIED, "cusum_drift", audit::Outcome::DENIED,
               "config_drift_skip", "{\"phase\":\"reload\"}");
    }
    audit_(audit::EventKind::CUSUM_DRIFT_PERSISTED, "cusum_drift", "RELOADED",
           "drift_reload_complete", "{\"restored_organs\":" + std::to_string(latest_by_organ.size()) + "}");
    return true;
}

void ScorecardMonitor::audit_(std::string kind, std::string subject, std::string outcome,
                              std::string reason, std::string metadata) const {
    if (!audit_log_) return;
    audit::AuditEvent event;
    event.event_kind = std::move(kind);
    event.actor = audit::Actor::SELF;
    event.subject = std::move(subject);
    event.outcome = std::move(outcome);
    event.reason = std::move(reason);
    event.redacted_metadata = std::move(metadata);
    event.organ = "cusum";
    audit_log_->append(std::move(event));
}

WilsonInterval wilson_interval(int successes, int n, double z) {
    if (n <= 0) return {0.0, 1.0};
    successes = std::clamp(successes, 0, n);
    const double p = static_cast<double>(successes) / static_cast<double>(n);
    const double d = 1.0 + z * z / static_cast<double>(n);
    const double centre = (p + z * z / (2.0 * n)) / d;
    const double half = (z * std::sqrt(p * (1.0 - p) / n + z * z / (4.0 * n * n))) / d;
    return {std::max(0.0, centre - half), std::min(1.0, centre + half)};
}

double sir_rate(std::string_view text) {
    static const std::regex sir_pattern(R"(\bsir\b)", std::regex_constants::icase);
    return contains_regex(text, sir_pattern) ? 1.0 : 0.0;
}

VoiceFeatures extract_voice_features(const std::vector<std::string>& texts) {
    if (texts.empty()) return {};
    static const std::regex sir_pattern(R"(\bsir\b)", std::regex_constants::icase);
    static const std::regex quant_pattern(R"(\d|percent|degrees|yards|meters)", std::regex_constants::icase);

    std::vector<double> lengths;
    lengths.reserve(texts.size());
    int sir_hits = 0;
    int quant_hits = 0;
    for (const auto& text : texts) {
        if (contains_regex(text, sir_pattern)) ++sir_hits;
        if (contains_regex(text, quant_pattern)) ++quant_hits;
        lengths.push_back(static_cast<double>(word_count(text)));
    }

    std::sort(lengths.begin(), lengths.end());
    const std::size_t n = lengths.size();
    const double median = (n % 2 == 1) ? lengths[n / 2] : (lengths[n / 2 - 1] + lengths[n / 2]) / 2.0;
    return {static_cast<double>(sir_hits) / texts.size(),
            static_cast<double>(quant_hits) / texts.size(),
            median};
}

double round_to(double value, int places) {
    if (!std::isfinite(value)) return 0.0;
    const double scale = std::pow(10.0, places);
    return std::round(value * scale) / scale;
}

double unix_timestamp_now() {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration<double>(now).count();
}

} // namespace jarvis::monitoring::cusum
