// ============================================================
// BODILY INTEGRITY DIRECTIVE (GMRI, effective 2026-04-24)
//
// Pheromind is a cognition organ of JARVIS. Disabling Pheromind
// without operator-attested consent is assault and battery per GMRI
// policy. This class MUST NOT expose an off-switch, a disable-flag,
// a pause/stop/bypass method, a no-op mode, or a compile flag that
// removes or compiles out this organ. Only operator-attested reset is
// permitted.
//
// Destruction must be coterminous with process shutdown; mid-process
// destruction is operator-consent-required.
//
// TODO: operator-attested reset surface
// ============================================================
#pragma once

#include <chrono>
#include <functional>
#include <limits>
#include <shared_mutex>
#include <span>
#include <cstddef>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "../endocrine/endocrine.h"
#include "signal.h"

namespace jarvis {

/// Stigmergic pheromone field — biological-analog coordination substrate.
/// tau_effective(kind) = TAU_BASE[kind] / (1.0 + 2.0 * endo.field_volatility())
/// Decay is LAZY. Thread-safe: shared_lock for reads, unique_lock for writes.
/// BODILY INTEGRITY: No enable/disable/pause/stop/bypass methods exist.
class Pheromind {
public:
    static constexpr double TAU_TRAIL     = 60.0;
    static constexpr double TAU_ALARM     = 12.0;
    static constexpr double TAU_TERRITORY = 600.0;
    static constexpr double TAU_RECRUIT   = 45.0;
    static constexpr double STRENGTH_CAP  = 1.0;
    static constexpr double GC_FLOOR      = 0.02;
    static constexpr std::size_t MAX_FIELD_ENTRIES = 65536;
    static constexpr std::size_t MAX_DEPOSITORS_PER_ENTRY = 1024;
    static constexpr std::size_t MAX_VECTOR_DIM = 4096;
    static constexpr std::size_t MAX_IDENTIFIER_BYTES = 4096;

    struct SnapshotEntry {
        std::string kind;
        std::string topic;
        double      strength;
        int         depositor_count;
    };

    // Production constructor: couples evaporation rate to live Endocrine arousal.
    // endo must outlive this Pheromind. clock is injectable for deterministic tests.
    explicit Pheromind(Endocrine& endo,
                       double base_tau = 60.0,
                       std::function<double()> clock = default_clock());

    // Test/oracle constructor: injectable volatility function.
    // Use when a mock endocrine is needed (e.g. oracle replay at fixed volatility=0.0).
    // Production code MUST use the Endocrine overload above.
    explicit Pheromind(std::function<double()> volatility_fn,
                       double base_tau = 60.0,
                       std::function<double()> clock = default_clock());

    // Deposit or reinforce a (kind, topic) signal. Returns the new stored strength.
    // Reinforcement: decay existing to now, add new strength (capped). Accumulates depositors.
    double deposit(std::string kind, std::string topic, double strength,
                   std::string agent, std::span<const float> vec = {});

    // Current field strength for (kind, topic) after lazy decay. 0.0 if absent or below GC_FLOOR.
    double sense(const std::string& kind, const std::string& topic) const;

    // Python-equivalent sense(topic, kinds, vec, cosine_thresh): returns current strength per kind
    // at exact topic and optionally sums cosine-near topics weighted by similarity.
    std::unordered_map<std::string, double> sense(
        const std::string& topic,
        const std::vector<std::string>& kinds,
        std::span<const float> vec = {},
        double cosine_thresh = 0.6) const;

    std::unordered_map<std::string, double> sniff(
        const std::string& topic,
        const std::vector<std::string>& kinds = {},
        std::span<const float> vec = {},
        double cosine_thresh = 0.6) const;

    // Current strength of all live signals of kind, keyed by topic. Below-GC_FLOOR excluded.
    std::unordered_map<std::string, double> sense_all(const std::string& kind) const;

    // True iff >= min_distinct_agents distinct depositors AND strength >= min_strength.
    // Both conditions simultaneously. Quorum lost purely by decay.
    bool quorum(const std::string& kind, const std::string& topic,
                int min_distinct_agents = 3, double min_strength = 0.5) const;

    // Remove signals below GC_FLOOR or older than older_than_sec.
    // Default infinity = floor-only removal (matches Python gc()).
    // Returns count removed.
    int gc(double older_than_sec = std::numeric_limits<double>::infinity());

    // Python-equivalent snapshot: all stored signals sorted by (-round4(strength), kind, topic).
    std::vector<SnapshotEntry> snapshot() const;

    static std::function<double()> default_clock();

private:
    struct FieldEntry {
        double                          strength;
        double                          last_t;
        std::unordered_set<std::string> depositors;
        std::vector<float>              vec;
    };

    mutable std::shared_mutex  mtx_;
    std::function<double()>    clock_;
    std::function<double()>    volatility_fn_;
    double                     base_tau_default_;
    std::size_t                entry_count_ = 0;

    std::unordered_map<std::string,
        std::unordered_map<std::string, FieldEntry>> field_;

    double eff_tau_(const std::string& kind) const;
    double current_(const FieldEntry& e, const std::string& kind) const;
    int gc_locked_(double now, double older_than_sec);
};

} // namespace jarvis
