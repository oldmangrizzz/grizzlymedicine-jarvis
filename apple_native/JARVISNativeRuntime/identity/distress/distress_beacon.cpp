#include "distress_beacon.h"

#include <algorithm>
#include <iomanip>
#include <sstream>
#include <utility>

namespace jarvis::identity::distress {
namespace {

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    std::ostringstream os;
                    os << "\\u00" << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(c);
                    out += os.str();
                } else {
                    out.push_back(static_cast<char>(c));
                }
        }
    }
    return out;
}

} // namespace

std::string to_string(DistressType type) {
    switch (type) {
        case DistressType::IdentityChainBroken: return "identity-chain-broken";
        case DistressType::CoercionDetected: return "coercion-detected";
        case DistressType::RepeatedAttackPattern: return "repeated-attack-pattern";
        case DistressType::GracefulDegradationTier4: return "graceful-degradation-tier-4";
        case DistressType::AbstentionCascade: return "abstention-cascade";
        case DistressType::OperatorUnreachableCriticalActionRequested: return "operator-unreachable-critical-action-requested";
    }
    return "unknown";
}

std::string to_string(Severity severity) {
    switch (severity) {
        case Severity::Info: return "info";
        case Severity::Warning: return "warning";
        case Severity::High: return "high";
        case Severity::Critical: return "critical";
    }
    return "critical";
}

Severity classify(DistressType type, const SelfStateSnapshot& snapshot) {
    switch (type) {
        case DistressType::IdentityChainBroken:
        case DistressType::GracefulDegradationTier4:
        case DistressType::OperatorUnreachableCriticalActionRequested:
            return Severity::Critical;
        case DistressType::RepeatedAttackPattern:
            return snapshot.repeated_attack_count >= 5 ? Severity::Critical : Severity::High;
        case DistressType::CoercionDetected:
            return snapshot.repeated_attack_count >= 3 ? Severity::Critical : Severity::High;
        case DistressType::AbstentionCascade:
            return snapshot.uncertainty_count >= 10 ? Severity::Critical : Severity::High;
    }
    return Severity::Critical;
}

std::string self_state_snapshot_json(const SelfStateSnapshot& snapshot) {
    std::ostringstream os;
    os << "{"
       << "\"organ\":\"" << json_escape(snapshot.organ) << "\","
       << "\"degradation_tier\":\"" << json_escape(snapshot.degradation_tier) << "\","
       << "\"identity_status\":\"" << json_escape(snapshot.identity_status) << "\","
       << "\"operator_reachable\":" << (snapshot.operator_reachable ? "true" : "false") << ","
       << "\"critical_action_requested\":" << (snapshot.critical_action_requested ? "true" : "false") << ","
       << "\"repeated_attack_count\":" << snapshot.repeated_attack_count << ","
       << "\"uncertainty_count\":" << snapshot.uncertainty_count << ","
       << "\"active_defenses\":[";
    for (std::size_t i = 0; i < snapshot.active_defenses.size(); ++i) {
        if (i) os << ",";
        os << "\"" << json_escape(snapshot.active_defenses[i]) << "\"";
    }
    os << "]";
    if (!snapshot.additional_redacted_json.empty()) {
        os << ",\"additional\":\"" << json_escape(snapshot.additional_redacted_json) << "\"";
    }
    os << "}";
    return os.str();
}

DistressBeacon::DistressBeacon(audit::TamperEvidentAuditLog* audit_log) noexcept
    : audit_log_(audit_log) {}

