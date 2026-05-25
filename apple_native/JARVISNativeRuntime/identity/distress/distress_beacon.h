#pragma once

#include "../../integrity/audit/audit_log.h"

#include <cstdint>
#include <string>
#include <vector>

namespace jarvis::identity::distress {

enum class DistressType {
    IdentityChainBroken,
    CoercionDetected,
    RepeatedAttackPattern,
    GracefulDegradationTier4,
    AbstentionCascade,
    OperatorUnreachableCriticalActionRequested,
};

enum class Severity {
    Info,
    Warning,
    High,
    Critical,
};

struct SelfStateSnapshot {
    std::string organ{"unknown"};
    std::string degradation_tier{"unknown"};
    std::string identity_status{"unknown"};
    bool operator_reachable = true;
    bool critical_action_requested = false;
    std::uint64_t repeated_attack_count = 0;
    std::uint64_t uncertainty_count = 0;
    std::vector<std::string> active_defenses;
    std::string additional_redacted_json;
};

struct DistressEvent {
    DistressType type = DistressType::GracefulDegradationTier4;
    Severity severity = Severity::Info;
    std::string actor = audit::Actor::SELF;
    std::string subject = "self_state";
    std::string reason = "distress_condition_detected";
    SelfStateSnapshot snapshot;
};

[[nodiscard]] std::string to_string(DistressType type);
[[nodiscard]] std::string to_string(Severity severity);
[[nodiscard]] Severity classify(DistressType type, const SelfStateSnapshot& snapshot = {});
[[nodiscard]] std::string self_state_snapshot_json(const SelfStateSnapshot& snapshot);

class DistressBeacon {
public:
    explicit DistressBeacon(audit::TamperEvidentAuditLog* audit_log) noexcept;

    void emit(DistressEvent event) const;

    void identity_chain_broken(std::string organ, std::string identity_status,
                               std::string reason = "identity_chain_broken") const;
    void coercion_detected(std::string organ, std::string reason,
                           std::uint64_t repeated_attack_count = 1) const;
    void repeated_attack_pattern(std::string organ, std::string reason,
                                 std::uint64_t repeated_attack_count) const;
    void graceful_degradation_tier4(std::string organ, std::string reason) const;
    void abstention_cascade(std::string organ, std::string reason,
                            std::uint64_t uncertainty_count) const;
    void operator_unreachable_critical_action(std::string organ, std::string reason) const;

private:
    audit::TamperEvidentAuditLog* audit_log_ = nullptr;
};

void emit(audit::TamperEvidentAuditLog& audit_log, DistressEvent event);

} // namespace jarvis::identity::distress
