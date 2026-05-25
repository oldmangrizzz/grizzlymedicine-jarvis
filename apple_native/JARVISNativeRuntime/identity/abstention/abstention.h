#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "../../holograph/beliefstore/beliefstore.h"
#include "../../holograph/hdc/hdc.h"
#include "../../holograph/hdc/hdc_hierarchy.h"
#include "../../swarm/swarm.h"

namespace jarvis::abstention {

enum class AbstentionState { Confident, Uncertain, Refuse };

struct Abstention {
    AbstentionState state = AbstentionState::Uncertain;
    std::string reason;
    double confidence = 0.0;

    bool confident() const noexcept { return state == AbstentionState::Confident; }
    bool uncertain() const noexcept { return state == AbstentionState::Uncertain; }
    bool refused() const noexcept { return state == AbstentionState::Refuse; }
};

template <typename T>
struct CognitiveOutcome {
    std::optional<T> value;
    Abstention abstention;

    bool has_value() const noexcept { return value.has_value() && abstention.confident(); }
};

struct CandidateMatch {
    std::string label;
    double similarity = 0.0;
};

struct SimilarityCandidate {
    std::string label;
    std::vector<std::uint8_t> hv_blob;
};

struct HdcThresholds {
    static constexpr double DEFAULT_SIMILARITY_FLOOR = 0.35;
};

std::string to_string(AbstentionState state);
Abstention confident(double confidence, std::string reason = "confidence threshold cleared");
Abstention uncertain(double confidence, std::string reason);
Abstention refuse(double confidence, std::string reason);
std::string operator_display(const std::string& subject, const Abstention& abstention);

Abstention from_belief_query(const jarvis::QueryResult& result);
CognitiveOutcome<std::string> belief_outcome(const jarvis::QueryResult& result);

Abstention from_swarm_result(const jarvis::SwarmResult& result);
CognitiveOutcome<std::string> swarm_outcome(const jarvis::SwarmResult& result);

Abstention from_hdc_similarity(double similarity,
                               double threshold = HdcThresholds::DEFAULT_SIMILARITY_FLOOR,
                               std::string reason_prefix = "HDC similarity");
CognitiveOutcome<CandidateMatch> nearest_above_threshold(
    hdc::HDCKernel& kernel,
    std::span<const std::uint8_t> query,
    const std::vector<SimilarityCandidate>& candidates,
    double threshold = HdcThresholds::DEFAULT_SIMILARITY_FLOOR);

Abstention from_hdc_route(const hdc::RouteResult& route,
                          double best_similarity,
                          double threshold = HdcThresholds::DEFAULT_SIMILARITY_FLOOR);

} // namespace jarvis::abstention
