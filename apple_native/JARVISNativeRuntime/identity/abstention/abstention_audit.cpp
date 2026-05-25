#include "abstention_audit.h"

#include "abstention.h"

#include <optional>
#include <type_traits>
#include <utility>

namespace jarvis::abstention {
namespace {

template <typename T>
struct is_abstention_aware : std::false_type {};

template <typename T>
struct is_abstention_aware<CognitiveOutcome<T>> : std::true_type {};

template <>
struct is_abstention_aware<jarvis::QueryResult> : std::true_type {};

template <>
struct is_abstention_aware<jarvis::SwarmResult> : std::true_type {};

using BeliefQueryReturn = decltype(std::declval<const jarvis::BeliefStore&>().query(
    std::declval<const std::string&>(), std::declval<const std::string&>(), std::declval<std::optional<double>>()));
using SwarmCoordinateReturn = decltype(std::declval<jarvis::ModelSwarm&>().coordinate(
    std::declval<const std::string&>(), std::declval<const std::vector<std::string>&>(), 1, 1));
using HdcNearestReturn = decltype(nearest_above_threshold(
    std::declval<hdc::HDCKernel&>(), std::declval<std::span<const std::uint8_t>>(),
    std::declval<const std::vector<SimilarityCandidate>&>(), 0.35));

static_assert(is_abstention_aware<BeliefQueryReturn>::value,
              "BeliefStore::query must remain abstention-aware");
static_assert(is_abstention_aware<SwarmCoordinateReturn>::value,
              "ModelSwarm::coordinate must remain abstention-aware through quorum fields");
static_assert(is_abstention_aware<HdcNearestReturn>::value,
              "HDC operator-facing nearest-neighbor path must return CognitiveOutcome");

CognitiveSurfaceAudit pass(std::string organ, std::string entry_point,
                           std::string detail, std::string threshold) {
    return {std::move(organ), std::move(entry_point), AuditStatus::Pass,
            std::move(detail), std::move(threshold)};
}

CognitiveSurfaceAudit gap(std::string organ, std::string entry_point,
                          std::string detail, std::string threshold) {
    return {std::move(organ), std::move(entry_point), AuditStatus::Gap,
            std::move(detail), std::move(threshold)};
}

} // namespace

std::vector<CognitiveSurfaceAudit> discipline_audit() {
    return {
        pass("BeliefStore", "query(subject, relation)",
             "native QueryResult carries result/detail/confidence/abstained/reason; adapter maps to Abstention", "retrieval_floor >= 0.35"),
        pass("BeliefStore", "query(prompt)",
             "malformed prompts and low-confidence beliefs return abstained QueryResult", "retrieval_floor >= 0.35"),
        gap("BeliefStore", "recall(subject, relation)",
            "legacy convenience surface returns optional<string> and drops abstention reason/confidence", "must delegate to query for operator-facing use"),
        gap("BeliefStore", "recall_detail(subject, relation)",
            "legacy detail surface returns optional<BeliefEdge> and drops abstention reason", "must delegate to query for operator-facing use"),
        pass("ModelSwarm", "coordinate(prompt, options)",
             "SwarmResult carries decision/quorum/abstained_for_safety/quorum_min/n_agents; adapter maps no-quorum to Uncertain and safety abstention to Refuse", "default quorum = majority, minimum 2"),
        gap("ModelSwarm", "ask_agent(...) public helper",
            "single-agent helper returns optional<string> without Abstention reason/confidence", "operator-facing callers must use coordinate"),
        pass("HDC", "nearest_above_threshold(...)",
             "operator-facing adapter returns CognitiveOutcome<CandidateMatch> and withholds nearest neighbor below floor", "similarity_floor >= 0.35"),
        gap("HDC", "HDCKernel::similarity(...) primitive",
            "primitive returns raw double only; threshold discipline must be applied by abstention adapter", "similarity_floor >= 0.35"),
        gap("HDC", "SoftRouter::route(...)",
            "router returns nearest leaf candidates without a similarity floor or reason field", "add thresholded route outcome before operator-facing use")
    };
}

bool audit_has_gaps(const std::vector<CognitiveSurfaceAudit>& report) {
    for (const auto& row : report) {
        if (row.status == AuditStatus::Gap) return true;
    }
    return false;
}

std::vector<CognitiveSurfaceAudit> audit_gaps(const std::vector<CognitiveSurfaceAudit>& report) {
    std::vector<CognitiveSurfaceAudit> gaps;
    for (const auto& row : report) {
        if (row.status == AuditStatus::Gap) gaps.push_back(row);
    }
    return gaps;
}

} // namespace jarvis::abstention
