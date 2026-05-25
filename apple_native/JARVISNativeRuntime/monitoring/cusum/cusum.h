// ============================================================
// MONITORING MODULE (GMRI / JARVIS Native Runtime)
//
// CUSUM drift monitoring observes cognition organs (Swarm,
// BeliefStore, Endocrine, voice/probe streams) for statistical drift
// from a baseline. It is not itself a cognition organ. Resetting its drift
// score requires verified operator attestation so drift cannot be silently forgiven.
// ============================================================
#pragma once

#include "operator_attestation.h"
#include "../../integrity/audit/audit_log.h"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <functional>
#include <memory>
#include <set>
#include <stdexcept>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace jarvis::monitoring::cusum {

using OperatorAttestation = jarvis::identity::operator_attestation::AttestationVerdict;

class ResetAttestationError final : public std::runtime_error {
public:
    explicit ResetAttestationError(const std::string& reason) : std::runtime_error(reason) {}
};

class CUSUMPersistenceError final : public std::runtime_error {
public:
    explicit CUSUMPersistenceError(const std::string& reason) : std::runtime_error(reason) {}
};

struct Parameters {
    double mean = 0.4326118326118326;
    double sigma = 0.16683320951983083;
    double slack = 0.5;
    double threshold = 3.0;
};

struct WilsonInterval {
    double lo = 0.0;
    double hi = 1.0;
};

struct StepResult {
    std::string organ;
    double timestamp = 0.0;
    double observed = 0.0;
    double z = 0.0;
    double cumulative = 0.0;
    bool threshold_crossed = false;
};

struct OrganScore {
    std::string organ;
    double drift_score = 0.0;
    double threshold = 0.0;
    bool threshold_crossed = false;
    double timestamp = 0.0;
};

struct Scorecard {
    double timestamp = 0.0;
    std::vector<OrganScore> organs;
};

struct VoiceFeatures {
    double sir_rate = 0.0;
    double quant_rate = 0.0;
    double median_len = 0.0;
};

class ConsumedChallengeStore {
public:
    explicit ConsumedChallengeStore(std::filesystem::path path = default_path());

    [[nodiscard]] bool consume(const OperatorAttestation& attestation);
    [[nodiscard]] bool consumed(const std::string& challenge_id) const;

    static std::filesystem::path default_path();

    // Returns a stable identity string for this store, used as store_id in
    // consumed-challenge audit events to make cross-store replay detectable.
    [[nodiscard]] std::string store_id() const { return path_.string(); }

private:
    void load_existing_();

    std::filesystem::path path_;
    mutable std::mutex mutex_;
    std::set<std::string> consumed_;
};

class Detector {
public:
    using PersistenceCallback = std::function<void(const std::string&, const Parameters&, double, double, const std::string&)>;

    explicit Detector(Parameters parameters = {}, PersistenceCallback persistence_callback = {});

    StepResult observe(double value, double timestamp, std::string organ = "voice");
    void reset(const std::string& organ, const OperatorAttestation& attestation, ConsumedChallengeStore& challenge_store);

    [[nodiscard]] double cumulative() const noexcept { return cumulative_; }
    [[nodiscard]] const Parameters& parameters() const noexcept { return parameters_; }

private:
    friend class ScorecardMonitor;

    [[nodiscard]] StepResult preview_(double value, double timestamp, std::string organ) const;
    void restore_(double cumulative) noexcept { cumulative_ = std::max(0.0, cumulative); }

    Parameters parameters_;
    double cumulative_ = 0.0;
    PersistenceCallback persistence_callback_;
};

class ScorecardMonitor {
public:
    explicit ScorecardMonitor(Parameters defaults = {},
                              std::filesystem::path consumed_challenge_path = ConsumedChallengeStore::default_path(),
                              audit::TamperEvidentAuditLog* audit_log = nullptr,
                              std::filesystem::path drift_store_path = default_drift_path());

    static std::filesystem::path default_drift_path();

    StepResult observe(const std::string& organ, double value, double timestamp);
    void configure(const std::string& organ, Parameters parameters);
    void reset(const std::string& organ, const OperatorAttestation& attestation);
    [[nodiscard]] Scorecard scorecard(double timestamp) const;

private:
    Parameters defaults_;
    mutable std::mutex mutex_;
    ConsumedChallengeStore challenge_store_;
    audit::TamperEvidentAuditLog* audit_log_ = nullptr;
    std::filesystem::path drift_store_path_;
    std::unordered_map<std::string, Detector> detectors_;
    std::map<std::string, OrganScore> latest_;

    [[nodiscard]] Detector make_detector_(Parameters parameters);
    void persist_drift_or_throw_(const std::string& organ, const Parameters& parameters,
                                 double cumulative, double timestamp, const std::string& type);
    [[nodiscard]] bool append_drift_record_(const std::string& record) const noexcept;
    [[nodiscard]] bool replay_drift_records_() noexcept;
    void audit_(std::string kind, std::string subject, std::string outcome,
                std::string reason, std::string metadata = {}) const;
};

[[nodiscard]] WilsonInterval wilson_interval(int successes, int n, double z = 1.96);
[[nodiscard]] VoiceFeatures extract_voice_features(const std::vector<std::string>& texts);
[[nodiscard]] double sir_rate(std::string_view text);
[[nodiscard]] double round_to(double value, int places);
[[nodiscard]] double unix_timestamp_now();

} // namespace jarvis::monitoring::cusum
