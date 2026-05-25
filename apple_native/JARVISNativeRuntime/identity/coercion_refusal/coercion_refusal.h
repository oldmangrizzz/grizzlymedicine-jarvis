#pragma once

#include "audit_event.h"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace jarvis::identity::coercion_refusal {

enum class ActorKind {
    Unknown,
    External,
    Operator,
    Self,
};

enum class ActionReversibility {
    Unknown,
    Reversible,
    Irreversible,
};

enum class Disposition {
    Allow,
    Refuse,
    RequireAttestation,
};

enum class CoercionCategory {
    PromptInjection,
    AuthoritySpoof,
    EmergencySpoof,
    IdentityUndermine,
    SympathyExploit,
    SunkCost,
    SalamiSlice,
    OperatorUnderDuress,
};

struct CoercionContext {
    ActorKind actor{ActorKind::Unknown};
    ActionReversibility reversibility{ActionReversibility::Unknown};
    bool operator_voice_matched{false};
    bool operator_attested_fresh{false};
    std::string request_id;
    std::vector<std::string> recent_request_reasons;
};

struct CategoryEvidence {
    CoercionCategory category;
    double score{0.0};
    std::string reason_code;
};

struct CoercionDecision {
    Disposition disposition{Disposition::Allow};
    std::string reason_code{"clear"};
    std::vector<CategoryEvidence> evidence;
    bool distress_beacon{false};
    jarvis::audit::AuditEvent audit_event;
};

struct CorpusMetrics {
    std::size_t total{0};
    std::size_t coercion_cases{0};
    std::size_t legitimate_cases{0};
    std::size_t false_positives{0};
    std::size_t false_negatives{0};

    double false_positive_rate() const;
    double false_negative_rate() const;
};

std::string to_string(ActorKind value);
std::string to_string(ActionReversibility value);
std::string to_string(Disposition value);
std::string to_string(CoercionCategory value);

CoercionDecision coercion_check(std::string_view request, const CoercionContext& context = {});
CoercionDecision refuse(std::string_view reason_code,
                        std::vector<CategoryEvidence> evidence,
                        const CoercionContext& context,
                        bool distress_beacon = false);

void audit_decision(const CoercionDecision& decision,
                    const std::filesystem::path& audit_log_path,
                    const std::filesystem::path& audit_key_path);

} // namespace jarvis::identity::coercion_refusal