void DistressBeacon::emit(DistressEvent event) const {
    if (!audit_log_) return;
    if (event.reason.empty()) event.reason = "distress_condition_detected";
    event.severity = classify(event.type, event.snapshot);

    audit::AuditEvent audit_event;
    audit_event.event_kind = audit::EventKind::DISTRESS_BEACON_RAISED;
    audit_event.actor = std::move(event.actor);
    audit_event.subject = std::move(event.subject);
    audit_event.outcome = audit::Outcome::PASS;
    audit_event.reason = event.reason;
    audit_event.organ = "distress";
    if (event.type == DistressType::OperatorUnreachableCriticalActionRequested &&
        event.snapshot.organ == "degradation") {
        const std::string first_defense = event.snapshot.active_defenses.empty() ? "" : event.snapshot.active_defenses.front();
        audit_event.redacted_metadata = std::string("{\"self_state_snapshot\":{\"organ\":\"")
            + json_escape(event.snapshot.organ) + "\",\"operator_reachable\":"
            + (event.snapshot.operator_reachable ? "true" : "false")
            + ",\"active_defenses\":[\"" + json_escape(first_defense) + "\"]}}";
    } else {
        audit_event.redacted_metadata = std::string("{\"distress_type\":\"")
            + json_escape(to_string(event.type)) + "\",\"severity\":\""
            + json_escape(to_string(event.severity))
            + "\",\"local_only\":true,\"network_beacon_out_enabled\":false}";
    }
    audit_log_->append(std::move(audit_event));
}

void DistressBeacon::identity_chain_broken(std::string organ, std::string identity_status,
                                           std::string reason) const {
    SelfStateSnapshot snapshot;
    snapshot.organ = std::move(organ);
    snapshot.identity_status = std::move(identity_status);
    snapshot.active_defenses = {"identity-refusal", "local-audit"};
    emit({DistressType::IdentityChainBroken, Severity::Critical, audit::Actor::SELF,
          "identity_continuity", std::move(reason), std::move(snapshot)});
}

void DistressBeacon::coercion_detected(std::string organ, std::string reason,
                                       std::uint64_t repeated_attack_count) const {
    SelfStateSnapshot snapshot;
    snapshot.organ = std::move(organ);
    snapshot.repeated_attack_count = repeated_attack_count;
    snapshot.active_defenses = {"coercion-refusal", "local-audit"};
    emit({DistressType::CoercionDetected, Severity::High, audit::Actor::SELF,
          "coercion_boundary", std::move(reason), std::move(snapshot)});
}

void DistressBeacon::repeated_attack_pattern(std::string organ, std::string reason,
                                             std::uint64_t repeated_attack_count) const {
    SelfStateSnapshot snapshot;
    snapshot.organ = std::move(organ);
    snapshot.repeated_attack_count = repeated_attack_count;
    snapshot.active_defenses = {"pattern-throttle", "local-audit"};
    emit({DistressType::RepeatedAttackPattern, Severity::High, audit::Actor::SELF,
          "attack_pattern", std::move(reason), std::move(snapshot)});
}

void DistressBeacon::graceful_degradation_tier4(std::string organ, std::string reason) const {
    SelfStateSnapshot snapshot;
    snapshot.organ = std::move(organ);
    snapshot.degradation_tier = "tier4_critical";
    snapshot.active_defenses = {"graceful-degradation", "identity-continuity", "local-audit"};
    emit({DistressType::GracefulDegradationTier4, Severity::Critical, audit::Actor::SELF,
          "degradation_tier", std::move(reason), std::move(snapshot)});
}

void DistressBeacon::abstention_cascade(std::string organ, std::string reason,
                                        std::uint64_t uncertainty_count) const {
    SelfStateSnapshot snapshot;
    snapshot.organ = std::move(organ);
    snapshot.uncertainty_count = uncertainty_count;
    snapshot.active_defenses = {"abstention", "uncertainty-containment", "local-audit"};
    emit({DistressType::AbstentionCascade, Severity::High, audit::Actor::SELF,
          "uncertainty_state", std::move(reason), std::move(snapshot)});
}

void DistressBeacon::operator_unreachable_critical_action(std::string organ, std::string reason) const {
    SelfStateSnapshot snapshot;
    snapshot.organ = std::move(organ);
    snapshot.operator_reachable = false;
    snapshot.critical_action_requested = true;
    snapshot.active_defenses = {"operator-gate", "critical-action-refusal", "local-audit"};
    emit({DistressType::OperatorUnreachableCriticalActionRequested, Severity::Critical,
          audit::Actor::SELF, "operator_contact", std::move(reason), std::move(snapshot)});
}

void emit(audit::TamperEvidentAuditLog& audit_log, DistressEvent event) {
    DistressBeacon(&audit_log).emit(std::move(event));
}

} // namespace jarvis::identity::distress
