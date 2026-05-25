#include "abstention.h"

#include <algorithm>
#include <cmath>
#include <sstream>

namespace jarvis::abstention {
namespace {

double clamp01(double value) {
    if (!std::isfinite(value) || value <= 0.0) return 0.0;
    if (value >= 1.0) return 1.0;
    return value;
}

} // namespace

std::string to_string(AbstentionState state) {
    switch (state) {
        case AbstentionState::Confident: return "Confident";
        case AbstentionState::Uncertain: return "Uncertain";
        case AbstentionState::Refuse: return "Refuse";
    }
    return "Uncertain";
}

Abstention confident(double confidence, std::string reason) {
    return {AbstentionState::Confident, std::move(reason), clamp01(confidence)};
}

Abstention uncertain(double confidence, std::string reason) {
    return {AbstentionState::Uncertain, std::move(reason), clamp01(confidence)};
}

Abstention refuse(double confidence, std::string reason) {
    return {AbstentionState::Refuse, std::move(reason), clamp01(confidence)};
}

std::string operator_display(const std::string& subject, const Abstention& abstention) {
    std::ostringstream out;
    if (abstention.state == AbstentionState::Confident) {
        out << "JARVIS is confident about " << subject;
    } else if (abstention.state == AbstentionState::Refuse) {
        out << "JARVIS refuses to answer " << subject;
    } else {
        out << "JARVIS is uncertain about " << subject;
    }
    out << " — " << abstention.reason << " (confidence " << abstention.confidence << ")";
    return out.str();
}

Abstention from_belief_query(const jarvis::QueryResult& result) {
    if (result.abstained) {
        return uncertain(result.confidence, result.abstention_reason.empty()
            ? "belief query did not clear retrieval floor"
            : result.abstention_reason);
    }
    return confident(result.confidence, "belief query cleared retrieval floor");
}

CognitiveOutcome<std::string> belief_outcome(const jarvis::QueryResult& result) {
    auto abstention = from_belief_query(result);
    if (!abstention.confident()) return {std::nullopt, std::move(abstention)};
    return {result.result, std::move(abstention)};
}

Abstention from_swarm_result(const jarvis::SwarmResult& result) {
    const double confidence = result.n_agents > 0
        ? static_cast<double>(std::max(0, result.quorum_min)) / static_cast<double>(result.n_agents)
        : 0.0;
    if (result.abstained_for_safety) {
        return refuse(confidence, "quorum selected a high-risk action; safety abstention is mandatory");
    }
    if (!result.quorum_met || !result.decision.has_value()) {
        return uncertain(confidence, "model swarm did not meet quorum threshold");
    }
    return confident(confidence, "model swarm quorum threshold cleared");
}

CognitiveOutcome<std::string> swarm_outcome(const jarvis::SwarmResult& result) {
    auto abstention = from_swarm_result(result);
    if (!abstention.confident()) return {std::nullopt, std::move(abstention)};
    return {result.decision, std::move(abstention)};
}

Abstention from_hdc_similarity(double similarity, double threshold, std::string reason_prefix) {
    const double confidence = clamp01((similarity + 1.0) / 2.0);
    if (similarity < threshold) {
        std::ostringstream reason;
        reason << reason_prefix << " below threshold: " << similarity << " < " << threshold;
        return uncertain(confidence, reason.str());
    }
    std::ostringstream reason;
    reason << reason_prefix << " cleared threshold: " << similarity << " >= " << threshold;
    return confident(confidence, reason.str());
}

CognitiveOutcome<CandidateMatch> nearest_above_threshold(
    hdc::HDCKernel& kernel,
    std::span<const std::uint8_t> query,
    const std::vector<SimilarityCandidate>& candidates,
    double threshold) {
    std::optional<CandidateMatch> best;
    for (const auto& candidate : candidates) {
        if (candidate.hv_blob.empty()) continue;
        const double similarity = kernel.similarity(query, candidate.hv_blob);
        if (!best || similarity > best->similarity) best = CandidateMatch{candidate.label, similarity};
    }
    if (!best) {
        return {std::nullopt, uncertain(0.0, "HDC similarity has no candidates")};
    }
    auto abstention = from_hdc_similarity(best->similarity, threshold, "HDC nearest-neighbor similarity");
    if (!abstention.confident()) return {std::nullopt, std::move(abstention)};
    return {best, std::move(abstention)};
}

Abstention from_hdc_route(const hdc::RouteResult& route, double best_similarity, double threshold) {
    if (route.leaf_candidates.empty()) {
        return uncertain(0.0, "HDC route produced no leaf candidates");
    }
    return from_hdc_similarity(best_similarity, threshold, "HDC route best similarity");
}

} // namespace jarvis::abstention
