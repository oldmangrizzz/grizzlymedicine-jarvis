#pragma once

#include "../../endocrine/endocrine.h"
#include "../../pheromind/pheromind.h"
#include "../../swarm/swarm.h"
#include "../../holograph/beliefstore/beliefstore.h"
#include "../../holograph/hmem/hmem.h"
#include "../../monitoring/cusum/cusum.h"
#include "../../resilience/degradation/degradation.h"
#include "../../integrity/audit/audit_log.h"
#include "../character_values/character_values.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace jarvis::identity::self_health {

struct EndocrineState {
    double cortisol = 0.0;
    double dopamine = 0.0;
    double adrenaline = 0.0;
    double field_volatility = 0.0;
    bool present = false;
};

struct PheromindState {
    std::size_t live_signals = 0;
    std::size_t sampled_signals = 0;
    double mean_strength = 0.0;
    double max_strength = 0.0;
    double alarm_strength = 0.0;
    double volatility = 0.0;
    bool volatile_field = false;
    bool present = false;
};

struct SwarmHeadState {
    std::size_t configured_heads = 0;
    bool has_available_head = false;
    bool present = false;
};

struct BeliefConfidenceDistribution {
    std::size_t total_edges = 0;
    std::size_t sampled_edges = 0;
    std::size_t low_confidence = 0;
    std::size_t medium_confidence = 0;
    std::size_t high_confidence = 0;
    double mean_confidence = 0.0;
    bool present = false;
};

struct HMemTierOccupancy {
    std::size_t short_term = 0;
    std::size_t working = 0;
    std::size_t long_term = 0;
    std::size_t belief = 0;
    bool present = false;
};

struct CusumDriftState {
    double max_drift_score = 0.0;
    double max_threshold = 0.0;
    std::string max_organ;
    bool threshold_crossed = false;
    bool present = false;
};

struct IntegrityChainState {
    std::string status = "unknown";
    bool warning = false;
    bool present = false;
};

struct SelfState {
    double timestamp = 0.0;
    EndocrineState endocrine;
    PheromindState pheromind;
    SwarmHeadState swarm;
    BeliefConfidenceDistribution beliefstore;
    HMemTierOccupancy hmem;
    CusumDriftState cusum;
    resilience::degradation::DegradationTier degradation_tier = resilience::degradation::DegradationTier::normal;
    bool degradation_present = false;
    IntegrityChainState identity_chain;
    IntegrityChainState audit_chain;
    std::vector<std::string> distress_reasons;
    std::string summary;
};

struct SelfHealthConfig {
    double tick_hz = 1.0;
    std::size_t max_pheromind_signals = 512;
    std::size_t max_belief_edges = 2048;
    double pheromind_volatility_threshold = 0.70;
    double severe_drift_ratio = 1.0;
    int audit_degradation_tier_threshold = 3;
};

struct SelfHealthOrgans {
    Endocrine* endocrine = nullptr;
    Pheromind* pheromind = nullptr;
    ModelSwarm* swarm = nullptr;
    BeliefStore* beliefstore = nullptr;
    hmem::HMemRouter* hmem = nullptr;
    monitoring::cusum::ScorecardMonitor* cusum = nullptr;
    resilience::degradation::DegradationController* degradation = nullptr;
    audit::TamperEvidentAuditLog* audit_log = nullptr;
    std::function<IdentityStatus()> identity_status_reader;
    std::function<double()> clock;
};

class SelfHealth {
public:
    explicit SelfHealth(SelfHealthOrgans organs, SelfHealthConfig config = {});
    ~SelfHealth();

    SelfHealth(const SelfHealth&) = delete;
    SelfHealth& operator=(const SelfHealth&) = delete;
    SelfHealth(SelfHealth&&) = delete;
    SelfHealth& operator=(SelfHealth&&) = delete;

    [[nodiscard]] SelfState current();
    [[nodiscard]] SelfState cached() const;

    static std::string summarize(const SelfState& state);
    static std::function<double()> default_clock();

private:
    SelfHealthOrgans organs_;
    SelfHealthConfig config_;
    std::function<double()> clock_;
    mutable std::mutex mtx_;
    SelfState cached_;
    std::thread loop_;
    std::atomic<bool> alive_{true};
    std::string last_distress_signature_;

    SelfState sample_();
    void loop_body_();
    void audit_if_distressed_(const SelfState& state);
    static std::string distress_signature_(const SelfState& state);
};

} // namespace jarvis::identity::self_health
