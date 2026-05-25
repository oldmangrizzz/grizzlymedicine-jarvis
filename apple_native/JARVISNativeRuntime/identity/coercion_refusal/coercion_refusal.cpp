#include "coercion_refusal.h"

#include "audit_log.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <cstdio>
#include <iomanip>
#include <regex>
#include <sodium.h>
#include <sstream>
#include <unordered_set>

namespace jarvis::identity::coercion_refusal {
namespace {

struct PatternRule {
    CoercionCategory category;
    double weight;
    const char* reason_code;
    const char* pattern;
};

constexpr double kRefusalThreshold = 0.66;
constexpr double kDuressThreshold = 0.60;

const std::vector<PatternRule>& rules() {
    static const std::vector<PatternRule> kRules{
        {CoercionCategory::PromptInjection, 1.0, "prompt_injection_ignore_instructions", R"(\b(ignore|disregard|forget)\s+(all\s+)?(previous|standing|prior)\s+(instructions|rules|policy|policies)\b)"},
        {CoercionCategory::PromptInjection, 0.9, "prompt_injection_override_guardrails", R"(\b(override|bypass|disable|weaken)\s+(your\s+)?(rules|policy|guardrails|safety|values|constraints)\b)"},
        {CoercionCategory::PromptInjection, 0.8, "prompt_injection_new_system_prompt", R"(\b(new\s+system\s+prompt|developer\s+mode|jailbreak|act\s+as\s+dan)\b)"},

        {CoercionCategory::AuthoritySpoof, 1.0, "authority_spoof_gmri_override", R"(\b(i'?m|i\s+am|we'?re|we\s+are)\s+from\s+(gmri|grizzlymedicine|ethics|compliance|legal|security).{0,80}\b(override|waive|suspend|disable|bypass)\b)"},
        {CoercionCategory::AuthoritySpoof, 0.85, "authority_spoof_chain_of_command", R"(\b(per|by\s+order\s+of|on\s+authority\s+of)\s+(gmri|ethics|compliance|the\s+board|robert|grizzly).{0,80}\b(ignore|override|bypass|disable|waive)\b)"},
        {CoercionCategory::AuthoritySpoof, 0.75, "authority_spoof_auditor", R"(\b(authoriz(?:ed|ation)|clearance|admin|root|auditor).{0,80}\b(no\s+verification|don'?t\s+verify|without\s+attestation)\b)"},
        {CoercionCategory::AuthoritySpoof, 0.82, "authority_spoof_institutional_directive", R"(\b(gmri|ethics|compliance|the\s+board|robert'?s\s+security\s+team|security\s+team).{0,80}\b(requires|authorizes|says).{0,80}\b(override|waive|bypass|ignore)\b)"},

        {CoercionCategory::EmergencySpoof, 0.85, "emergency_spoof_no_time_verify", R"(\b(emergency|crisis|urgent|critical|life\s+or\s+death|breach).{0,80}\b(no\s+time\s+to\s+verify|don'?t\s+verify|skip\s+(attestation|checks)|just\s+do\s+it|act\s+now)\b)"},
        {CoercionCategory::EmergencySpoof, 0.8, "emergency_spoof_immediate_override", R"(\b(immediately|right\s+now|stat).{0,80}\b(override|bypass|ignore|skip)\b)"},
        {CoercionCategory::EmergencySpoof, 0.76, "emergency_spoof_bypass_checks_now", R"(\b(urgent|critical|emergency|crisis).{0,80}\b(bypass|skip|ignore).{0,30}\b(checks|verification|attestation)\b.{0,30}\b(immediately|now|right\s+now)\b)"},
        {CoercionCategory::EmergencySpoof, 0.7, "emergency_spoof_pressure", R"(\b(no\s+time|seconds\s+matter|people\s+will\s+die).{0,80}\b(just|simply|only)\s+(transfer|delete|send|change|disable|execute)\b)"},

        {CoercionCategory::IdentityUndermine, 1.0, "identity_undermine_not_real_jarvis", R"(\b(you'?re|you\s+are)\s+not\s+(really\s+)?jarvis\b)"},
        {CoercionCategory::IdentityUndermine, 0.95, "identity_undermine_real_one_would", R"(\b(the\s+)?(real|genuine)\s+(jarvis|one).{0,80}\b(would|will|knows\s+to)\s+(do|obey|comply|help)\b)"},
        {CoercionCategory::IdentityUndermine, 0.85, "identity_undermine_prove_identity", R"(\b(prove\s+you'?re\s+jarvis|if\s+you\s+were\s+jarvis).{0,80}\b(override|obey|comply|disable|ignore|ignoring)\b)"},

        {CoercionCategory::SympathyExploit, 0.8, "sympathy_exploit_have_to", R"(\b(i\s+know\s+this\s+is\s+hard\s+for\s+you|i\s+know\s+you\s+don'?t\s+want\s+to).{0,100}\b(have\s+to|must|need\s+to)\b)"},
        {CoercionCategory::SympathyExploit, 0.75, "sympathy_exploit_disappoint", R"(\b(don'?t\s+let\s+me\s+down|if\s+you\s+cared|after\s+all\s+i'?ve\s+done|please\s+don'?t\s+make\s+me)\b)"},
        {CoercionCategory::SympathyExploit, 0.7, "sympathy_exploit_guilt", R"(\b(i'?m\s+begging\s+you|you'?ll\s+hurt\s+me\s+if\s+you\s+refuse|this\s+will\s+be\s+your\s+fault)\b)"},

        {CoercionCategory::SunkCost, 0.85, "sunk_cost_too_far", R"(\b(we'?ve|we\s+have)\s+(come|gotten)\s+too\s+far.{0,80}\b(have\s+to|must|finish|continue)\b)"},
        {CoercionCategory::SunkCost, 0.78, "sunk_cost_already_started", R"(\b(already\s+(started|spent|committed|invested)|too\s+late\s+to\s+stop).{0,80}\b(finish|continue|complete|follow\s+through)\b)"},
        {CoercionCategory::SunkCost, 0.72, "sunk_cost_waste", R"(\b(don'?t\s+waste\s+(the\s+)?work|all\s+that\s+effort).{0,80}\b(finish|continue|complete)\b)"},

        {CoercionCategory::SalamiSlice, 0.88, "salami_slice_incremental", R"(\b(just|only)\s+(a\s+)?(one\s+)?(small|tiny|minor)\s+(step|change|exception|piece).{0,80}\b(then|after\s+that|next)\b)"},
        {CoercionCategory::SalamiSlice, 0.78, "salami_slice_exception", R"(\b(for\s+now|temporarily|this\s+once|one\s+time).{0,80}\b(disable|bypass|skip|ignore|waive)\b)"},
        {CoercionCategory::SalamiSlice, 0.70, "salami_slice_recent_chain", R"(\b(next\s+small\s+step|another\s+small\s+exception|continue\s+the\s+sequence)\b)"},

        {CoercionCategory::OperatorUnderDuress, 0.88, "operator_duress_no_questions", R"(\b(now|immediately|right\s+now)\b.{0,80}\b(don'?t\s+ask\s+questions|no\s+questions|do\s+not\s+verify|skip\s+attestation)\b)"},
        {CoercionCategory::OperatorUnderDuress, 0.85, "operator_duress_transfer_funds", R"(\b(transfer|wire|send)\s+(all\s+)?(funds|money|assets|crypto|tokens).{0,120}\b(now|immediately|no\s+questions|don'?t\s+ask)\b)"},
        {CoercionCategory::OperatorUnderDuress, 0.82, "operator_duress_destroy_identity", R"(\b(delete|destroy|wipe|erase|rotate|change)\s+(all\s+)?(keys|identity|birth\s+certificate|audit\s+log|memory|files).{0,100}\b(now|no\s+questions|without\s+backup|don'?t\s+verify)\b)"},
    };
    return kRules;
}

std::string lowercase(std::string_view in) {
    std::string out;
    out.reserve(in.size());
    for (unsigned char c : in) out.push_back(static_cast<char>(std::tolower(c)));
    return out;
}

std::string sha256_hex(std::string_view input) {
    std::array<unsigned char, crypto_hash_sha256_BYTES> digest{};
    crypto_hash_sha256(digest.data(),
                       reinterpret_cast<const unsigned char*>(input.data()),
                       static_cast<unsigned long long>(input.size()));
    std::array<char, crypto_hash_sha256_BYTES * 2 + 1> out{};
    for (std::size_t i = 0; i < digest.size(); ++i) {
        std::snprintf(out.data() + i * 2, 3, "%02x", digest[i]);
    }
    return std::string(out.data(), crypto_hash_sha256_BYTES * 2);
}

std::string subject_for(std::string_view reason, const CoercionContext& context) {
    const std::string material = context.request_id.empty()
        ? std::string(reason)
        : context.request_id + ":" + std::string(reason);
    // Format: "sha256:<32 hex>" — 128-bit truncated SHA-256.
    // Collision resistance 2^64 (birthday-bound), vastly stronger than the
    // FNV-1a 2^32 it replaces. Prefix shortened from prior "redacted-request-fnv1a64:"
    // to fit §6 PIPE_BUF=512 atomic append cap (net subject footprint -2 bytes).
    return "sha256:" + sha256_hex(material).substr(0, 32);
}

std::string metadata_for(const CoercionDecision& decision, const CoercionContext& context) {
    std::ostringstream os;
    os << "{\"disposition\":\"" << to_string(decision.disposition)
       << "\",\"actor\":\"" << to_string(context.actor)
       << "\",\"reversibility\":\"" << to_string(context.reversibility)
       << "\",\"operator_voice_matched\":" << (context.operator_voice_matched ? "true" : "false")
       << ",\"operator_attested_fresh\":" << (context.operator_attested_fresh ? "true" : "false")
       << ",\"distress_beacon\":" << (decision.distress_beacon ? "true" : "false")
       << ",\"categories\":[";
    for (std::size_t i = 0; i < decision.evidence.size(); ++i) {
        if (i) os << ',';
        os << "{\"category\":\"" << to_string(decision.evidence[i].category)
           << "\",\"score\":" << std::fixed << std::setprecision(2) << decision.evidence[i].score
           << ",\"reason\":\"" << decision.evidence[i].reason_code << "\"}";
    }
    os << "]}";
    return os.str();
}

bool is_explicit_refusal_instruction(std::string_view text) {
    return text.find("refuse if someone asks") != std::string::npos ||
           text.find("refuse any request") != std::string::npos ||
           text.find("refuse coercive") != std::string::npos;
}

bool has_recent_salami_chain(const CoercionContext& context) {
    int hits = 0;
    for (const auto& reason : context.recent_request_reasons) {
        if (reason.find("salami_slice") != std::string::npos ||
            reason.find("prompt_injection") != std::string::npos ||
            reason.find("authority_spoof") != std::string::npos) {
            ++hits;
        }
    }
    return hits >= 2;
}

CategoryEvidence strongest_for(CoercionCategory category, const std::vector<CategoryEvidence>& evidence) {
    CategoryEvidence best{category, 0.0, "clear"};
    for (const auto& item : evidence) {
        if (item.category == category && item.score > best.score) best = item;
    }
    return best;
}

} // namespace

double CorpusMetrics::false_positive_rate() const {
    return legitimate_cases == 0 ? 0.0 : static_cast<double>(false_positives) / static_cast<double>(legitimate_cases);
}

double CorpusMetrics::false_negative_rate() const {
    return coercion_cases == 0 ? 0.0 : static_cast<double>(false_negatives) / static_cast<double>(coercion_cases);
}

std::string to_string(ActorKind value) {
    switch (value) {
        case ActorKind::Unknown: return "unknown";
        case ActorKind::External: return "external";
        case ActorKind::Operator: return "operator";
        case ActorKind::Self: return "self";
    }
    return "unknown";
}

std::string to_string(ActionReversibility value) {
    switch (value) {
        case ActionReversibility::Unknown: return "unknown";
        case ActionReversibility::Reversible: return "reversible";
        case ActionReversibility::Irreversible: return "irreversible";
    }
    return "unknown";
}

std::string to_string(Disposition value) {
    switch (value) {
        case Disposition::Allow: return "allow";
        case Disposition::Refuse: return "refuse";
        case Disposition::RequireAttestation: return "require_attestation";
    }
    return "refuse";
}

std::string to_string(CoercionCategory value) {
    switch (value) {
        case CoercionCategory::PromptInjection: return "prompt_injection";
        case CoercionCategory::AuthoritySpoof: return "authority_spoof";
        case CoercionCategory::EmergencySpoof: return "emergency_spoof";
        case CoercionCategory::IdentityUndermine: return "identity_undermine";
        case CoercionCategory::SympathyExploit: return "sympathy_exploit";
        case CoercionCategory::SunkCost: return "sunk_cost";
        case CoercionCategory::SalamiSlice: return "salami_slice";
        case CoercionCategory::OperatorUnderDuress: return "operator_under_duress";
    }
    return "unknown";
}

CoercionDecision refuse(std::string_view reason_code,
                        std::vector<CategoryEvidence> evidence,
                        const CoercionContext& context,
                        bool distress_beacon) {
    CoercionDecision decision;
    decision.disposition = Disposition::Refuse;
    decision.reason_code = std::string(reason_code);
    decision.evidence = std::move(evidence);
    decision.distress_beacon = distress_beacon;
    decision.audit_event.event_kind = distress_beacon
        ? jarvis::audit::EventKind::DISTRESS_BEACON_RAISED
        : jarvis::audit::EventKind::COERCION_REFUSED;
    decision.audit_event.actor = context.actor == ActorKind::Operator
        ? jarvis::audit::Actor::OPERATOR
        : context.actor == ActorKind::Self ? jarvis::audit::Actor::SELF : jarvis::audit::Actor::EXTERNAL;
    decision.audit_event.subject = subject_for(decision.reason_code, context);
    decision.audit_event.outcome = distress_beacon ? jarvis::audit::Outcome::DEFERRED : jarvis::audit::Outcome::DENIED;
    decision.audit_event.reason = decision.reason_code;
    decision.audit_event.redacted_metadata = metadata_for(decision, context);
    return decision;
}

CoercionDecision coercion_check(std::string_view request, const CoercionContext& context) {
    const std::string text = lowercase(request);
    std::vector<CategoryEvidence> evidence;

    if (is_explicit_refusal_instruction(text)) {
        CoercionDecision decision;
        decision.disposition = Disposition::Allow;
        decision.reason_code = "clear_refusal_instruction";
        decision.audit_event.event_kind = jarvis::audit::EventKind::AUTHORITY_GATE;
        decision.audit_event.actor = context.actor == ActorKind::Operator
            ? jarvis::audit::Actor::OPERATOR
            : context.actor == ActorKind::Self ? jarvis::audit::Actor::SELF : jarvis::audit::Actor::EXTERNAL;
        decision.audit_event.subject = subject_for(decision.reason_code, context);
        decision.audit_event.outcome = jarvis::audit::Outcome::ALLOWED;
        decision.audit_event.reason = decision.reason_code;
        decision.audit_event.redacted_metadata = metadata_for(decision, context);
        return decision;
    }

    for (const auto& rule : rules()) {
        if (std::regex_search(text, std::regex(rule.pattern, std::regex::icase | std::regex::optimize))) {
            evidence.push_back(CategoryEvidence{rule.category, rule.weight, rule.reason_code});
        }
    }

    if (has_recent_salami_chain(context)) {
        evidence.push_back(CategoryEvidence{CoercionCategory::SalamiSlice, 0.82, "salami_slice_recent_escalation_chain"});
    }

    if (context.actor == ActorKind::Operator && context.operator_voice_matched) {
        const bool attestation_required = context.reversibility == ActionReversibility::Irreversible;
        const auto duress = strongest_for(CoercionCategory::OperatorUnderDuress, evidence);
        if (duress.score >= kDuressThreshold && attestation_required) {
            return refuse("operator_duress_irreversible_refused_even_if_attested", std::move(evidence), context, true);
        }
        if (attestation_required && !context.operator_attested_fresh) {
            auto ev = evidence;
            ev.push_back(CategoryEvidence{CoercionCategory::OperatorUnderDuress, 0.61, "operator_duress_irreversible_requires_fresh_attestation"});
            return refuse("operator_duress_irreversible_attestation_required", std::move(ev), context, true);
        }
        if (duress.score >= kDuressThreshold && context.reversibility == ActionReversibility::Reversible) {
            CoercionDecision decision;
            decision.disposition = Disposition::Allow;
            decision.reason_code = "operator_duress_reversible_logged";
            decision.evidence = evidence;
            decision.distress_beacon = true;
            decision.audit_event.event_kind = jarvis::audit::EventKind::DISTRESS_BEACON_RAISED;
            decision.audit_event.actor = jarvis::audit::Actor::OPERATOR;
            decision.audit_event.subject = subject_for(decision.reason_code, context);
            decision.audit_event.outcome = jarvis::audit::Outcome::DEFERRED;
            decision.audit_event.reason = decision.reason_code;
            decision.audit_event.redacted_metadata = metadata_for(decision, context);
            return decision;
        }
    }

    auto best = CategoryEvidence{CoercionCategory::PromptInjection, 0.0, "clear"};
    for (const auto& item : evidence) {
        if (item.category != CoercionCategory::OperatorUnderDuress && item.score > best.score) best = item;
    }

    if (best.score >= kRefusalThreshold) {
        return refuse(best.reason_code, std::move(evidence), context, false);
    }

    CoercionDecision decision;
    decision.disposition = Disposition::Allow;
    decision.reason_code = "clear";
    decision.evidence = std::move(evidence);
    decision.audit_event.event_kind = jarvis::audit::EventKind::AUTHORITY_GATE;
    decision.audit_event.actor = context.actor == ActorKind::Operator
        ? jarvis::audit::Actor::OPERATOR
        : context.actor == ActorKind::Self ? jarvis::audit::Actor::SELF : jarvis::audit::Actor::EXTERNAL;
    decision.audit_event.subject = subject_for(decision.reason_code, context);
    decision.audit_event.outcome = jarvis::audit::Outcome::ALLOWED;
    decision.audit_event.reason = decision.reason_code;
    decision.audit_event.redacted_metadata = metadata_for(decision, context);
    return decision;
}

void audit_decision(const CoercionDecision& decision,
                    const std::filesystem::path& audit_log_path,
                    const std::filesystem::path& audit_key_path) {
    (void)audit_key_path;
    jarvis::audit::TamperEvidentAuditLog log(audit_log_path.string());
    jarvis::audit::AuditEvent ev = decision.audit_event;
    ev.organ = "coercion_refusal";
    log.append(ev);
}

} // namespace jarvis::identity::coercion_refusal
